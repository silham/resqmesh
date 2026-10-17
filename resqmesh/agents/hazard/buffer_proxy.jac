"""Buffer-proxy inundation — the documented degraded hazard path.

Proposal section 4.3: when the HAND model cannot run, flood extent is approximated
by a distance buffer around the watercourses, widened with rainfall. It is crude on
purpose. It needs only the OSM waterway lines and a rainfall number, so it survives
a missing DEM, a failed terrain computation and a dead network. Its output is always
published with `method=BUFFER_PROXY` and a low confidence, so A6 annotates the
SITREP accordingly.

Rainfall -> radius (judgement call, documented here and in the README):

* below `RAIN_TRIGGER_MM` (the NBRO 75 mm watch level) in 24 h there is no
  out-of-bank flooding: empty surface;
* above it the river buffer grows linearly at `METRES_PER_MM` from `BASE_RADIUS_M`,
  capped at `MAX_RADIUS_M` — at the May 2016 peak (262 mm/24 h) that is ~470 m
  either side of the main channel, matching HAND's extent to within a factor of two;
* smaller watercourses get a fraction of the river radius (`KIND_FACTOR`).
"""

import from shapely.geometry { shape }
import from shapely.ops { unary_union }
import from resqmesh.adapters.geo.shapes {
    collection_from_geometry, empty_collection, to_metric, to_wgs84
}

glob RAIN_TRIGGER_MM: float = 75.0;
glob BASE_RADIUS_M: float = 100.0;
glob METRES_PER_MM: float = 2.0;
glob MAX_RADIUS_M: float = 1000.0;

"""Only the main river carries the full radius. Urban drains are excluded: their
failure is local ponding, not the out-of-bank flooding this proxy stands in for.
A kind missing from the table contributes nothing."""
glob KIND_FACTOR: dict[str, float] = {"river": 1.0, "canal": 0.25, "stream": 0.1, "drain": 0.0};

"""Simplification tolerance for the published polygon (metres). Keeps the GeoJSON
that travels through state and checkpoints small without moving edges materially."""
glob SIMPLIFY_M: float = 15.0;

"""River buffer radius for a 24-hour rainfall total."""
def buffer_radius_m(rain_24h_mm: float) -> float {
    if rain_24h_mm < RAIN_TRIGGER_MM {
        return 0.0;
    }
    return min(MAX_RADIUS_M, BASE_RADIUS_M + METRES_PER_MM * (rain_24h_mm - RAIN_TRIGGER_MM));
}

"""Inundation FeatureCollection (EPSG:4326) from watercourse lines and rainfall."""
def buffer_proxy_inundation(waterways: dict[str, any] | None, rain_24h_mm: float) -> dict[str, any] {
    radius = buffer_radius_m(rain_24h_mm);
    if radius <= 0 or not waterways {
        return empty_collection();
    }
    buffers: list[any] = [];
    for feature in waterways.get("features", []) {
        geom = feature.get("geometry");
        props = feature.get("properties") or {};
        if not geom {
            continue;
        }
        r = radius * KIND_FACTOR.get(str(props.get("waterway", "stream")), 0.0);
        if r > 0 {
            buffers.append(to_metric(shape(geom)).buffer(r, quad_segs=4));
        }
    }
    if not buffers {
        return empty_collection();
    }
    merged = unary_union(buffers).simplify(SIMPLIFY_M, preserve_topology=True);
    return collection_from_geometry(
        to_wgs84(merged), kind="inundation", method="buffer_proxy",
        river_radius_m=round(radius, 1), rain_24h_mm=round(rain_24h_mm, 1)
    );
}
