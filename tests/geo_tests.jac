"""Weather adapters and road graph helpers.

Open-Meteo runs against a mocked transport: parsing, caching, degradation. No test
here touches the network. The failure paths matter more than the happy one —
degraded mode depends on the adapter answering from cache, flagged as such, rather
than raising into A2.

ReplayWeather answers 'the last N hours' from the archive at the replay clock.

Road graph helpers: edge identity, hashing, nearest node, pickle round-trip.
"""

import tempfile;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import httpx;
import from resqmesh.adapters.geo.open_meteo { OpenMeteoWeather, WeatherUnavailableError }
import from resqmesh.adapters.geo.replay_weather { ReplayWeather }
import from resqmesh.adapters.geo.roads {
    edge_id, graph_hash, haversine_m, iter_edge_ids, load_graph, nearest_node, save_graph
}
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }

glob NOW: datetime = datetime(2026, 9, 21, 6, 30, tzinfo=UTC);

def tmp_dir -> Path {
    return Path(tempfile.mkdtemp());
}

def payload(start: datetime, values: list[float | None]) -> dict[str, any] {
    return {
        "hourly": {
            "time": [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M") for i in range(len(values))],
            "precipitation": values
        }
    };
}

def client(handler: any) -> any {
    return httpx.Client(transport=httpx.MockTransport(handler));
}

def fixed_now -> datetime {
    return NOW;
}

def adapter(cache_root: Path, handler: any) -> OpenMeteoWeather {
    return OpenMeteoWeather(
        client=client(handler), cache_root=cache_root, offline=False,
        retries=1, backoff_s=0.0, now=fixed_now
    );
}

# --------------------------------------------------------------------------- #
# Open-Meteo
# --------------------------------------------------------------------------- #

test "open meteo satisfies the weather port" {
    assert isinstance(OpenMeteoWeather(cache_root=tmp_dir()), WeatherPort);
}

test "rainfall splits observed and forecast" {
    # 03,04,05,06 observed; 07,08 forecast
    start = datetime(2026, 9, 21, 3, tzinfo=UTC);
    seen: dict[str, any] = {};

    def handler(req: any) -> any {
        seen.update(dict(req.url.params));
        return httpx.Response(200, json=payload(start, [1.0, 2.0, None, 4.0, 5.0, 6.0]));
    }

    series = adapter(tmp_dir(), handler).rainfall(6.95, 79.98, hours_back=4);
    assert series.observed_mm == [1.0, 2.0, 0.0, 4.0];
    assert series.forecast_mm == [5.0, 6.0];
    assert series.start_time == start;
    assert series.from_cache is False;
    assert seen["past_hours"] == "4" and seen["hourly"] == "precipitation";
}

test "network failure serves last cached reading" {
    root_dir = tmp_dir();
    start = datetime(2026, 9, 21, 5, tzinfo=UTC);

    def ok_handler(req: any) -> any {
        return httpx.Response(200, json=payload(start, [3.0, 7.0]));
    }

    def down(req: any) -> any {
        raise httpx.ConnectError("no route to host");
    }

    adapter(root_dir, ok_handler).rainfall(6.95, 79.98, hours_back=2);
    series = adapter(root_dir, down).rainfall(6.95, 79.98, hours_back=2);
    assert series.from_cache is True;
    assert series.observed_mm == [3.0, 7.0];
}

test "http error with no cache raises typed error" {
    def unavailable(req: any) -> any {
        return httpx.Response(503);
    }

    weather = adapter(tmp_dir(), unavailable);
    with testraises(WeatherUnavailableError) {
        weather.rainfall(6.95, 79.98);
    }
}

test "offline mode never calls the network" {
    calls: list[any] = [];

    def handler(req: any) -> any {
        calls.append(req);
        return httpx.Response(200, json=payload(NOW, [1.0]));
    }

    weather = adapter(tmp_dir(), handler);
    weather.offline = True;
    with testraises(WeatherUnavailableError) {
        weather.rainfall(6.95, 79.98);
    }
    assert calls == [];
}

test "malformed body is not coerced" {
    def bad(req: any) -> any {
        return httpx.Response(200, json={"error": True});
    }

    weather = adapter(tmp_dir(), bad);
    with testraises(WeatherUnavailableError) {
        weather.rainfall(6.95, 79.98);
    }
}

test "circuit breaker opens after repeated failures" {
    calls: list[any] = [];

    def down(req: any) -> any {
        calls.append(req);
        raise httpx.ConnectError("down");
    }

    weather = adapter(tmp_dir(), down);
    weather.retries = 0;
    for _ in range(3) {
        with testraises(WeatherUnavailableError) {
            weather.rainfall(6.95, 79.98);
        }
    }
    assert len(calls) == 3;
    with testraises(WeatherUnavailableError) {
        weather.rainfall(6.95, 79.98);
    }
    # open breaker: network skipped
    assert len(calls) == 3;
}

test "retries back off exponentially through the injected sleep" {
    calls: list[any] = [];
    pauses: list[float] = [];

    def down(req: any) -> any {
        calls.append(req);
        raise httpx.ConnectError("down");
    }

    def record_pause(seconds: float) -> None {
        pauses.append(seconds);
    }

    weather = OpenMeteoWeather(
        client=client(down), cache_root=tmp_dir(), offline=False, now=fixed_now, sleep=record_pause
    );
    with testraises(WeatherUnavailableError) {
        weather.rainfall(6.95, 79.98);
    }
    # 2 retries: three attempts, with 0.5 s then 1.0 s between them
    assert len(calls) == 3;
    assert pauses == [0.5, 1.0];
}

test "historical is windowed and cached permanently" {
    day = datetime(2016, 5, 15, tzinfo=UTC);
    calls: list[any] = [];

    def handler(req: any) -> any {
        calls.append(req);
        return httpx.Response(200, json=payload(day, [float(i) for i in range(48)]));
    }

    weather = adapter(tmp_dir(), handler);
    s = weather.historical(6.95, 79.98, day + timedelta(hours=6), day + timedelta(hours=10));
    assert s.observed_mm == [6.0, 7.0, 8.0, 9.0];
    assert s.start_time == day + timedelta(hours=6);
    assert s.forecast_mm == [];
    again = weather.historical(6.95, 79.98, day + timedelta(hours=6), day + timedelta(hours=10));
    assert again.from_cache is True and len(calls) == 1;
}

test "cache files are named by endpoint, rounded point and window" {
    day = datetime(2016, 5, 15, tzinfo=UTC);
    root_dir = tmp_dir();

    def handler(req: any) -> any {
        return httpx.Response(200, json=payload(day, [1.0]));
    }

    weather = adapter(root_dir, handler);
    weather.historical(6.90123, 80.08467, day, day + timedelta(hours=1));
    weather.rainfall(6.95, 79.98, hours_back=4);
    names = sorted([p.name for p in root_dir.iterdir()]);
    assert names == ["archive_6.901_80.085_2016-05-15_2016-05-15.json", "forecast_6.950_79.980_4.json"];
}

# --------------------------------------------------------------------------- #
# ReplayWeather
# --------------------------------------------------------------------------- #

glob T0: datetime = datetime(2016, 5, 15, tzinfo=UTC);

"""Hour i since T0 rained i mm; every answer claims to come from disk."""
obj Archive(WeatherPort) {
    has calls: list[tuple[datetime, datetime]] = [];

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        raise AssertionError("replay must never ask for live rainfall");
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        self.calls.append((start, end));
        hours = int((end - start).total_seconds() // 3600);
        first = int((start - T0).total_seconds() // 3600);
        return RainfallSeries(
            lat=lat, lon=lon, observed_mm=[float(first + i) for i in range(hours)],
            forecast_mm=[], start_time=start, from_cache=True
        );
    }
}

test "live question is answered from the archive at the clock" {
    archive = Archive();
    clock = T0 + timedelta(hours=10);
    weather = ReplayWeather(archive, clock=lambda -> datetime { return clock; });
    assert isinstance(weather, WeatherPort);
    s = weather.rainfall(6.9, 80.0, hours_back=3);
    assert archive.calls == [(clock - timedelta(hours=3), clock)];
    assert s.observed_mm == [7.0, 8.0, 9.0];
    # no leaking the future
    assert s.forecast_mm == [];
    # history does not go stale
    assert s.from_cache is False;
}

test "historical is capped at the replay clock" {
    archive = Archive();
    clock = T0 + timedelta(hours=5);
    ReplayWeather(archive, clock=lambda -> datetime { return clock; }).historical(6.9, 80.0, T0, T0 + timedelta(days=3));
    assert archive.calls[-1][1] == clock;
}

# --------------------------------------------------------------------------- #
# Road graph helpers
# --------------------------------------------------------------------------- #

test "edge id format is the shared contract" {
    # A5 compares A2's impassable ids with A4's route ids as plain strings.
    assert edge_id(12, 34, 0) == "12-34-0";
    assert edge_id("a", "b") == "a-b-0";
}

test "every edge has a unique id" {
    g = grid_graph(3, 3);
    ids = list(iter_edge_ids(g));
    assert len(ids) == g.number_of_edges();
    assert len(ids) == len(set(ids));
}

test "graph hash is structural not order dependent" {
    a = grid_graph(3, 4);
    b = grid_graph(3, 4);
    assert graph_hash(a) == graph_hash(b);
    b.remove_edge(0, 1, key=0);
    assert graph_hash(a) != graph_hash(b);
}

test "haversine is sane" {
    # ~0.005 deg of latitude is ~553 m
    assert 540 < haversine_m(6.90, 79.9, 6.905, 79.9) < 565;
}

test "nearest node and candidate restriction" {
    g = grid_graph(3, 3, origin=(6.90, 79.90));
    found = nearest_node(g, 6.9001, 79.9001);
    assert found[0] == 0 and found[1] < 20;
    restricted = nearest_node(g, 6.9001, 79.9001, candidates=[4, 8]);
    assert restricted[0] == 4;
    with testraises(ValueError) {
        nearest_node(g, 6.9, 79.9, candidates=[]);
    }
}

test "pickle round trip and cache" {
    g = grid_graph(2, 2);
    p = save_graph(g, tmp_dir() / "g.pkl");
    loaded = load_graph(p);
    assert graph_hash(loaded) == graph_hash(g);
    # same process, unchanged file: served from memory
    assert load_graph(p) is loaded;
}

test "missing graph points at fetch script" {
    with testraises(FileNotFoundError, `match="fetch_data") {
        load_graph(tmp_dir() / "absent.pkl");
    }
}
