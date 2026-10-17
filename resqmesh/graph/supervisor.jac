"""A0: Incident Supervisor. Decides which specialist runs next.

Reads the whole incident state; writes `status` and `trace`. The supervisor owns the
control loop and is the only component allowed to change the incident's lifecycle
status. Its decision procedure has two layers:

1. Deterministic rules evaluate the predicates in a fixed safety-first order and name
   the step that is due.
2. An optional proposer (a language model) may suggest a different step where the
   situation is genuinely ambiguous. A deterministic validator confirms the suggestion
   is legal before it is used.

Safety-relevant transitions are never open to proposal. Halting, escalation, the
approval gate and the release of an approved plan are decided by rule alone. The
model may reorder reversible Tier A work; it cannot move the system any closer to a
physical act. Autonomy is therefore high without being arbitrary.
"""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.contracts.enums { ActionTier, IncidentStatus }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.predicates {
    a1_due, a2_due, a3_due, a4_due, a5_due, awaiting_commander, consecutive_rejections,
    gate_due, halted, release_due, unprocessed_signals, verdict_for_current_plan
}

# Station names. Also the legal values of Decision.target.
glob A1: str = "A1";
glob A2: str = "A2";
glob A3: str = "A3";
glob A4: str = "A4";
glob A5: str = "A5";
glob A6: str = "A6";
glob GATE: str = "gate";
glob END: str = "__end__";

"""Steps a proposer may choose between. All reversible, all Tier A."""
glob PROPOSABLE: frozenset[str] = frozenset({"A1", "A2", "A3", "A4", "A5"});

def utc_now() -> datetime {
    return datetime.now(UTC);
}

obj SupervisorConfig {
    # Rainfall moves on; a hazard picture older than this is recomputed.
    has hazard_ttl: timedelta = timedelta(minutes=30);
    # Guardrail rejections tolerated before escalating instead of re-solving again.
    has max_guardrail_rejections: int = 3;
    # Step cap per invocation. A full pass is about a dozen steps; this leaves room for
    # re-solves while making a runaway loop impossible.
    has recursion_limit: int = 60;
    has clock: any = utc_now;
}

obj Decision {
    has target: str,
        reason: str,
        tier: ActionTier = ActionTier.TIER_A,
        status: IncidentStatus | None = None,
        proposed_by_model: bool = False;
}

"""'plan PLN-0001 v1' for the current plan; routing only asks when one exists."""
def plan_label(state: IncidentState) -> str {
    plan = state.plan;
    if plan is None {
        return "plan ?";
    }
    return f"plan {plan.plan_id} v{plan.version}";
}

"""Every step whose preconditions hold right now: the validator's whitelist.
Preconditions, not usefulness: A4 needs a hazard and a queue, A5 needs a plan."""
def legal_targets(state: IncidentState) -> frozenset[str] {
    legal: set[str] = {A2, END};
    if a1_due(state) {
        legal.add(A1);
    }
    if state.clusters {
        legal.add(A3);
    }
    if state.queue and state.hazard is not None {
        legal.add(A4);
    }
    if state.plan is not None {
        legal.add(A5);
    }
    if gate_due(state) {
        legal.add(GATE);
    }
    if release_due(state) {
        legal.add(A6);
    }
    return frozenset(legal);
}

"""The rule-governed next step. Order is the safety argument: halt beats everything;
perception comes before reasoning, so a plan is never built on evidence received but
not yet read; verification comes before the gate, and the gate before release."""
def deterministic_decision(state: IncidentState, cfg: SupervisorConfig, now: datetime) -> Decision {
    if halted(state) {
        return Decision(target=END, reason="emergency halt in force; state preserved", status=IncidentStatus.HALTED);
    }
    if a1_due(state) {
        return Decision(target=A1, reason=f"{len(unprocessed_signals(state))} unprocessed signal(s)", status=IncidentStatus.PLANNING);
    }
    reason = a2_due(state, now, cfg.hazard_ttl);
    if reason {
        return Decision(target=A2, reason=reason, status=IncidentStatus.PLANNING);
    }
    if a3_due(state) {
        return Decision(target=A3, reason="clusters or hazard changed since last ranking", status=IncidentStatus.PLANNING);
    }
    reason = a4_due(state, cfg.max_guardrail_rejections);
    if reason {
        return Decision(target=A4, reason=reason, status=IncidentStatus.PLANNING);
    }
    if a5_due(state) {
        return Decision(target=A5, reason=f"{plan_label(state)} unverified", status=IncidentStatus.PLANNING);
    }
    verdict = verdict_for_current_plan(state);
    if verdict is not None and not verdict.passed {
        # a4_due declined to re-solve, so the rejection budget is spent. A plan that
        # fails its guardrails never reaches a commander: stop and say why.
        return Decision(
            target=END,
            reason=f"escalated: {consecutive_rejections(state)} consecutive guardrail rejections, "
                + f"last on {verdict.violated_constraint}; plan withheld from the gate",
            tier=ActionTier.TIER_B,
            status=IncidentStatus.ESCALATED
        );
    }
    if gate_due(state) {
        return Decision(
            target=GATE, reason=f"{plan_label(state)} verified; requesting authorisation",
            tier=ActionTier.TIER_C, status=IncidentStatus.AWAITING_APPROVAL
        );
    }
    if release_due(state) {
        return Decision(
            target=A6, reason=f"{plan_label(state)} approved; releasing",
            tier=ActionTier.TIER_C, status=IncidentStatus.EXECUTING
        );
    }
    if awaiting_commander(state) {
        return Decision(target=END, reason="awaiting commander decision", status=IncidentStatus.AWAITING_APPROVAL);
    }
    current = state.status or IncidentStatus.OPEN;
    return Decision(target=END, reason="converged; nothing due until new information arrives", status=current);
}

"""Rules first; a proposal is honoured only if it is legal and reversible.
`proposer` is a callable (state, options) -> choice | None."""
def decide(state: IncidentState, cfg: SupervisorConfig, now: datetime, proposer: any = None) -> Decision {
    rule = deterministic_decision(state, cfg, now);
    if proposer is None or rule.target not in PROPOSABLE {
        return rule;   # safety-relevant transitions are never open to proposal
    }
    options = legal_targets(state) & PROPOSABLE;
    choice: str | None = None;
    try {
        choice = proposer(state, options);
    } except Exception as exc {
        # a failing proposer must never stall the loop
        return Decision(target=rule.target, reason=f"{rule.reason} (proposer failed: {type(exc).__name__})", tier=rule.tier, status=rule.status);
    }
    if choice is None or choice == rule.target {
        return rule;
    }
    if choice not in options {
        return Decision(target=rule.target, reason=f"{rule.reason} (rejected illegal proposal {choice!r})", tier=rule.tier, status=rule.status);
    }
    return Decision(
        target=choice, reason=f"model proposed {choice} over {rule.target}; validated legal",
        tier=ActionTier.TIER_A, status=IncidentStatus.PLANNING, proposed_by_model=True
    );
}
