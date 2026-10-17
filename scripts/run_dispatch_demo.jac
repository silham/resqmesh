"""Smoke-run the geospatial + optimisation chain: A2 -> A3 -> A4 -> A5.

    jac run -b python --no-takeover scripts/run_dispatch_demo.jac                        # real basin, 2016 peak
    jac run -b python --no-takeover scripts/run_dispatch_demo.jac --at 2016-05-14T00:00  # earlier in the event
    jac run -b python --no-takeover scripts/run_dispatch_demo.jac --no-prune             # ablation: no graph pruning
    jac run -b python --no-takeover scripts/run_dispatch_demo.jac --synthetic            # no downloaded data needed
    jac run -b python --no-takeover scripts/run_dispatch_demo.jac --geojson out.geojson  # hazard + routes for a map

Rainfall is the real Open-Meteo archive replayed at `--at` (cached after the first
run, so `RESQMESH_OFFLINE=1` works). The incidents and fleet are **synthetic**, placed
at seeded-random real GN division centroids, because this script exercises the
pipeline, not the evaluation. Table 7 numbers come only from the replay harness over
the labelled scenarios.
"""

import argparse;
import json;
import random;
import sys;
import time;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.adapters.fakes { FakeGazetteer, FakeWeather }
import from resqmesh.adapters.geo.open_meteo { OpenMeteoWeather }
import from resqmesh.adapters.geo.paths { gn_boundaries_path, road_graph_path }
import from resqmesh.adapters.geo.replay_weather { ReplayWeather }
import from resqmesh.adapters.geo.roads { load_graph }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.hazard.agent { HazardAgent, HazardConfig }
import from resqmesh.agents.optimiser.agent { OptimiserAgent, OptimiserConfig }
import from resqmesh.agents.optimiser.exact { gap_to_exact }
import from resqmesh.agents.triage.agent { TriageAgent }
import from resqmesh.contracts.enums { ClusterState, HazardType, VulnerabilityFlag }
import from resqmesh.contracts.models { IncidentCluster, IncidentReport, Vehicle }
import from resqmesh.contracts.state { IncidentState, apply_update }

glob USAGE: str = __doc__ or "";

glob KINDS: list[tuple[str, int]] = [("boat", 8), ("boat", 12), ("truck", 12), ("ambulance", 4)];

