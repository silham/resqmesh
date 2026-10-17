"""Travel times on the hazard-pruned road graph.

ETA = free-flow time per edge (by OSM road class) x the adaptation store's learned
correction for that road class and rainfall band, plus a slow "access" leg from the
nearest drivable node to the demand point (a crew on foot or by boat from the last
dry junction).

Shortest paths run in C via `scipy.sparse.csgraph.dijkstra` over a CSR matrix built
once per (graph, rainfall band, residuals, forbidden edges). On the 101k-edge basin
graph a build is ~0.5 s and a many-source solve is well under a second, which is what
keeps a full re-plan inside the ten-second budget. Nothing here touches the network —
degraded mode depends on it.
"""

import math;
import numpy as np;
import from scipy.sparse { csr_matrix }
import from scipy.sparse.csgraph { dijkstra }
import from shapely.geometry { LineString, Point }
import from resqmesh.adapters.geo.roads { EARTH_RADIUS_M, edge_id }
import from resqmesh.contracts.models { TravelTimeResidual }

"""Free-flow speeds (km/h) for Sri Lankan roads under emergency driving, by OSM class."""
glob FREE_FLOW_KPH: dict[str, float] = {
    "motorway": 80.0,
    "trunk": 55.0,
    "primary": 45.0,
    "secondary": 40.0,
    "tertiary": 35.0,
    "unclassified": 30.0,
    "residential": 25.0,
    "living_street": 15.0,
    "service": 15.0,
    "road": 25.0
};
glob DEFAULT_KPH: float = 25.0;

"""Last-mile access from the snapped node to the demand point, and its cap. Beyond
MAX_ACCESS_M the demand is treated as unreachable by road."""
glob ACCESS_KPH: float = 6.0;
glob MAX_ACCESS_M: float = 2000.0;

"""Boats are trailered by road to the last dry junction, then travel over the water:
a longer, faster final leg. This is what lets a plan reach demand deep inside the
inundation that no road vehicle can."""
glob BOAT_ACCESS_KPH: float = 8.0;
glob BOAT_MAX_ACCESS_M: float = 6000.0;

"""How many nearby drivable nodes are considered as the start of the final leg."""
glob ACCESS_CANDIDATES: int = 64;

"""Rainfall bands used to key learned travel-time residuals."""
glob RAIN_BANDS: list[tuple[float, str]] = [(25.0, "dry"), (100.0, "moderate"), (150.0, "heavy")];
glob EXTREME_BAND: str = "extreme";

"""Normalise an OSM `highway` tag (string or list, `*_link` variants)."""
def road_class(highway: any) -> str {
    if isinstance(highway, (list, tuple)) {
        highway = highway[0] if highway else "";
    }
    return str(highway or "road").removesuffix("_link");
}

def rainfall_band(rain_mm: float | None) -> str {
    if rain_mm is None {
        return "dry";
    }
    for (limit, name) in RAIN_BANDS {
        if rain_mm < limit {
            return name;
        }
    }
    return EXTREME_BAND;
}

def residual_key(cls: str, band: str) -> str {
    return f"{cls}|{band}";
}

def residual_factor(residuals: dict[str, TravelTimeResidual], cls: str, band: str) -> float {
    r = residuals.get(residual_key(cls, band));
    return r.correction_factor if r is not None else 1.0;
}

"""Exponentially weighted update of a road-class x rainfall-band correction.

For the adaptation store (A0) to call when a crew's actual travel time is known:
ratio = observed / predicted, smoothed with weight `alpha`, bounded to [0.5, 4.0] so
a single outlier cannot teach the model that roads are teleporters or walls."""
def update_residual(
    current: TravelTimeResidual | None,
    cls: str,
    band: str,
    observed_minutes: float,
    predicted_minutes: float,
    alpha: float = 0.3
) -> TravelTimeResidual {
    ratio = max(0.5, min(4.0, observed_minutes / max(predicted_minutes, 0.1)));
    prev = current.correction_factor if current is not None else 1.0;
    count = current.sample_count if current is not None else 0;
    factor = max(0.5, min(4.0, (1 - alpha) * prev + alpha * ratio));
    return TravelTimeResidual(
        road_class=cls, rainfall_band=band, correction_factor=round(factor, 4), sample_count=count + 1
    );
}

def _haversine_vec(lat: float, lon: float, lats: any, lons: any) -> any {
    p1 = math.radians(lat);
    p2: any = np.radians(lats);
    dp: any = p2 - p1;
    dl: any = np.radians(lons - lon);
    a: any = np.sin(dp / 2) ** 2 + math.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2;
    return np.asarray(2 * EARTH_RADIUS_M * np.arcsin(np.sqrt(a)));
}

"""One vehicle-to-demand journey, fully determined by the graph.

`access_segments` are the off-graph ends of the journey as (lat1, lon1, lat2, lon2):
depot to the snapped node, and the staging node to the demand point. Carried so A5
can test them against the hazard — they own no edge ids and are otherwise invisible."""
obj Leg {
    has eta_minutes: float,
        distance_km: float,
        edge_ids: list[str],
        access_segments: list[list[float]] = [];
}

