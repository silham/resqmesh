"""Worlds an incident can run in: every agent wired over one shared picture.

The synthetic world needs no download and no API key, so the full seven-agent loop
can be demonstrated and tested on any laptop, offline, in seconds. It is synthetic and
says so: Kelani division names are placed on the nodes of a 6x8 synthetic road grid
(about 3 x 4 km) with a river across its western half. The geography is compressed,
so A1's clustering radius is scaled down to match. Evaluation numbers come only from
the replay harness over labelled scenarios, never from this world.

The real world is the Kelani basin: 757 GN divisions, the OSM road network and SRTM
terrain. Only the data underneath changes; the agents and contracts are identical.
"""

import from datetime { datetime, timedelta }
import from pathlib { Path }
import from resqmesh.adapters.fakes { FakeGazetteer, FakeWeather, StubLLM }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.agents.comms.agent { CommsAgent }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.hazard.agent { HazardAgent, HazardConfig }
import from resqmesh.agents.ingest.agent { IngestAgent }
import from resqmesh.agents.ingest.fusion { FusionConfig }
import from resqmesh.agents.optimiser.agent { OptimiserAgent, OptimiserConfig }
import from resqmesh.agents.triage.agent { TriageAgent }
import from resqmesh.contracts.enums { SourceChannel }
import from resqmesh.contracts.models { RawSignal, Shelter, Vehicle }
import from resqmesh.graph.loop { AgentSet }

glob ORIGIN: tuple[float, float] = (6.90, 79.90);
glob STEP: float = 0.005;

def grid_node(row: int, col: int) -> tuple[float, float] {
    return (ORIGIN[0] + row * STEP, ORIGIN[1] + col * STEP);
}

def place(gid: str, name: str, row: int, col: int) -> tuple[str, tuple[str, float, float]] {
    (lat, lon) = grid_node(row, col);
    return (gid, (name, lat, lon));
}

"""GN id -> (name, lat, lon), each on a grid node."""
glob DIVISIONS: dict[str, tuple[str, float, float]] = dict([
    place("KLN-001", "Biyagama", 0, 1),
    place("KLN-002", "Kaduwela", 1, 6),
    place("KLN-003", "Kolonnawa", 2, 1),    # riverside: inside the inundation
    place("KLN-004", "Hanwella", 4, 6),
    place("KLN-005", "Avissawella", 5, 7),
    place("KLN-006", "Kelaniya", 0, 4),
    place("KLN-007", "Malabe", 3, 4),
    place("KLN-008", "Pahathgama", 4, 1),
    place("KLN-009", "Sedawatta", 1, 2),    # riverside
    place("KLN-010", "Wellampitiya", 5, 3)
]);

"""East-west river between grid rows 1 and 2, western half."""
glob RIVER: dict[str, any] = {
    "type": "FeatureCollection",
    "features": [{
        "type": "Feature",
        "geometry": {"type": "LineString", "coordinates": [[79.895, 6.9075], [79.9175, 6.9075]]},
        "properties": {"waterway": "river"}
    }]
};

def fleet() -> list[Vehicle] {
    specs = [
        ("BOAT-01", "boat", 12, "KLN-006"),
        ("BOAT-02", "boat", 8, "KLN-007"),
        ("AMB-01", "ambulance", 4, "KLN-002"),
        ("TRK-01", "truck", 12, "KLN-004"),
        ("TRK-02", "truck", 10, "KLN-010")
    ];
    return [
        Vehicle(vehicle_id=v, kind=k, capacity=cap, depot_gn_id=gn, depot_lat=DIVISIONS[gn][1], depot_lon=DIVISIONS[gn][2])
        for (v, k, cap, gn) in specs
    ];
}

"""Relief centres an evacuation order can name. A real deployment loads these from the
district's own register. With none at all `evacuate_area` cannot be composed: an order
that cannot say where to go is not an order."""
def default_shelters() -> list[Shelter] {
    specs = [
        ("SH-01", "Kolonnawa Maha Vidyalaya", "KLN-003", 6.9340, 79.8880, 400),
        ("SH-02", "Kaduwela Community Hall", "KLN-002", 6.9350, 79.9820, 250),
        ("SH-03", "Biyagama Temple Grounds", "KLN-001", 6.9450, 79.9900, 300)
    ];
    return [
        Shelter(shelter_id=sid, name=name, gn_id=gn, lat=lat, lon=lon, capacity=cap)
        for (sid, name, gn, lat, lon, cap) in specs
    ];
}

