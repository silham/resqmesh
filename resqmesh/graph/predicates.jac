"""Pure predicates over incident state. No I/O, no model.

The supervisor delegates by evaluating these rather than by open-ended reasoning
about what might be useful next. Keeping them pure is what makes routing testable,
replayable and explainable: given a state, the next step is a function of that state.

Staleness is read from the order of events in `trace`. The audit trail is append-only
and every specialist writes one event per run, so "has A3 run since A1 last changed
the clusters?" is a comparison of two positions in that list. The audit log doubles
as the dependency tracker: no extra bookkeeping field, and no way for the two to
disagree.
"""

import from datetime { datetime, timedelta }
import from resqmesh.contracts.enums { ApprovalDecision, HazardType, IncidentStatus }
import from resqmesh.contracts.models {
    ApprovalRecord, DispatchPlan, GuardrailVerdict, RawSignal, TraceEvent
}
import from resqmesh.contracts.state { IncidentState }

# Actions each station writes into the trace.
glob A5_VERIFIED: str = "plan_verified";
glob A5_REJECTED: str = "plan_rejected";
glob GATE_REQUESTED: str = "approval_requested";
glob APPROVAL_RECEIVED: str = "approval_received";
glob RELEASED: str = "dispatch_released";
"""Written when an operator places a held report."""
glob REPORT_PLACED: str = "report_placed";
"""Written when a crew hands a dispatch back."""
glob RESPONDER_DECLINED: str = "responder_declined";

"""Position of the most recent matching event, or -1 if there is none."""
def last_index(trace: list[TraceEvent], agent: str, action: str | None = None) -> int {
    i = len(trace) - 1;
    while i >= 0 {
        e = trace[i];
        if e.agent == agent and (action is None or e.action == action) {
            return i;
        }
        i -= 1;
    }
    return -1;
}

def trace_of(state: IncidentState) -> list[TraceEvent] {
    return list(state.trace or []);
}

"""Signals with no report yet."""
def unprocessed_signals(state: IncidentState) -> list[RawSignal] {
    done = {r.signal_id for r in state.reports or []};
    return [s for s in state.raw_signals or [] if s.signal_id not in done];
}

# ------------------------------------------------ plan / verdict / approval relationships

"""The verdict only counts if it was issued on this plan generation."""
def verdict_for_current_plan(state: IncidentState) -> GuardrailVerdict | None {
    plan = state.plan;
    verdict = state.verdict;
    if plan is None or verdict is None {
        return None;
    }
    if verdict.plan_id != plan.plan_id or verdict.plan_version != plan.version {
        return None;
    }
    return verdict;
}

"""The commander's most recent decision on exactly this plan version. Approval is bound
to a version, not a plan id: approving v7 does not approve the v8 produced a minute later."""
def approval_for_current_plan(state: IncidentState) -> ApprovalRecord | None {
    plan = state.plan;
    if plan is None {
        return None;
    }
    best: ApprovalRecord | None = None;
    for a in state.approvals or [] {
        if a.plan_id == plan.plan_id and a.plan_version == plan.version {
            if best is None or a.decided_at > best.decided_at {
                best = a;
            }
        }
    }
    return best;
}

"""Deterministic, so a plan version can be released at most once."""
def released_event_id(plan: DispatchPlan) -> str {
    return f"REL-{plan.plan_id}-v{plan.version}";
}

"""Commander decisions not yet written into the trace. The supervisor records each
human touch exactly once; that event is what the autonomy metric counts."""
def unrecorded_approvals(state: IncidentState) -> list[ApprovalRecord] {
    seen = {e.event_id for e in trace_of(state)};
    return [a for a in state.approvals or [] if f"APR-{a.approval_id}" not in seen];
}

def already_released(state: IncidentState) -> bool {
    plan = state.plan;
    if plan is None {
        return False;
    }
    target = released_event_id(plan);
    return any([e.event_id == target for e in trace_of(state)]);
}

"""Guardrail rejections since the queue last changed. If the optimiser cannot satisfy
the guardrails after a few attempts, looping forever is worse than stopping."""
def consecutive_rejections(state: IncidentState) -> int {
    trace = trace_of(state);
    since = last_index(trace, "A3");
    return len([e for e in trace[since + 1:] if e.agent == "A5" and e.action == A5_REJECTED]);
}

# ------------------------------------------------ what is due

