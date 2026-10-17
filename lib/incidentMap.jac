"""Map data preparation for the 3D map: turn the incident view into the GeoJSON sources
the renderer draws, and say when a source actually has to be rewritten.

Coordinates inside this module follow GeoJSON ([lon, lat]) once they leave the route
helpers, which work in Leaflet order ([lat, lon]).
"""

import from .format { dispatchedAt }
import from .route { estimatedProgress, orientedFromDepot, pointAlong, toLatLon }

glob EMPTY: dict[str, any] = {"type": "FeatureCollection", "features": []};

"""Hazard objects are legitimate API values before a surface has been produced; anything
that is not a GeoJSON object draws as nothing."""
def:pub hazardData(value: any) -> any {
    if not value or not value["type"] {
        return EMPTY;
    }
    return value;
}

def routeIdOf(route: any) -> str {
    return JSON.stringify([route["vehicle_id"], route["cluster_id"]]);  # jac:ignore[E1032,E1001,E1002]
}

"""Each route with a stable id and its line oriented depot-first."""
def prepareRoutes(view: any) -> list[any] {
    depots: dict[str, any] = {};
    for v in view["vehicles"] {
        depots[v["vehicle_id"]] = [v["depot_lat"], v["depot_lon"]];
    }
    out: list[any] = [];
    for route in view["routes"] {
        depot = depots[route["vehicle_id"]];
        line: any = toLatLon(route);
        if depot {
            line = orientedFromDepot(line, depot);
        }
        out = out + [{"route": route, "routeId": routeIdOf(route), "line": line}];
    }
    return out;
}

"""Does an approved assignment with a real ETA exist whose approval time is still ahead
of the browser clock? That happens when the browser clock lags the server's."""
def awaitsClock(view: any, route: any, approvedAt: any, now: any) -> bool {
    if not approvedAt or approvedAt.getTime() <= now.getTime() or not view["plan"] {
        return False;
    }
    for a in view["plan"]["assignments"] {
        if a["vehicle_id"] == route["vehicle_id"] and a["cluster_id"] == route["cluster_id"] and a["eta_minutes"] > 0 {
            return True;
        }
    }
    return False;
}