"""Everything an incident needs: the agents, the fleet, shelters and the gazetteer.
`divisions` maps GN id -> (name, lat, lon) for the console and the SITREP."""
obj World {
    has agents: AgentSet,
        vehicles: list[Vehicle],
        gazetteer: any,
        divisions: dict[str, tuple[str, float, float]],
        shelters: list[Shelter] = [];

    def postinit {
        if not self.shelters {
            self.shelters = default_shelters();
        }
    }
}

"""The SITREP PDF, falling back to plain text when the PDF renderer is unavailable."""
def sitrep_renderer() -> any {
    import from resqmesh.agents.comms.sitrep { PlainTextRenderer, ReportLabRenderer }
    try {
        import reportlab;
    } except ImportError {
        return PlainTextRenderer();
    }
    return ReportLabRenderer();
}

"""Every specialist over one shared synthetic world. `out_dir` receives A2's pruned
graphs and A6's SITREPs; `llm` defaults to the offline stub."""
def synthetic_world(out_dir: Path, rain_peak_mm: float = 8.0, llm: any = None) -> World {
    roads = grid_graph();
    gazetteer = FakeGazetteer(divisions=DIVISIONS);
    guardrail = GuardrailAgent(gazetteer=gazetteer);
    centroids = {gid: (lat, lon) for (gid, (_, lat, lon)) in DIVISIONS.items()};

    def roads_loader() -> any {
        return roads;
    }

    def river_loader() -> any {
        return RIVER;
    }

    def no_dem() -> any {
        return None;
    }

    agents = AgentSet(
        ingest=IngestAgent(llm=llm or StubLLM(), gazetteer=gazetteer, config=FusionConfig(eps_km=0.3)),
        hazard=HazardAgent(
            weather=FakeWeather(peak_mm=rain_peak_mm),
            graph_loader=roads_loader,
            waterways_loader=river_loader,
            dem_loader=no_dem,
            inundation_model=None,
            gn_centroids=centroids,
            config=HazardConfig(prefer_hand=False),
            out_dir=out_dir
        ),
        triage=TriageAgent(),
        optimiser=OptimiserAgent(base_graph_loader=roads_loader, config=OptimiserConfig(time_budget_s=5.0)),
        guardrail=guardrail,
        # A6 runs inside the release step, after an approval: SITREP + alerts.
        comms=CommsAgent(
            guardrail=guardrail, out_dir=out_dir / "sitreps", renderer=sitrep_renderer(),
            division_names={gid: name for (gid, (name, _, _)) in DIVISIONS.items()}
        )
    );
    return World(agents=agents, vehicles=fleet(), gazetteer=gazetteer, divisions=DIVISIONS);
}

def signal(n: int, body: str, source: str, at: datetime, channel: SourceChannel = SourceChannel.TELEGRAM) -> RawSignal {
    return RawSignal(signal_id=f"S{n:03d}", channel=channel, source_id=source, body=body, received_at=at);
}

"""The first wave. Each message exercises a behaviour the system promises:
Kolonnawa is reported by three different people (corroboration); Biyagama's culvert is
reported three times by the same person (one cluster, one vote: repetition is not
corroboration); Malabe is contested; "near the old temple" names no real division and
is held, never guessed."""
def opening_signals(t0: datetime) -> list[RawSignal] {
    def m(minutes: int) -> datetime {
        return t0 + timedelta(minutes=minutes);
    }
    return [
        signal(1, "Flooding in Kolonnawa, 12 people trapped, elderly couple on the roof. Urgent!", "src:a1", m(0)),
        signal(2, "Water rising fast at Kolonnawa, children stranded", "src:b2", m(4)),
        signal(3, "Kolonnawa families stranded, water above knee level", "src:c3", m(9)),
        signal(4, "Culvert collapsed near Biyagama, road blocked", "src:d4", m(2)),
        signal(5, "Biyagama culvert gone, road impassable", "src:d4", m(6)),
        signal(6, "Still blocked at Biyagama culvert", "src:d4", m(11)),
        signal(7, "Flooding at Malabe junction, 5 people need help", "src:e5", m(5)),
        signal(8, "Malabe water has receded, all clear", "src:f6", m(12)),
        signal(9, "Patient needs dialysis at Hanwella, 3 people cannot leave. Critical", "src:g7", m(7)),
        signal(10, "Hanwella dialysis patient confirmed, urgent medical help", "src:h8", m(10)),
        signal(11, "Water entering houses near the old temple", "src:i9", m(8))
    ];
}

