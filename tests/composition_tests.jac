"""Contract tests at the A2 / A3 / A4 boundaries.

Each node's output must (1) validate and round-trip through its contract, (2) touch
only the state fields that node owns (one writer per field), and (3) compose with the
shared reducers.
"""

import json;
import re;
import tempfile;
import warnings;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.adapters.fakes { FakeGazetteer }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.agents.hazard.agent { HazardAgent, HazardConfig }
import from resqmesh.agents.triage.agent { TriageAgent }
import from resqmesh.agents.optimiser.agent { OptimiserAgent }
import from resqmesh.contracts.enums { ClusterState, HazardMethod, HazardType, SolverStatus }
import from resqmesh.contracts.models {
    Assignment, DispatchPlan, HazardSurface, IncidentCluster, IncidentReport, PriorityItem,
    PrunedGraphRef, SCORE_COMPONENTS, ScoreComponents, Vehicle, evolve, to_json
}
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }
import from resqmesh.contracts.state { IncidentState, STATE_FIELDS, append_only, versioned }

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
glob EDGE_ID: any = re.compile(r"^[^-\s]+-[^-\s]+-\d+$");

"""The only state fields each node may return. "trace" is append-only for everyone."""
glob OWNED: dict[str, set[str]] = {
    "A2": {"hazard", "pruned_graph", "trace"},
    "A3": {"queue", "trace"},
    "A4": {"plan", "trace"}
};

obj SteadyRain(WeatherPort) {
    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        return RainfallSeries(lat=lat, lon=lon, observed_mm=[5.0] * hours_back, forecast_mm=[], start_time=NOW);
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        return self.rainfall(lat, lon);
    }
}

def outputs() -> dict[str, any] {
    g = grid_graph();
    river: dict[str, any] = {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature", "properties": {"waterway": "river"},
                "geometry": {"type": "LineString", "coordinates": [[79.895, 6.9075], [79.9175, 6.9075]]}
            }
        ]
    };
    sites = [(6.925, 79.905, "KLN-001"), (6.905, 79.935, "KLN-002")];
    clusters = [
        IncidentCluster(
            cluster_id=f"CL-{i}", member_report_ids=[f"R-{i}"], centroid_lat=site[0], centroid_lon=site[1],
            gn_id=site[2], hazard_type=HazardType.FLOOD, confidence_0_1=0.8, state=ClusterState.CORROBORATED,
            first_seen=NOW - timedelta(hours=2), last_seen=NOW
        )
        for (i, site) in enumerate(sites)
    ];
    reports = [
        IncidentReport(
            report_id=f"R-{i}", signal_id=f"S-{i}", source_id="s", hazard_type=HazardType.FLOOD,
            description="d", raw_place_text="p", observed_at=NOW, reported_people_affected=5
        )
        for i in range(2)
    ];
    vehicles = [
        Vehicle(vehicle_id="V-1", kind="boat", capacity=8, depot_gn_id="KLN-001", depot_lat=6.90, depot_lon=79.90),
        Vehicle(vehicle_id="V-2", kind="truck", capacity=8, depot_gn_id="KLN-002", depot_lat=6.925, depot_lon=79.935)
    ];

    def graph_loader() -> any {
        return g;
    }

    def river_loader() -> any {
        return river;
    }

    def no_dem() -> any {
        return None;
    }

    state = IncidentState(clusters=clusters, reports=reports, vehicles=vehicles, approvals=[]);
    a2 = HazardAgent(
        weather=SteadyRain(), graph_loader=graph_loader, waterways_loader=river_loader, dem_loader=no_dem,
        inundation_model=None, gn_centroids={}, config=HazardConfig(prefer_hand=False),
        out_dir=Path(tempfile.mkdtemp(prefix="composition_tests_"))
    ).run(state, now=NOW);
    for (k, v) in a2.items() {
        setattr(state, k, v);
    }
    a3 = TriageAgent().run(state, now=NOW);
    for (k, v) in a3.items() {
        setattr(state, k, v);
    }
    a4 = OptimiserAgent(base_graph_loader=graph_loader, gazetteer=FakeGazetteer()).run(state, now=NOW);
    return {"A2": a2, "A3": a3, "A4": a4, "state": state};
}

