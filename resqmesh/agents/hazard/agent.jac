"""A2 — Spatial Hazard Agent.

Turns rainfall and terrain into the physical picture every downstream decision
rests on: where the water is, which slopes are failing, and which roads no longer
exist for routing purposes.

State fields read: `hazard` and `pruned_graph` (previous versions, A2's own), and
`clusters` (road-blockage reports).
State fields written: `hazard`, `pruned_graph` — and a `trace` event.

Fallback chain (roadmap section 5.3 — a lower-confidence answer, never silence):

==============================  ===========================================  ==========
condition                       what A2 does                                 confidence
==============================  ===========================================  ==========
normal                          HAND inundation + NBRO susceptibility         0.75
HAND fails / no DEM             buffer proxy around OSM watercourses          0.40
rainfall served from cache      same model, stale input                       x 0.85
rainfall unavailable entirely   assume `assumed_rain_mm` (alert level)        x 0.50
no HAND and no waterways        empty inundation, nothing pruned by water    0.10
==============================  ===========================================  ==========

Assuming alert-level rain when blind is deliberate: over-pruning costs a longer
route; under-pruning sends a crew into water.

No number here comes from a language model. Every polygon and every impassable edge
is a deterministic function of the DEM, the watercourses, the road graph and the
rainfall series, so A5 can recompute any of it.
"""

import json;
import uuid;
import from datetime { UTC, datetime }
import from pathlib { Path }
import from shapely.geometry { Point }
import from shapely.ops { unary_union }
import from resqmesh.adapters.geo.hydro { load_waterways }
import from resqmesh.adapters.geo.paths { dem_path, gn_boundaries_path }
import from resqmesh.adapters.geo.roads { graph_hash, load_graph }
import from resqmesh.adapters.geo.shapes { prepared, union_of }
import from resqmesh.adapters.geo.terrain { Dem, load_dem }
import from resqmesh.agents.hazard.buffer_proxy { buffer_proxy_inundation }
import from resqmesh.agents.hazard.hand { HandModel }
import from resqmesh.agents.hazard.pruning { impassable_edges, publish_pruned_graph, reported_block_edges }
import from resqmesh.agents.hazard.susceptibility { susceptibility_surface }
import from resqmesh.contracts.enums { ActionTier, HazardMethod, HazardType }
import from resqmesh.contracts.models { HazardSurface, PrunedGraphRef, TraceEvent }
import from resqmesh.contracts.ports { WeatherPort }
import from resqmesh.contracts.state { IncidentState }

glob CONFIDENCE_HAND: float = 0.75;
glob CONFIDENCE_BUFFER: float = 0.40;
glob CONFIDENCE_NOTHING: float = 0.10;
glob STALE_RAIN_FACTOR: float = 0.85;
glob BLIND_RAIN_FACTOR: float = 0.50;

obj HazardConfig {
    # Basin rainfall points; the maximum across them drives the surface (conservative).
    # Defaults: Hanwella and Glencourse gauges on the lower/middle Kelani.
    has rain_points: list[tuple[float, float]] = [(6.901, 80.085), (6.976, 80.186)],
        hours_back: int = 72,
        prefer_hand: bool = True,
        # Ablation switch — False publishes impassable edges but leaves the graph whole.
        prune: bool = True,
        # Susceptible slopes close roads from NBRO Level 3 ("evacuate"); below that they
        # are shown on the map and feed triage, but do not remove edges.
        susceptibility_prunes_from_level: int = 3,
        assumed_rain_mm: float = 100.0;
}

"""Weight on the 72-hour total when forming the flood driver. Rivers crest after the
rain stops — the lower Kelani peaked on 17-18 May 2016 when 24 h totals had
already fallen — so the driver is max(24 h, 0.6 x 72 h): a simple antecedent index
that lets water recede over ~3 days instead of vanishing overnight."""
glob ANTECEDENT_WEIGHT: float = 0.6;

