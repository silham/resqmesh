"""The routing g: build once, pickle, load in well under a second.

Edge identity is the one thing every consumer must agree on. A2 publishes
`impassable_edge_ids`, A4 publishes `route_edge_ids`, and A5 compares the two as plain
strings, so the format lives here, in `edge_id`, and nowhere else.
"""

import hashlib;
import math;
import pickle;
import from pathlib { Path }
import builtins;
import networkx as nx;
import from resqmesh.adapters.geo.paths { KELANI_BBOX, cache_dir, ensure_dir, road_graph_path }

glob EARTH_RADIUS_M: float = 6371008.8;

"""Stable string identity of a directed multigraph edge: "u-v-key"."""
def edge_id(u: any, v: any, key: any = 0) -> str {
    return f"{u}-{v}-{key}";
}

def iter_edge_ids(g: any) -> list[str] {
    return [edge_id(u, v, k) for (u, v, k) in g.edges(keys=True)];
}

"""Structural fingerprint: node count plus the sorted edge-id set. Independent of
pickle bytes and insertion order."""
def graph_hash(g: any) -> str {
    h = hashlib.sha256(str(g.number_of_nodes()).encode());
    for eid in sorted(iter_edge_ids(g)) {
        h.update(b"\n");
        h.update(eid.encode());
    }
    return h.hexdigest();
}

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    p1 = math.radians(lat1);
    p2 = math.radians(lat2);
    dp = p2 - p1;
    dl = math.radians(lon2 - lon1);
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2;
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a));
}

def node_latlon(g: any, n: any) -> tuple[float, float] {
    data = g.nodes[n];
    return (float(data["y"]), float(data["x"]));
}

"""Nearest g node to a point and its great-circle distance in metres.

`candidates` restricts the search, e.g. to nodes that still have edges after pruning,
so a demand inside the water snaps to the last dry node rather than to an island."""
def nearest_node(g: any, lat: float, lon: float, candidates: any = None) -> tuple[any, float] {
    best: any = None;
    best_d = math.inf;
    pool = candidates if candidates is not None else g.nodes;
    for n in pool {
        (y, x) = node_latlon(g, n);
        d = haversine_m(lat, lon, y, x);
        if d < best_d {
            best = n;
            best_d = d;
        }
    }
    if best is None {
        raise ValueError("g has no candidate nodes");
    }
    return (best, best_d);
}

"""Keep OSMnx's HTTP cache under the gitignored data dir."""
def configure_osmnx() -> None {
    import osmnx as ox;
    ox.settings.cache_folder = str(ensure_dir(cache_dir() / "osmnx"));
    ox.settings.use_cache = True;
}

"""Download the drivable OSM network for bbox (west, south, east, north). Network
access: only the data fetcher calls this, never the decision path."""
def build_graph(bbox: tuple[float, float, float, float] = KELANI_BBOX) -> any {
    import osmnx as ox;
    configure_osmnx();
    g = ox.graph_from_bbox(bbox, network_type="drive", simplify=True, retain_all=False);
    keep_edge = {"length", "highway", "geometry", "name", "bridge", "oneway"};
    for (_, _, data) in g.edges(data=True) {
        for attr in [a for a in data if a not in keep_edge] {
            del data[attr];
        }
    }
    return g;
}

"""Run `action` with the interpreter's own importer.

Pickling a road graph resolves the reducer of every edge geometry through
`__import__` (about 100k calls for the basin), and the runtime's scoped importer
resolves paths on each call, which turns a sub-second dump into many seconds. Every
module a pickle touches is already loaded, so the plain importer is equivalent here."""
def with_plain_imports(action: any) -> any {
    scope: any = globals().get("__builtins__");
    if not isinstance(scope, dict) or "__import__" not in scope {
        return action();
    }
    scoped = scope["__import__"];
    scope["__import__"] = builtins.__import__;
    try {
        return action();
    } finally {
        scope["__import__"] = scoped;
    }
}

def save_graph(g: any, path: Path) -> Path {
    ensure_dir(path.parent);
    tmp = path.with_suffix(path.suffix + ".part");
    def dump() -> None {
        with tmp.open("wb") as fh {
            pickle.dump(g, fh, protocol=pickle.HIGHEST_PROTOCOL);
        }
    }
    with_plain_imports(dump);
    tmp.replace(path);
    return path;
}

glob _GRAPH_CACHE: dict[str, any] = {};

"""Load a pickled g once per process; a rewritten file is picked up again.
Callers must treat the result as read-only: it is shared."""
def load_graph(path: any = None) -> any {
    p = Path(path) if path is not None else road_graph_path();
    if not p.exists() {
        raise FileNotFoundError(f"road g not found at {p}; run `jac run scripts/fetch_data.jac`");
    }
    key = f"{p.resolve()}|{p.stat().st_mtime_ns}";
    if key in _GRAPH_CACHE {
        return _GRAPH_CACHE[key];
    }
    def read() -> any {
        with p.open("rb") as fh {
            return pickle.load(fh);
        }
    }
    g = with_plain_imports(read);
    if not isinstance(g, nx.MultiDiGraph) {
        raise TypeError(f"{p} does not contain a MultiDiGraph");
    }
    if len(_GRAPH_CACHE) >= 4 {
        _GRAPH_CACHE.pop(next(iter(_GRAPH_CACHE)));
    }
    _GRAPH_CACHE[key] = g;
    return g;
}