"""Unprocessed reports exist, or an operator placed a held one since A1 last ran.

Ordered by the trace: a fix that lands outside every division leaves its report held,
so "is there a fix for a held report" would stay true forever. Running A1 is itself
what satisfies a trace-ordered condition, so it cannot loop."""
def a1_due(state: IncidentState) -> bool {
    if unprocessed_signals(state) {
        return True;
    }
    trace = trace_of(state);
    return last_index(trace, "OPS", REPORT_PLACED) > last_index(trace, "A1");
}

"""Why the hazard picture needs recomputing, or None if it is fresh: no surface yet;
older than its TTL; or a road reported blocked since it was computed."""
def a2_due(state: IncidentState, now: datetime, ttl: timedelta) -> str | None {
    hazard = state.hazard;
    if hazard is None {
        return "no hazard surface yet";
    }
    if now - hazard.generated_at > ttl {
        return f"hazard surface v{hazard.version} older than {ttl}";
    }
    # Ordered by the trace, not by timestamps: "A1 brought new evidence after A2 last
    # ran". Comparing report times to the clock would loop forever in a replay whose
    # reports are stamped ahead of the simulated clock.
    trace = trace_of(state);
    if last_index(trace, "A1") <= last_index(trace, "A2") {
        return None;
    }
    for c in state.clusters or [] {
        if c.hazard_type == HazardType.ROAD_BLOCKED and c.last_seen > hazard.generated_at {
            return f"road reported blocked at {c.gn_id} after hazard v{hazard.version}";
        }
    }
    return None;
}

"""Clusters or hazard changed since the queue was last ranked."""
def a3_due(state: IncidentState) -> bool {
    if not state.clusters {
        return False;
    }
    trace = trace_of(state);
    return last_index(trace, "A3") < max(last_index(trace, "A1"), last_index(trace, "A2"));
}

"""Why a (re-)solve is needed, or None: the queue changed; a crew declined; the
guardrail rejected the current plan (bounded); or the commander rejected or modified it."""
def a4_due(state: IncidentState, max_rejections: int) -> str | None {
    if not state.queue or state.hazard is None {
        return None;
    }
    trace = trace_of(state);
    last_a4 = last_index(trace, "A4");
    if last_a4 < last_index(trace, "A3") {
        return "queue changed since last plan";
    }
    # A crew handing a job back is new information about the world, and the cluster is
    # demand again the moment they do.
    if last_a4 < last_index(trace, "OPS", RESPONDER_DECLINED) {
        return "a crew declined a dispatch";
    }
    verdict = verdict_for_current_plan(state);
    if verdict is not None
        and not verdict.passed
        and last_a4 < last_index(trace, "A5")
        and consecutive_rejections(state) < max_rejections {
        return f"guardrail rejected: {verdict.violated_constraint}";
    }
    approval = approval_for_current_plan(state);
    if approval is not None
        and approval.decision in [ApprovalDecision.REJECTED, ApprovalDecision.MODIFIED]
        and last_a4 < last_index(trace, "gate", APPROVAL_RECEIVED) {
        # Bound to the moment the decision was received: one decision, one re-solve.
        return f"commander {approval.decision.value} plan v{approval.plan_version}";
    }
    return None;
}

"""A plan exists that has not been verified in its current version."""
def a5_due(state: IncidentState) -> bool {
    return state.plan is not None and verdict_for_current_plan(state) is None;
}

"""A verified plan is waiting for a decision that has not been requested yet."""
def gate_due(state: IncidentState) -> bool {
    verdict = verdict_for_current_plan(state);
    if verdict is None or not verdict.passed or approval_for_current_plan(state) is not None {
        return False;
    }
    trace = trace_of(state);
    return last_index(trace, "gate", GATE_REQUESTED) < last_index(trace, "A5");
}

"""The gate has asked and nobody has answered. Nothing to do but wait."""
def awaiting_commander(state: IncidentState) -> bool {
    verdict = verdict_for_current_plan(state);
    return verdict is not None
        and verdict.passed
        and approval_for_current_plan(state) is None
        and not gate_due(state);
}

"""The current plan version is approved and has not been released yet."""
def release_due(state: IncidentState) -> bool {
    approval = approval_for_current_plan(state);
    return approval is not None
        and approval.decision == ApprovalDecision.APPROVED
        and not already_released(state);
}

def halted(state: IncidentState) -> bool {
    return state.status == IncidentStatus.HALTED;
}
