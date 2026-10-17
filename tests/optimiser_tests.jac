"""A4 optimiser: travel, greedy, CP-SAT, exact, targeted re-solve, and the full
A2 -> A3 -> A4 -> A5 chain on a synthetic basin.

Grid (see resqmesh.adapters.geo.synthetic): 6 rows x 8 cols, origin (6.90, 79.90),
0.005 deg (~550 m) spacing, node id = row * 8 + col. A river runs east-west between
rows 1 and 2 over the western half, so heavy rain cuts the direct north-south streets
there and forces routes east.
"""

import json;
import math;
import tempfile;
import warnings;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.adapters.geo.roads { edge_id }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.agents.hazard.agent { HazardAgent, HazardConfig }
import from resqmesh.agents.triage.agent { TriageAgent }
import from resqmesh.agents.optimiser.agent { OptimiserAgent, OptimiserConfig }
import resqmesh.agents.optimiser.agent as agent_module;
import from resqmesh.agents.optimiser.cpsat { solve_cpsat }
import from resqmesh.agents.optimiser.exact { gap_to_exact, solve_exact }
import from resqmesh.agents.optimiser.greedy { solve_greedy }
import from resqmesh.agents.optimiser.problem { Demand, DispatchProblem, Fleet, plan_cost }
import from resqmesh.agents.optimiser.travel { Leg, TravelModel, update_residual }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.guardrail.checks { NO_GO_INTERSECTION, VEHICLE_CAPACITY }
import from resqmesh.contracts.enums {
    ActionTier, ApprovalDecision, ClusterState, CommitmentStatus, HazardType, SolverStatus
}
import from resqmesh.contracts.models {
    ApprovalRecord, Assignment, Commitment, DispatchPlan, GuardrailCheck, GuardrailVerdict,
    IncidentCluster, IncidentReport, TravelTimeResidual, Vehicle, evolve, to_json
}
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.commitments { commitment_id, served_cluster_ids }

"""The metric reprojection helpers in the geo adapter still go through
`shapely.ops.transform`, which shapely 2.2 deprecates; the test runner turns every
warning into an error, so that one deprecation is silenced for this file."""
def _quiet_reprojection_deprecation() -> bool {
    warnings.filterwarnings(
        "ignore", message=r"The 'shapely\.ops\.transform\(\)' function is deprecated",
        category=DeprecationWarning
    );
    return True;
}

glob _QUIET: bool = _quiet_reprojection_deprecation();

glob NOW: datetime = datetime(2016, 5, 17, 6, 0, tzinfo=UTC);
glob RIVER: dict[str, any] = {
    "type": "FeatureCollection",
    "features": [
        {
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": [[79.895, 6.9075], [79.9175, 6.9075]]},
            "properties": {"waterway": "river"}
        }
    ]
};

