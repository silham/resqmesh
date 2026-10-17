"""Road pruning: make a route through rising water unrepresentable.

This is the proposal's central claim about the hazard layer. A2 intersects the
hazard polygons with every road edge and removes the ones that touch them from the
routing graph A4 solves on. A4 therefore cannot produce a route across a flooded
segment — not because it is penalised, but because the edge does not exist in its
world. A5 independently re-checks the published `impassable_edge_ids` against every
route anyway.

Elevated bridges on major roads are exempt from *inundation*: a bridge line always
crosses the river polygon, yet the deck of a major river bridge is designed to sit
above the design flood. Without this exemption every river crossing is cut the
moment it rains and the network splits along the river. The approach edges are
still cut when under water, so a bridge only helps if its approaches are dry. Minor-road bridges and culverts, which
are overtopped, are treated like any other edge. Landslide closures apply to all.

`prune=False` is the ablation switch for Sprint 4 ("no hazard-based graph
pruning"): impassable edges are still *computed and published* — so A5 and the
metrics can see the crossings — but the graph handed to A4 is left whole.
"""

import weakref;
import from pathlib { Path }
import from shapely { STRtree }
import from shapely.geometry { LineString, Point }
import from shapely.geometry.base { BaseGeometry }
import from resqmesh.adapters.geo.paths { cache_dir, ensure_dir }
import from resqmesh.adapters.geo.roads { edge_id, save_graph }
import from resqmesh.contracts.models { PrunedGraphRef }

"""How many pruned-graph pickles to keep on disk; older generations are deleted."""
glob KEEP_GENERATIONS: int = 4;

"""Road classes whose bridges are engineered above the design flood."""
glob MAJOR_ROADS: frozenset[str] = frozenset({"motorway", "trunk", "primary", "secondary"});

"""Spatial index over a graph's edges, built once per graph object."""
obj EdgeIndex {
    has ids: list[str],
        keys: list[tuple[any, any, any]],
        tree: any,
        elevated: frozenset[int];  # positions of major-road bridge edges
}

"""True for a bridge on a major road (or its `_link` ramp)."""
def is_elevated(data: dict[str, any]) -> bool {
    bridge = data.get("bridge");
    if isinstance(bridge, list) {
        bridge = bridge[0] if bridge else None;
    }
    if bridge in [None, "no", False] {
        return False;
    }
    highway = data.get("highway");
    if isinstance(highway, list) {
        highway = highway[0] if highway else "";
    }
    return str(highway or "").removesuffix("_link") in MAJOR_ROADS;
}

glob _INDEX_CACHE: any = weakref.WeakKeyDictionary();

def _edge_geometry(g: any, u: any, v: any, data: dict[str, any]) -> any {
    geom = data.get("geometry");
    if isinstance(geom, BaseGeometry) {
        return geom;
    }
    a = g.nodes[u];
    b = g.nodes[v];
    return LineString([(a["x"], a["y"]), (b["x"], b["y"])]);
}

def edge_index(g: any) -> EdgeIndex {
    cached = _INDEX_CACHE.get(g);
    if cached is not None {
        return cached;
    }
    ids: list[str] = [];
    keys: list[tuple[any, any, any]] = [];
    geoms: list[any] = [];
    elevated: set[int] = set();
    for (i, e) in enumerate(g.edges(keys=True, data=True)) {
        (u, v, k, data) = e;
        ids.append(edge_id(u, v, k));
        keys.append((u, v, k));
        geoms.append(_edge_geometry(g, u, v, data));
        if is_elevated(data) {
            elevated.add(i);
        }
    }
    index = EdgeIndex(ids=ids, keys=keys, tree=STRtree(geoms), elevated=frozenset(elevated));
    _INDEX_CACHE[g] = index;
    return index;
}

"""Ids of every edge whose geometry intersects `hazard` (EPSG:4326), sorted.

`bridges_exempt` spares elevated major-road bridges — pass it for inundation,
not for landslide closures."""
def impassable_edges(g: any, hazard: any, bridges_exempt: bool = False) -> list[str] {
    if hazard is None or hazard.is_empty {
        return [];
    }
    index = edge_index(g);
    hits = index.tree.query(hazard, predicate="intersects");
    exempt: frozenset[int] = index.elevated if bridges_exempt else frozenset();
    return sorted([index.ids[int(i)] for i in hits if int(i) not in exempt]);
}

"""Ids of the road edge nearest each reported blockage `(lat, lon)`, sorted.

A citizen's "the road is blocked here" is not inundation A2 can model from
rainfall, so it is added to the impassable set directly: the single nearest
edge to the report is removed, and the optimiser routes around it. One point
closes one edge — deliberately conservative, so a vague report cannot sever a
whole district."""
def reported_block_edges(g: any, points: list[tuple[float, float]]) -> list[str] {
    if not points {
        return [];
    }
    index = edge_index(g);
    out: set[str] = set();
    for (lat, lon) in points {
        try {
            i = int(index.tree.nearest(Point(lon, lat)));
        } except (ValueError, IndexError, TypeError) {
            continue;  # empty graph or degenerate index: nothing to close
        }
        out.add(index.ids[i]);
    }
    return sorted(out);
}

"""A copy of `g` without the impassable edges. Nodes are kept: a node left
with no edges is simply unreachable, which is the truth on the ground."""
def prune_graph(g: any, impassable: any) -> any {
    drop = set(impassable);
    pruned = g.copy();
    index = edge_index(g);
    pruned.remove_edges_from(
        [key for (eid, key) in zip(index.ids, index.keys, strict=True) if eid in drop]
    );
    return pruned;
}

"""Write the routing graph A4 will load and return the contract pointing at it."""
def publish_pruned_graph(
    g: any,
    base_hash: str,
    impassable: list[str],
    surface_version: int,
    version: int,
    prune: bool = True,
    out_dir: Path | None = None
) -> PrunedGraphRef {
    routed = prune_graph(g, impassable) if prune else g;
    directory = ensure_dir(out_dir or cache_dir() / "pruned");
    path = save_graph(routed, directory / f"pruned_v{version:05d}.pkl");
    _cleanup(directory);
    return PrunedGraphRef(
        graph_path=str(path),
        base_graph_hash=base_hash,
        surface_version=surface_version,
        removed_edge_count=g.number_of_edges() - routed.number_of_edges(),
        node_count=routed.number_of_nodes(),
        version=version
    );
}

def _cleanup(directory: Path) -> None {
    old = sorted(directory.glob("pruned_v*.pkl"))[:-KEEP_GENERATIONS];
    for p in old {
        p.unlink(missing_ok=True);
    }
}
