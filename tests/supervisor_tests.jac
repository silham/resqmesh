"""A0 routing: pure decisions over hand-built states. These exercise the decision
procedure directly, so every routing rule is pinned independently of the agents."""

import uuid;
import from datetime { datetime, timedelta, UTC }
import from resqmesh.contracts.enums {
    ActionTier, ApprovalDecision, ClusterState, HazardMethod, HazardType, IncidentStatus,
    SolverStatus, SourceChannel
}
import from resqmesh.contracts.models {
    ApprovalRecord, Assignment, DispatchPlan, GuardrailCheck, GuardrailVerdict, HazardSurface,
    IncidentCluster, IncidentReport, PriorityItem, RawSignal, ScoreComponents, TraceEvent, evolve
}
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.predicates {
    A5_REJECTED, APPROVAL_RECEIVED, GATE_REQUESTED, RELEASED, RESPONDER_DECLINED,
    approval_for_current_plan, released_event_id
}
import from resqmesh.graph.supervisor {
    A1, A2, A3, A4, A5, A6, END, GATE, Decision, SupervisorConfig, decide, legal_targets
}

glob T0: datetime = datetime(2026, 9, 21, 6, 0, tzinfo=UTC);
glob FC: dict[str, any] = {"type": "FeatureCollection", "features": []};

def clock() -> datetime {
    return T0;
}

glob CFG: SupervisorConfig = SupervisorConfig(clock=clock);

def ev(agent: str, action: str = "ran", event_id: str | None = None) -> TraceEvent {
    return TraceEvent(event_id=event_id or f"E-{uuid.uuid4().hex[:8]}", agent=agent, action=action, tier=ActionTier.TIER_A, occurred_at=T0);
}

def hazard(version: int = 1, at: datetime | None = None) -> HazardSurface {
    return HazardSurface(surface_id=f"H{version}", version=version, generated_at=at or T0, method=HazardMethod.HAND, confidence_0_1=0.7, inundation_geojson=FC, susceptibility_geojson=FC);
}

def cluster(hz: HazardType = HazardType.FLOOD, seen: datetime | None = None) -> IncidentCluster {
    t = seen or T0;
    return IncidentCluster(cluster_id="CL-1", member_report_ids=["R1"], centroid_lat=6.9, centroid_lon=79.9, gn_id="KLN-001", hazard_type=hz, confidence_0_1=0.8, state=ClusterState.CORROBORATED, first_seen=t, last_seen=t);
}

def queue_item() -> PriorityItem {
    comps = ScoreComponents(hazard_severity=0.5, population_exposure=0.5, vulnerability=0.5, time_criticality=0.5, cluster_confidence=0.5);
    weights = {k: 0.2 for k in ["hazard_severity", "population_exposure", "vulnerability", "time_criticality", "cluster_confidence"]};
    return PriorityItem(cluster_id="CL-1", rank=1, score_0_1=0.5, components=comps, weights=weights, rationale_text="x");
}

def plan(version: int = 1) -> DispatchPlan {
    return DispatchPlan(
        plan_id=f"P{version}", version=version, generated_at=T0,
        assignments=[Assignment(vehicle_id="V1", cluster_id="CL-1", route_edge_ids=[], eta_minutes=1.0, distance_km=1.0, load=1)],
        objective_value=1.0, solver_status=SolverStatus.OPTIMAL, solve_seconds=0.1, warm_started=True,
        input_surface_version=1, input_queue_hash="h"
    );
}

def verdict(p: DispatchPlan, passed: bool = True) -> GuardrailVerdict {
    return GuardrailVerdict(
        plan_id=p.plan_id, plan_version=p.version, passed=passed,
        checks=[GuardrailCheck(name="gazetteer_membership", passed=passed)],
        violated_constraint=None if passed else "gazetteer_membership", evaluated_at=T0
    );
}

def approval(p: DispatchPlan, decision: ApprovalDecision, aid: str = "AP1") -> ApprovalRecord {
    return ApprovalRecord(approval_id=aid, plan_id=p.plan_id, plan_version=p.version, tier=ActionTier.TIER_C, decision=decision, commander_id="cmdr", decided_at=T0);
}

def signal(n: int = 1) -> RawSignal {
    return RawSignal(signal_id=f"S{n}", channel=SourceChannel.TELEGRAM, source_id="s", body="x", received_at=T0);
}