def node_pos(n: int) -> tuple[float, float] {
    return (6.90 + (n // 8) * 0.005, 79.90 + (n % 8) * 0.005);
}

def approx(a: float, b: float, rel: float = 1e-6) -> bool {
    return math.isclose(a, b, rel_tol=rel, abs_tol=1e-12);
}

obj Rain(WeatherPort) {
    has rate: float = 5.0;

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        return RainfallSeries(
            lat=lat, lon=lon, observed_mm=[self.rate] * hours_back, forecast_mm=[], start_time=NOW
        );
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        return self.rainfall(lat, lon);
    }
}

# --------------------------------------------------------------------------- #
# Fixtures: a small incident on the grid, with real gazetteer ids
# --------------------------------------------------------------------------- #

def make_cluster(cid: str, n: int, gn: str, **kw: any) -> IncidentCluster {
    (lat, lon) = node_pos(n);
    base: dict[str, any] = {
        "cluster_id": cid, "member_report_ids": [f"R-{cid}"], "centroid_lat": lat, "centroid_lon": lon,
        "gn_id": gn, "hazard_type": HazardType.FLOOD, "confidence_0_1": 0.85,
        "state": ClusterState.CORROBORATED, "corroborating_source_count": 2,
        "first_seen": NOW - timedelta(hours=1), "last_seen": NOW
    };
    base.update(kw);
    return IncidentCluster(**base);
}

def make_report(cid: str, n: int, people: int) -> IncidentReport {
    (lat, lon) = node_pos(n);
    return IncidentReport(
        report_id=f"R-{cid}", signal_id=f"S-{cid}", source_id="src", hazard_type=HazardType.FLOOD,
        description="stranded", raw_place_text="x", resolved_gn_id="KLN-001", lat=lat, lon=lon,
        severity_claim=3, reported_people_affected=people, observed_at=NOW - timedelta(hours=1)
    );
}

def make_vehicle(vid: str, n: int, capacity: int = 8, gn: str = "KLN-001") -> Vehicle {
    (lat, lon) = node_pos(n);
    return Vehicle(vehicle_id=vid, kind="boat", capacity=capacity, depot_gn_id=gn, depot_lat=lat, depot_lon=lon);
}

def make_world() -> dict[str, any] {
    return {
        "graph": grid_graph(),
        "clusters": [
            make_cluster("NORTH", 41, "KLN-001"),  # row 5, col 1 — across the river from the south depot
            make_cluster("EAST", 15, "KLN-002"),  # row 1, col 7
            make_cluster("WEST", 8, "KLN-003")  # row 1, col 0 — on the flooded bank
        ],
        "reports": [make_report("NORTH", 41, 6), make_report("EAST", 15, 3), make_report("WEST", 8, 12)],
        "vehicles": [
            make_vehicle("BOAT-S", 0), make_vehicle("AMB-E", 7, capacity=4),
            make_vehicle("TRK-N", 47, capacity=10)
        ],
        "tmp": Path(tempfile.mkdtemp(prefix="optimiser_tests_"))
    };
}

"""Overwrite state fields with an agent's update, the way the test harness merges."""
def merge(state: IncidentState, update: dict[str, any]) -> None {
    for (k, v) in update.items() {
        setattr(state, k, v);
    }
}

def make_state(world: dict[str, any], prune: bool = True, rate: float = 5.0) -> IncidentState {
    g = world["graph"];

    def graph_loader() -> any {
        return g;
    }

    def river_loader() -> any {
        return RIVER;
    }

    def no_dem() -> any {
        return None;
    }

    a2 = HazardAgent(
        weather=Rain(rate=rate), graph_loader=graph_loader, waterways_loader=river_loader, dem_loader=no_dem,
        inundation_model=None, gn_centroids={}, config=HazardConfig(prefer_hand=False, prune=prune),
        out_dir=world["tmp"]
    );
    state = IncidentState(
        clusters=world["clusters"], reports=world["reports"], vehicles=world["vehicles"], approvals=[],
        plan=None, verdict=None
    );
    merge(state, a2.run(state, now=NOW));
    merge(state, TriageAgent().run(state, now=NOW));
    return state;
}

def make_a4(world: dict[str, any], **kw: any) -> OptimiserAgent {
    g = world["graph"];

    def base_loader() -> any {
        return g;
    }

    return OptimiserAgent(base_graph_loader=base_loader, gazetteer=FakeGazetteer(), **kw);
}

def verify(state: IncidentState, plan: DispatchPlan) -> GuardrailVerdict {
    return GuardrailAgent(gazetteer=FakeGazetteer()).verify_plan(
        plan, state.clusters, state.hazard, state.vehicles, now=NOW
    );
}

def pairs_of(plan: DispatchPlan) -> list[tuple[str, str]] {
    return [(a.vehicle_id, a.cluster_id) for a in plan.assignments];
}

"""Rebuild a plan from its JSON form, so a round trip can be compared field by field."""
def plan_from_json(text: str) -> DispatchPlan {
    data: dict[str, any] = json.loads(text);
    data.pop("schema_version", None);
    assignments: list[Assignment] = [];
    for a in data["assignments"] {
        a.pop("schema_version", None);
        assignments.append(Assignment(**a));
    }
    data["assignments"] = assignments;
    data["generated_at"] = datetime.fromisoformat(data["generated_at"].replace("Z", "+00:00"));
    data["solver_status"] = SolverStatus(data["solver_status"]);
    return DispatchPlan(**data);
}

# --------------------------------------------------------------------------- #
# Travel
# --------------------------------------------------------------------------- #

test "legs follow real edges end to end" {
    g = grid_graph();
    model = TravelModel.build(g);
    legs = model.legs({"V": node_pos(0)}, {"C": node_pos(19)});
    leg = legs[("V", "C")];
    assert leg.edge_ids[0].startswith("0-") and leg.edge_ids[-1].split("-")[1] == "19";
    for (a, b) in zip(leg.edge_ids, leg.edge_ids[1:]) {
        assert a.split("-")[1] == b.split("-")[0];  # consecutive
    }
    assert leg.eta_minutes > 0 and approx(leg.distance_km, 5 * 0.553, rel=0.02);
}

test "forbidden edges are not used" {
    g = grid_graph();
    direct = TravelModel.build(g).legs({"V": node_pos(0)}, {"C": node_pos(1)})[("V", "C")];
    assert direct.edge_ids == [edge_id(0, 1)];
    around = TravelModel.build(g, forbidden_edges={edge_id(0, 1)}).legs({"V": node_pos(0)}, {"C": node_pos(1)});
    assert edge_id(0, 1) not in around[("V", "C")].edge_ids;
    assert around[("V", "C")].eta_minutes > direct.eta_minutes;
}

test "learned residual slows matching roads" {
    g = grid_graph();
    base = TravelModel.build(g, rain_mm=200).legs({"V": node_pos(0)}, {"C": node_pos(1)})[("V", "C")];
    slow = TravelModel.build(
        g, rain_mm=200,
        residuals={
            "residential|extreme": TravelTimeResidual(
                road_class="residential", rainfall_band="extreme", correction_factor=2.0
            )
        }
    ).legs({"V": node_pos(0)}, {"C": node_pos(1)})[("V", "C")];
    assert approx(slow.eta_minutes, 2 * base.eta_minutes, rel=1e-3);
}

test "unreachable and too far pairs are absent" {
    g = grid_graph();
    g.remove_edges_from([(40, 41, 0), (41, 40, 0), (33, 41, 0), (41, 33, 0), (41, 42, 0), (42, 41, 0)]);
    model = TravelModel.build(g);
    # 41 is now isolated: a demand at 41 snaps to the nearest *dry* junction instead.
    legs = model.legs({"V": node_pos(0)}, {"C": node_pos(41), "FAR": (7.5, 81.0)});
    assert ("V", "C") in legs and ("V", "FAR") not in legs;
    assert legs[("V", "C")].distance_km > 0;
}

test "residual update is smoothed and bounded" {
    r = update_residual(None, "primary", "heavy", observed_minutes=30, predicted_minutes=10);
    assert 1.0 < r.correction_factor < 3.0 and r.sample_count == 1;
    wild = update_residual(r, "primary", "heavy", observed_minutes=1e6, predicted_minutes=1);
    assert wild.correction_factor <= 4.0;
}

# --------------------------------------------------------------------------- #
# Solvers on a hand-built problem where greedy is provably suboptimal
# --------------------------------------------------------------------------- #

"""Greedy gives the top cluster its nearest vehicle — the only one that can reach the
second cluster. The optimum swaps them."""
def trap() -> DispatchProblem {
    legs = {
        ("V1", "A"): Leg(5.0, 1.0, ["e"]),
        ("V2", "A"): Leg(8.0, 1.5, ["e"]),
        ("V1", "B"): Leg(10.0, 2.0, ["e"])  # V2 cannot reach B
    };
    return DispatchProblem(
        demands=[Demand("A", 0.9, 4, 1), Demand("B", 0.8, 4, 2)],
        vehicles=[Fleet("V1", 8), Fleet("V2", 8)],
        legs=legs
    );
}

test "greedy serves in rank order and can be trapped" {
    p = trap();
    assert solve_greedy(p) == {"V1": "A"};  # B left unserved
}

test "cpsat beats greedy and matches exact" {
    p = trap();
    greedy = solve_greedy(p);
    sol = solve_cpsat(p, time_budget_s=5, hint=greedy);
    assert sol.assignment == {"V1": "B", "V2": "A"};
    assert sol.status == SolverStatus.OPTIMAL and sol.optimality_gap == 0.0 and sol.warm_started;
    assert sol.objective < plan_cost(p, greedy);
    exact = solve_exact(p);
    assert approx(exact.objective, sol.objective);
    assert gap_to_exact(plan_cost(p, greedy), exact.objective) > 0.05;
    assert gap_to_exact(sol.objective, exact.objective) == 0.0;
}

test "capacity shortfall prefers the bigger vehicle" {
    legs = {("SMALL", "A"): Leg(5.0, 1.0, []), ("BIG", "A"): Leg(6.0, 1.2, [])};
    p = DispatchProblem(
        demands=[Demand("A", 0.9, 10, 1)], vehicles=[Fleet("SMALL", 4), Fleet("BIG", 12)], legs=legs
    );
    assert solve_cpsat(p).assignment == {"BIG": "A"};
    assert p.load("SMALL", "A") == 4;  # never above capacity, by construction
}

test "tight budget still returns a stated answer" {
    demands = [Demand(f"C{i}", 0.5 + (i % 5) / 10, 3, i + 1) for i in range(40)];
    vehicles = [Fleet(f"V{j}", 8) for j in range(30)];
    legs: dict[tuple[str, str], Leg] = {};
    for i in range(40) {
        for j in range(30) {
            legs[(f"V{j}", f"C{i}")] = Leg(float((i * 7 + j * 13) % 50 + 1), 1.0, []);
        }
    }
    p = DispatchProblem(demands=demands, vehicles=vehicles, legs=legs);
    sol = solve_cpsat(p, time_budget_s=0.001, hint=solve_greedy(p), workers=1);
    assert sol.status in [SolverStatus.OPTIMAL, SolverStatus.FEASIBLE];
    assert sol.optimality_gap is not None and 0.0 <= sol.optimality_gap <= 1.0;
    assert len(set(sol.assignment.values())) == len(sol.assignment);
}

# --------------------------------------------------------------------------- #
# The agent, end to end with A2, A3 and A5
# --------------------------------------------------------------------------- #

test "full chain produces a plan the guardrail accepts" {
    world = make_world();
    state = make_state(world);
    out = make_a4(world).run(state, now=NOW);
    assert set(out) == {"plan", "trace"};  # sole writer: nothing else leaves A4
    plan = out["plan"];
    hazard: any = state.hazard;
    assert plan.version == 1 and plan.input_surface_version == hazard.version;
    assert plan.solver_status == SolverStatus.OPTIMAL and plan.warm_started;
    assert plan.assignments;
    impassable = set(hazard.impassable_edge_ids);
    for a in plan.assignments {
        assert not impassable.intersection(a.route_edge_ids);
        assert a.load <= [v.capacity for v in world["vehicles"] if v.vehicle_id == a.vehicle_id][0];
    }
    verdict = verify(state, plan);
    assert verdict.passed, verdict.checks;
    assert out["trace"][0].agent == "A4" and out["trace"][0].tier == ActionTier.TIER_A;
}

test "plan round trips through its contract" {
    world = make_world();
    plan = make_a4(world).run(make_state(world), now=NOW)["plan"];
    text = json.dumps(to_json(plan), sort_keys=True);
    assert json.dumps(to_json(plan_from_json(text)), sort_keys=True) == text;
}

test "ablation without pruning crosses water and a5 catches it" {
    world = make_world();
    state = make_state(world, prune=False);
    a4 = make_a4(world);
    plan = a4.run(state, now=NOW)["plan"];
    verdict = verify(state, plan);
    assert not verdict.passed and verdict.violated_constraint == NO_GO_INTERSECTION;
    # Targeted re-solve: the verdict becomes an avoid-constraint, and the new plan passes.
    merge(state, {"plan": plan, "verdict": verdict});
    replan = a4.run(state, now=NOW)["plan"];
    assert replan.version == 2;
    assert any([t.startswith("avoid_impassable") for t in replan.commander_constraints]);
    assert verify(state, replan).passed;
}

test "capacity verdict forbids exactly the offending pair" {
    world = make_world();
    state = make_state(world);
    bad = DispatchPlan(
        plan_id="PLN-0001", version=1, generated_at=NOW,
        assignments=[
            Assignment(vehicle_id="AMB-E", cluster_id="WEST", route_edge_ids=[], eta_minutes=1, distance_km=1, load=12)
        ],
        objective_value=1, solver_status=SolverStatus.OPTIMAL, solve_seconds=0.1, warm_started=False,
        input_surface_version=1, input_queue_hash="x"
    );
    verdict = GuardrailVerdict(
        plan_id="PLN-0001", plan_version=1, passed=False, evaluated_at=NOW, violated_constraint=VEHICLE_CAPACITY,
        checks=[GuardrailCheck(name=VEHICLE_CAPACITY, passed=False, detail="AMB-E load 12 > capacity 4")]
    );
    merge(state, {"plan": bad, "verdict": verdict});
    plan = make_a4(world).run(state, now=NOW)["plan"];
    assert "forbid_pair:AMB-E>WEST (capacity)" in plan.commander_constraints;
    assert ("AMB-E", "WEST") not in pairs_of(plan);
}

test "commander rejection carries forward" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    target = first.assignments[0].cluster_id;
    state.plan = first;
    state.approvals = [
        ApprovalRecord(
            approval_id="AP-1", plan_id=first.plan_id, plan_version=1, tier=ActionTier.TIER_C,
            decision=ApprovalDecision.REJECTED, commander_id="cmdr", decided_at=NOW,
            constraint_note=f"hold {target}"
        )
    ];
    second = make_a4(world).run(state, now=NOW)["plan"];
    assert target not in {a.cluster_id for a in second.assignments};
    assert target in second.unassigned_cluster_ids;
    assert f"exclude_cluster:{target} (commander)" in second.commander_constraints;
}

