"""The flat situational map: hazard polygons, incident clusters coloured by priority,
dispatch routes and vehicle positions. Read-only: the map shows the system's picture, it
does not edit it.

Two deliberate choices about what the map claims to know:

* Vehicles are drawn at their depot, because that is the only position the system actually
  knows. There is no GPS feed and no responder check-in.
* Once a plan is approved, a hollow dashed marker shows where each crew is *estimated* to
  be, from the approval time and the solver's ETA, and says so. A solid icon sliding along
  the road would present a guess as a measurement.
"""

import from "react" { useEffect, useMemo }
import from "react-leaflet" { CircleMarker, GeoJSON, MapContainer, Marker, Polyline, Popup, TileLayer, Tooltip, useMap }
import from "leaflet" { svg }
import from ..lib.format { clusterPlace, clusterScore, dispatchedAt, divisionName, hazardColor, isCompleted, navigationUrl, prettyHazard, priorityBand }
import from ..lib.route { estimatedProgress, orientedFromDepot, pointAlong, toLatLon }
import from ..lib.vehicleIcon { vehicleIcon }
import from ..lib.incidentMap { hazardData, overviewPoints }
import from .MapLegend { MapLegend }

glob BAND_HEX: dict[str, str] = {
    "red": "#e03131", "orange": "#f08c00", "green": "#2f9e44", "gray": "#868e96"
};

glob ROUTE: str = "#0bbbb1";

# Size carries urgency, so the eye lands on the worst emergency first and the fleet reads
# as secondary to it. A P1 incident must never be the smallest thing on the map.
glob BAND_RADIUS: dict[str, int] = {"red": 15, "orange": 12, "green": 10, "gray": 9};

# One icon object per look. A fresh divIcon on every render makes Leaflet rebuild the
# marker's DOM, which the one-second ticker would otherwise do every second.
glob ICONS: dict[str, any] = {};

def iconFor(kind: str, dispatched: bool) -> any {
    key = kind + ("|on" if dispatched else "|off");
    if not ICONS[key] {
        ICONS[key] = vehicleIcon(kind, dispatched);
    }
    return ICONS[key];
}

def hasScore(score: any) -> bool {
    return Number.isFinite(score);
}

"""A second-resolution clock, only while something is actually moving.

The incident view is polled every few seconds, which would advance the estimate in
visible jumps. The ticker smooths it without touching the network, and stops entirely
when no crew is en route so an idle console is not re-rendering forever."""
def useTicker(active: bool) -> any {
    has now: any = new(Date);
    useEffect(lambda {
        timer: any = None;
        if active {
            timer = setInterval(lambda { now = new(Date); }, 1000);
        }
        return lambda {
            if timer {
                clearInterval(timer);
            }
        };
    }, [active]);
    return now;
}

"""Frame the incidents, depots and hazard extent once, when there is something to frame.
After that the commander's own panning and zooming is left alone."""
def FitToOverview(view: any) -> JsxElement {
    map: any = useMap();
    has fitted: Ref[bool] = Ref(False);
    points: list[any] = overviewPoints(view);
    count: int = len(points);
    useEffect(lambda {
        if fitted.current or count == 0 {
            return;
        }
        lat0: float = points[0][1];
        lon0: float = points[0][0];
        south: float = lat0;
        north: float = lat0;
        west: float = lon0;
        east: float = lon0;
        for p in points {
            south = min(south, p[1]);
            north = max(north, p[1]);
            west = min(west, p[0]);
            east = max(east, p[0]);
        }
        map.fitBounds([[south, west], [north, east]], {"padding": [40, 40], "maxZoom": 13});
        fitted.current = True;
    }, [count]);
    <></>
}

