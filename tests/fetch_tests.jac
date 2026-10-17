"""Data fetcher: resumable downloads and step skipping.

The downloader runs against `httpx.MockTransport` and the steps against a throwaway
`RESQMESH_DATA_DIR`, so nothing here touches the network or the real `data/`
directory. The failure paths matter most: a re-run must continue a partial file, a
flaky link must be retried, and a finished artefact must never be fetched again.
"""

import io;
import json;
import os;
import tempfile;
import zipfile;
import from datetime { datetime, UTC }
import from pathlib { Path }
import httpx;
import from resqmesh.adapters.geo.fetch {
    ADAM_FLOOD_EVENT, ADAM_FLOOD_URL, DEM_BBOX, GN_COLUMNS, HDX_GDB_URL, RAIN_STATIONS,
    SCENARIO_WINDOWS, SKADI_URL, STEP_NAMES, download, peak_24h, run_step, run_steps,
    step_flood_reference, step_gn, step_rainfall, step_roads, step_srtm, step_waterways,
    tile_names
}
import from resqmesh.adapters.geo.paths {
    dem_path, flood_reference_dir, gn_boundaries_path, raw_dir, road_graph_path, waterways_path
}
import from resqmesh.adapters.geo.roads { save_graph }
import from resqmesh.adapters.geo.synthetic { grid_graph }
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }

glob BODY: bytes = b"0123456789abcdefghij";
glob ENV_KEY: str = "RESQMESH_DATA_DIR";

def tmp_dir -> Path {
    return Path(tempfile.mkdtemp());
}

def client(handler: any) -> any {
    return httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True);
}

"""Point the data directory at `path`; returns what to hand to `restore_data_dir`."""
def use_data_dir(path: Path) -> any {
    prev = os.environ.get(ENV_KEY);
    os.environ[ENV_KEY] = str(path);
    return prev;
}

def restore_data_dir(prev: any) -> None {
    if prev is None {
        os.environ.pop(ENV_KEY, None);
    } else {
        os.environ[ENV_KEY] = prev;
    }
}

def touch(path: Path, text: str = "x") -> None {
    path.parent.mkdir(parents=True, exist_ok=True);
    path.write_text(text, encoding="utf-8");
}

"""A data directory in which every step's artefact is already present."""
def populated_data_dir() -> Path {
    root_dir = tmp_dir();
    prev = use_data_dir(root_dir);
    try {
        touch(dem_path());
        touch(waterways_path());
        touch(gn_boundaries_path());
        touch(flood_reference_dir() / f"{ADAM_FLOOD_EVENT}.tiff");
        save_graph(grid_graph(rows=3, cols=3), road_graph_path());
        for scenario in SCENARIO_WINDOWS {
            for station in RAIN_STATIONS {
                touch(raw_dir() / "rainfall" / f"{scenario}_{station}.json", "{}");
            }
        }
    } finally {
        restore_data_dir(prev);
    }
    return root_dir;
}

"""A weather port serving a fixed series; counts calls, optionally refuses them."""
obj FakeArchive(WeatherPort) {
    has calls: list[tuple[float, float]] = [],
        refuse: bool = False;

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        self.calls.append((lat, lon));
        if self.refuse {
            raise RuntimeError("the archive must not be called");
        }
        hours = int((end - start).total_seconds() // 3600);
        return RainfallSeries(
            lat=lat, lon=lon, observed_mm=[0.5] * hours, forecast_mm=[], start_time=start
        );
    }
}

# --------------------------------------------------------------------------- #
# download: resume and retry
# --------------------------------------------------------------------------- #

test "download writes the body and leaves no part file" {
    seen: list[any] = [];

    def handler(req: any) -> any {
        seen.append(req);
        return httpx.Response(200, content=BODY);
    }

    dest = tmp_dir() / "sub" / "file.bin";
    out = download("https://example.test/file.bin", dest, client=client(handler));
    assert out == dest;
    assert dest.read_bytes() == BODY;
    assert not (dest.parent / "file.bin.part").exists();
    assert len(seen) == 1;
    assert seen[0].headers["user-agent"] == "resqmesh-fetch/0.1";
    assert "range" not in seen[0].headers;
}

