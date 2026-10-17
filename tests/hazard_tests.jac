"""A2 against fixed fixtures: buffer proxy, pruning, susceptibility, HAND, fallbacks,
and citizen road-block reports.

Everything here is synthetic — a grid road network, one river line, a V-shaped
valley DEM — so the tests pin behaviour, not data, and run with no network.
"""

import json;
import math;
import tempfile;
import warnings;
import numpy as np;
import from datetime { datetime, UTC }
import from pathlib { Path }
import from rasterio.transform { from_origin }
import from shapely.geometry { Point, box }
import from resqmesh.adapters.fakes { FakeWeather }
import from resqmesh.adapters.geo.roads { edge_id, load_graph, node_latlon }
import from resqmesh.adapters.geo.shapes { collection_from_geometry, union_of }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.adapters.geo.terrain { Dem }
import from resqmesh.agents.hazard.agent { HazardAgent, HazardConfig }
import from resqmesh.agents.hazard.buffer_proxy { buffer_proxy_inundation, buffer_radius_m }
import from resqmesh.agents.hazard.hand { compute_hand, inundation_from_hand, stage_m }
import from resqmesh.agents.hazard.pruning { impassable_edges, prune_graph, reported_block_edges }
import from resqmesh.agents.hazard.susceptibility { nbro_level, susceptibility_surface }
import from resqmesh.contracts.enums { HazardMethod }
import from resqmesh.contracts.models { HazardSurface, to_json }
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }
import from resqmesh.contracts.state { IncidentState }

"""The metric reprojection helpers in the geo adapter still go through
`shapely.ops.transform`, which shapely 2.2 deprecates; the test runner turns every
warning into an error, so that one deprecation is silenced for this file."""
def _quiet_reprojection_deprecation() -> bool {
    warnings.filterwarnings(
        "ignore", message=r"The 'shapely\.ops\.transform\(\)' function is deprecated",
        category=DeprecationWarning
    );
    return True;
}

glob _QUIET: bool = _quiet_reprojection_deprecation();

glob NOW: datetime = datetime(2016, 5, 17, 6, 0, tzinfo=UTC);

# Grid origin (6.90, 79.90), 0.005 deg steps: rows at 6.900 .. 6.925.
# A river running east-west between rows 1 and 2, across the western half only.
glob RIVER: dict[str, any] = {
    "type": "FeatureCollection",
    "features": [
        {
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": [[79.895, 6.9075], [79.9175, 6.9075]]},
            "properties": {"waterway": "river"}
        }
    ]
};

"""WeatherPort returning a flat hourly rate, optionally flagged as cached."""
obj FixedWeather(WeatherPort) {
    has rate: float = 0.0,
        cached: bool = False,
        fail: bool = False;

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        if self.fail {
            raise RuntimeError("gauge down");
        }
        return RainfallSeries(
            lat=lat, lon=lon, observed_mm=[self.rate] * hours_back, forecast_mm=[],
            start_time=NOW, from_cache=self.cached
        );
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        return self.rainfall(lat, lon);
    }
}

def approx(a: any, b: float, tol: float = 1e-6) -> bool {
    return math.isclose(a, b, rel_tol=1e-6, abs_tol=tol);
}

def tmp_dir() -> Path {
    return Path(tempfile.mkdtemp(prefix="hazard_tests_"));
}

def no_dem() -> any {
    return None;
}

def river_loader() -> any {
    return RIVER;
}

def make_agent(tmp: Path, weather: any, **kw: any) -> HazardAgent {
    g = grid_graph();

    def graph_loader() -> any {
        return g;
    }

    defaults: dict[str, any] = {
        "graph_loader": graph_loader,
        "waterways_loader": river_loader,
        "dem_loader": no_dem,
        "inundation_model": None,
        "gn_centroids": {"GN-RIVERSIDE": (6.9075, 79.905), "GN-DRY": (6.925, 79.935)},
        "config": HazardConfig(prefer_hand=False),
        "out_dir": tmp
    };
    defaults.update(kw);
    return HazardAgent(weather=weather, **defaults);
}

# --------------------------------------------------------------------------- #
# Buffer proxy
# --------------------------------------------------------------------------- #

test "buffer radius is monotone and capped" {
    assert buffer_radius_m(10) == 0.0;
    radii = [buffer_radius_m(r) for r in [30, 60, 120, 240, 500, 2000]];
    assert radii == sorted(radii);
    assert radii[-1] == 1000.0;
}