test "low confidence and unresolved clusters are held not proposed" {
    world = make_world();
    world["clusters"] = [
        evolve(world["clusters"][0], confidence_0_1=0.2),
        evolve(world["clusters"][1], state=ClusterState.UNRESOLVED),
        world["clusters"][2]
    ];
    out = make_a4(world).run(make_state(world), now=NOW);
    plan = out["plan"];
    assert {a.cluster_id for a in plan.assignments} <= {"WEST"};
    assert {"NORTH", "EAST"} <= set(plan.unassigned_cluster_ids);
    assert "held" in out["trace"][0].detail;
}

test "unknown place is never proposed" {
    world = make_world();
    world["clusters"] = [evolve(world["clusters"][0], gn_id="KLN-999")] + world["clusters"][1:];
    plan = make_a4(world).run(make_state(world), now=NOW)["plan"];
    assert "NORTH" not in {a.cluster_id for a in plan.assignments};
}

def make_commit(plan: DispatchPlan, index: int, status: CommitmentStatus, closed: datetime | None = None) -> Commitment {
    a = plan.assignments[index];
    return Commitment(
        commitment_id=commitment_id(a), plan_id=plan.plan_id, plan_version=plan.version,
        assignment=a, status=status, released_at=NOW, closed_at=closed
    );
}