def _divisions(synthetic: bool) -> dict[str, tuple[str, float, float]] {
    if synthetic or not gn_boundaries_path().exists() {
        return {
            f"GRID-{n:02d}": (f"grid {n}", 6.90 + (n // 8) * 0.005, 79.90 + (n % 8) * 0.005)
            for n in range(48)
        };
    }
    fc = json.loads(gn_boundaries_path().read_text(encoding="utf-8"));
    return {
        str(f["properties"]["gn_id"]): (
            str(f["properties"]["name_en"]), float(f["properties"]["center_lat"]), float(f["properties"]["center_lon"])
        )
        for f in fc["features"]
    };
}

"""Seeded demand and fleet at division centroids. Returns (clusters, reports, vehicles)."""
def _incident(
    divs: dict[str, tuple[str, float, float]], n_clusters: int, n_vehicles: int, now: datetime, seed: int
) -> tuple[list[IncidentCluster], list[IncidentReport], list[Vehicle]] {
    rng = random.Random(seed);
    ids = sorted(divs.keys());
    clusters: list[IncidentCluster] = [];
    reports: list[IncidentReport] = [];
    hazard_choices = [HazardType.FLOOD] * 4 + [HazardType.MEDICAL, HazardType.LANDSLIDE];
    state_choices = [ClusterState.CORROBORATED] * 3 + [ClusterState.SINGLE_SOURCE];
    for (i, gn) in enumerate(rng.sample(ids, min(n_clusters, len(ids)))) {
        lat = divs[gn][1];
        lon = divs[gn][2];
        hazard = rng.choice(hazard_choices);
        clusters.append(IncidentCluster(
            cluster_id=f"CL-{i:03d}", member_report_ids=[f"R-{i:03d}"], centroid_lat=lat, centroid_lon=lon,
            gn_id=gn, hazard_type=hazard, confidence_0_1=round(rng.uniform(0.35, 0.95), 2),
            state=rng.choice(state_choices),
            corroborating_source_count=rng.randint(1, 4),
            first_seen=now - timedelta(hours=rng.randint(0, 10)), last_seen=now
        ));
        severity = rng.randint(1, 4);
        people = rng.randint(1, 40);
        flags: list[VulnerabilityFlag] = [
            VulnerabilityFlag(f) for f in rng.sample(list(VulnerabilityFlag), rng.randint(0, 2))
        ];
        reports.append(IncidentReport(
            report_id=f"R-{i:03d}", signal_id=f"S-{i:03d}", source_id="synthetic", hazard_type=hazard,
            description="synthetic demand", raw_place_text=divs[gn][0], resolved_gn_id=gn, lat=lat, lon=lon,
            severity_claim=severity, reported_people_affected=people,
            vulnerability_flags=flags, observed_at=now
        ));
    }
    vehicles: list[Vehicle] = [];
    for (j, gn) in enumerate(rng.sample(ids, min(n_vehicles, len(ids)))) {
        spec = KINDS[j % len(KINDS)];
        vehicles.append(Vehicle(
            vehicle_id=f"{spec[0][:3].upper()}-{j:02d}", kind=spec[0], capacity=spec[1],
            depot_gn_id=gn, depot_lat=divs[gn][1], depot_lon=divs[gn][2]
        ));
    }
    return (clusters, reports, vehicles);
}

def _geojson(state: IncidentState, roads: any) -> dict[str, any] {
    feats: list[dict[str, any]] = [];
    hazard = state.hazard;
    plan = state.plan;
    if hazard is not None {
        layers: list[tuple[dict[str, any], str]] = [
            (hazard.inundation_geojson, "inundation"), (hazard.susceptibility_geojson, "susceptibility")
        ];
        for layer in layers {
            for f in layer[0]["features"] {
                feats.append({**f, "properties": {**f.get("properties", {}), "layer": layer[1]}});
            }
        }
    }
    if plan is not None {
        for a in plan.assignments {
            coords: list[list[float]] = [];
            for eid in a.route_edge_ids {
                parts = eid.split("-");
                for n in parts[:2] {
                    key: any = int(n) if n.lstrip("-").isdigit() else n;
                    vertex: any = roads.nodes[key];
                    pt = [vertex["x"], vertex["y"]];
                    if not coords or coords[-1] != pt {
                        coords.append(pt);
                    }
                }
            }
            if len(coords) >= 2 {
                feats.append({
                    "type": "Feature", "geometry": {"type": "LineString", "coordinates": coords},
                    "properties": {
                        "layer": "route", "vehicle": a.vehicle_id, "cluster": a.cluster_id,
                        "eta_min": a.eta_minutes
                    }
                });
            }
        }
    }
    for c in state.clusters {
        feats.append({
            "type": "Feature", "geometry": {"type": "Point", "coordinates": [c.centroid_lon, c.centroid_lat]},
            "properties": {"layer": "cluster", "cluster": c.cluster_id}
        });
    }
    return {"type": "FeatureCollection", "features": feats};
}

def main(argv: list[str]) -> int {
    p = argparse.ArgumentParser(description=USAGE, formatter_class=argparse.RawDescriptionHelpFormatter);
    p.add_argument("--at", `default="2016-05-16T06:00", help="replay clock, UTC (default: 2016 peak)");
    p.add_argument("--clusters", `type=int, `default=40);
    p.add_argument("--vehicles", `type=int, `default=15);
    p.add_argument("--seed", `type=int, `default=7);
    p.add_argument("--no-prune", action="store_true", help="ablation: publish impassable edges, keep graph whole");
    p.add_argument("--synthetic", action="store_true", help="synthetic grid + fake weather; no data needed");
    p.add_argument("--budget", `type=float, `default=10.0, help="CP-SAT time budget (s)");
    p.add_argument("--geojson", `type=Path, help="write hazard polygons, routes and clusters here");
    args = p.parse_args(argv);

    now = datetime.fromisoformat(args.at).replace(tzinfo=UTC);
    synthetic: bool = bool(args.synthetic) or not road_graph_path().exists();
    divs = _divisions(synthetic);
    built = _incident(divs, args.clusters, args.vehicles, now, args.seed);
    clusters = built[0];
    vehicles = built[2];
    state = IncidentState(clusters=clusters, reports=built[1], vehicles=vehicles, approvals=[]);
    config = HazardConfig(prune=not args.no_prune, prefer_hand=not synthetic);
    a2: HazardAgent;
    a4: OptimiserAgent;
    if synthetic {
        roads: any = grid_graph();
        def graph_loader() -> any {
            return roads;
        }
        def no_data() -> any {
            return None;
        }
        a2 = HazardAgent(
            weather=FakeWeather(peak_mm=12.0), graph_loader=graph_loader, waterways_loader=no_data,
            dem_loader=no_data, gn_centroids={}, config=config
        );
        a4 = OptimiserAgent(base_graph_loader=graph_loader, config=OptimiserConfig(time_budget_s=args.budget));
        print("[demo] synthetic grid (no fetched data found or --synthetic given)");
    } else {
        def clock() -> datetime {
            return now;
        }
        a2 = HazardAgent(weather=ReplayWeather(archive=OpenMeteoWeather(), clock=clock), config=config);
        a4 = OptimiserAgent(config=OptimiserConfig(time_budget_s=args.budget));
    }

    stages: list[tuple[str, any]] = [("A2", a2), ("A3", TriageAgent()), ("A4", a4)];
    for stage in stages {
        t = time.perf_counter();
        out: dict[str, any] = stage[1].run(state, now);
        trace = out.pop("trace");
        state = apply_update(state, out);
        print(f"[{stage[0]}] {time.perf_counter() - t:5.2f}s  {trace[0].detail}");
    }
    plan = state.plan;
    hazard = state.hazard;
    pruned = state.pruned_graph;
    if plan is None or hazard is None {
        print("[A4] no plan produced");
        return 1;
    }

    verdict = GuardrailAgent(gazetteer=FakeGazetteer(divisions=dict(divs))).verify_plan(
        plan, clusters, hazard, vehicles, now=now
    );
    print(f"[A5] passed={verdict.passed} violated={verdict.violated_constraint}");
    for c in verdict.checks {
        print(f"       {'ok ' if c.passed else 'FAIL'} {c.name}: {c.detail[:120]}");
    }

    greedy = a4.plan(
        queue=state.queue, clusters=state.clusters, reports=state.reports, vehicles=state.vehicles,
        hazard=hazard, pruned_graph=pruned, now=now, mode="greedy"
    );
    exact = a4.plan(
        queue=state.queue, clusters=state.clusters, reports=state.reports, vehicles=state.vehicles,
        hazard=hazard, pruned_graph=pruned, now=now, mode="exact"
    );
    live_gap = gap_to_exact(plan.objective_value, exact.solution.objective);
    greedy_gap = gap_to_exact(greedy.solution.objective, exact.solution.objective);
    print(
        f"[eval] objective live={plan.objective_value:.1f} greedy={greedy.solution.objective:.1f} "
        + f"exact={exact.solution.objective:.1f} | gap live={live_gap:.4f} greedy={greedy_gap:.4f}"
    );
    gn_of = {c.cluster_id: c.gn_id for c in state.clusters};
    for a in plan.assignments[:10] {
        place = divs[gn_of[a.cluster_id]][0];
        print(
            f"       {a.vehicle_id:>7} -> {a.cluster_id} ({place}): "
            + f"{a.eta_minutes:5.1f} min, {a.distance_km:5.2f} km, load {a.load}"
        );
    }

    if args.geojson is not None {
        if pruned is None {
            print("[demo] no pruned graph published; geojson not written");
        } else {
            routed: any = load_graph(pruned.graph_path);
            args.geojson.write_text(json.dumps(_geojson(state, routed)), encoding="utf-8");
            print(f"[demo] wrote {args.geojson}");
        }
    }
    return 0 if verdict.passed else 2;
}

with entry {
    argv = [a for a in sys.argv[1:] if not a.endswith(".jac")];
    sys.exit(main(argv));
}