test "download of an existing file makes no request" {
    calls: list[any] = [];

    def handler(req: any) -> any {
        calls.append(req);
        return httpx.Response(200, content=b"new");
    }

    dest = tmp_dir() / "file.bin";
    dest.write_bytes(b"old");
    download("https://example.test/file.bin", dest, client=client(handler));
    assert calls == [];
    assert dest.read_bytes() == b"old";
}

test "download resumes a partial file with a range request" {
    seen: list[str | None] = [];

    def handler(req: any) -> any {
        seen.append(req.headers.get("range"));
        return httpx.Response(206, content=BODY[7:]);
    }

    dest = tmp_dir() / "file.bin";
    part = dest.parent / "file.bin.part";
    part.write_bytes(BODY[:7]);
    download("https://example.test/file.bin", dest, client=client(handler));
    assert seen == ["bytes=7-"];
    assert dest.read_bytes() == BODY;
    assert not part.exists();
}

test "download restarts when the server ignores the range" {
    def handler(req: any) -> any {
        return httpx.Response(200, content=BODY);
    }

    dest = tmp_dir() / "file.bin";
    (dest.parent / "file.bin.part").write_bytes(b"stale-bytes");
    download("https://example.test/file.bin", dest, client=client(handler));
    assert dest.read_bytes() == BODY;
}

test "download treats 416 as an already complete part file" {
    def handler(req: any) -> any {
        return httpx.Response(416);
    }

    dest = tmp_dir() / "file.bin";
    (dest.parent / "file.bin.part").write_bytes(BODY);
    download("https://example.test/file.bin", dest, client=client(handler));
    assert dest.read_bytes() == BODY;
    assert not (dest.parent / "file.bin.part").exists();
}

test "download retries with exponential backoff" {
    attempts: list[int] = [];
    pauses: list[float] = [];

    def handler(req: any) -> any {
        attempts.append(1);
        if len(attempts) == 1 {
            raise httpx.ConnectError("no route to host");
        }
        if len(attempts) == 2 {
            return httpx.Response(503);
        }
        return httpx.Response(200, content=BODY);
    }

    def sleeper(seconds: float) -> None {
        pauses.append(seconds);
    }

    dest = tmp_dir() / "file.bin";
    download("https://example.test/file.bin", dest, client=client(handler), sleep=sleeper);
    assert len(attempts) == 3;
    assert pauses == [1, 2];
    assert dest.read_bytes() == BODY;
}