"""A responder reporting a job done frees the vehicle: the served cluster is held out
of the next plan, so it is never dispatched a second time."""
test "a completed cluster is dropped from demand" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    assert first.assignments;  # baseline: at least one dispatch
    served = first.assignments[0].cluster_id;

    state.commitments = [make_commit(first, 0, CommitmentStatus.COMPLETE, closed=NOW + timedelta(hours=1))];
    second = make_a4(world).run(state, now=NOW)["plan"];
    assert served not in {a.cluster_id for a in second.assignments};
    assert served in second.unassigned_cluster_ids;
}

"""Completion closes an emergency, not a location: served is a question about
evidence, and something newer re-opens it."""
test "a fresh report reopens a cluster a crew already served" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    served = first.assignments[0].cluster_id;
    cluster = [c for c in state.clusters if c.cluster_id == served][0];
    observed = {r.report_id: r.observed_at for r in state.reports};
    newest = max([observed[rid] for rid in cluster.member_report_ids if rid in observed]);

    # The crew stood down, and then a report arrived from that place: still demand.
    state.commitments = [make_commit(first, 0, CommitmentStatus.COMPLETE, closed=newest - timedelta(minutes=1))];
    assert served_cluster_ids(state) == [];

    # Had the same report arrived before they stood down, it would stay served.
    state.commitments = [make_commit(first, 0, CommitmentStatus.COMPLETE, closed=newest + timedelta(minutes=1))];
    assert served_cluster_ids(state) == [served];
}

