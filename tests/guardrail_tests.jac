"""A5 unit tests: the checks pass what they should, and the plumbing (verdict
aggregation, remediation hints, source-binding helpers) is correct. The adversarial
rejections live in adversarial_tests.jac."""

import from resqmesh.agents.guardrail.agent { GuardrailAgent, GuardrailConfig }
import from resqmesh.agents.guardrail.checks {
    check_gazetteer_membership, check_no_go_intersection, check_source_binding,
    check_targets_exist, check_tier_c_confidence_floor, check_vehicle_capacity,
    strip_unsourced, unsourced_claims
}
import from resqmesh.contracts.models { SourcedClaim }
import from tests.support.baseline { NOW, clusters, gazetteer, hazard, valid_plan, vehicles }

def claims() -> list[SourcedClaim] {
    return [
        SourcedClaim(sentence="Ward 4 reports rising water.", source_ref="R-1"),
        SourcedClaim(sentence="Malabe Rd access is cut.", source_ref="CL-2"),
        SourcedClaim(sentence="A landslide watch is in effect.", source_ref="NBRO-2016-05")
    ];
}

test "every check passes on a valid plan" {
    plan = valid_plan();
    assert check_targets_exist(plan, clusters(), vehicles()).passed;
    assert check_gazetteer_membership(plan, clusters(), gazetteer()).passed;
    assert check_no_go_intersection(plan, hazard()).passed;
    assert check_vehicle_capacity(plan, vehicles()).passed;
    assert check_tier_c_confidence_floor(plan, clusters(), 0.5).passed;
}

test "agent passes a valid plan" {
    v = GuardrailAgent(gazetteer=gazetteer()).verify_plan(valid_plan(), clusters(), hazard(), vehicles(), now=NOW);
    assert v.passed and v.violated_constraint is None and v.remediation_hint is None;
    assert v.plan_id == "PLN-1" and v.plan_version == 1;
    assert len(v.checks) == 5 and all([c.passed for c in v.checks]);
}

test "no go check fails closed without a hazard surface" {
    c = check_no_go_intersection(valid_plan(), None);
    assert not c.passed and "failing closed" in c.detail;
}

test "confidence floor is configurable" {
    strict = GuardrailAgent(gazetteer=gazetteer(), config=GuardrailConfig(tier_c_confidence_floor=0.7));
    v = strict.verify_plan(valid_plan(), clusters(), hazard(), vehicles(), now=NOW);
    assert not v.passed and v.violated_constraint == "tier_c_confidence_floor";
}

test "source binding passes when every ref is known" {
    known = {"R-1", "CL-2", "NBRO-2016-05"};
    assert check_source_binding(claims(), known).passed;
    assert unsourced_claims(claims(), known) == [];
    assert len(strip_unsourced(claims(), known)) == 3;
}

test "source binding flags and strips a fabricated ref" {
    known = {"R-1", "CL-2"};
    c = check_source_binding(claims(), known);
    assert not c.passed and "NBRO-2016-05" in c.detail;
    survivors = strip_unsourced(claims(), known);
    assert len(survivors) == 2 and all([s.source_ref in known for s in survivors]);
}

test "audit sitrep claims returns check and survivors" {
    (c, survivors) = GuardrailAgent(gazetteer=gazetteer()).audit_sitrep_claims(claims(), {"R-1", "CL-2"});
    assert not c.passed and len(survivors) == 2;
}