def RouteLayer(view: any, route: any, depot: any, approvedAt: any, now: any, renderer: any) -> JsxElement {
    line: any = toLatLon(route);
    if depot {
        line = orientedFromDepot(line, depot);
    }
    progress = estimatedProgress(view, route, approvedAt, now);
    at: any = None;
    flowing: bool = False;
    if progress {
        at = pointAlong(line, progress["fraction"]);
        # Flowing only once a crew is authorised to move and has not yet arrived. An
        # unapproved plan is a proposal, and a proposal should not look like traffic.
        flowing = not progress["arrived"];
    }
    place = clusterPlace(view, route["cluster_id"]);
    flowClass: any = "resqmesh-route-flow" if flowing else None;
    dash: any = "6 6" if (route["approximate"] and not flowing) else None;

    <>
        {#* Leaflet reads `className` and `renderer` only when it creates the path, and
            react-leaflet applies `pathOptions` later through setStyle. So these are passed
            as plain props (creation options), and the key remounts the line the moment a
            commander approves it; otherwise the dashes would never start marching. *#}
        <Polyline
            key={"line-" + ("flow" if flowing else "static") + ("-approx" if route["approximate"] else "")}
            positions={line}
            renderer={renderer}
            color={ROUTE}
            weight={4}
            opacity={0.85}
            className={flowClass}
            dashArray={dash}
        >
            <Tooltip sticky={True}>
                {route["vehicle_id"] + " → " + place + (" · straight-line estimate (no road geometry)" if route["approximate"] else "")}
            </Tooltip>
        </Polyline>

        {#* The estimate is shown only while it still says something. Once the ETA is
            spent the marker would park on the incident dot, and whether the crew actually
            arrived is precisely what the system cannot know. So it disappears and the
            incident marker, which is real, stands alone. *#}
        {if at and progress and not progress["arrived"] {
            <CircleMarker
                center={at}
                radius={6}
                renderer={renderer}
                color={ROUTE}
                weight={2}
                dashArray="3 3"
                fillColor="#ffffff"
                fillOpacity={0.9}
            >
                <Tooltip direction="top">
                    {route["vehicle_id"] + " · "}<strong>estimated</strong>{" position"}
                    <br />
                    {progress["elapsedMin"].toFixed(0) + " of ~" + progress["etaMin"].toFixed(0) + " min to " + place}
                    <br />
                    <em>inferred from ETA — the vehicle does not report its position</em>
                </Tooltip>
            </CircleMarker>
        }}
    </>
}

def ClusterLayer(view: any, c: any) -> JsxElement {
    score: any = clusterScore(view, c);
    scored: bool = hasScore(score);
    band: any = {"color": "gray", "label": "?"};
    if scored {
        band = priorityBand(score);
    }
    place = divisionName(view, c["gn_id"]);
    # A responder has reported this one served. It stops competing for the commander's
    # attention, or the map contradicts the crew's own screen, but it stays on the map:
    # an incident that happened is part of the picture and the audit trail.
    done: bool = isCompleted(view, c["cluster_id"]);
    radius: int = 8 if done else BAND_RADIUS[band["color"]];
    options: dict[str, any] = {
        "color": "#868e96" if done else hazardColor(c["hazard_type"]),
        "weight": 2,
        "fillColor": "#ced4da" if done else BAND_HEX[band["color"]],
        "fillOpacity": 0.55 if done else 0.85
    };
    if done {
        options["dashArray"] = "3 3";
    }
    tip: str = ("SERVED · " + place) if done else (band["label"] + " · " + place + " · " + prettyHazard(c["hazard_type"]));

    <CircleMarker
        key={c["cluster_id"] + ("-done" if done else "-open")}
        center={[c["centroid_lat"], c["centroid_lon"]]}
        radius={radius}
        pathOptions={options}
    >
        <Tooltip direction="top">{tip}</Tooltip>
        <Popup>
            <strong>{place}</strong>{" — " + prettyHazard(c["hazard_type"])}
            {if done {
                <>
                    <br />
                    <strong style={{"color": "#2f9e44"}}>served — reported complete by the crew</strong>
                </>
            }}
            <br />
            {"confidence " + (c["confidence_0_1"] * 100).toFixed(0) + "% · " + c["state"].replace("_", " ")}
            {if scored {
                <>
                    <br />
                    {"priority " + (score * 100).toFixed(0)}
                </>
            }}
            <br />
            <a href={navigationUrl(c["centroid_lat"], c["centroid_lon"])} target="_blank" rel="noreferrer">
                Navigate to location →
            </a>
            <br />
            <small style={{"color": "#868e96"}}>{c["gn_id"]}</small>
        </Popup>
    </CircleMarker>
}

def VehicleLayer(view: any, v: any, dispatched: bool) -> JsxElement {
    <Marker position={[v["depot_lat"], v["depot_lon"]]} icon={iconFor(v["kind"], dispatched)}>
        <Tooltip direction="top">
            <strong>{v["vehicle_id"]}</strong>
            {" · " + v["kind"] + " · capacity " + str(v["capacity"])}
            <br />
            {("dispatched" if dispatched else "available") + " · depot " + divisionName(view, v["depot_gn_id"])}
        </Tooltip>
    </Marker>
}

def:pub Map2D(view: any) -> JsxElement {
    hazard = view["hazard"];
    inundation: any = hazardData(hazard["inundation_geojson"] if hazard else None);
    susceptibility: any = hazardData(hazard["susceptibility_geojson"] if hazard else None);
    blocked: any = hazardData(view["blocked_roads_geojson"]);
    version: str = str(hazard["version"]) if hazard else "none";

    # The hazard polygons can be large, so the map renders to canvas, but a canvas path
    # cannot carry a CSS animation. Routes get their own SVG renderer so the flowing
    # dashes work while the heavy layers stay on canvas.
    renderer: any = useMemo(lambda { return svg(); }, []);

    approvedAt = dispatchedAt(view);
    enRoute: bool = False;
    if approvedAt and len(view["routes"]) > 0 {
        enRoute = True;
    }
    now: any = useTicker(enRoute);

    depots: dict[str, any] = {};
    for v in view["vehicles"] {
        depots[v["vehicle_id"]] = [v["depot_lat"], v["depot_lon"]];
    }
    committed: dict[str, bool] = {};
    if view["plan"] {
        for a in view["plan"]["assignments"] {
            committed[a["vehicle_id"]] = True;
        }
    }

    <div style={{"position": "relative", "height": "100%", "width": "100%"}}>
        <MapLegend />
        <MapContainer center={[6.95, 79.98]} zoom={12} style={{"height": "100%", "width": "100%"}} preferCanvas={True}>
            <FitToOverview view={view} />
            <TileLayer attribution="&copy; OpenStreetMap contributors" url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" />

            {if susceptibility["type"] != "FeatureCollection" or len(susceptibility["features"]) > 0 {
                <GeoJSON
                    key={"susc-" + version}
                    data={susceptibility}
                    style={{"color": "#e8730c", "weight": 1, "fillColor": "#e8730c", "fillOpacity": 0.15}}
                />
            }}
            {if inundation["type"] != "FeatureCollection" or len(inundation["features"]) > 0 {
                <GeoJSON
                    key={"inun-" + version}
                    data={inundation}
                    style={{"color": "#2f6fed", "weight": 1, "fillColor": "#2f6fed", "fillOpacity": 0.2}}
                />
            }}
            {if blocked["type"] != "FeatureCollection" or len(blocked["features"]) > 0 {
                <GeoJSON key={"blocked-" + version} data={blocked} style={{"color": "#e03131", "weight": 4, "opacity": 0.9}}>
                    <Tooltip sticky={True}>Impassable road — modelled hazard or reported blockage</Tooltip>
                </GeoJSON>
            }}

            {for (i, route) in enumerate(view["routes"]) {
                <RouteLayer
                    key={"route-" + route["vehicle_id"] + "-" + route["cluster_id"] + "-" + str(i)}
                    view={view}
                    route={route}
                    depot={depots[route["vehicle_id"]]}
                    approvedAt={approvedAt}
                    now={now}
                    renderer={renderer}
                />
            }}

            {for c in view["clusters"] {
                <ClusterLayer key={c["cluster_id"]} view={view} c={c} />
            }}

            {for v in view["vehicles"] {
                <VehicleLayer key={v["vehicle_id"]} view={view} v={v} dispatched={bool(committed[v["vehicle_id"]])} />
            }}
        </MapContainer>
    </div>
}