test "download gives up after the retry budget" {
    attempts: list[int] = [];
    pauses: list[float] = [];

    def handler(req: any) -> any {
        attempts.append(1);
        return httpx.Response(500);
    }

    def sleeper(seconds: float) -> None {
        pauses.append(seconds);
    }

    dest = tmp_dir() / "file.bin";
    with testraises(RuntimeError, `match="could not download") {
        download("https://example.test/file.bin", dest, retries=3, client=client(handler), sleep=sleeper);
    }
    assert len(attempts) == 3;
    assert pauses == [1, 2, 4];
    assert not dest.exists();
}

"""A body cut off after one full download chunk (1 MiB), as a dropped connection would."""
class TornStream(httpx.SyncByteStream) {
    def __iter__(self: TornStream) -> any {
        yield b"x" * (1 << 20);
        raise httpx.ReadError("connection reset");
    }
}

"""First request is torn mid body; later ones honour the Range header."""
class TearingTransport(httpx.BaseTransport) {
    def init(self: TearingTransport) {
        super.init();
        self.ranges: list[str | None] = [];
    }

    def handle_request(self: TearingTransport, request: httpx.Request) -> httpx.Response {
        self.ranges.append(request.headers.get("range"));
        if len(self.ranges) == 1 {
            return httpx.Response(200, stream=TornStream());
        }
        return httpx.Response(206, content=b"tail");
    }
}

test "download continues after a connection drops mid body" {
    transport = TearingTransport();
    pauses: list[float] = [];

    def sleeper(seconds: float) -> None {
        pauses.append(seconds);
    }

    dest = tmp_dir() / "file.bin";
    http = httpx.Client(transport=transport);
    download("https://example.test/file.bin", dest, client=http, sleep=sleeper);
    assert transport.ranges == [None, f"bytes={1 << 20}-"];
    assert pauses == [1];
    assert dest.read_bytes() == b"x" * (1 << 20) + b"tail";
    assert not (dest.parent / "file.bin.part").exists();
}

# --------------------------------------------------------------------------- #
# constants
# --------------------------------------------------------------------------- #

test "tile names cover the dem bbox" {
    assert tile_names(DEM_BBOX) == [
        ("N06", "N06E079"), ("N06", "N06E080"), ("N07", "N07E079"), ("N07", "N07E080")
    ];
    assert tile_names((-1.5, -0.5, 0.5, 0.5)) == [
        ("S01", "S01W002"), ("S01", "S01W001"), ("S01", "S01E000"),
        ("N00", "N00W002"), ("N00", "N00W001"), ("N00", "N00E000")
    ];
    assert SKADI_URL.format(ns="N06", name="N06E079") == (
        "https://s3.amazonaws.com/elevation-tiles-prod/skadi/N06/N06E079.hgt.gz"
    );
}

test "source urls and stations are the published ones" {
    assert HDX_GDB_URL.endswith("/download/lka_admin_boundaries.gdb.zip");
    assert ADAM_FLOOD_URL.endswith("/download/lka_wfpadam_flood_20251201.zip");
    assert list(RAIN_STATIONS.keys()) == ["nagalagam_street", "hanwella", "glencourse", "kitulgala"];
    assert list(SCENARIO_WINDOWS.keys()) == ["A_2016", "B_2017"];
    assert SCENARIO_WINDOWS["A_2016"][0] == datetime(2016, 5, 12, tzinfo=UTC);
    assert SCENARIO_WINDOWS["B_2017"][1] == datetime(2017, 6, 3, tzinfo=UTC);
    assert GN_COLUMNS["adm4_pcode"] == "gn_id" and GN_COLUMNS["adm2_name"] == "district";
    assert STEP_NAMES == ["srtm", "roads", "waterways", "gn", "rainfall", "flood_reference"];
}

test "peak 24h is the largest rolling day" {
    assert peak_24h([]) == 0.0;
    assert peak_24h([1.0] * 10) == 10.0;
    assert peak_24h([0.0] * 5 + [2.0] * 24 + [0.0] * 5) == 48.0;
}

# --------------------------------------------------------------------------- #
# steps skip finished artefacts
# --------------------------------------------------------------------------- #

test "every step skips when its artefact is present" {
    root_dir = populated_data_dir();
    prev = use_data_dir(root_dir);
    try {
        archive = FakeArchive(refuse=True);
        assert step_srtm(False) is False;
        assert step_roads(False) is False;
        assert step_waterways(False) is False;
        assert step_gn(False) is False;
        assert step_rainfall(False, weather=archive) is False;
        assert step_flood_reference(False) is False;
        assert archive.calls == [];
        # nothing was rewritten
        assert dem_path().read_text(encoding="utf-8") == "x";
        assert not any([p.name.endswith(".part") for p in root_dir.rglob("*")]);
    } finally {
        restore_data_dir(prev);
    }
}

test "a full run on a populated data dir reports no failures" {
    root_dir = populated_data_dir();
    prev = use_data_dir(root_dir);
    try {
        assert run_steps([], False) == [];
        assert run_steps(["roads", "rainfall"], False) == [];
        assert run_steps(["srtm"], False) == [];
    } finally {
        restore_data_dir(prev);
    }
}

test "run step rejects an unknown name" {
    with testraises(KeyError) {
        run_step("bogus", False);
    }
}

test "a failed step does not stop the others" {
    root_dir = populated_data_dir();
    prev = use_data_dir(root_dir);
    try {
        # a corrupt road graph makes `roads` fail while its neighbours still run
        road_graph_path().write_bytes(b"not a pickle");
        failed = run_steps(["srtm", "roads", "gn", "flood_reference"], False);
        assert failed == ["roads"];
    } finally {
        restore_data_dir(prev);
    }
}

# --------------------------------------------------------------------------- #
# rainfall step
# --------------------------------------------------------------------------- #

test "rainfall step writes one record per scenario and station" {
    root_dir = tmp_dir();
    prev = use_data_dir(root_dir);
    try {
        archive = FakeArchive();
        assert step_rainfall(False, weather=archive) is True;
        assert len(archive.calls) == 8;
        assert archive.calls[0] == (6.9580, 79.8780);
        files = sorted([p.name for p in (root_dir / "raw" / "rainfall").iterdir()]);
        assert files == sorted([
            f"{s}_{st}.json" for s in ["A_2016", "B_2017"]
            for st in ["nagalagam_street", "hanwella", "glencourse", "kitulgala"]
        ]);
        record = json.loads((root_dir / "raw" / "rainfall" / "A_2016_hanwella.json").read_text(encoding="utf-8"));
        assert record["scenario"] == "A_2016" and record["station"] == "hanwella";
        assert record["lat"] == 6.9010 and record["lon"] == 80.0850;
        assert len(record["observed_mm"]) == 12 * 24;
        assert record["forecast_mm"] == [];
        assert record["start_time"] == "2016-05-12T00:00:00Z";
        assert record["step_hours"] == 1 and record["from_cache"] is False;
        assert record["source"].startswith("Open-Meteo archive");
        assert "schema_version" in record;
    } finally {
        restore_data_dir(prev);
    }
}

test "rainfall step only fetches what is missing unless forced" {
    root_dir = tmp_dir();
    prev = use_data_dir(root_dir);
    try {
        step_rainfall(False, weather=FakeArchive());
        (root_dir / "raw" / "rainfall" / "B_2017_kitulgala.json").unlink();
        archive = FakeArchive();
        assert step_rainfall(False, weather=archive) is True;
        assert archive.calls == [(6.9910, 80.4180)];
        forced = FakeArchive();
        assert step_rainfall(True, weather=forced) is True;
        assert len(forced.calls) == 8;
    } finally {
        restore_data_dir(prev);
    }
}

# --------------------------------------------------------------------------- #
# flood reference step (served from an in-memory archive)
# --------------------------------------------------------------------------- #

def adam_zip -> bytes {
    buf = io.BytesIO();
    with zipfile.ZipFile(buf, "w") as zf {
        zf.writestr(f"{ADAM_FLOOD_EVENT}.tiff", b"raster-bytes");
        zf.writestr(f"nested/{ADAM_FLOOD_EVENT}.json", '{"event": 1}');
        zf.writestr("metadata.txt", "meta");
        zf.writestr("readme.pdf", "unrelated");
    }
    return buf.getvalue();
}

test "flood reference step downloads and extracts the event files" {
    root_dir = tmp_dir();
    prev = use_data_dir(root_dir);
    try {
        urls: list[str] = [];

        def handler(req: any) -> any {
            urls.append(str(req.url));
            return httpx.Response(200, content=adam_zip());
        }

        assert step_flood_reference(False, client=client(handler)) is True;
        out_dir = root_dir / "raw" / "flood_reference";
        assert urls == [ADAM_FLOOD_URL];
        assert (out_dir / f"{ADAM_FLOOD_EVENT}.tiff").read_bytes() == b"raster-bytes";
        assert (out_dir / f"{ADAM_FLOOD_EVENT}.json").read_text(encoding="utf-8") == '{"event": 1}';
        assert (out_dir / "metadata.txt").read_text(encoding="utf-8") == "meta";
        assert not (out_dir / "readme.pdf").exists();
        # a second run finds the raster and does not download again
        assert step_flood_reference(False, client=client(handler)) is False;
        assert len(urls) == 1;
    } finally {
        restore_data_dir(prev);
    }
}