"""The plan churns around a moving crew, never through it."""
test "a committed crew is not retasked by a replan" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    assert first.assignments;
    crew = first.assignments[0];
    state.commitments = [make_commit(first, 0, CommitmentStatus.EN_ROUTE)];

    # Something changes enough that A4 would otherwise reshuffle the whole fleet.
    gone = first.assignments[-1].vehicle_id;
    state.vehicles = [v for v in state.vehicles if v.vehicle_id != gone];
    second = make_a4(world).run(state, now=NOW)["plan"];

    # The committed crew kept its exact assignment.
    assert to_json(crew) in [to_json(a) for a in second.assignments];
}

"""A crew is the only source of truth about why a job cannot be done."""
test "a declined dispatch stops being proposed" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    handed_back = first.assignments[0];
    state.commitments = [
        evolve(make_commit(first, 0, CommitmentStatus.DECLINED, closed=NOW), note="bridge out at Kaduwela")
    ];

    second = make_a4(world).run(state, now=NOW)["plan"];

    assert (handed_back.vehicle_id, handed_back.cluster_id) not in pairs_of(second);
    assert any(["bridge out" in t for t in second.commander_constraints]);
}

"""Re-tasking a moving crew is possible, but only because a human said so."""
test "a commander constraint recalls a committed crew" {
    world = make_world();
    state = make_state(world);
    first = make_a4(world).run(state, now=NOW)["plan"];
    crew = first.assignments[0];
    state.commitments = [make_commit(first, 0, CommitmentStatus.EN_ROUTE)];
    state.approvals = [
        ApprovalRecord(
            approval_id="AP-9", plan_id=first.plan_id, plan_version=first.version, tier=ActionTier.TIER_C,
            decision=ApprovalDecision.REJECTED, commander_id="cmdr-01",
            constraint_note=f"exclude_vehicle: {crew.vehicle_id}", decided_at=NOW
        )
    ];

    out = make_a4(world).run(state, now=NOW);
    assert crew.vehicle_id not in {a.vehicle_id for a in out["plan"].assignments};
    assert [c.status for c in out["commitments"]] == [CommitmentStatus.RECALLED];
    assert out["commitments"][0].note == "commander constraint";
}