# ---------------------------------------------------------------- rebuild from JSON

def _fields(text: str) -> dict[str, any] {
    data: dict[str, any] = json.loads(text);
    data.pop("schema_version", None);
    return data;
}

def _when(value: str) -> datetime {
    return datetime.fromisoformat(value.replace("Z", "+00:00"));
}

def surface_from_json(text: str) -> HazardSurface {
    data = _fields(text);
    data["generated_at"] = _when(data["generated_at"]);
    data["method"] = HazardMethod(data["method"]);
    return HazardSurface(**data);
}

def graph_ref_from_json(text: str) -> PrunedGraphRef {
    return PrunedGraphRef(**_fields(text));
}

def priority_from_json(text: str) -> PriorityItem {
    data = _fields(text);
    comps: dict[str, any] = data["components"];
    comps.pop("schema_version", None);
    data["components"] = ScoreComponents(**comps);
    return PriorityItem(**data);
}

def plan_from_json(text: str) -> DispatchPlan {
    data = _fields(text);
    assignments: list[Assignment] = [];
    for a in data["assignments"] {
        a.pop("schema_version", None);
        assignments.append(Assignment(**a));
    }
    data["assignments"] = assignments;
    data["generated_at"] = _when(data["generated_at"]);
    data["solver_status"] = SolverStatus(data["solver_status"]);
    return DispatchPlan(**data);
}

def dumps(value: any) -> str {
    return json.dumps(to_json(value), sort_keys=True);
}

# ---------------------------------------------------------------- the tests

test "nodes write only their own fields" {
    out = outputs();
    for node in ["A2", "A3", "A4"] {
        written = set(out[node]);
        assert written <= OWNED[node], f"{node} wrote {written - OWNED[node]}";
        assert written <= set(STATE_FIELDS);
    }
}

test "hazard surface and graph ref round trip" {
    out = outputs();
    surface = out["A2"]["hazard"];
    ref = out["A2"]["pruned_graph"];
    assert dumps(surface_from_json(dumps(surface))) == dumps(surface);
    assert dumps(graph_ref_from_json(dumps(ref))) == dumps(ref);
    assert surface.inundation_geojson["type"] == "FeatureCollection";
    assert all([EDGE_ID.match(e) for e in surface.impassable_edge_ids]);
    assert ref.surface_version == surface.version;
}

test "priority items decompose and round trip" {
    out = outputs();
    queue: list[PriorityItem] = out["A3"]["queue"];
    expected = set(SCORE_COMPONENTS);
    assert [q.rank for q in queue] == list(range(1, len(queue) + 1));
    for item in queue {
        assert set(item.weights) == expected;
        assert dumps(priority_from_json(dumps(item))) == dumps(item);
    }
}

test "dispatch plan round trips and binds to its inputs" {
    out = outputs();
    plan: DispatchPlan = out["A4"]["plan"];
    assert dumps(plan_from_json(dumps(plan))) == dumps(plan);
    assert plan.input_surface_version == out["A2"]["hazard"].version;
    for a in plan.assignments {
        assert all([EDGE_ID.match(e) for e in a.route_edge_ids]);
    }
}

test "outputs compose with the shared reducers" {
    out = outputs();
    old = out["A2"]["hazard"];
    newer = evolve(old, version=old.version + 1);
    assert versioned(newer, old) is newer;  # a late, stale surface never overwrites a fresh one
    plan = out["A4"]["plan"];
    assert versioned(plan, evolve(plan, version=plan.version + 1)).version == plan.version + 1;
    trace = append_only(out["A2"]["trace"], out["A3"]["trace"] + out["A4"]["trace"]);
    assert [e.agent for e in trace] == ["A2", "A3", "A4"];
}