test "no rain means no inundation" {
    assert buffer_proxy_inundation(RIVER, 5.0)["features"] == [];
}

test "buffer proxy polygon is wgs84 and covers the river" {
    fc = buffer_proxy_inundation(RIVER, 100.0);  # ~150 m radius
    geom = union_of(fc);
    assert geom is not None;
    assert geom.contains(Point(79.905, 6.9075));
    assert not geom.contains(Point(79.935, 6.925));
    b: any = geom.bounds;
    (minx, miny, maxx, maxy) = (b[0], b[1], b[2], b[3]);
    assert 79.8 < minx < maxx < 80.0 and 6.8 < miny < maxy < 7.0;  # degrees, not metres
}

test "unknown watercourse kinds carry no buffer" {
    odd = {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "geometry": {"type": "LineString", "coordinates": [[79.895, 6.9075], [79.9175, 6.9075]]},
                "properties": {"waterway": "ditch"}
            }
        ]
    };
    assert buffer_proxy_inundation(odd, 200.0)["features"] == [];
}

# --------------------------------------------------------------------------- #
# Pruning
# --------------------------------------------------------------------------- #

test "edges touching the hazard are impassable" {
    g = grid_graph();
    water = box(79.9024, 6.9045, 79.9076, 6.9105);  # swallows the node-9/node-17 link
    ids = set(impassable_edges(g, water));
    assert edge_id(9, 17, 0) in ids and edge_id(17, 9, 0) in ids;
    assert edge_id(0, 1, 0) not in ids;
}

test "nothing is impassable without a hazard" {
    assert impassable_edges(grid_graph(), None) == [];
}

test "pruned graph really lacks the edges" {
    g = grid_graph();
    ids = impassable_edges(g, box(79.9024, 6.9045, 79.9076, 6.9105));
    pruned = prune_graph(g, ids);
    assert not pruned.has_edge(9, 17);
    assert pruned.number_of_edges() == g.number_of_edges() - len(ids);
    assert pruned.number_of_nodes() == g.number_of_nodes();
    assert g.has_edge(9, 17);  # base graph untouched
}

# --------------------------------------------------------------------------- #
# Susceptibility (NBRO levels) and HAND thresholding
# --------------------------------------------------------------------------- #

test "nbro levels" {
    cases = [(10, 20, 0), (80, 90, 1), (60, 160, 1), (120, 130, 2), (160, 100, 3), (10, 260, 3)];
    for (r24, r72, level) in cases {
        assert nbro_level(r24, r72)[0] == level, (r24, r72);
    }
}

"""Flat western half, a 45-degree-ish ramp on the eastern half."""
def slope_dem() -> Dem {
    rows = 40;
    cols = 40;
    res = 1 / 3600;
    elev: any = np.zeros((rows, cols));
    cell_m: float = float(res * 111320 * np.cos(np.radians(6.9)));
    for c in range(20, cols) {
        elev[0:rows, c:c + 1] = (c - 20) * cell_m;  # rise == run -> 45 deg
    }
    return Dem(elevation=elev, transform=from_origin(80.0, 6.95, res, res));
}

test "susceptibility flags steep ground only when wet" {
    dem = slope_dem();
    assert susceptibility_surface(dem, 20, 30).collection["features"] == [];
    wet = susceptibility_surface(dem, 160, 200);
    assert wet.level == 3;
    geom = union_of(wet.collection);
    assert geom is not None;
    assert geom.contains(Point(80.0 + 30 / 3600, 6.95 - 20 / 3600));  # on the ramp
    assert not geom.contains(Point(80.0 + 5 / 3600, 6.95 - 20 / 3600));  # on the flat
}

test "hand stage mapping" {
    assert stage_m(10) == 0.0;
    assert approx(stage_m(125), 1.0);
    assert stage_m(5000) == 8.0;
}

test "hand threshold vectorises low cells" {
    hand: any = np.full((30, 30), 20.0);
    hand[0:30, 10:20] = 1.0;  # a 10-cell-wide valley floor
    fc = inundation_from_hand(hand, from_origin(80.0, 6.95, 1 / 3600, 1 / 3600), stage=3.0);
    geom = union_of(fc);
    assert geom is not None;
    assert geom.contains(Point(80.0 + 15 / 3600, 6.95 - 15 / 3600));
    assert not geom.contains(Point(80.0 + 3 / 3600, 6.95 - 15 / 3600));
    assert fc["features"][0]["properties"]["method"] == "hand";
}