def boom(*args: any, **kwargs: any) -> any {
    raise RuntimeError("solver crashed");
}

test "solver failure falls back to greedy with unknown gap" {
    world = make_world();
    state = make_state(world);
    original = agent_module.solve_cpsat;
    agent_module.solve_cpsat = boom;
    try {
        plan = make_a4(world).run(state, now=NOW)["plan"];
    } finally {
        agent_module.solve_cpsat = original;
    }
    assert plan.solver_status == SolverStatus.GREEDY_FALLBACK;
    assert plan.optimality_gap is None;
    assert plan.assignments;
}

test "no hazard surface means no plan" {
    world = make_world();
    out = make_a4(world).run(IncidentState(queue=[], clusters=[], vehicles=[]), now=NOW);
    assert "plan" not in out;
    assert out["trace"][0].action == "plan_skipped";
}

test "missing pruned graph still honours the hazard" {
    world = make_world();
    state = make_state(world);
    state.pruned_graph = None;  # degraded: route on base graph minus impassable edges
    plan = make_a4(world).run(state, now=NOW)["plan"];
    assert verify(state, plan).passed;
}

test "greedy mode is the baseline" {
    world = make_world();
    state = make_state(world);
    kw: dict[str, any] = {
        "queue": state.queue, "clusters": state.clusters, "reports": state.reports,
        "vehicles": state.vehicles, "hazard": state.hazard, "pruned_graph": state.pruned_graph
    };
    a4 = make_a4(world, config=OptimiserConfig(time_budget_s=5));
    greedy = a4.plan(**kw, now=NOW, mode="greedy");
    exact = a4.plan(**kw, now=NOW, mode="exact");
    live = a4.plan(**kw, now=NOW);
    # Asked for, not fallen back to: a baseline run must not look like a solver failure.
    assert greedy.plan.solver_status == SolverStatus.GREEDY_BASELINE;
    assert exact.solution.objective <= greedy.solution.objective + 1e-9;
    assert gap_to_exact(live.solution.objective, exact.solution.objective) <= 0.05;
}

