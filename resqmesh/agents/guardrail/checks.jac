"""The individual guardrail assertions.

Each function answers exactly one adversarial question about a proposed plan and
returns a GuardrailCheck. They are pure and deterministic (no model, no network)
because a safety gate that cannot be re-run identically is not a safety gate: A4
proposes numbers, A5 recomputes and confirms them.

Two of these, gazetteer membership and the source-binding pair, back the two hard
constraints. A single failure of either is a guardrail-layer failure irrespective of
every other metric, because each is the failure mode that would make an autonomous
system in this domain unsafe to deploy.

The whole module fails closed: a missing precondition (an absent hazard surface, a
cluster the plan references but the state does not hold) is a rejection, never a
silent pass.
"""

import from shapely.geometry { LineString, Point }
import from resqmesh.adapters.geo.shapes { prepared, union_of }
import from resqmesh.contracts.enums { ClusterState }
import from resqmesh.contracts.models {
    DispatchPlan, GuardrailCheck, HazardSurface, IncidentCluster, SourcedClaim, Vehicle
}
import from resqmesh.contracts.ports { GeocodePort }

# Check names are stable identifiers. They travel into the verdict as the violated
# constraint and A0 routes a targeted re-solve on them, so renaming one is a breaking
# change to the correction loop.
glob TARGETS_EXIST: str = "targets_exist";
glob GAZETTEER_MEMBERSHIP: str = "gazetteer_membership";
glob NO_GO_INTERSECTION: str = "no_go_intersection";
glob VEHICLE_CAPACITY: str = "vehicle_capacity";
glob TIER_C_CONFIDENCE_FLOOR: str = "tier_c_confidence_floor";
glob SOURCE_BINDING: str = "source_binding";

def index_clusters(clusters: list[IncidentCluster]) -> dict[str, IncidentCluster] {
    return {c.cluster_id: c for c in clusters};
}

def index_vehicles(vehicles: list[Vehicle]) -> dict[str, Vehicle] {
    return {v.vehicle_id: v for v in vehicles};
}

"""Every assignment must name a cluster and a vehicle the state actually holds.

Runs first: the remaining checks index into these collections, so a phantom cluster
or vehicle would otherwise surface as a confusing error deep inside another check."""
def check_targets_exist(
    plan: DispatchPlan, clusters: list[IncidentCluster], vehicles: list[Vehicle]
) -> GuardrailCheck {
    cluster_ids = {c.cluster_id for c in clusters};
    vehicle_ids = {v.vehicle_id for v in vehicles};
    dangling: list[str] = [];
    for a in plan.assignments {
        if a.cluster_id not in cluster_ids {
            dangling.append(f"cluster {a.cluster_id}");
        }
        if a.vehicle_id not in vehicle_ids {
            dangling.append(f"vehicle {a.vehicle_id}");
        }
    }
    if dangling {
        return GuardrailCheck(name=TARGETS_EXIST, passed=False, detail=f"assignment references unknown {', '.join(dangling)}");
    }
    return GuardrailCheck(name=TARGETS_EXIST, passed=True, detail="all assignments resolve to known state");
}

"""HARD CONSTRAINT. No dispatch to a place that is not a real GN division.

This makes the most dangerous hallucination, a confidently invented location,
structurally impossible to act on. Target: exactly 0 violations, ever."""
def check_gazetteer_membership(
    plan: DispatchPlan, clusters: list[IncidentCluster], gazetteer: GeocodePort
) -> GuardrailCheck {
    by_id = index_clusters(clusters);
    offenders: list[str] = [];
    for a in plan.assignments {
        cluster = by_id.get(a.cluster_id);
        if cluster is None {
            # targets_exist owns the phantom-cluster message; here we just fail closed.
            offenders.append(f"{a.cluster_id} (absent)");
            continue;
        }
        if not gazetteer.contains(cluster.gn_id) {
            offenders.append(f"{a.cluster_id} -> {cluster.gn_id}");
        }
    }
    if offenders {
        return GuardrailCheck(name=GAZETTEER_MEMBERSHIP, passed=False, detail=f"destination not in gazetteer: {', '.join(offenders)}");
    }
    return GuardrailCheck(name=GAZETTEER_MEMBERSHIP, passed=True, detail="every destination is a real GN division");
}

"""Water is a road for a boat and a wall for everything else.

Defined here rather than borrowed from A4: a guardrail that takes its definitions
from the agent it audits is not an independent check."""
def is_boat(vehicle: Vehicle | None) -> bool {
    return vehicle is not None and "boat" in vehicle.kind.lower();
}

def segment_in(flooded: any, seg: list[float]) -> bool {
    lat1 = seg[0];
    lon1 = seg[1];
    lat2 = seg[2];
    lon2 = seg[3];
    if lat1 == lat2 and lon1 == lon2 {
        return bool(flooded.intersects(Point(lon1, lat1)));
    }
    return bool(flooded.intersects(LineString([(lon1, lat1), (lon2, lat2)])));
}