"""The two off-graph ends of a journey, zero-length ones dropped."""
def _segments(
    origin: tuple[float, float],
    src: tuple[float, float],
    dst: tuple[float, float],
    dest: tuple[float, float]
) -> list[list[float]] {
    out: list[list[float]] = [];
    for (a, b) in [(origin, src), (dst, dest)] {
        if tuple(a) != tuple(b) {
            out.append([a[0], a[1], b[0], b[1]]);
        }
    }
    return out;
}

"""Does the straight line from `a` to `b` (both lat, lon) enter the geometry?"""
def _crosses(blocked: any, a: tuple[float, float], b: tuple[float, float]) -> bool {
    if tuple(a) == tuple(b) {
        return bool(blocked.intersects(Point(a[1], a[0])));
    }
    return bool(blocked.intersects(LineString([(a[1], a[0]), (b[1], b[0])])));
}

obj TravelModel {
    has nodes: list[any],
        index: dict[any, int],
        matrix: any,  # scipy csr_matrix of minutes
        arcs: dict[tuple[int, int], tuple[str, float]],  # (i, j) -> (edge_id, length_m)
        snap_idx: any,
        snap_lat: any,
        snap_lon: any,
        # node index -> (lat, lon), for the drivable nodes. The access legs are drawn
        # between these and the depot/demand points.
        xy: dict[int, tuple[float, float]] = {};

    static def build(
        g: any,
        rain_mm: float | None = None,
        residuals: dict[str, TravelTimeResidual] | None = None,
        forbidden_edges: any = ()
    ) -> TravelModel {
        forbidden = set(forbidden_edges);
        band = rainfall_band(rain_mm);
        res: dict[str, TravelTimeResidual] = residuals or {};
        nodes = list(g.nodes);
        index: dict[any, int] = {};
        for (i, n) in enumerate(nodes) {
            index[n] = i;
        }
        best: dict[tuple[int, int], tuple[float, str, float]] = {};
        for (u, v, k, data) in g.edges(keys=True, data=True) {
            eid = edge_id(u, v, k);
            if eid in forbidden {
                continue;
            }
            length = float(data.get("length", 0.0));
            rc = road_class(data.get("highway"));
            kph = FREE_FLOW_KPH.get(rc, DEFAULT_KPH);
            minutes = length / 1000.0 / kph * 60.0 * residual_factor(res, rc, band);
            key = (index[u], index[v]);
            if key not in best or minutes < best[key][0] {
                best[key] = (max(minutes, 1e-6), eid, length);
            }
        }
        n_nodes = len(nodes);
        keys = list(best.keys());
        rows: any = np.array([kk[0] for kk in keys], dtype=np.int64);
        cols: any = np.array([kk[1] for kk in keys], dtype=np.int64);
        vals: any = np.array([best[kk][0] for kk in keys], dtype=np.float64);
        matrix = csr_matrix((vals, (rows, cols)), shape=(n_nodes, n_nodes));
        # Snap only to nodes that still have an edge: after pruning, a junction in the
        # water is isolated, and the right staging point is the last dry one.
        touched: set[int] = set();
        for kk in keys {
            touched.add(kk[0]);
            touched.add(kk[1]);
        }
        active = sorted(touched);
        snap: any = np.array(active, dtype=np.int64);
        lat: any = np.array([g.nodes[nodes[i]]["y"] for i in active], dtype=np.float64);
        lon: any = np.array([g.nodes[nodes[i]]["x"] for i in active], dtype=np.float64);
        return TravelModel(
            nodes=nodes,
            index=index,
            matrix=matrix,
            arcs={kk: (b[1], b[2]) for (kk, b) in best.items()},
            snap_idx=snap,
            snap_lat=lat,
            snap_lon=lon,
            xy={i: (float(g.nodes[nodes[i]]["y"]), float(g.nodes[nodes[i]]["x"])) for i in active}
        );
    }

    """Nearest drivable node index and its distance in metres."""
    def snap(lat: float, lon: float) -> tuple[int, float] | None {
        if self.snap_idx.size == 0 {
            return None;
        }
        d: any = _haversine_vec(lat, lon, self.snap_lat, self.snap_lon);
        j = int(np.argmin(d));
        return (int(self.snap_idx[j]), float(d[j]));
    }

    """Up to `ACCESS_CANDIDATES` drivable nodes within `max_access_m`, nearest first.

    The final leg may start from any of them. Snapping to the single nearest dry node
    is wrong inside a flood: that node is often a small dry island cut off from every
    depot, while a slightly farther one is on the connected network."""
    def access_candidates(lat: float, lon: float, max_access_m: float) -> tuple[any, any] {
        if self.snap_idx.size == 0 {
            return (np.empty(0, dtype=np.int64), np.empty(0));
        }
        d: any = _haversine_vec(lat, lon, self.snap_lat, self.snap_lon);
        within: any = np.flatnonzero(d <= max_access_m);
        order: any = within[np.argsort(d[within], kind="stable")][:ACCESS_CANDIDATES];
        return (self.snap_idx[order], d[order]);
    }

    """Every reachable (origin, destination) journey. Unreachable pairs are absent.

    `max_access_m` / `access_kph` govern the final leg to the demand point;
    `origin_access_m` caps how far a depot may sit from the road network.

    `blocked` is a prepared geometry the access legs may not cross — the inundation,
    for a vehicle that cannot swim. The graph legs are already safe by construction
    (A2 pruned them), but the two access legs are off-graph and carry no edge ids, so
    nothing else in the system can see them. A destination whose every candidate
    staging node would require wading is simply unreachable for that vehicle, exactly
    as an unroutable pair is. Pass None for a boat: for a boat the water is the road."""
    def legs(
        origins: dict[str, tuple[float, float]],
        destinations: dict[str, tuple[float, float]],
        max_access_m: float = MAX_ACCESS_M,
        access_kph: float = ACCESS_KPH,
        origin_access_m: float = MAX_ACCESS_M,
        blocked: any = None
    ) -> dict[tuple[str, str], Leg] {
        o_snap: dict[str, tuple[int, float]] = {};
        for (k, pos) in origins.items() {
            s = self.snap(pos[0], pos[1]);
            if s and s[1] <= origin_access_m {
                o_snap[k] = s;
            }
        }
        if blocked is not None {
            # A depot that cannot be left without crossing water is out of the fleet.
            o_snap = {
                k: s
                for (k, s) in o_snap.items()
                if not _crosses(blocked, origins[k], self.xy[s[0]])
            };
        }
        d_cand: dict[str, tuple[any, any]] = {};
        for (k, pos) in destinations.items() {
            c = self.access_candidates(pos[0], pos[1], max_access_m);
            if c[0].size {
                d_cand[k] = c;
            }
        }
        if not o_snap or not d_cand {
            return {};
        }
        o_keys = sorted(o_snap);
        sources = [o_snap[k][0] for k in o_keys];
        solved: any = dijkstra(self.matrix, directed=True, indices=sources, return_predecessors=True);
        dist: any = solved[0];
        pred: any = solved[1];
        out: dict[tuple[str, str], Leg] = {};
        for (row, ok) in enumerate(o_keys) {
            (src, src_access) = o_snap[ok];
            for (dk, cand) in d_cand.items() {
                cand_nodes: any = cand[0];
                metres: any = cand[1];
                # Best staging node = least drive + final-leg time, over the candidates.
                total: any = dist[row, cand_nodes] + metres / 1000.0 / access_kph * 60.0;
                j = self.best_staging(total, cand_nodes, destinations[dk], blocked);
                if j is None {
                    continue;
                }
                dst = int(cand_nodes[j]);
                dst_access = float(metres[j]);
                drive = float(dist[row, dst]);
                (edges, length) = self.path(pred[row], src, dst);
                access = src_access + dst_access;
                access_min = src_access / 1000.0 / ACCESS_KPH * 60.0 + dst_access / 1000.0 / access_kph * 60.0;
                out[(ok, dk)] = Leg(
                    eta_minutes=round(drive + access_min, 3),
                    distance_km=round((length + access) / 1000.0, 3),
                    edge_ids=edges,
                    access_segments=_segments(origins[ok], self.xy[src], self.xy[dst], destinations[dk])
                );
            }
        }
        return out;
    }

    """Index into `cand_nodes` of the quickest staging point whose final leg is legal.

    With no hazard to respect this is a plain argmin. With one, the candidates are
    tried in time order and the first whose final leg stays out of the water wins: a
    nearer staging node in the flood must not beat a slightly farther dry one."""
    def best_staging(total: any, cand_nodes: any, dest: tuple[float, float], blocked: any) -> int | None {
        if blocked is None {
            j = int(np.argmin(total));
            return j if math.isfinite(float(total[j])) else None;
        }
        order: any = np.argsort(total, kind="stable");
        for j in order {
            if not math.isfinite(float(total[j])) {
                return None;  # sorted, so everything after this is unreachable too
            }
            if not _crosses(blocked, self.xy[int(cand_nodes[j])], dest) {
                return int(j);
            }
        }
        return None;
    }

    def path(pred_row: any, src: int, dst: int) -> tuple[list[str], float] {
        edges: list[str] = [];
        length = 0.0;
        n = dst;
        while n != src {
            prev = int(pred_row[n]);
            if prev < 0 {  # defensive: dist was finite, so this cannot happen
                break;
            }
            (eid, meters) = self.arcs[(prev, n)];
            edges.append(eid);
            length += meters;
            n = prev;
        }
        edges.reverse();
        return (edges, length);
    }
}