"""One updater per map.

The incident view is polled, and unchanged nested JSON keeps its identity from one poll
to the next. The large sources (flood, slope, roads, routes) are therefore written to the
renderer only when their data is a different object from the one last sent; a clock tick
only has to move the handful of estimated crew positions. `update` returns whether
another clock tick is needed.

`write(sourceId, data)` hands a source to the renderer and `setFlowing(routeIds)` says
which routes carry the flow animation."""
obj:pub MapDataUpdater {
    has write: any,
        setFlowing: any,
        sent: any = None,
        previousRoutes: any = None,
        previousVehicles: any = None,
        prepared: list[any] = [],
        estimateKey: str = "",
        flowingKey: str = "[]";

    def send(sourceId: str, data: any) -> None {
        if self.sent is None {
            self.sent = {};
        }
        if self.sent[sourceId] is data {
            return;
        }
        self.write.call(None, sourceId, data);
        self.sent[sourceId] = data;
    }

    def update(view: any, now: any) -> bool {
        hazard = view["hazard"];
        self.send("flood", hazardData(hazard["inundation_geojson"] if hazard else None));
        self.send("slope", hazardData(hazard["susceptibility_geojson"] if hazard else None));
        self.send("roads", hazardData(view["blocked_roads_geojson"]));

        if self.previousRoutes is not view["routes"] or self.previousVehicles is not view["vehicles"] {
            self.prepared = prepareRoutes(view);
            features: list[any] = [];
            for item in self.prepared {
                line = item["line"];
                if len(line) < 2 {
                    continue;
                }
                features = features + [{
                    "type": "Feature",
                    "geometry": {"type": "LineString", "coordinates": [[p[1], p[0]] for p in line]},
                    "properties": {"routeId": item["routeId"], "approximate": item["route"]["approximate"]}
                }];
            }
            self.send("routes", {"type": "FeatureCollection", "features": features});
            self.previousRoutes = view["routes"];
            self.previousVehicles = view["vehicles"];
        }

        approvedAt = dispatchedAt(view);
        points: list[any] = [];
        flowing: list[str] = [];
        waiting: bool = False;
        for item in self.prepared {
            route = item["route"];
            if awaitsClock(view, route, approvedAt, now) {
                waiting = True;
            }
            progress = estimatedProgress(view, route, approvedAt, now);
            if not progress or progress["arrived"] {
                continue;
            }
            at = pointAlong(item["line"], progress["fraction"]);
            if not at {
                continue;
            }
            points = points + [{
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [at[1], at[0]]},
                "properties": {"routeId": item["routeId"]}
            }];
            # An approximate route is a straight-line guess; it does not get to flow.
            if not route["approximate"] {
                flowing = flowing + [item["routeId"]];
            }
        }
        # Only the few moving points are serialised, never the road or flood layers.
        estimates = {"type": "FeatureCollection", "features": points};
        nextEstimateKey = JSON.stringify(estimates);  # jac:ignore[E1032,E1001,E1002]
        if nextEstimateKey != self.estimateKey {
            self.send("estimates", estimates);
            self.estimateKey = nextEstimateKey;  # jac:ignore[E1032,E1001,E1002]
        }
        nextFlowingKey = JSON.stringify(flowing);  # jac:ignore[E1032,E1001,E1002]
        if nextFlowingKey != self.flowingKey {
            self.setFlowing.call(None, flowing);
            self.flowingKey = nextFlowingKey;  # jac:ignore[E1032,E1001,E1002]
        }
        return len(points) > 0 or waiting;
    }
}

"""Collect every [lon, lat] pair nested in a GeoJSON coordinates array."""
def collectCoords(value: any, points: list[any]) -> None {
    if not Array.isArray(value) {  # jac:ignore[E1032,E1001,E1002]
        return;
    }
    if value.length >= 2 and Number.isFinite(value[0]) and Number.isFinite(value[1]) {  # jac:ignore[E1032,E1001,E1002]
        points.append([value[0], value[1]]);
        return;
    }
    for inner in value {
        collectCoords(inner, points);
    }
}

def collectGeo(value: any, points: list[any]) -> None {
    if not value {
        return;
    }
    if value["coordinates"] {
        collectCoords(value["coordinates"], points);
    }
    if value["geometry"] {
        collectGeo(value["geometry"], points);
    }
    if Array.isArray(value["features"]) {  # jac:ignore[E1032,E1001,E1002]
        for f in value["features"] {
            collectGeo(f, points);
        }
    }
    if Array.isArray(value["geometries"]) {  # jac:ignore[E1032,E1001,E1002]
        for g in value["geometries"] {
            collectGeo(g, points);
        }
    }
}

"""Every [lon, lat] the overview should frame: incidents, depots and the hazard extent,
so the flood is in shot even before any citizen report has arrived."""
def:pub overviewPoints(view: any) -> list[any] {
    raw: list[any] = [];
    for c in view["clusters"] {
        raw.append([c["centroid_lon"], c["centroid_lat"]]);
    }
    for v in view["vehicles"] {
        raw.append([v["depot_lon"], v["depot_lat"]]);
    }
    hazard = view["hazard"];
    if hazard {
        collectGeo(hazard["inundation_geojson"], raw);
        collectGeo(hazard["susceptibility_geojson"], raw);
    }
    collectGeo(view["blocked_roads_geojson"], raw);
    out: list[any] = [];
    for p in raw {
        if Number.isFinite(p[0]) and Number.isFinite(p[1]) and abs(p[0]) <= 180 and abs(p[1]) <= 90 {  # jac:ignore[E1032,E1001,E1002]
            out.append(p);
        }
    }
    return out;
}

