"""The 3D incident map: a tilted OpenStreetMap basemap with optional terrain and extruded
buildings, the hazard layers and routes as GeoJSON sources, and incident / vehicle
markers as real buttons.

The style is defined here rather than fetched, so a failed external style request cannot
stop the incident layers loading. If the renderer cannot start at all (no WebGL, worker
blocked) the panel is told through `onUnavailable` and shows the flat map instead.
"""

import "maplibre-gl/dist/maplibre-gl.css";
import from "react" { useEffect }
import from "@mantine/core" { Button, Group, Paper, SegmentedControl, Select, Stack, Text }
import from "maplibre-gl" { Map as GLMap, Marker, NavigationControl, LngLatBounds, setWorkerUrl }
import from "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url" { default as workerUrl }
import from ..lib.format { clusterPlace, clusterScore, divisionName, hazardColor, isCompleted, navigationUrl, prettyHazard, priorityBand }
import from ..lib.incidentMap { EMPTY, MapDataUpdater, overviewPoints }
import from ..lib.vehicleIcon { vehicleBadgeSvg }
import from .MapLegend { MapLegend }

glob COLORS: dict[str, str] = {"red": "#e03131", "orange": "#f08c00", "green": "#2f9e44", "gray": "#868e96"};
glob SIZES: dict[str, int] = {"red": 30, "orange": 24, "green": 20, "gray": 18};
glob TERRAIN_URL: str = "https://tiles.mapterhorn.com/tilejson.json";
glob QUALITY_KEY: str = "resqmesh.map-quality";
glob FLOW_STEPS: list[any] = [[0, 4, 3], [1, 4, 2], [2, 4, 1], [3, 4, 0]];

glob LAYER_KIND: dict[str, str] = {
    "estimates": "estimate", "roads": "road", "routes": "route", "routes-approximate": "route",
    "flood": "flood", "slope": "slope"
};