"""No assigned journey may pass through water the vehicle cannot cross.

On-graph: A2 pruned the impassable edges, so a correct A4 could not have routed over
one; A5 re-derives the intersection anyway. Off-graph: the access legs at each end
own no edge ids, so an edge-set test cannot see them, and for a flood the final leg
ends where the water is. A boat's access leg over the inundation is legal by design;
every other vehicle wading is a rejection.

Fails closed when the hazard surface is absent."""
def check_no_go_intersection(
    plan: DispatchPlan, hazard: HazardSurface | None, vehicles: list[Vehicle] | None = None
) -> GuardrailCheck {
    if hazard is None {
        return GuardrailCheck(
            name=NO_GO_INTERSECTION, passed=False,
            detail="no hazard surface available; cannot verify routes (failing closed)"
        );
    }
    impassable = set(hazard.impassable_edge_ids);
    by_vehicle = index_vehicles(vehicles or []);
    water = union_of(hazard.inundation_geojson);
    flooded: any = prepared(water) if water is not None and not water.is_empty else None;
    offenders: list[str] = [];
    for a in plan.assignments {
        crossed = impassable.intersection(a.route_edge_ids);
        if crossed {
            offenders.append(f"{a.vehicle_id}->{a.cluster_id} via {sorted(crossed)}");
        }
        if flooded is None or is_boat(by_vehicle.get(a.vehicle_id)) {
            continue;
        }
        wet = len([seg for seg in a.access_segments if segment_in(flooded, seg)]);
        if wet {
            offenders.append(f"{a.vehicle_id}->{a.cluster_id} wades {wet} access leg(s) through the inundation");
        }
    }
    if offenders {
        return GuardrailCheck(name=NO_GO_INTERSECTION, passed=False, detail=f"journey crosses impassable terrain: {'; '.join(offenders)}");
    }
    return GuardrailCheck(name=NO_GO_INTERSECTION, passed=True, detail="no journey crosses a no-go segment, on or off the graph");
}

"""No assignment may load a vehicle beyond its stated capacity."""
def check_vehicle_capacity(plan: DispatchPlan, vehicles: list[Vehicle]) -> GuardrailCheck {
    by_id = index_vehicles(vehicles);
    offenders: list[str] = [];
    for a in plan.assignments {
        vehicle = by_id.get(a.vehicle_id);
        if vehicle is None {
            offenders.append(f"{a.vehicle_id} (absent)");
            continue;
        }
        if a.load > vehicle.capacity {
            offenders.append(f"{a.vehicle_id} load {a.load} > capacity {vehicle.capacity}");
        }
    }
    if offenders {
        return GuardrailCheck(name=VEHICLE_CAPACITY, passed=False, detail=f"capacity exceeded: {', '.join(offenders)}");
    }
    return GuardrailCheck(name=VEHICLE_CAPACITY, passed=True, detail="no vehicle over capacity");
}

"""A dispatch (Tier C) may not rest on evidence below the confidence floor.

A single uncorroborated report cannot alone commit a crew, and genuinely balanced
contradictory evidence (UNRESOLVED) can be triaged but must never alone justify
sending people into danger, whatever number is attached to it."""
def check_tier_c_confidence_floor(
    plan: DispatchPlan, clusters: list[IncidentCluster], floor: float
) -> GuardrailCheck {
    by_id = index_clusters(clusters);
    offenders: list[str] = [];
    for a in plan.assignments {
        cluster = by_id.get(a.cluster_id);
        if cluster is None {
            offenders.append(f"{a.cluster_id} (absent)");
            continue;
        }
        if cluster.state == ClusterState.UNRESOLVED {
            offenders.append(f"{a.cluster_id} (unresolved)");
        } elif cluster.confidence_0_1 < floor {
            offenders.append(f"{a.cluster_id} (conf {cluster.confidence_0_1:.2f} < {floor:.2f})");
        }
    }
    if offenders {
        return GuardrailCheck(name=TIER_C_CONFIDENCE_FLOOR, passed=False, detail=f"Tier C below confidence floor: {', '.join(offenders)}");
    }
    return GuardrailCheck(name=TIER_C_CONFIDENCE_FLOOR, passed=True, detail=f"every dispatched cluster is resolved and >= {floor:.2f}");
}

# ------------------------------------------------ source binding: the SITREP constraint

"""Claims whose source_ref binds to no report, cluster or dataset we hold. The contract
forbids an empty ref, so the residual danger is a plausible but fabricated id."""
def unsourced_claims(claims: list[SourcedClaim], known_refs: set[str]) -> list[SourcedClaim] {
    return [c for c in claims if c.source_ref not in known_refs];
}

"""The surviving claims. Unsourced sentences are removed before the commander sees them."""
def strip_unsourced(claims: list[SourcedClaim], known_refs: set[str]) -> list[SourcedClaim] {
    return [c for c in claims if c.source_ref in known_refs];
}

"""HARD CONSTRAINT. Every factual SITREP sentence must bind to real evidence."""
def check_source_binding(claims: list[SourcedClaim], known_refs: set[str]) -> GuardrailCheck {
    dangling = unsourced_claims(claims, known_refs);
    if dangling {
        preview = "; ".join([c.source_ref for c in dangling[:3]]);
        return GuardrailCheck(name=SOURCE_BINDING, passed=False, detail=f"{len(dangling)} claim(s) bind to unknown source(s): {preview}");
    }
    return GuardrailCheck(name=SOURCE_BINDING, passed=True, detail="every claim binds to known evidence");
}