test "compute hand on a valley" {
    import rasterio;
    import importlib.util;
    if importlib.util.find_spec("pysheds") is None {
        return;  # optional dependency absent: nothing to check
    }
    rows = 60;
    cols = 60;
    res = 1 / 3600;
    xs: any = np.abs(np.arange(cols) - cols // 2);
    x: any = xs.reshape(1, cols) * 3.0;  # V across columns
    ys: any = rows - np.arange(rows);
    y: any = ys.reshape(rows, 1) * 0.5;  # tilted downstream (south)
    dem: any = (x + y + 10).astype("float32");
    path = tmp_dir() / "valley.tif";
    with rasterio.open(
        path, "w", driver="GTiff", height=rows, width=cols, count=1, dtype="float32",
        crs="EPSG:4326", transform=from_origin(80.0, 6.95, res, res), nodata=-9999
    ) as dst {
        dst.write(dem, 1);
    }
    result: any = compute_hand(path, channel_threshold_cells=50);
    hand: any = result[0];
    mid = rows // 2;
    assert abs(float(hand[mid, cols // 2])) <= 1e-6;  # on the channel
    assert hand[mid, cols // 2 + 10] > hand[mid, cols // 2 + 2] > 0;  # rises away from it
}

# --------------------------------------------------------------------------- #
# The agent: versions, fallbacks, ablation, state contract
# --------------------------------------------------------------------------- #

test "agent buffer path prunes and publishes" {
    out = make_agent(tmp_dir(), FixedWeather(rate=5.0)).run(IncidentState(), now=NOW);  # 120 mm/24h, 360 mm/72h
    surface = out["hazard"];
    ref = out["pruned_graph"];
    assert isinstance(surface, HazardSurface);
    assert surface.method == HazardMethod.BUFFER_PROXY;
    assert approx(surface.confidence_0_1, 0.40);
    assert surface.version == 1 and ref.version == 1 and ref.surface_version == 1;
    assert approx(surface.driving_rainfall_mm_24h, 216.0);  # antecedent: 0.6 x 360
    assert len(surface.impassable_edge_ids) == ref.removed_edge_count;
    assert ref.removed_edge_count > 0;
    assert surface.no_go_gn_ids == ["GN-RIVERSIDE"];
    routed = load_graph(ref.graph_path);
    for e in surface.impassable_edge_ids {
        parts = [int(p) for p in e.split("-")];
        assert not routed.has_edge(parts[0], parts[1], parts[2]);
    }
    assert out["trace"][0].agent == "A2";
    assert out["trace"][0].action == "hazard_recomputed";
    assert surface.surface_id == "HS-0001";
}

test "versions increase on every tick" {
    agent = make_agent(tmp_dir(), FixedWeather(rate=5.0));
    first = agent.run(IncidentState(), now=NOW);
    second = agent.run(IncidentState(hazard=first["hazard"], pruned_graph=first["pruned_graph"]), now=NOW);
    assert second["hazard"].version == 2 and second["pruned_graph"].version == 2;
    assert second["hazard"].surface_id == "HS-0002";
}

test "ablation publishes impassable but does not prune" {
    out = make_agent(
        tmp_dir(), FixedWeather(rate=5.0), config=HazardConfig(prefer_hand=False, prune=False)
    ).run(IncidentState(), now=NOW);
    assert out["hazard"].impassable_edge_ids;  # the truth is still reported
    assert out["pruned_graph"].removed_edge_count == 0;  # but A4 sees the whole graph
}

def broken_model(rain: float) -> dict[str, any] {
    raise MemoryError("DEM too big");
}

test "hand failure degrades to buffer proxy" {
    out = make_agent(tmp_dir(), FixedWeather(rate=5.0), inundation_model=broken_model).run(IncidentState(), now=NOW);
    assert out["hazard"].method == HazardMethod.BUFFER_PROXY;
    assert "hand failed" in out["trace"][0].detail;
    assert "hand failed (MemoryError); buffer proxy used" in out["trace"][0].detail;
}

test "hand path when model available" {
    flood = collection_from_geometry(box(79.9024, 6.9045, 79.9076, 6.9105));

    def model(rain: float) -> dict[str, any] {
        return flood;
    }

    out = make_agent(tmp_dir(), FixedWeather(rate=5.0), inundation_model=model).run(IncidentState(), now=NOW);
    assert out["hazard"].method == HazardMethod.HAND;
    assert approx(out["hazard"].confidence_0_1, 0.75);
    assert edge_id(9, 17, 0) in out["hazard"].impassable_edge_ids;
}

test "stale rainfall lowers confidence" {
    out = make_agent(tmp_dir(), FixedWeather(rate=5.0, cached=True)).run(IncidentState(), now=NOW);
    assert approx(out["hazard"].confidence_0_1, 0.40 * 0.85);
}

test "blind rainfall assumes alert level rather than dry" {
    out = make_agent(tmp_dir(), FixedWeather(rate=0.0, fail=True)).run(IncidentState(), now=NOW);
    assert approx(out["hazard"].driving_rainfall_mm_24h, 100.0);
    assert out["hazard"].impassable_edge_ids;  # conservative: roads by the river closed
    assert approx(out["hazard"].confidence_0_1, 0.40 * 0.5);
}

def no_waterways() -> any {
    return None;
}

test "no data at all still answers" {
    out = make_agent(tmp_dir(), FakeWeather(), waterways_loader=no_waterways).run(IncidentState(), now=NOW);
    assert out["hazard"].confidence_0_1 <= 0.10;
    assert out["hazard"].impassable_edge_ids == [];
}

test "surface round trips through its contract" {
    surface = make_agent(tmp_dir(), FixedWeather(rate=5.0)).run(IncidentState(), now=NOW)["hazard"];
    data = json.loads(json.dumps(to_json(surface)));
    data.pop("schema_version");
    data["generated_at"] = datetime.fromisoformat(data["generated_at"].replace("Z", "+00:00"));
    again = HazardSurface(**data);
    assert to_json(again) == to_json(surface);
}

test "trace detail has the documented format" {
    out = make_agent(tmp_dir(), FixedWeather(rate=5.0)).run(IncidentState(), now=NOW);
    detail = out["trace"][0].detail;
    n = len(out["hazard"].impassable_edge_ids);
    expected = (
        f"method=buffer_proxy conf=0.40 rain24=120mm rain72=360mm driver=216mm nbro_level=3 impassable={n} "
        "no_go_gn=1 pruned=True | no DEM; susceptibility not assessed"
    );
    assert detail == expected, detail;
}

test "pruning is line based not node based" {
    # Water over the middle of the 0->1 street, with both end junctions dry: the
    # street is still cut. A node-only test would miss exactly this case.
    g = grid_graph();
    puddle = Point(79.9025, 6.9000).buffer(0.0004);
    assert not puddle.contains(Point(79.900, 6.900)) and not puddle.contains(Point(79.905, 6.900));
    ids = impassable_edges(g, puddle);
    assert set(ids) == {edge_id(0, 1, 0), edge_id(1, 0, 0)};
}

test "major bridges survive inundation but minor ones do not" {
    g = grid_graph();
    for (u, v) in [(0, 1), (1, 0)] {
        g.edges[u, v, 0].update(bridge="yes", highway="primary");
    }
    for (u, v) in [(1, 2), (2, 1)] {
        g.edges[u, v, 0].update(bridge="yes", highway="residential");
    }
    water = box(79.899, 6.8995, 79.911, 6.9005);  # over the 0-1-2 street
    flooded = set(impassable_edges(g, water, bridges_exempt=True));
    assert edge_id(0, 1, 0) not in flooded;  # elevated primary bridge stays open
    assert edge_id(1, 2, 0) in flooded;  # minor bridge / culvert is overtopped
    assert edge_id(0, 1, 0) in impassable_edges(g, water);  # landslide closures spare nothing
}

# --------------------------------------------------------------------------- #
# Reported road blocks: a citizen's report closes the nearest edge
# --------------------------------------------------------------------------- #

test "nearest edge to a reported point is returned" {
    g = grid_graph();
    # A point sitting on node 9 must resolve to an edge incident to node 9.
    ll = node_latlon(g, 9);
    ids = reported_block_edges(g, [(ll[0], ll[1])]);
    assert ids;  # something was closed
    assert any([eid.startswith("9-") or eid.endswith("-9-0") or "-9-" in eid for eid in ids]);
}

test "no points closes nothing" {
    assert reported_block_edges(grid_graph(), []) == [];
}

test "the reported edge is actually removed from the routing graph" {
    g = grid_graph();
    ll = node_latlon(g, 9);
    ids = reported_block_edges(g, [(ll[0], ll[1])]);
    pruned = prune_graph(g, ids);
    assert pruned.number_of_edges() == g.number_of_edges() - len(ids);
    assert g.number_of_edges() == pruned.number_of_edges() + len(ids);  # base untouched
}
