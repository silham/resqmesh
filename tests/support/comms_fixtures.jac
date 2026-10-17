"""Fixtures for the A6 release scenarios: a commander approval bound to a plan, a
relief shelter, and an incident state carrying the guardrail baseline."""

import from resqmesh.contracts.enums { ActionTier, ApprovalDecision }
import from resqmesh.contracts.models {
    ApprovalRecord, DispatchPlan, HazardSurface, IncidentCluster, Shelter
}
import from resqmesh.contracts.state { IncidentState }
import from tests.support.baseline { NOW }

"""A Tier-C approval of `plan`, optionally ticking the separate broadcast consent."""
def approval_for(plan: DispatchPlan, publish_alerts: bool = True) -> ApprovalRecord {
    return ApprovalRecord(
        approval_id="AP-1", plan_id=plan.plan_id, plan_version=plan.version, tier=ActionTier.TIER_C,
        decision=ApprovalDecision.APPROVED, commander_id="cmdr-01",
        publish_alerts=publish_alerts, decided_at=NOW
    );
}

def shelter() -> Shelter {
    return Shelter(
        shelter_id="SH-1", name="Kolonnawa Maha Vidyalaya", gn_id="KLN-001",
        lat=6.9497, lon=79.9853, capacity=400
    );
}

"""The incident state A6 sees on release; extra fields (shelters, alerts, queue...)
pass straight through."""
def comms_state(
    plan: DispatchPlan,
    clusters: list[IncidentCluster],
    hazard: HazardSurface | None,
    approvals: list[ApprovalRecord],
    sitreps: list[any] = [],
    **extra: any
) -> IncidentState {
    return IncidentState(
        incident_id="KLN-1", plan=plan, clusters=clusters, hazard=hazard, reports=[],
        approvals=list(approvals), sitreps=list(sitreps), **extra
    );
}
