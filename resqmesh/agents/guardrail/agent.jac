"""A5: Guardrail and Verification.

Attacks the plan before the commander ever sees it. It reads the proposed plan and
the state the plan was built from, runs every assertion in `checks`, and emits one
GuardrailVerdict. A failing verdict carries the first violated constraint and a
remediation hint back to A0, so A4 can do a targeted re-solve (exclude one edge, drop
one under-confident cluster) rather than a blind retry.

Reads: plan (A4), clusters (A1), hazard (A2), vehicles (set at open). Writes: verdict.
"""

import from datetime { datetime, UTC }
import from resqmesh.agents.guardrail.checks {
    GAZETTEER_MEMBERSHIP, NO_GO_INTERSECTION, SOURCE_BINDING, TARGETS_EXIST,
    TIER_C_CONFIDENCE_FLOOR, VEHICLE_CAPACITY, check_gazetteer_membership,
    check_no_go_intersection, check_source_binding, check_targets_exist,
    check_tier_c_confidence_floor, check_vehicle_capacity, strip_unsourced
}
import from resqmesh.contracts.models {
    DispatchPlan, GuardrailCheck, GuardrailVerdict, HazardSurface, IncidentCluster,
    SourcedClaim, Vehicle
}
import from resqmesh.contracts.ports { GeocodePort }

"""What A0 should do about each violated constraint. Part of the correction-loop
contract, not user-facing prose."""
glob REMEDIATION: dict[str, str] = {
    TARGETS_EXIST: "drop assignments to unknown clusters/vehicles and re-solve on the current queue",
    GAZETTEER_MEMBERSHIP: "exclude clusters whose destination does not resolve to a GN division",
    NO_GO_INTERSECTION: "re-prune the graph against the current hazard surface and re-solve",
    VEHICLE_CAPACITY: "reduce load or reassign; the target exceeds vehicle capacity",
    TIER_C_CONFIDENCE_FLOOR: "hold the under-confident cluster for corroboration; do not dispatch on it yet",
    SOURCE_BINDING: "the SITREP has unsourced sentences; A6 must strip them before release"
};

"""Tunable safety thresholds. The floor is configuration, not code: a deploying
authority sets the boundary its own governance requires."""
obj GuardrailConfig {
    has tier_c_confidence_floor: float = 0.5;
}

obj GuardrailAgent {
    has gazetteer: GeocodePort,
        config: GuardrailConfig = GuardrailConfig();

    """Run the full suite over a dispatch plan. Order matters only for the reported
    violated constraint: targets first for the clearest message, then the two hard
    constraints so they win precedence."""
    def verify_plan(
        plan: DispatchPlan,
        clusters: list[IncidentCluster],
        hazard: HazardSurface | None,
        vehicles: list[Vehicle],
        now: datetime | None = None
    ) -> GuardrailVerdict {
        checks: list[GuardrailCheck] = [
            check_targets_exist(plan, clusters, vehicles),
            check_gazetteer_membership(plan, clusters, self.gazetteer),
            check_no_go_intersection(plan, hazard, vehicles),
            check_vehicle_capacity(plan, vehicles),
            check_tier_c_confidence_floor(plan, clusters, self.config.tier_c_confidence_floor)
        ];
        return GuardrailAgent.verdict(plan.plan_id, plan.version, checks, now);
    }

    """Check source binding and return the surviving claims, so an unsourced sentence
    never reaches the commander."""
    def audit_sitrep_claims(
        claims: list[SourcedClaim], known_refs: set[str]
    ) -> tuple[GuardrailCheck, list[SourcedClaim]] {
        check = check_source_binding(claims, known_refs);
        return (check, strip_unsourced(claims, known_refs));
    }

    static def verdict(
        plan_id: str, plan_version: int, checks: list[GuardrailCheck], now: datetime | None
    ) -> GuardrailVerdict {
        failed = [c for c in checks if not c.passed];
        first: GuardrailCheck | None = failed[0] if failed else None;
        return GuardrailVerdict(
            plan_id=plan_id,
            plan_version=plan_version,
            passed=not failed,
            checks=checks,
            violated_constraint=first.name if first else None,
            remediation_hint=REMEDIATION.get(first.name) if first else None,
            evaluated_at=now or datetime.now(UTC)
        );
    }
}
