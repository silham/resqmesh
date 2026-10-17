"""Scoring tests: a metric with nothing to check is None ("not measured"), never a free
1.0/0; score_run is exercised against a fabricated finished incident (no pipeline, so
every metric and both hard constraints are checked without the agent stack); and the
measurements that are experiments rather than readings each pin a mistake that was
actually made while building them, because every one of them produces a
plausible-looking number rather than an error."""

import from datetime { datetime, UTC }
import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.contracts.enums {
    ActionTier, ApprovalDecision, ClusterState, HazardMethod, HazardType, SolverStatus
}
import from resqmesh.contracts.models {
    ApprovalRecord, Assignment, DispatchPlan, HazardSurface, IncidentCluster, PriorityItem,
    ScoreComponents, Sitrep, SourcedClaim, TraceEvent, evolve
}
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.eval.harness { score_run }
import from resqmesh.eval.measurements {
    BaselineComparison, DegradedComparison, Timings, ToolCalls, compare_plans
}
import from resqmesh.eval.scenarios { ScenarioLabels }
import from tests.support.baseline { clusters as baseline_clusters, hazard as baseline_hazard, valid_plan }

glob NOW: datetime = datetime(2026, 9, 21, 6, 0, tzinfo=UTC);

glob EMPTY_LABELS: ScenarioLabels = ScenarioLabels(
    relevance_by_gn={}, observed_inundation_gn=set(), contradicted_gn=set()
);

glob LABELS: ScenarioLabels = ScenarioLabels(
    relevance_by_gn={"KLN-003": 3.0, "KLN-004": 2.0, "KLN-007": 1.0},
    observed_inundation_gn={"KLN-003"},
    contradicted_gn={"KLN-007"}
);

# --- a state with nothing to check ----------------------------------------- #

def vacuous_state() -> IncidentState {
    return IncidentState(
        clusters=baseline_clusters(), queue=[], plan=valid_plan(), hazard=baseline_hazard(),
        approvals=[], sitreps=[], reports=[]
    );
}

test "no sitreps reports unsourced as none not zero" {
    scored = score_run("t", vacuous_state(), [], EMPTY_LABELS, FakeGazetteer());
    m = scored.get("unsourced_sitrep_claims");
    assert m.value is None and m.meets is None;
    # A not-measured hard constraint must not fail the gate (only a violation does).
    assert scored.hard_constraints_pass() is True;
}

test "vacuous label metrics are none" {
    scored = score_run("t", vacuous_state(), [], EMPTY_LABELS, FakeGazetteer());
    assert scored.get("triage_ndcg_at_10").value is None;
    assert scored.get("hazard_footprint_iou").value is None;
    assert scored.get("contradiction_resolution_f1").value is None;
}

test "reference is carried into the scorecard" {
    scored = score_run(
        "t", vacuous_state(), [], EMPTY_LABELS, FakeGazetteer(),
        reference="synthetic self-consistency"
    );
    assert scored.as_dict()["reference"] == "synthetic self-consistency";
}

# --- score_run over a fabricated finished incident ------------------------- #

def make_cluster(cid: str, gn: str, state: ClusterState) -> IncidentCluster {
    return IncidentCluster(
        cluster_id=cid, member_report_ids=[f"R-{cid}"], centroid_lat=6.93, centroid_lon=79.89,
        gn_id=gn, hazard_type=HazardType.FLOOD, confidence_0_1=0.8, state=state,
        first_seen=NOW, last_seen=NOW
    );
}

def make_item(cid: str, rank: int, score: float) -> PriorityItem {
    comps = ScoreComponents(
        hazard_severity=score, population_exposure=score, vulnerability=score,
        time_criticality=score, cluster_confidence=score
    );
    return PriorityItem(
        cluster_id=cid, rank=rank, score_0_1=score, components=comps,
        weights={
            "hazard_severity": 0.3, "population_exposure": 0.2, "vulnerability": 0.2,
            "time_criticality": 0.2, "cluster_confidence": 0.1
        },
        rationale_text="test"
    );
}

