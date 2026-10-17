"""The guardrail adversarial suite: the primary safety gate.

A battery of deliberately malformed plans, each carrying exactly one fault, asserted
to be rejected by name. A malformed plan reaching the approval gate is the specific
failure mode that would make an autonomous system in this domain unsafe to deploy,
so a regression here fails the build.
"""

import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.contracts.enums { ClusterState, HazardType }
import from resqmesh.contracts.models { IncidentCluster, SourcedClaim, evolve }
import from tests.support.baseline {
    NOW, clusters, gazetteer, hazard, replace_assignment, valid_plan, vehicles
}

"""Water over CL-1's approach. The baseline hazard has an empty inundation."""
glob FLOODED: dict[str, any] = {
    "type": "FeatureCollection",
    "features": [{
        "type": "Feature", "properties": {},
        "geometry": {"type": "Polygon", "coordinates": [[[79.980, 6.945], [79.990, 6.945], [79.990, 6.955], [79.980, 6.955], [79.980, 6.945]]]}
    }]
};

"""Staging node to demand point, both inside FLOODED: the last 200 m on foot."""
glob WADE: list[list[float]] = [[6.9480, 79.9840, 6.9497, 79.9853]];

def agent() -> GuardrailAgent {
    return GuardrailAgent(gazetteer=gazetteer());
}

def detail_of(verdict: any, name: str) -> str {
    return [c.detail for c in verdict.checks if c.name == name][0];
}

test "route through a no go segment is rejected" {
    bad = replace_assignment(valid_plan(), 0, route_edge_ids=["E-1", "E-500"]);
    v = agent().verify_plan(bad, clusters(), hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "no_go_intersection";
    assert "E-500" in detail_of(v, "no_go_intersection");
}

test "access leg through the inundation is rejected" {
    flooded = evolve(hazard(), inundation_geojson=FLOODED);
    bad = replace_assignment(valid_plan(), 0, route_edge_ids=[], access_segments=WADE);
    v = agent().verify_plan(bad, clusters(), flooded, vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "no_go_intersection";
    assert "wades" in detail_of(v, "no_go_intersection");
}

test "a boat may cross the inundation on its access leg" {
    flooded = evolve(hazard(), inundation_geojson=FLOODED);
    plan = valid_plan();
    # BOAT-01 now serves CL-1; its other assignment is dropped so it is not double-booked.
    first = evolve(plan.assignments[0], vehicle_id="BOAT-01", route_edge_ids=[], access_segments=WADE);
    afloat = evolve(plan, assignments=[first] + plan.assignments[2:]);
    v = agent().verify_plan(afloat, clusters(), flooded, vehicles(), now=NOW);
    assert v.passed;
}

test "capacity overflow is rejected" {
    v = agent().verify_plan(replace_assignment(valid_plan(), 0, load=99), clusters(), hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "vehicle_capacity";
}

test "fabricated place name is rejected" {
    phantom = IncidentCluster(
        cluster_id="CL-X", member_report_ids=["R-9"], centroid_lat=6.90, centroid_lon=79.99, gn_id="KLN-999",
        hazard_type=HazardType.FLOOD, confidence_0_1=0.95, state=ClusterState.CORROBORATED,
        corroborating_source_count=3, first_seen=NOW, last_seen=NOW
    );
    bad = replace_assignment(valid_plan(), 0, cluster_id="CL-X");
    v = agent().verify_plan(bad, clusters() + [phantom], hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "gazetteer_membership";
}

test "tier c below confidence floor is rejected" {
    cs = clusters();
    mutated = [cs[0], cs[1], evolve(cs[2], confidence_0_1=0.2)];
    v = agent().verify_plan(valid_plan(), mutated, hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "tier_c_confidence_floor";
}

test "unresolved cluster cannot alone justify dispatch" {
    cs = clusters();
    mutated = [cs[0], cs[1], evolve(cs[2], state=ClusterState.UNRESOLVED, confidence_0_1=0.95)];
    v = agent().verify_plan(valid_plan(), mutated, hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "tier_c_confidence_floor";
}

test "assignment to a phantom cluster is rejected" {
    bad = replace_assignment(valid_plan(), 0, cluster_id="CL-DOES-NOT-EXIST");
    v = agent().verify_plan(bad, clusters(), hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "targets_exist";
}

test "missing hazard surface fails closed" {
    v = agent().verify_plan(valid_plan(), clusters(), None, vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "no_go_intersection";
}

test "unsourced sitrep sentence is caught" {
    cl = [
        SourcedClaim(sentence="Ward 4 is flooding.", source_ref="R-1"),
        SourcedClaim(sentence="The dam has failed.", source_ref="FABRICATED-999")
    ];
    (c, survivors) = agent().audit_sitrep_claims(cl, {"R-1"});
    assert not c.passed and len(survivors) == 1 and survivors[0].source_ref == "R-1";
}

test "a confidently invented place never resolves" {
    assert not FakeGazetteer().resolve("Shangri-La Division").matched;
}