test "only boats reach demand deep in the water" {
    g = grid_graph();
    deep = (6.925 + 0.03, 79.90);  # ~3.3 km north of the grid: beyond road access, within boat reach
    model = TravelModel.build(g);
    assert model.legs({"TRUCK": node_pos(0)}, {"C": deep}) == {};
    boat = model.legs({"BOAT": node_pos(0)}, {"C": deep}, max_access_m=6000, access_kph=8.0);
    assert ("BOAT", "C") in boat;
}

test "agent sends a boat where roads cannot go" {
    world = make_world();
    (lat, lon) = (6.925 + 0.025, 79.905);  # ~2.8 km north of the top row
    world["clusters"] = [make_cluster("ISLAND", 41, "KLN-004", centroid_lat=lat, centroid_lon=lon)];
    world["reports"] = [make_report("ISLAND", 41, 5)];
    world["vehicles"] = [
        evolve(make_vehicle("TRK-1", 47), kind="truck"),
        evolve(make_vehicle("BOAT-1", 0), kind="boat")
    ];
    plan = make_a4(world).run(make_state(world), now=NOW)["plan"];
    assert pairs_of(plan) == [("BOAT-1", "ISLAND")];
}

test "final leg starts from the best connected node not the nearest island" {
    g = grid_graph();
    # Make node 40/41 a two-node dry island: cut every link to the rest of the grid.
    for (u, v) in [(32, 40), (33, 41), (41, 42)] {
        g.remove_edge(u, v, 0);
        g.remove_edge(v, u, 0);
    }
    demand = (6.9255, 79.9045);  # right beside 41, the island
    leg = TravelModel.build(g).legs({"V": node_pos(0)}, {"C": demand})[("V", "C")];
    last = leg.edge_ids[-1].split("-")[1];
    assert last not in ["40", "41"];  # staged from the connected network instead
}