glob STYLE: dict[str, any] = {
    "version": 8,
    "sources": {
        "basemap": {
            "type": "raster",
            "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
            "tileSize": 256,
            "maxzoom": 19,
            "attribution": '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        },
        # Global elevation coverage stops at z12; higher-resolution tiles are regional.
        # Reuse the global elevation at street zoom instead of requesting absent tiles.
        "terrain": {"type": "raster-dem", "url": TERRAIN_URL, "maxzoom": 12},
        "buildings": {"type": "vector", "url": "https://tiles.openfreemap.org/planet"}
    },
    "layers": [
        {"id": "background", "type": "background", "paint": {"background-color": "#e6eef0"}},
        {"id": "basemap", "type": "raster", "source": "basemap"},
        {
            "id": "buildings",
            "type": "fill-extrusion",
            "source": "buildings",
            "source-layer": "building",
            "minzoom": 16,
            "filter": ["!=", ["get", "hide_3d"], True],
            "paint": {
                "fill-extrusion-color": "#a5b7bd",
                "fill-extrusion-opacity": 1,
                "fill-extrusion-height": ["coalesce", ["get", "render_height"], 0],
                "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0]
            }
        }
    ]
};

def motionDuration() -> int {
    reduce: any = window.matchMedia("(prefers-reduced-motion: reduce)");
    return 0 if reduce.matches else 1500;
}

def initiallyLight() -> bool {
    try {
        return localStorage.getItem(QUALITY_KEY) != "detailed";
    } except Exception {
        return True;
    }
}

def pixelRatioFor(light: bool) -> float {
    return 1.0 if light else min(window.devicePixelRatio, 1.5);
}

def overview(map: any, view: any, animate: bool) -> None {
    points: list[any] = overviewPoints(view);
    duration: int = motionDuration() if animate else 0;
    if len(points) == 0 {
        map.flyTo({"center": [79.98, 6.95], "zoom": 11, "pitch": 45, "bearing": -15, "duration": duration});
        return;
    }
    bounds: any = new(LngLatBounds, points[0], points[0]);
    for p in points {
        bounds.extend(p);
    }
    map.fitBounds(bounds, {
        "padding": {"top": 160, "bottom": 75, "left": 45, "right": 45},
        "maxZoom": 13, "pitch": 45, "bearing": -15, "duration": duration
    });
}

def addIncidentLayers(map: any) -> None {
    for id in ["flood", "slope", "roads", "routes", "estimates"] {
        map.addSource(id, {"type": "geojson", "data": EMPTY});
    }
    for pair in [["slope", "#e8730c"], ["flood", "#2f6fed"]] {
        map.addLayer({"id": pair[0], "type": "fill", "source": pair[0], "paint": {"fill-color": pair[1], "fill-opacity": 0.28}});
        map.addLayer({"id": pair[0] + "-outline", "type": "line", "source": pair[0], "paint": {"line-color": pair[1], "line-width": 1.2}});
    }
    map.addLayer({"id": "roads", "type": "line", "source": "roads", "paint": {"line-color": "#e03131", "line-width": 5, "line-opacity": 0.9}});
    map.addLayer({
        "id": "routes", "type": "line", "source": "routes",
        "filter": ["!=", ["get", "approximate"], True],
        "paint": {"line-color": "#0bbbb1", "line-width": 4}
    });
    map.addLayer({
        "id": "routes-approximate", "type": "line", "source": "routes",
        "filter": ["==", ["get", "approximate"], True],
        "paint": {"line-color": "#0bbbb1", "line-width": 4, "line-dasharray": [2, 2]}
    });
    # Marching white dashes over the routes a commander has approved. The filter starts
    # matching nothing and is narrowed by the data updater.
    map.addLayer({
        "id": "route-flow", "type": "line", "source": "routes",
        "filter": ["==", ["get", "routeId"], ""],
        "paint": {"line-color": "#ffffff", "line-width": 2, "line-dasharray": [0, 4, 3]}
    });
    map.addLayer({
        "id": "estimates", "type": "circle", "source": "estimates",
        "paint": {"circle-radius": 6, "circle-color": "#ffffff", "circle-stroke-color": "#0bbbb1", "circle-stroke-width": 2}
    });
}

"""Create or move the button marker for `key`, and return its element for styling."""
def putMarker(map: any, store: any, keep: any, key: str, kind: str, id: str, lon: float, lat: float, label: str, focusFn: any) -> any {
    keep[key] = True;
    marker: any = store[key];
    if not marker {
        button: any = document.createElement("button");
        button.type = "button";
        marker = new(Marker, {"element": button});
        marker.setLngLat([lon, lat]).addTo(map);
        store[key] = marker;
    }
    el: any = marker.getElement();
    position: any = marker.getLngLat();
    if position.lng != lon or position.lat != lat {
        marker.setLngLat([lon, lat]);
    }
    el.title = label;
    el.setAttribute("aria-label", label);
    selection: dict[str, any] = {"kind": kind, "id": id, "at": [lon, lat]};
    el.onclick = lambda (event: any) {
        event.stopPropagation();
        focusFn.call(None, selection);
    };
    return el;
}

def clearMarkers(store: any) -> None {
    for key in Object.keys(store) {
        if store[key] {
            store[key].remove();
            store[key] = None;
        }
    }
}

def SelectionDetails(selected: any, view: any, close: Callable[[], None]) -> JsxElement {
    title: str = "Selected location";
    detail: str = "No incident status is available for this point.";
    kind: str = selected["kind"];
    if kind == "cluster" {
        found: any = None;
        for c in view["clusters"] {
            if c["cluster_id"] == selected["id"] {
                found = c;
            }
        }
        if found {
            score: any = clusterScore(view, found);
            band: str = "Unranked";
            if Number.isFinite(score) {
                band = priorityBand(score)["label"];
            }
            served: str = "Served — reported complete by the crew. " if isCompleted(view, found["cluster_id"]) else "";
            title = divisionName(view, found["gn_id"]) + " · " + prettyHazard(found["hazard_type"]);
            detail = served + band + " · confidence " + (found["confidence_0_1"] * 100).toFixed(0) + "% · " + found["state"].replace("_", " ");
        } else {
            detail = "This incident is no longer in the current view.";
        }
    } elif kind == "vehicle" {
        vehicle: any = None;
        for v in view["vehicles"] {
            if v["vehicle_id"] == selected["id"] {
                vehicle = v;
            }
        }
        title = selected["id"];
        if vehicle {
            detail = vehicle["kind"] + " · capacity " + str(vehicle["capacity"]) + " · depot " + divisionName(view, vehicle["depot_gn_id"]) + ". Depot location, not live GPS.";
        } else {
            detail = "Vehicle no longer in the current view.";
        }
    } elif kind == "road" {
        stillBlocked: bool = False;
        if view["hazard"] {
            stillBlocked = view["hazard"]["impassable_edge_ids"].includes(selected["id"]);
        }
        if stillBlocked {
            title = "Impassable road";
            detail = "Edge " + selected["id"] + ". Excluded by the hazard model or a reported blockage. This is not a measured water depth.";
        } else {
            title = "Road status updated";
            detail = "Edge " + selected["id"] + " is no longer in the current impassable list. This does not confirm that the road is safe.";
        }
    } elif kind == "flood" {
        title = "Modelled flood extent";
        detail = "Estimated from rainfall and terrain. This layer does not provide measured water depth or confirm conditions at every road.";
    } elif kind == "slope" {
        title = "Landslide-susceptible slope";
        detail = "Modelled susceptibility; not a confirmed landslide.";
    } elif kind == "route" or kind == "estimate" {
        route: any = None;
        for r in view["routes"] {
            if JSON.stringify([r["vehicle_id"], r["cluster_id"]]) == selected["id"] {
                route = r;
            }
        }
        title = "Estimated crew position" if kind == "estimate" else "Dispatch route";
        if route {
            inferred: str = "Inferred from approval time and ETA, not live GPS. " if kind == "estimate" else "";
            tail: str = "Straight-line estimate; road geometry unavailable." if route["approximate"] else "Route from the current plan.";
            detail = route["vehicle_id"] + " → " + clusterPlace(view, route["cluster_id"]) + ". " + inferred + tail;
        } else {
            detail = "Route no longer in the current plan.";
        }
    }
    at: any = selected["at"];

    <Paper className="map-selection" p="sm" radius="md" shadow="md" role="region" aria-label="Selected map location">
        <Group justify="space-between" wrap="nowrap">
            <Text fw={700} size="sm">{title}</Text>
            <Button variant="subtle" size="compact-xs" onClick={close} aria-label="Close location details">×</Button>
        </Group>
        <Text size="xs" mt={6}>{detail}</Text>
        <Text size="xs" c="dimmed" mt={6}>{at[1].toFixed(5) + ", " + at[0].toFixed(5)}</Text>
        <Button component="a" href={navigationUrl(at[1], at[0])} target="_blank" rel="noreferrer" variant="light" size="xs" mt="xs">
            Navigate to location ↗
        </Button>
    </Paper>
}

def:pub Map3D(view: any, onFlat: Callable[[], None], onUnavailable: Callable[[str], None]) -> JsxElement {
    has ready: bool = False;
    has selected: any = None;
    has tileErrors: any = [];
    has lightMode: bool = initiallyLight();
    has terrain: bool = not initiallyLight();
    has container: Ref[any] = Ref();
    has mapRef: Ref[any] = Ref(None);
    has markers: Ref[any] = Ref({});
    has latest: Ref[any] = Ref(view);
    has unavailable: Ref[any] = Ref(None);
    has updater: Ref[any] = Ref(None);
    has initialLight: Ref[any] = Ref(initiallyLight());
    has errorSources: Ref[any] = Ref({});

    # The event handlers registered once on the map must see the current view and
    # callback, so they read them through refs that every render refreshes.
    latest.current = view;
    unavailable.current = onUnavailable;

    def fallback(message: str) {
        cb: any = unavailable.current;
        cb.call(None, message);
    }

    def focus(selection: any) {
        selected = selection;
        if mapRef.current {
            mapRef.current.flyTo({"center": selection["at"], "zoom": 16, "pitch": 55, "duration": motionDuration()});
        }
    }

    def closeSelection() {
        selected = None;
    }

    def mountMap() -> any {
        if not container.current {
            return;
        }
        # The worker and its shared chunks are bundled by the build, not fetched from a CDN.
        setWorkerUrl(workerUrl);
        map: any = None;
        try {
            map = new(GLMap, {
                "container": container.current,
                "style": STYLE,
                "center": [79.98, 6.95],
                "zoom": 11,
                "pitch": 45,
                "bearing": -15,
                "maxZoom": 18,
                "maxPitch": 60,
                "pixelRatio": pixelRatioFor(bool(initialLight.current)),
                "maxTileCacheSize": 64,
                "maxTileCacheZoomLevels": 2,
                "canvasContextAttributes": {"antialias": False}
            });
        } except Exception {
            fallback("3D is unavailable on this device. Showing 2D.");
            return;
        }
        mapRef.current = map;
        map.addControl(new(NavigationControl, {"visualizePitch": True}), "top-right");

        def onError(event: any) -> None {
            message: any = "";
            if event.error and event.error.message {
                message = event.error.message;
            }
            if message.includes("Worker failed to load") {
                fallback("The 3D renderer could not load. Showing 2D.");
                return;
            }
            source: str = str(event.sourceId) if event.sourceId else "map tiles";
            if not errorSources.current[source] {
                errorSources.current[source] = True;
                tileErrors = Object.keys(errorSources.current);
            }
            if source == "terrain" {
                map.setTerrain(None);
                terrain = False;
            }
        }
        map.on("error", onError);
        map.on("webglcontextlost", lambda (event: any) {
            fallback("3D graphics were interrupted. Showing 2D.");
        });

        def onStyleLoad(event: any) -> None {
            addIncidentLayers(map);
            writeSource: any = lambda (source: str, data: any) {
                map.getSource(source).setData(data);
            };
            setFlow: any = lambda (ids: any) {
                map.setFilter("route-flow", ["in", ["get", "routeId"], ["literal", ids]]);
            };
            updater.current = MapDataUpdater(write=writeSource, setFlowing=setFlow);
            updater.current.update(latest.current, new(Date));
            overview(map, latest.current, False);
            ready = True;
        }
        map.on("style.load", onStyleLoad);

        def onClick(event: any) -> None {
            if not map.getLayer("roads") {
                return;
            }
            features: any = map.queryRenderedFeatures(event.point, {
                "layers": ["estimates", "roads", "routes", "routes-approximate", "flood", "slope"]
            });
            hit: any = None;
            for f in features {
                if f.layer.id == "estimates" {
                    hit = f;
                    break;
                }
            }
            if not hit {
                for f in features {
                    if f.layer.id == "roads" {
                        hit = f;
                        break;
                    }
                }
            }
            if not hit and features.length > 0 {
                hit = features[0];
            }
            kind: str = "place";
            ident: str = "";
            if hit {
                kind = LAYER_KIND[hit.layer.id] or "place";
                props: any = hit.properties;
                if props and props.edge_id {
                    ident = str(props.edge_id);
                } elif props and props.routeId {
                    ident = str(props.routeId);
                }
            }
            focus({"kind": kind, "id": ident, "at": [event.lngLat.lng, event.lngLat.lat]});
        }
        map.on("click", onClick);

        observer: any = new(ResizeObserver, lambda { map.resize(); });
        observer.observe(container.current);
        store: any = markers.current;
        return lambda {
            observer.disconnect();
            clearMarkers(store);
            mapRef.current = None;
            updater.current = None;
            map.remove();
        };
    }

    # Markers are real buttons, so they are reachable by keyboard and carry their own label.
    def syncMarkers() -> None {
        map: any = mapRef.current;
        if not map or not ready {
            return;
        }
        keep: dict[str, bool] = {};
        store: any = markers.current;
        for c in view["clusters"] {
            score: any = clusterScore(view, c);
            scored: bool = Number.isFinite(score);
            band: any = {"color": "gray", "label": "Unranked"};
            if scored {
                band = priorityBand(score);
            }
            done: bool = isCompleted(view, c["cluster_id"]);
            label: str = ("Served" if done else band["label"]) + " · " + divisionName(view, c["gn_id"]) + " · " + prettyHazard(c["hazard_type"]);
            el: any = putMarker(map, store, keep, "cluster-" + c["cluster_id"], "cluster", c["cluster_id"], c["centroid_lon"], c["centroid_lat"], label, focus);
            size: str = str(16 if done else SIZES[band["color"]]) + "px";
            el.className = "map-incident-marker";
            el.style.width = size;
            el.style.height = size;
            el.style.background = "#ced4da" if done else COLORS[band["color"]];
            el.style.borderColor = "#868e96" if done else hazardColor(c["hazard_type"]);
            el.style.borderStyle = "dashed" if done else "solid";
            el.textContent = "✓" if done else ("?" if not scored else band["label"]);
        }
        committed: dict[str, bool] = {};
        if view["plan"] {
            for a in view["plan"]["assignments"] {
                committed[a["vehicle_id"]] = True;
            }
        }
        for v in view["vehicles"] {
            dispatched: bool = bool(committed[v["vehicle_id"]]);
            label: str = v["vehicle_id"] + " · " + v["kind"] + " · " + ("dispatched" if dispatched else "available") + " · depot position";
            el: any = putMarker(map, store, keep, "vehicle-" + v["vehicle_id"], "vehicle", v["vehicle_id"], v["depot_lon"], v["depot_lat"], label, focus);
            el.className = "map-vehicle-marker";
            # Only the constant badge markup, never API-provided HTML.
            icon: str = vehicleBadgeSvg(v["kind"], dispatched, 26);
            if el.innerHTML != icon {
                el.innerHTML = icon;
            }
        }
        for key in Object.keys(store) {
            if store[key] and not keep[key] {
                store[key].remove();
                store[key] = None;
            }
        }
    }

    def applyQuality() -> None {
        map: any = mapRef.current;
        if not ready or not map {
            return;
        }
        map.setPixelRatio(pixelRatioFor(lightMode));
        map.setLayerZoomRange("buildings", 16 if lightMode else 14, 24);
    }

    def applyTerrain() -> None {
        if ready and mapRef.current {
            mapRef.current.setTerrain({"source": "terrain", "exaggeration": 1} if terrain else None);
        }
    }

    # The clock tick that moves the estimated crew positions. It runs only while there is
    # something to move, and not at all in a hidden tab.
    def runTicker() -> any {
        map: any = mapRef.current;
        if not ready or not map {
            return;
        }
        run: dict[str, any] = {"timer": None, "step": 0};
        def tick() -> None {
            clearTimeout(run["timer"]);
            doc: any = document;
            if doc.hidden or not updater.current {
                return;
            }
            moving: bool = updater.current.update(latest.current, new(Date));
            if not moving {
                return;
            }
            if not lightMode and motionDuration() > 0 {
                map.setPaintProperty("route-flow", "line-dasharray", FLOW_STEPS[run["step"] % 4]);
                run["step"] = run["step"] + 1;
            }
            run["timer"] = setTimeout(tick, 3000 if lightMode else 1000);
        }
        tick();
        document.addEventListener("visibilitychange", tick);
        return lambda {
            clearTimeout(run["timer"]);
            document.removeEventListener("visibilitychange", tick);
        };
    }

    useEffect(mountMap, []);
    useEffect(syncMarkers, [view, ready]);
    useEffect(applyQuality, [ready, lightMode]);
    useEffect(applyTerrain, [ready, terrain]);
    useEffect(runTicker, [ready, view, lightMode]);

    def goOverview() {
        if mapRef.current {
            overview(mapRef.current, view, True);
        }
        selected = None;
    }

    def flipTerrain() {
        if mapRef.current {
            mapRef.current.setTerrain(None if terrain else {"source": "terrain", "exaggeration": 1});
        }
        terrain = not terrain;
    }

    def pickQuality(value: str) {
        lightMode = value == "light";
        terrain = value == "detailed" and not tileErrors.includes("terrain");
        try {
            localStorage.setItem(QUALITY_KEY, value);
        } except Exception {
            # Storage is optional: the choice just does not persist.
            persisted: bool = False;
        }
    }

    def pickIncident(id: any) {
        found: any = None;
        for c in view["clusters"] {
            if c["cluster_id"] == id {
                found = c;
            }
        }
        if found {
            focus({"kind": "cluster", "id": found["cluster_id"], "at": [found["centroid_lon"], found["centroid_lat"]]});
        } else {
            selected = None;
        }
    }

    options: list[any] = [];
    for c in view["clusters"] {
        options = options + [{"value": c["cluster_id"], "label": divisionName(view, c["gn_id"]) + " · " + prettyHazard(c["hazard_type"])}];
    }
    pickedId: any = None;
    if selected and selected["kind"] == "cluster" {
        pickedId = selected["id"];
    }
    blocked: int = 0;
    if view["hazard"] {
        blocked = view["hazard"]["impassable_edge_ids"].length;
    }
    mapped: int = 0;
    geo: any = view["blocked_roads_geojson"];
    if geo and geo["features"] {
        mapped = geo["features"].length;
    }
    hazardLine: str = (str(blocked) + " impassable road edges · " + str(mapped) + " mapped") if view["hazard"] else "Awaiting hazard data";
    if mapped < blocked {
        hazardLine = hazardLine + " · some geometry unavailable";
    }
    terrainFailed: bool = tileErrors.includes("terrain");

    <>
        <div ref={container} className="map-canvas" aria-label="3D incident map" />
        <Paper className="map-toolbar" p="sm" radius="md" shadow="sm">
            <Stack gap={8}>
                <Group gap={6}>
                    <Text size="sm" fw={700} mr="auto">Incident map · 3D</Text>
                    <Button size="compact-xs" variant="light" disabled={not ready} onClick={goOverview}>Overview</Button>
                    <Button size="compact-xs" variant="default" onClick={onFlat}>2D</Button>
                    <Button
                        size="compact-xs"
                        variant={"light" if terrain else "default"}
                        disabled={not ready or terrainFailed}
                        aria-pressed={terrain}
                        onClick={flipTerrain}
                    >
                        {"Terrain " + ("on" if terrain else "off")}
                    </Button>
                </Group>
                <SegmentedControl
                    size="xs"
                    fullWidth={True}
                    value={"light" if lightMode else "detailed"}
                    disabled={not ready}
                    data={[{"value": "light", "label": "Light 3D"}, {"value": "detailed", "label": "Detailed 3D"}]}
                    onChange={pickQuality}
                />
                <Select
                    size="xs"
                    placeholder="Fly to an incident…"
                    aria-label="Fly to an incident"
                    searchable={True}
                    clearable={True}
                    data={options}
                    value={pickedId}
                    onChange={pickIncident}
                />
                <Text size="xs" c="dimmed">Click a place to fly closer. Right-drag to tilt or rotate.</Text>
                <Text size="xs" c="dimmed">{hazardLine}</Text>
                {if tileErrors.length > 0 {
                    <Text size="xs" c="orange" role="status">
                        {"Some map tiles could not load (" + tileErrors.join(", ") + "). Incident overlays remain available. Use 2D if needed."}
                    </Text>
                }}
            </Stack>
        </Paper>
        <MapLegend threeDimensional={True} />
        {if selected {
            <SelectionDetails selected={selected} view={view} close={closeSelection} />
        }}
    </>
}
