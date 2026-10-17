"""Contract tests: every agent boundary is validated against its schema, so a change
by one writer cannot silently break another writer's consumer."""

import json;
import from datetime { datetime, timedelta, UTC }
import from resqmesh.contracts.enums {
    ActionTier, ApprovalDecision, ClusterState, HazardMethod, HazardType, SolverStatus,
    SourceChannel, VulnerabilityFlag, SCHEMA_VERSION
}
import from resqmesh.contracts.models {
    ApprovalRecord, Assignment, ContractError, DamageObservation, DispatchPlan,
    GuardrailCheck, GuardrailVerdict, HazardSurface, IncidentCluster, IncidentReport,
    PriorityItem, RawSignal, ScoreComponents, SourcedClaim, SourceTrust, evolve, to_json
}
import from resqmesh.contracts.state { new_state }

glob NOW: datetime = datetime.now(UTC);

def make_cluster(**kw: any) -> IncidentCluster {
    defaults: dict[str, any] = {
        "cluster_id": "C1", "member_report_ids": ["R1", "R2"], "centroid_lat": 6.9497,
        "centroid_lon": 79.9853, "gn_id": "KLN-001", "hazard_type": HazardType.FLOOD,
        "confidence_0_1": 0.82, "state": ClusterState.CORROBORATED,
        "first_seen": NOW - timedelta(hours=1), "last_seen": NOW
    };
    return IncidentCluster(**{**defaults, **kw});
}

def make_plan(**kw: any) -> DispatchPlan {
    defaults: dict[str, any] = {
        "plan_id": "P1", "version": 1, "generated_at": NOW,
        "assignments": [Assignment(vehicle_id="AMB-03", cluster_id="C1", route_edge_ids=["e1", "e2"], eta_minutes=14.0, distance_km=6.2, load=3)],
        "objective_value": 123.4, "optimality_gap": 0.018, "solver_status": SolverStatus.FEASIBLE,
        "solve_seconds": 9.8, "warm_started": True, "input_surface_version": 1, "input_queue_hash": "abc123"
    };
    return DispatchPlan(**{**defaults, **kw});
}

test "round trip through json is lossless" {
    for payload in [
        RawSignal(signal_id="S1", channel=SourceChannel.TELEGRAM, source_id="hash:abc", body="water rising", received_at=NOW),
        make_cluster(), make_plan(), SourceTrust(source_id="hash:abc", alpha=3.0, beta=1.0)
    ] {
        once = json.dumps(to_json(payload), sort_keys=True);
        assert json.loads(once)["schema_version"] == SCHEMA_VERSION;
        assert json.dumps(to_json(evolve(payload)), sort_keys=True) == once;
    }
}

test "unknown fields are rejected" {
    with testraises(TypeError) {
        make_cluster(confidance=0.5);
    }
}

test "naive datetimes are rejected" {
    with testraises(ContractError) {
        make_cluster(last_seen=datetime(2026, 1, 1));
    }
}

test "scores are bounded zero to one" {
    for bad in [-0.01, 1.01] {
        with testraises(ContractError) {
            make_cluster(confidence_0_1=bad);
        }
    }
}

test "damage severity is bounded zero to four" {
    for bad in [-1, 5] {
        with testraises(ContractError) {
            DamageObservation(report_id="R1", severity_0_4=bad, model_confidence=0.5);
        }
    }
}

test "coordinates are bounded" {
    with testraises(ContractError) {
        make_cluster(centroid_lat=91.0);
    }
}

test "a vehicle cannot be committed twice" {
    dup = Assignment(vehicle_id="AMB-03", cluster_id="C2", route_edge_ids=["e3"], eta_minutes=20.0, distance_km=9.0, load=2);
    with testraises(ContractError, `match="two assignments") {
        make_plan(assignments=[make_plan().assignments[0], dup]);
    }
}

test "priority weights must cover every score component" {
    comps = ScoreComponents(hazard_severity=0.9, population_exposure=0.6, vulnerability=0.4, time_criticality=0.8, cluster_confidence=0.82);
    with testraises(ContractError, `match="weights must cover") {
        PriorityItem(cluster_id="C1", rank=1, score_0_1=0.94, components=comps, weights={"hazard_severity": 0.5}, rationale_text="x");
    }
}

test "a verdict with no checks is rejected" {
    with testraises(ContractError, `match="silent pass") {
        GuardrailVerdict(plan_id="P1", plan_version=1, passed=True, checks=[], evaluated_at=NOW);
    }
}

test "a sourced claim cannot have an empty source" {
    with testraises(ContractError) {
        SourcedClaim(sentence="Ward 4 is inundated.", source_ref="");
    }
}

test "unresolved clusters are flagged" {
    assert make_cluster(state=ClusterState.UNRESOLVED, confidence_0_1=0.3).unresolved();
    assert not make_cluster().unresolved();
}

test "a report without a division is not located" {
    r = IncidentReport(report_id="R1", signal_id="S1", source_id="hash:abc", hazard_type=HazardType.FLOOD, description="water rising", raw_place_text="near the big tree", observed_at=NOW);
    assert not r.is_located();
}

test "vulnerability flags are functional need only" {
    members = {f.value for f in VulnerabilityFlag};
    assert not (members & {"ethnicity", "religion", "language", "caste", "nationality"});
    assert members == {"mobility_limited", "medical_dependency", "elderly", "children_present", "large_household"};
}

test "source trust posterior mean" {
    assert abs(SourceTrust(source_id="s", alpha=1.0, beta=1.0).reliability() - 0.5) < 1e-9;
    assert abs(SourceTrust(source_id="s", alpha=1.0, beta=4.0).reliability() - 0.2) < 1e-9;
}

test "approval binds a decision to a plan version" {
    rec = ApprovalRecord(approval_id="A1", plan_id="P1", plan_version=7, tier=ActionTier.TIER_C, decision=ApprovalDecision.APPROVED, commander_id="cmdr-01", decided_at=NOW);
    assert rec.plan_version == 7 and rec.tier == ActionTier.TIER_C;
}

test "a failing check carries detail" {
    c = GuardrailCheck(name="no_go_intersection", passed=False, detail="route e7 crosses polygon 2");
    assert not c.passed and "e7" in c.detail;
}

test "hazard surface declares its method" {
    s = HazardSurface(surface_id="H1", version=1, generated_at=NOW, method=HazardMethod.BUFFER_PROXY, confidence_0_1=0.4, inundation_geojson={"type": "FeatureCollection", "features": []}, susceptibility_geojson={"type": "FeatureCollection", "features": []});
    assert s.method == HazardMethod.BUFFER_PROXY;
}

test "new state starts empty and open" {
    st = new_state("KLN-2026-014", "coordinate the response to flooding in the Kelani basin");
    assert st.goal.startswith("coordinate");
    assert st.plan is None and st.clusters == [] and st.trace == [];
}
