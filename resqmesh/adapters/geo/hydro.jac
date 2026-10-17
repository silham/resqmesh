"""Watercourses for the buffer-proxy hazard model.

The OSM river/stream/canal lines are fetched once and stored as GeoJSON. At decision
time they are only read from disk, so the degraded hazard path never needs the network.
"""

import json;
import from pathlib { Path }
import from resqmesh.adapters.geo.paths { KELANI_BBOX, ensure_dir, waterways_path }

"""OSM `waterway` values treated as flood sources."""
glob WATERWAY_KINDS: list[str] = ["river", "stream", "canal", "drain"];

"""Download waterway lines as a GeoJSON FeatureCollection. Network access."""
def fetch_waterways(bbox: tuple[float, float, float, float] = KELANI_BBOX) -> dict[str, any] {
    import osmnx as ox;
    import from resqmesh.adapters.geo.roads { configure_osmnx }
    configure_osmnx();
    gdf = ox.features_from_bbox(bbox, tags={"waterway": WATERWAY_KINDS});
    gdf = gdf[gdf.geometry.geom_type.isin(["LineString", "MultiLineString"])];
    cols = ["waterway", "name", "geometry"] if "name" in gdf.columns else ["waterway", "geometry"];
    gdf = gdf[cols];
    return json.loads(gdf.reset_index(drop=True).to_json());
}

def save_waterways(collection: dict[str, any], path: Path | None = None) -> Path {
    p = path or waterways_path();
    ensure_dir(p.parent);
    tmp = p.with_suffix(".part");
    tmp.write_text(json.dumps(collection), encoding="utf-8");
    tmp.replace(p);
    return p;
}

"""The cached watercourse collection, or None if it has not been fetched."""
def load_waterways(path: Path | None = None) -> dict[str, any] | None {
    p = path or waterways_path();
    if not p.exists() {
        return None;
    }
    return json.loads(p.read_text(encoding="utf-8"));
}
