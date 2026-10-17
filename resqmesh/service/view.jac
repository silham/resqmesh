"""The incident view: the whole picture the console polls, in one JSON document.

Built by the worker after every command and served from memory, so a read never
touches the runner. Everything here is derived from the state: the pending decision,
the escalation, the current bulletins, which clusters are served and where each crew
is committed are all folds over the append-only record, never stored separately.
"""

import logging;
import from datetime { datetime, UTC }
import from resqmesh.agents.comms.lifecycle { current as current_alerts }
import from resqmesh.contracts.enums { IncidentStatus }
import from resqmesh.contracts.models { DispatchPlan, to_json }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.commitments { latest, served_cluster_ids }
import from resqmesh.graph.predicates {
    A5_REJECTED, GATE_REQUESTED, awaiting_commander, consecutive_rejections, halted, last_index, trace_of
}

glob log: any = logging.getLogger(__name__);

"""How much of the audit trail one poll carries."""
glob TRACE_TAIL: int = 200;

def iso(moment: datetime | None) -> str | None {
    return to_json(moment) if moment is not None else None;
}

"""Edge ids "u-v-k" -> [[lon, lat], ...] along the road, consecutive duplicates removed.
An empty list when any node is missing from the graph."""
def route_coordinates(g: any, edge_ids: list[str]) -> list[list[float]] {
    coords: list[list[float]] = [];
    for eid in edge_ids {
        parts = eid.rsplit("-", 2);
        for raw in [parts[0], parts[1]] {
            node_id: any = int(raw) if raw.lstrip("-").isdigit() else raw;
            if node_id not in g.nodes {
                return [];
            }
            data = g.nodes[node_id];
            pt = [float(data["x"]), float(data["y"])];
            if not coords or coords[-1] != pt {
                coords.append(pt);
            }
        }
    }
    return coords;
}

"""The map lines for the current plan, one per assignment, as [lon, lat] pairs.
A crew already on site is a real zero-length route; missing geometry is drawn as a
straight line flagged `approximate`, so the map dashes it."""
def plan_routes(state: IncidentState, g: any) -> list[dict[str, any]] {
    plan = state.plan;
    if plan is None {
        return [];
    }
    clusters = {c.cluster_id: c for c in state.clusters or []};
    vehicles = {v.vehicle_id: v for v in state.vehicles or []};
    out: list[dict[str, any]] = [];
    for a in plan.assignments {
        v = vehicles.get(a.vehicle_id);
        c = clusters.get(a.cluster_id);
        straight: list[list[float]] = [];
        if v is not None and c is not None {
            straight = [[v.depot_lon, v.depot_lat], [c.centroid_lon, c.centroid_lat]];
        }
        if not a.route_edge_ids and straight {
            out.append({"vehicle_id": a.vehicle_id, "cluster_id": a.cluster_id, "coordinates": straight, "approximate": False});
            continue;
        }
        coords = route_coordinates(g, a.route_edge_ids) if g is not None else [];
        if len(coords) >= 2 {
            out.append({"vehicle_id": a.vehicle_id, "cluster_id": a.cluster_id, "coordinates": coords, "approximate": False});
        } elif straight {
            out.append({"vehicle_id": a.vehicle_id, "cluster_id": a.cluster_id, "coordinates": straight, "approximate": True});
        }
    }
    return out;
}

"""Impassable roads as map lines from the original graph (they no longer exist in the
pruned one). Keeps actual edge geometry, bends included; never draws across a gap."""
def blocked_road_features(g: any, edge_ids: list[str]) -> dict[str, any] {
    import from resqmesh.adapters.geo.roads { edge_id }
    wanted = set(edge_ids);
    features: list[dict[str, any]] = [];
    for (u, v, key, data) in g.edges(keys=True, data=True) {
        eid = edge_id(u, v, key);
        if eid not in wanted {
            continue;
        }
        geom = data.get("geometry");
        geometry: dict[str, any] = {};
        if geom is not None and hasattr(geom, "__geo_interface__") {
            geometry = dict(geom.__geo_interface__);
            if geometry["type"] not in ["LineString", "MultiLineString"] {
                continue;
            }
            geometry = {"type": geometry["type"], "coordinates": to_lists(geometry["coordinates"])};
        } else {
            a = g.nodes[u];
            b = g.nodes[v];
            geometry = {"type": "LineString", "coordinates": [[float(a["x"]), float(a["y"])], [float(b["x"]), float(b["y"])]]};
        }
        features.append({"type": "Feature", "geometry": geometry, "properties": {"edge_id": eid, "status": "impassable"}});
    }
    return {"type": "FeatureCollection", "features": features};
}