obj RainfallReading {
    has rain_24h_mm: float,
        rain_72h_mm: float,
        stale: bool,
        blind: bool;

    """24-hour-equivalent rainfall that sets the flood stage."""
    def flood_driver_mm -> float {
        return max(self.rain_24h_mm, ANTECEDENT_WEIGHT * self.rain_72h_mm);
    }
}

obj HazardAssessment {
    has surface: HazardSurface,
        pruned_graph: PrunedGraphRef,
        detail: str;
}

"""GN id -> (lat, lon) from the fetched boundary file, if present."""
def load_gn_centroids() -> dict[str, tuple[float, float]] {
    p = gn_boundaries_path();
    if not p.exists() {
        return {};
    }
    fc = json.loads(p.read_text(encoding="utf-8"));
    out: dict[str, tuple[float, float]] = {};
    for f in fc.get("features", []) {
        props = f.get("properties") or {};
        if props.get("gn_id") and props.get("center_lat") is not None {
            out[str(props["gn_id"])] = (float(props["center_lat"]), float(props["center_lon"]));
        }
    }
    return out;
}

"""The basin DEM, or None when it has not been fetched (or rasterio is missing)."""
def optional_dem() -> Dem | None {
    try {
        return load_dem();
    } except (FileNotFoundError, ImportError) {
        return None;
    }
}

