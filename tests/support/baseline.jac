"""One valid baseline shared by the guardrail tests and the adversarial suite:
vehicles, clusters, a hazard surface and a plan that passes every check. Tests derive
a copy with exactly one fault, so a failing assertion isolates a single failure mode."""

import from datetime { datetime, UTC }
import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.contracts.enums { ClusterState, HazardMethod, HazardType, SolverStatus }
import from resqmesh.contracts.models {
    Assignment, DispatchPlan, HazardSurface, IncidentCluster, Vehicle, evolve
}

glob NOW: datetime = datetime(2026, 5, 17, 6, 0, tzinfo=UTC);

def gazetteer() -> FakeGazetteer {
    return FakeGazetteer();
}

def vehicles() -> list[Vehicle] {
    return [
        Vehicle(vehicle_id="AMB-03", kind="ambulance", capacity=8, depot_gn_id="KLN-001", depot_lat=6.95, depot_lon=79.98),
        Vehicle(vehicle_id="BOAT-01", kind="boat", capacity=8, depot_gn_id="KLN-003", depot_lat=6.93, depot_lon=79.88),
        Vehicle(vehicle_id="AMB-07", kind="ambulance", capacity=8, depot_gn_id="KLN-002", depot_lat=6.93, depot_lon=79.98)
    ];
}

"""Two corroborated, high-confidence clusters and one single-source cluster still
above the default floor."""
def clusters() -> list[IncidentCluster] {
    return [
        IncidentCluster(
            cluster_id="CL-1", member_report_ids=["R-1", "R-2"], centroid_lat=6.9497, centroid_lon=79.9853,
            gn_id="KLN-001", hazard_type=HazardType.FLOOD, confidence_0_1=0.91, state=ClusterState.CORROBORATED,
            corroborating_source_count=3, first_seen=NOW, last_seen=NOW
        ),
        IncidentCluster(
            cluster_id="CL-2", member_report_ids=["R-3"], centroid_lat=6.9339, centroid_lon=79.9836,
            gn_id="KLN-002", hazard_type=HazardType.MEDICAL, confidence_0_1=0.86, state=ClusterState.CORROBORATED,
            corroborating_source_count=2, first_seen=NOW, last_seen=NOW
        ),
        IncidentCluster(
            cluster_id="CL-3", member_report_ids=["R-4"], centroid_lat=6.9294, centroid_lon=79.8878,
            gn_id="KLN-003", hazard_type=HazardType.LANDSLIDE, confidence_0_1=0.62, state=ClusterState.SINGLE_SOURCE,
            corroborating_source_count=1, first_seen=NOW, last_seen=NOW
        )
    ];
}

def hazard() -> HazardSurface {
    return HazardSurface(
        surface_id="HS-1", version=1, generated_at=NOW, method=HazardMethod.HAND, confidence_0_1=0.8,
        inundation_geojson={"type": "FeatureCollection", "features": []},
        susceptibility_geojson={"type": "FeatureCollection", "features": []},
        impassable_edge_ids=["E-500", "E-501"], no_go_gn_ids=["KLN-009"], driving_rainfall_mm_24h=180.0
    );
}

"""A plan every check should pass: real destinations, routes clear of the impassable
edges, loads within capacity, confident targets."""
def valid_plan() -> DispatchPlan {
    return DispatchPlan(
        plan_id="PLN-1", version=1, generated_at=NOW,
        assignments=[
            Assignment(vehicle_id="AMB-03", cluster_id="CL-1", route_edge_ids=["E-1", "E-2"], eta_minutes=14.0, distance_km=5.0, load=4),
            Assignment(vehicle_id="BOAT-01", cluster_id="CL-3", route_edge_ids=["E-3", "E-4"], eta_minutes=22.0, distance_km=9.0, load=6),
            Assignment(vehicle_id="AMB-07", cluster_id="CL-2", route_edge_ids=["E-5", "E-6"], eta_minutes=19.0, distance_km=7.0, load=3)
        ],
        objective_value=41.0, optimality_gap=0.018, solver_status=SolverStatus.OPTIMAL, solve_seconds=1.4,
        warm_started=True, input_surface_version=1, input_queue_hash="qh-1"
    );
}

"""A copy of `plan` with one assignment's fields overridden."""
def replace_assignment(plan: DispatchPlan, index: int, **updates: any) -> DispatchPlan {
    assignments = list(plan.assignments);
    assignments[index] = evolve(assignments[index], **updates);
    return evolve(plan, assignments=assignments);
}