"""Nested tuples (shapely's geo interface) as nested lists, so the result is plain JSON."""
def to_lists(value: any) -> any {
    if isinstance(value, (list, tuple)) {
        return [to_lists(v) for v in value];
    }
    return value;
}

"""The whole console view as a JSON document. Field names are the contract the
console reads."""
def build_view(
    state: IncidentState,
    busy: bool,
    commands: list[dict[str, any]],
    divisions: dict[str, dict[str, any]],
    llm: dict[str, any],
    routes: list[dict[str, any]],
    blocked_roads: dict[str, any] | None,
    now: datetime | None = None
) -> dict[str, any] {
    moment = now or datetime.now(UTC);
    plan: DispatchPlan | None = state.plan;
    trace = trace_of(state);
    pending: dict[str, any] | None = None;
    # Under an emergency halt the panel must not invite a Tier C action.
    if plan is not None and not halted(state) and awaiting_commander(state) {
        idx = last_index(trace, "gate", GATE_REQUESTED);
        at = trace[idx].occurred_at if idx >= 0 else moment;
        pending = {"plan_id": plan.plan_id, "plan_version": plan.version, "requested_at": iso(at)};
    }
    # A0 gave up on this plan. Its own field, because "no decision pending" and "the
    # loop has stopped" look identical to a console otherwise.
    escalated: dict[str, any] | None = None;
    if state.status == IncidentStatus.ESCALATED and plan is not None {
        verdict = state.verdict;
        at_idx = last_index(trace, "A5", A5_REJECTED);
        since = trace[at_idx].occurred_at if at_idx >= 0 else (trace[-1].occurred_at if trace else moment);
        escalated = {
            "violated_constraint": verdict.violated_constraint if verdict is not None else None,
            "remediation_hint": verdict.remediation_hint if verdict is not None else None,
            "rejections": consecutive_rejections(state),
            "plan_id": plan.plan_id,
            "plan_version": plan.version,
            "since": iso(since)
        };
    }
    return {
        "incident_id": state.incident_id,
        "goal": state.goal,
        "status": to_json(state.status or IncidentStatus.OPEN),
        "updated_at": iso(trace[-1].occurred_at if trace else moment),
        "busy": busy,
        "awaiting_decision": pending,
        "escalated": escalated,
        "clusters": to_json(state.clusters or []),
        "queue": to_json(state.queue or []),
        "reports": to_json(state.reports or []),
        "unresolved": to_json(state.unresolved_queue or []),
        "hazard": to_json(state.hazard),
        "plan": to_json(plan),
        "routes": routes,
        "blocked_roads_geojson": blocked_roads,
        "verdict": to_json(state.verdict),
        "approvals": to_json(state.approvals or []),
        "sitreps": to_json(state.sitreps or []),
        # Folded: the current bulletins, newest first. The raw log is append-only, so
        # showing it verbatim would leave a superseded warning beside its replacement.
        "alerts": to_json(current_alerts(state.alerts or [], moment)),
        # Derived, not stored: a report arriving after the crew stood down re-opens it.
        "completed_cluster_ids": served_cluster_ids(state),
        "commitments": to_json(list(latest(state).values())),
        "vehicles": to_json(state.vehicles or []),
        "divisions": divisions,
        "trace": to_json(trace[-TRACE_TAIL:]),
        "commands": commands,
        "llm": llm
    };
}