"""A second wave after the first plan is approved: forces a re-plan mid-incident."""
def follow_up_signals(t0: datetime) -> list[RawSignal] {
    return [
        signal(12, "Flooding in Pahathgama, 8 people trapped, wheelchair user", "src:j10", t0),
        signal(13, "Pahathgama flood, urgent, family with baby trapped", "src:k11", t0 + timedelta(minutes=3))
    ];
}

# ------------------------------------------------------------ the real Kelani basin

"""Depots for the demonstration fleet, named as real divisions. Deliberately not in the
divisions the demo reports come from: parking a vehicle on top of its own incident gives
a zero-length assignment and a response time that flatters itself."""
glob REAL_FLEET: list[tuple[str, str, int, str]] = [
    ("BOAT-01", "boat", 12, "Kelaniya"),
    ("BOAT-02", "boat", 8, "Mulleriyawa"),
    ("AMB-01", "ambulance", 4, "Kaduwela"),
    ("TRK-01", "truck", 12, "Athurugiriya"),
    ("TRK-02", "truck", 10, "Avissawella")
];

"""Place the demonstration fleet at real division centroids."""
def real_fleet(gazetteer: any) -> list[Vehicle] {
    out: list[Vehicle] = [];
    for (vid, kind, capacity, depot) in REAL_FLEET {
        hit = gazetteer.resolve(depot);
        if not hit.matched or hit.lat is None or hit.lon is None {
            raise LookupError(f"depot {depot!r} is not in the register; re-run the data fetcher for gn");
        }
        out.append(Vehicle(vehicle_id=vid, kind=kind, capacity=capacity, depot_gn_id=hit.gn_id, depot_lat=hit.lat, depot_lon=hit.lon));
    }
    return out;
}

"""The real basin. Needs the fetched data. `clock` replays the rainfall archive at a past
moment (the May 2016 peak, say); without it the weather adapter fetches the forecast."""
def real_world(out_dir: Path, clock: any = None, llm: any = None, solve_budget_s: float = 10.0) -> World {
    import from resqmesh.adapters.gazetteer.gn { load_gazetteer }
    import from resqmesh.adapters.geo.open_meteo { OpenMeteoWeather }
    import from resqmesh.adapters.geo.replay_weather { ReplayWeather }

    gazetteer = load_gazetteer();
    divisions = {gid: (d.name_en, d.lat, d.lon) for (gid, d) in gazetteer.divisions.items()};
    centroids = {gid: (lat, lon) for (gid, (_, lat, lon)) in divisions.items()};
    weather: any = OpenMeteoWeather();
    if clock is not None {
        weather = ReplayWeather(archive=weather, clock=clock);
    }
    guardrail = GuardrailAgent(gazetteer=gazetteer);
    agents = AgentSet(
        # Real divisions are kilometres apart, so the default clustering radius applies.
        ingest=IngestAgent(llm=llm or StubLLM(), gazetteer=gazetteer, config=FusionConfig()),
        hazard=HazardAgent(weather=weather, gn_centroids=centroids, config=HazardConfig(prefer_hand=True), out_dir=out_dir),
        triage=TriageAgent(),
        optimiser=OptimiserAgent(config=OptimiserConfig(time_budget_s=solve_budget_s)),
        guardrail=guardrail,
        comms=CommsAgent(
            guardrail=guardrail, out_dir=out_dir / "sitreps", renderer=sitrep_renderer(),
            division_names={gid: name for (gid, (name, _, _)) in divisions.items()}
        )
    );
    return World(agents=agents, vehicles=real_fleet(gazetteer), gazetteer=gazetteer, divisions=divisions);
}