obj HazardAgent {
    has weather: WeatherPort,
        graph_loader: any = load_graph,
        waterways_loader: any = load_waterways,
        dem_loader: any = optional_dem,
        # rainfall (24 h mm) -> inundation GeoJSON. Default: HAND over the fetched DEM.
        inundation_model: any = None,
        gn_centroids: dict[str, tuple[float, float]] | None = None,
        config: HazardConfig = HazardConfig(),
        out_dir: Path | None = None;

    def postinit {
        if self.inundation_model is None and self.config.prefer_hand and dem_path().exists() {
            self.inundation_model = HandModel().inundation;
        }
        if self.gn_centroids is None {
            self.gn_centroids = load_gn_centroids();
        }
    }

    # -- inputs ------------------------------------------------------------------

    def read_rainfall -> RainfallReading {
        r24 = 0.0;
        r72 = 0.0;
        stale = False;
        got = 0;
        for (lat, lon) in self.config.rain_points {
            try {
                series = self.weather.rainfall(lat, lon, hours_back=self.config.hours_back);
            } except Exception {
                continue;  # one dead gauge must not blind the whole basin
            }
            got += 1;
            stale = stale or series.from_cache;
            r24 = max(r24, sum(series.observed_mm[-24:]));
            r72 = max(r72, sum(series.observed_mm[-72:]));
        }
        if got == 0 {
            a = self.config.assumed_rain_mm;
            return RainfallReading(rain_24h_mm=a, rain_72h_mm=a * 1.5, stale=True, blind=True);
        }
        return RainfallReading(rain_24h_mm=r24, rain_72h_mm=r72, stale=stale, blind=False);
    }

    # -- the computation ------------------------------------------------------------

    def assess(
        previous_surface: HazardSurface | None = None,
        previous_graph: PrunedGraphRef | None = None,
        blocked_points: list[tuple[float, float]] | None = None,
        now: datetime | None = None
    ) -> HazardAssessment {
        now = now or datetime.now(UTC);
        rain = self.read_rainfall();
        driver = rain.flood_driver_mm();

        method = HazardMethod.HAND;
        confidence = CONFIDENCE_HAND;
        notes: list[str] = [];
        inundation: dict[str, any] | None = None;
        if self.inundation_model is not None {
            try {
                inundation = self.inundation_model(driver);
            } except Exception as exc {  # HAND degraded -> buffer proxy, stated
                notes.append(f"hand failed ({exc.__class__.__name__}); buffer proxy used");
            }
        }
        if inundation is None {
            method = HazardMethod.BUFFER_PROXY;
            confidence = CONFIDENCE_BUFFER;
            waterways = self.waterways_loader();
            if waterways is None {
                confidence = CONFIDENCE_NOTHING;
                notes.append("no waterway data; inundation not assessed");
            }
            inundation = buffer_proxy_inundation(waterways, driver);
        }

        dem = self.dem_loader();
        suscept = susceptibility_surface(dem, rain.rain_24h_mm, rain.rain_72h_mm);
        if dem is None {
            notes.append("no DEM; susceptibility not assessed");
        }
        if rain.blind {
            confidence *= BLIND_RAIN_FACTOR;
            notes.append(f"rainfall unavailable; assumed {self.config.assumed_rain_mm:.0f} mm/24h");
        } elif rain.stale {
            confidence *= STALE_RAIN_FACTOR;
            notes.append("rainfall from cache");
        }

        water = union_of(inundation);
        slopes = union_of(suscept.collection)
            if suscept.level >= self.config.susceptibility_prunes_from_level
            else None;
        g = self.graph_loader();
        blocked = reported_block_edges(g, list(blocked_points or []));
        impassable = sorted(
            set(impassable_edges(g, water, bridges_exempt=True))
            | set(impassable_edges(g, slopes))
            | set(blocked)
        );
        closed = [geom for geom in [water, slopes] if geom is not None];
        no_go = self._no_go_gn_ids(unary_union(closed) if closed else None);

        surface_version = (previous_surface.version + 1) if previous_surface else 1;
        graph_version = (previous_graph.version + 1) if previous_graph else 1;
        surface = HazardSurface(
            surface_id=f"HS-{surface_version:04d}",
            version=surface_version,
            generated_at=now,
            method=method,
            confidence_0_1=round(confidence, 3),
            inundation_geojson=inundation,
            susceptibility_geojson=suscept.collection,
            impassable_edge_ids=impassable,
            no_go_gn_ids=no_go,
            driving_rainfall_mm_24h=round(driver, 1)
        );
        pruned = publish_pruned_graph(
            g,
            base_hash=graph_hash(g),
            impassable=impassable,
            surface_version=surface_version,
            version=graph_version,
            prune=self.config.prune,
            out_dir=self.out_dir
        );
        detail = (
            f"method={method.value} conf={surface.confidence_0_1:.2f} rain24={rain.rain_24h_mm:.0f}mm "
            f"rain72={rain.rain_72h_mm:.0f}mm driver={driver:.0f}mm nbro_level={suscept.level} impassable={len(impassable)} "
            f"no_go_gn={len(no_go)} pruned={self.config.prune}"
        );
        if blocked {
            detail += f" reported_blocks={len(blocked)}";
        }
        if notes {
            detail += " | " + "; ".join(notes);
        }
        return HazardAssessment(surface=surface, pruned_graph=pruned, detail=detail);
    }

    """Centroids of clusters a reporter typed as a road blockage, for pruning."""
    static def _reported_blocks(state: IncidentState) -> list[tuple[float, float]] {
        return [
            (c.centroid_lat, c.centroid_lon)
            for c in (state.clusters or [])
            if c.hazard_type == HazardType.ROAD_BLOCKED
        ];
    }

    def _no_go_gn_ids(hazard_geom: any) -> list[str] {
        if hazard_geom is None or not self.gn_centroids {
            return [];
        }
        prep = prepared(hazard_geom);
        return sorted(
            [gn for (gn, ll) in self.gn_centroids.items() if prep.intersects(Point(ll[1], ll[0]))]
        );
    }

    # -- graph node ---------------------------------------------------------------

    """Incident-graph step: returns only A2's fields plus one trace event."""
    def run(state: IncidentState, now: datetime | None = None) -> dict[str, any] {
        now = now or datetime.now(UTC);
        result = self.assess(
            previous_surface=state.hazard,
            previous_graph=state.pruned_graph,
            blocked_points=HazardAgent._reported_blocks(state),
            now=now
        );
        event = TraceEvent(
            event_id=f"EV-{uuid.uuid4().hex[:12]}",
            agent="A2",
            action="hazard_recomputed",
            tier=ActionTier.TIER_A,
            detail=result.detail,
            occurred_at=now
        );
        return {"hazard": result.surface, "pruned_graph": result.pruned_graph, "trace": [event]};
    }
}