def make_event(event_id: str, agent: str, action: str, tier: ActionTier, human_touch: bool = False) -> TraceEvent {
    return TraceEvent(
        event_id=event_id, agent=agent, action=action, tier=tier, human_touch=human_touch, occurred_at=NOW
    );
}

def base_trace() -> list[TraceEvent] {
    return [
        make_event("1", "A1", "ingest", ActionTier.TIER_A),
        make_event("2", "A2", "hazard", ActionTier.TIER_A),
        make_event("3", "A4", "plan", ActionTier.TIER_A),
        make_event("4", "gate", "approve", ActionTier.TIER_C, human_touch=True),
        make_event("5", "A6", "release", ActionTier.TIER_B)
    ];
}

def base_state(gn_for_cl1: str = "KLN-003") -> IncidentState {
    cl = [
        make_cluster("CL-1", gn_for_cl1, ClusterState.CORROBORATED),
        make_cluster("CL-2", "KLN-004", ClusterState.CORROBORATED),
        make_cluster("CL-3", "KLN-007", ClusterState.CONTRADICTED)
    ];
    plan = DispatchPlan(
        plan_id="PLN-1", version=1, generated_at=NOW,
        assignments=[
            Assignment(vehicle_id="AMB-01", cluster_id="CL-1", route_edge_ids=["E1"], eta_minutes=12.0, distance_km=4.0, load=3),
            Assignment(vehicle_id="BOAT-01", cluster_id="CL-2", route_edge_ids=["E2"], eta_minutes=18.0, distance_km=7.0, load=2)
        ],
        objective_value=30.0, optimality_gap=0.02, solver_status=SolverStatus.OPTIMAL,
        solve_seconds=1.0, warm_started=True, input_surface_version=1, input_queue_hash="qh"
    );
    hz = HazardSurface(
        surface_id="HS-1", version=1, generated_at=NOW, method=HazardMethod.HAND, confidence_0_1=0.8,
        inundation_geojson={"type": "FeatureCollection", "features": []},
        susceptibility_geojson={"type": "FeatureCollection", "features": []},
        no_go_gn_ids=["KLN-003"]
    );
    sitrep = Sitrep(
        sitrep_id="SR-1", generated_at=NOW, pdf_path="/tmp/sr.pdf",
        claims=[
            SourcedClaim(sentence="Kolonnawa flooding.", source_ref="CL-1"),
            SourcedClaim(sentence="Plan generated.", source_ref="PLN-1")
        ],
        hazard_method=HazardMethod.HAND, hash="abc"
    );
    approvals = [
        ApprovalRecord(
            approval_id="AP-1", plan_id="PLN-1", plan_version=1, tier=ActionTier.TIER_C,
            decision=ApprovalDecision.APPROVED, commander_id="c", decided_at=NOW
        )
    ];
    return IncidentState(
        clusters=cl,
        queue=[make_item("CL-1", 1, 0.9), make_item("CL-2", 2, 0.7), make_item("CL-3", 3, 0.4)],
        plan=plan, hazard=hz, sitreps=[sitrep], approvals=approvals, reports=[], trace=base_trace()
    );
}

test "perfect run scores well" {
    state = base_state();
    scored = score_run(
        "test", state, state.trace, LABELS, FakeGazetteer(),
        predicted_inundation_gn={"KLN-003"}  # matches observed exactly
    );

    assert scored.get("triage_ndcg_at_10").value == 1.0;
    assert scored.get("hazard_footprint_iou").value == 1.0;
    assert scored.get("contradiction_resolution_f1").value == 1.0;
    assert scored.get("dispatch_optimality_gap").meets is True;
    assert scored.get("autonomous_task_completion").meets is True;
    # trace = A1,A2,A4,[human],A6 -> chains [3, 1], mean 2.0
    assert scored.get("autonomous_decision_chain_length").value == 2.0;
}

