"""GeoJSON <-> shapely helpers shared by A2 (producing surfaces) and A3/A5 (reading them).

Every geometry that crosses an agent boundary is a GeoJSON FeatureCollection in
EPSG:4326. Metric operations (buffering, area) happen in WGS84 / UTM zone 44N, which
covers all of Sri Lanka, and are converted back before anything is published.
"""

import json;
import shapely;
import from shapely { wkb }
import from shapely.geometry { Point, shape }
import from shapely.ops { unary_union, transform }
import from shapely.prepared { prep }

glob METRIC_CRS: str = "EPSG:32644";
glob WGS84: str = "EPSG:4326";

def empty_collection() -> dict[str, any] {
    return {"type": "FeatureCollection", "features": []};
}

"""One-feature FeatureCollection, or an empty one for an empty geometry. Plain lists
and floats, so it is equal to itself after a JSON round trip through state."""
def collection_from_geometry(geom: any, **properties: any) -> dict[str, any] {
    if geom is None or geom.is_empty {
        return empty_collection();
    }
    return {
        "type": "FeatureCollection",
        "features": [
            {"type": "Feature", "geometry": json.loads(shapely.to_geojson(geom)), "properties": dict(properties)}
        ]
    };
}

"""Union of every feature's geometry, or None when there is nothing."""
def union_of(collection: dict[str, any] | None) -> any {
    if not collection {
        return None;
    }
    geoms = [shape(f["geometry"]) for f in collection.get("features", []) if f.get("geometry")];
    if not geoms {
        return None;
    }
    merged = unary_union(geoms);
    return None if merged.is_empty else merged;
}

glob _PREPARED: dict[bytes, any] = {};

"""Prepared geometry for fast repeated point tests, cached by content."""
def prepared(geom: any) -> any {
    blob = wkb.dumps(geom);
    if blob not in _PREPARED {
        if len(_PREPARED) >= 16 {
            _PREPARED.pop(next(iter(_PREPARED)));
        }
        _PREPARED[blob] = prep(wkb.loads(blob));
    }
    return _PREPARED[blob];
}

def contains_point(collection: dict[str, any] | None, lat: float, lon: float) -> bool {
    geom = union_of(collection);
    if geom is None {
        return False;
    }
    return bool(prepared(geom).intersects(Point(lon, lat)));
}

def to_metric(geom: any) -> any {
    import from pyproj { Transformer }
    t = Transformer.from_crs(WGS84, METRIC_CRS, always_xy=True);
    return transform(t.transform, geom);
}

def to_wgs84(geom: any) -> any {
    import from pyproj { Transformer }
    t = Transformer.from_crs(METRIC_CRS, WGS84, always_xy=True);
    return transform(t.transform, geom);
}