def report_for(s: RawSignal) -> IncidentReport {
    return IncidentReport(report_id=f"R-{s.signal_id}", signal_id=s.signal_id, source_id="s", hazard_type=HazardType.FLOOD, description="x", raw_place_text="x", observed_at=T0);
}

def base_trace() -> list[TraceEvent] {
    return [ev("A1"), ev("A2"), ev("A3"), ev("A4")];
}

"""A state that has been through A1 -> A2 -> A3 -> A4 once."""
def planned(**overrides: any) -> IncidentState {
    base = IncidentState(
        status=IncidentStatus.PLANNING, clusters=[cluster()], hazard=hazard(), queue=[queue_item()],
        plan=plan(), trace=base_trace()
    );
    return evolve(base, **overrides);
}

def route(state: IncidentState) -> str {
    return decide(state, CFG, T0).target;
}

test "fresh incident builds the hazard picture first" {
    assert route(IncidentState()) == A2;
}

test "unread evidence is read before anything else" {
    assert route(planned(raw_signals=[signal()])) == A1;
}

test "a processed signal is not reread" {
    s = signal();
    assert route(planned(raw_signals=[s], reports=[report_for(s)], verdict=verdict(plan()))) != A1;
}

test "stale hazard is recomputed" {
    assert route(planned(hazard=hazard(at=T0 - timedelta(hours=2)))) == A2;
}

test "new blocked road triggers a hazard recompute" {
    st = planned(clusters=[cluster(HazardType.ROAD_BLOCKED, seen=T0 + timedelta(minutes=5))], trace=[ev("A2"), ev("A1")]);
    assert route(st) == A2;
}

test "blocked road trigger fires once" {
    st = planned(clusters=[cluster(HazardType.ROAD_BLOCKED, seen=T0 + timedelta(minutes=5))], trace=[ev("A1"), ev("A2")]);
    assert route(st) != A2;
}

test "changed clusters are reranked" {
    assert route(planned(trace=[ev("A2"), ev("A3"), ev("A4"), ev("A1")])) == A3;
}

test "changed queue is replanned" {
    assert route(planned(trace=[ev("A1"), ev("A2"), ev("A4"), ev("A3")])) == A4;
}

test "unverified plan goes to the guardrail" {
    assert route(planned()) == A5;
}

test "verified plan goes to the gate" {
    d = decide(planned(verdict=verdict(plan()), trace=base_trace() + [ev("A5")]), CFG, T0);
    assert d.target == GATE and d.tier == ActionTier.TIER_C and d.status == IncidentStatus.AWAITING_APPROVAL;
}

test "gate is asked once then waits" {
    tr = base_trace() + [ev("A5"), ev("gate", GATE_REQUESTED)];
    d = decide(planned(verdict=verdict(plan()), trace=tr), CFG, T0);
    assert d.target == END and "awaiting" in d.reason;
}

test "approval releases the plan" {
    pl = plan();
    tr = base_trace() + [ev("A5"), ev("gate", GATE_REQUESTED)];
    d = decide(planned(verdict=verdict(pl), approvals=[approval(pl, ApprovalDecision.APPROVED)], trace=tr), CFG, T0);
    assert d.target == A6 and d.status == IncidentStatus.EXECUTING;
}

test "a released plan is never released twice" {
    pl = plan();
    tr = base_trace() + [ev("A5"), ev("A6", RELEASED, event_id=released_event_id(pl))];
    assert route(planned(verdict=verdict(pl), approvals=[approval(pl, ApprovalDecision.APPROVED)], trace=tr)) == END;
}

test "nothing due means converged" {
    pl = plan();
    tr = base_trace() + [ev("A5"), ev("A6", RELEASED, event_id=released_event_id(pl))];
    d = decide(planned(status=IncidentStatus.EXECUTING, verdict=verdict(pl), approvals=[approval(pl, ApprovalDecision.APPROVED)], trace=tr), CFG, T0);
    assert d.target == END and "converged" in d.reason;
    assert d.status == IncidentStatus.EXECUTING;
}

test "guardrail rejection triggers a targeted resolve" {
    d = decide(planned(verdict=verdict(plan(), passed=False), trace=base_trace() + [ev("A5", A5_REJECTED)]), CFG, T0);
    assert d.target == A4 and "gazetteer_membership" in d.reason;
}

