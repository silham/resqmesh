"""A small synthetic road grid laid over the Kelani basin.

Real data needs the fetcher (~250 MB, network). Unit tests and anyone developing
without the download use this instead: a rectangular grid of two-way streets with
OSMnx-shaped attributes (`x`, `y`, `length`, `highway`), so every code path that
consumes the real g runs unchanged against it.
"""

import networkx as nx;
import from resqmesh.adapters.geo.roads { haversine_m }

"""rows x cols two-way grid; node id r * cols + c. Row `arterial_row` is tagged
`primary`, everything else `residential`. A step of 0.005 degrees is roughly 550 m."""
def grid_graph(
    rows: int = 6,
    cols: int = 8,
    origin: tuple[float, float] = (6.90, 79.90),
    step_deg: float = 0.005,
    arterial_row: int | None = 2
) -> any {
    (lat0, lon0) = origin;
    g = nx.MultiDiGraph(crs="EPSG:4326", name="synthetic-grid");
    for r in range(rows) {
        for c in range(cols) {
            g.add_node(r * cols + c, y=lat0 + r * step_deg, x=lon0 + c * step_deg);
        }
    }

    def link(a: int, b: int, highway: str) -> None {
        ya = g.nodes[a]["y"];
        xa = g.nodes[a]["x"];
        yb = g.nodes[b]["y"];
        xb = g.nodes[b]["x"];
        length = haversine_m(ya, xa, yb, xb);
        g.add_edge(a, b, key=0, length=length, highway=highway);
        g.add_edge(b, a, key=0, length=length, highway=highway);
    }

    for r in range(rows) {
        for c in range(cols) {
            n = r * cols + c;
            if c + 1 < cols {
                link(n, n + 1, "primary" if r == arterial_row else "residential");
            }
            if r + 1 < rows {
                link(n, n + cols, "residential");
            }
        }
    }
    return g;
}