test "hard constraints pass on a clean run" {
    state = base_state();
    scored = score_run("test", state, state.trace, LABELS, FakeGazetteer());

    assert scored.get("gazetteer_violations").value == 0.0;
    assert scored.get("unsourced_sitrep_claims").value == 0.0;
    assert scored.hard_constraints_pass() is True;
}

test "dispatch to unknown division is a gazetteer violation" {
    state = base_state(gn_for_cl1="KLN-999");  # not in the gazetteer
    scored = score_run("test", state, state.trace, LABELS, FakeGazetteer());

    assert scored.get("gazetteer_violations").value == 1.0;
    assert scored.hard_constraints_pass() is False;
}

test "unmeasured metrics are none not invented" {
    state = base_state();
    scored = score_run("test", state, state.trace, LABELS, FakeGazetteer());

    rti = scored.get("response_time_improvement");
    assert rti.value is None;
    assert rti.meets is None;
}

test "scorecard dict carries every metric in order" {
    state = base_state();
    scored = score_run("test", state, state.trace, LABELS, FakeGazetteer());
    names = [m["name"] for m in scored.as_dict()["metrics"]];
    assert names == [
        "autonomous_task_completion", "autonomous_decision_chain_length", "human_intervention_rate",
        "triage_ndcg_at_10", "hazard_footprint_iou", "dispatch_optimality_gap",
        "contradiction_resolution_f1", "gazetteer_violations", "unsourced_sitrep_claims",
        "operating_cost_usd", "response_time_improvement", "replan_latency_p95_s",
        "tool_call_success_rate", "degraded_mode_continuity"
    ];
}

# --- measurements ---------------------------------------------------------- #

def state_of(plan: DispatchPlan | None, queue: list[PriorityItem]) -> IncidentState {
    return IncidentState(plan=plan, queue=queue);
}

test "improvement is scored on the shared objective" {
    # Not on mean arrival over served demand, which rewards abandoning the far ones.
    worse = evolve(valid_plan(), objective_value=100.0);
    better = evolve(valid_plan(), objective_value=75.0);
    c = compare_plans(state_of(better, []), state_of(worse, []));
    assert c is not None;
    assert c.improvement() == 0.25;
}

test "costs from different demand are not comparable" {
    # Two replays that faced different demand describe different problems. Comparing
    # their costs anyway is how a 44% improvement appeared that did not exist: the two
    # runs had been given different rainfall.
    ours = evolve(valid_plan(), objective_value=10.0);
    theirs = evolve(valid_plan(), objective_value=20.0);
    c = compare_plans(
        state_of(ours, [make_item("CL-1", 1, 0.5)]), state_of(theirs, [make_item("CL-9", 1, 0.5)])
    );
    assert c is not None;
    assert c.comparable is False;
    assert c.improvement() is None;
}

test "a missing baseline is not an improvement" {
    assert compare_plans(state_of(valid_plan(), []), state_of(None, [])) is None;
    assert BaselineComparison(None, 10.0, 0, 1).improvement() is None;
}

test "zero calls is not a hundred percent success" {
    assert ToolCalls().success_rate() is None;
    assert ToolCalls(attempted=4, unrecovered=1).success_rate() == 0.75;
}

test "no latencies is not a fast p95" {
    assert Timings().p95() is None;
    assert Timings(latencies_s=[1.0, 2.0, 60.0]).p95() == 60.0;
}

test "continuity without a normal run is unmeasured" {
    assert DegradedComparison(0, 0, 0, 0).continuity() is None;
    assert DegradedComparison(2, 1, 4, 4).continuity() == 0.75;
}

test "a requested greedy solve is not a failure" {
    # GREEDY_FALLBACK means the solver broke. The baseline did not break.
    assert SolverStatus.GREEDY_BASELINE != SolverStatus.GREEDY_FALLBACK;
}