test "repeated guardrail rejections escalate instead of looping" {
    rejections: list[TraceEvent] = [];
    for _ in range(CFG.max_guardrail_rejections) {
        rejections.extend([ev("A4"), ev("A5", A5_REJECTED)]);
    }
    st = planned(verdict=verdict(plan(), passed=False), trace=[ev("A1"), ev("A2"), ev("A3")] + rejections);
    d = decide(st, CFG, T0);
    assert d.target == END and d.reason.startswith("escalated");
    assert GATE not in legal_targets(st);
    assert d.status == IncidentStatus.ESCALATED;
}

test "a declined dispatch makes a resolve due" {
    d = decide(planned(trace=base_trace() + [ev("OPS", RESPONDER_DECLINED)]), CFG, T0);
    assert d.target == A4 and "declined" in d.reason;
}

test "commander rejection resolves once" {
    pl = plan();
    tr = base_trace() + [ev("A5"), ev("gate", GATE_REQUESTED), ev("gate", APPROVAL_RECEIVED)];
    rejected = planned(verdict=verdict(pl), approvals=[approval(pl, ApprovalDecision.REJECTED)], trace=tr);
    assert route(rejected) == A4;
    after = evolve(rejected, trace=rejected.trace + [ev("A4")]);
    assert route(after) != A4;
}

test "approval is bound to the plan version" {
    v1 = plan(1);
    v2 = plan(2);
    st = planned(plan=v2, verdict=verdict(v2), approvals=[approval(v1, ApprovalDecision.APPROVED)], trace=base_trace() + [ev("A5")]);
    assert approval_for_current_plan(st) is None;
    assert route(st) == GATE;
}

test "a verdict on an older plan does not count" {
    assert route(planned(plan=plan(2), verdict=verdict(plan(1)))) == A5;
}

test "halt beats everything" {
    d = decide(planned(status=IncidentStatus.HALTED, raw_signals=[signal()]), CFG, T0);
    assert d.target == END and d.status == IncidentStatus.HALTED;
}

test "release is illegal without approval" {
    pl = plan();
    assert A6 not in legal_targets(planned(verdict=verdict(pl)));
    assert A6 in legal_targets(planned(verdict=verdict(pl), approvals=[approval(pl, ApprovalDecision.APPROVED)]));
}

test "only an approval can release" {
    pl = plan();
    for dec in [ApprovalDecision.REJECTED, ApprovalDecision.MODIFIED, ApprovalDecision.COUNTERMANDED] {
        assert A6 not in legal_targets(planned(verdict=verdict(pl), approvals=[approval(pl, dec)]));
    }
}

test "optimiser is illegal without a hazard surface" {
    assert A4 not in legal_targets(planned(hazard=None));
}

def always_a2(state: any, options: any) -> str {
    return A2;
}

def always_a5(state: any, options: any) -> str {
    return A5;
}

test "a legal proposal is honoured and labelled" {
    d = decide(planned(trace=[ev("A2"), ev("A3"), ev("A4"), ev("A1")]), CFG, T0, proposer=always_a2);
    assert d.target == A2 and d.proposed_by_model;
}

test "an illegal proposal is rejected" {
    d = decide(planned(plan=None, trace=[ev("A2"), ev("A3"), ev("A4"), ev("A1")]), CFG, T0, proposer=always_a5);
    assert d.target == A3 and "rejected illegal proposal" in d.reason;
}

obj Recorder {
    has asked: list[any] = [],
        answer: str | None = None;

    def call(state: any, options: any) -> str | None {
        self.asked.append(options);
        return self.answer;
    }
}

test "a proposal cannot reach the gate or release" {
    pl = plan();
    rec = Recorder(answer=A6);
    st = planned(verdict=verdict(pl), trace=base_trace() + [ev("A5")]);
    assert decide(st, CFG, T0, proposer=rec.call).target == GATE;
    assert rec.asked == [];
}

test "the proposer never sees irreversible options" {
    rec = Recorder();
    decide(planned(), CFG, T0, proposer=rec.call);
    assert rec.asked and not (rec.asked[0] & {GATE, A6, END});
}

def boom(state: any, options: any) -> str {
    raise RuntimeError("model down");
}

test "a failing proposer cannot stall the loop" {
    d = decide(planned(), CFG, T0, proposer=boom);
    assert d.target == A5 and "proposer failed" in d.reason;
}
