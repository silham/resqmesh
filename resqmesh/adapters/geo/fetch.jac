"""Download and derive every geospatial input ResQ-Mesh needs, once.

Idempotent and resumable: each step checks for its finished artefact and skips if
present, downloads go to `*.part` and are renamed only when complete. Nothing is
committed: `data/raw` and `data/cache` are gitignored (roadmap section 9.2).
`scripts/fetch_data.jac` is the command-line front end; the helpers live here so
tests can drive them without touching the network.

Steps
-----
`srtm`             SRTM 1 arc-second tiles (AWS Terrain Tiles "skadi", public, no key),
                   mosaicked and clipped to the basin -> data/raw/dem_kelani.tif
`roads`            OSM drivable network via OSMnx -> data/cache/roads_kelani.pkl
`waterways`        OSM river/stream/canal lines -> data/raw/waterways_kelani.geojson
`gn`               HDX Sri Lanka admin-4 (Grama Niladhari) boundaries clipped to the
                   basin -> data/raw/gn_divisions_kelani.geojson
`rainfall`         Open-Meteo archive hourly series for the Scenario A (May 2016) and
                   Scenario B (May 2017) windows at basin gauge points
                   -> data/raw/rainfall/<scenario>_<station>.json (for the replay harness)
`flood_reference`  WFP ADAM flood extent used as an external accuracy reference
                   -> data/raw/flood_reference/

Every step returns True when it did work and False when it found its artefact
already present, so callers (and tests) can tell a skip from a build.
"""

import gzip;
import json;
import math;
import shutil;
import time;
import tracemalloc;
import zipfile;
import from datetime { datetime, UTC }
import from pathlib { Path }
import httpx;
import from resqmesh.adapters.geo.hydro { fetch_waterways, save_waterways }
import from resqmesh.adapters.geo.open_meteo { OpenMeteoWeather }
import from resqmesh.adapters.geo.paths {
    KELANI_BBOX, dem_path, ensure_dir, flood_reference_dir, gn_boundaries_path,
    raw_dir, road_graph_path, waterways_path
}
import from resqmesh.adapters.geo.roads { build_graph, graph_hash, load_graph, save_graph }
import from resqmesh.contracts.models { to_json }

"""The DEM extends further upstream (east) than the road bbox so that flow
accumulation along the main Kelani channel is not truncated at the clip edge."""
glob DEM_BBOX: tuple[float, float, float, float] = (79.84, 6.80, 80.45, 7.10);

glob SKADI_URL: str = "https://s3.amazonaws.com/elevation-tiles-prod/skadi/{ns}/{name}.hgt.gz";
glob HDX_GDB_URL: str = (
    "https://data.humdata.org/dataset/0bedcaf3-88cd-4591-b9d5-5d3220e26abf/resource/"
    "3bc0e89f-92c9-42f7-86f6-062949cbf8f1/download/lka_admin_boundaries.gdb.zip"
);

"""Basin gauge points for the replay rainfall. Named after the Irrigation
Department stations they sit nearest to. Order matters: it is the fetch order."""
glob RAIN_STATIONS: dict[str, tuple[float, float]] = {
    "nagalagam_street": (6.9580, 79.8780),  # river mouth, Colombo
    "hanwella": (6.9010, 80.0850),  # lower basin, the 2016 flood reference gauge
    "glencourse": (6.9760, 80.1860),  # middle basin
    "kitulgala": (6.9910, 80.4180)  # upper catchment
};

"""Replay windows (UTC, end exclusive). A = May 2016 Kelani flood,
B = May 2017 south-west monsoon event."""
glob SCENARIO_WINDOWS: dict[str, tuple[datetime, datetime]] = {
    "A_2016": (datetime(2016, 5, 12, tzinfo=UTC), datetime(2016, 5, 24, tzinfo=UTC)),
    "B_2017": (datetime(2017, 5, 22, tzinfo=UTC), datetime(2017, 6, 3, tzinfo=UTC))
};

glob RAINFALL_SOURCE: str = "Open-Meteo archive (ERA5-based reanalysis), hourly precipitation mm";

"""WFP ADAM rapid impact analysis for the Cyclone Ditwah floods, 1 December 2025:
a NOAA VIIRS 5-day flood composite at 375 m, CC BY-SA on HDX. Used as the
external reference for hazard footprint accuracy."""
glob ADAM_FLOOD_EVENT: str = "FL-20251201-LKA-00";
glob ADAM_FLOOD_URL: str = (
    "https://data.humdata.org/dataset/4cbd98e4-b0a0-47bd-8a49-1ab212a3c6db/resource/"
    "0aed4102-2da1-4814-8075-195a41a23154/download/lka_wfpadam_flood_20251201.zip"
);

"""Step names in the order a full run executes them."""
glob STEP_NAMES: list[str] = ["srtm", "roads", "waterways", "gn", "rainfall", "flood_reference"];

def log(msg: str) {
    print(f"[fetch_data] {msg}", flush=True);
}

"""Stream `url` to `dest` via `dest.part`, resuming a partial download.

A leftover `.part` is continued with an HTTP `Range` request; a 416 means the part
file already holds the whole body. A server that ignores the range (plain 200)
restarts the file from zero. Network and HTTP-status errors are retried `retries`
times with exponential backoff (1 s, 2 s, 4 s, ...); after the last failure the
`.part` file is kept for the next run and `RuntimeError` is raised.

`client` is any `httpx.Client` (tests inject a `MockTransport` client); `sleep`
replaces `time.sleep` between attempts.
"""
def download(url: str, dest: Path, retries: int = 3, client: any = None, sleep: any = None) -> Path {
    if dest.exists() {
        return dest;
    }
    ensure_dir(dest.parent);
    part = dest.with_name(dest.name + ".part");
    http: any = client if client is not None else httpx.Client(follow_redirects=True, timeout=60.0);
    pause: any = sleep if sleep is not None else time.sleep;
    finished = False;
    try {
        for attempt in range(retries) {
            headers: dict[str, str] = {"User-Agent": "resqmesh-fetch/0.1"};
            have = part.stat().st_size if part.exists() else 0;
            if have {
                headers["Range"] = f"bytes={have}-";
            }
            try {
                with http.stream("GET", url, headers=headers) as resp {
                    if resp.status_code == 416 {  # already complete
                        finished = True;
                        break;
                    }
                    resp.raise_for_status();
                    mode = "ab" if have and resp.status_code == 206 else "wb";
                    with part.open(mode) as fh {
                        for chunk in resp.iter_bytes(1 << 20) {
                            fh.write(chunk);
                        }
                    }
                }
                finished = True;
                break;
            } except httpx.HTTPError as exc {
                log(f"  download failed ({exc}); retry {attempt + 1}/{retries}");
                pause(2 ** attempt);
            }
        }
    } finally {
        if client is None {
            http.close();
        }
    }
    if not finished {
        raise RuntimeError(f"could not download {url}");
    }
    part.replace(dest);
    return dest;
}

# --------------------------------------------------------------------------- #
# Steps
# --------------------------------------------------------------------------- #

"""SKADI tile (folder, name) pairs covering bbox (west, south, east, north)."""
def tile_names(bbox: tuple[float, float, float, float]) -> list[tuple[str, str]] {
    west = bbox[0];
    south = bbox[1];
    east = bbox[2];
    north = bbox[3];
    names: list[tuple[str, str]] = [];
    for lat in range(math.floor(south), math.floor(north) + 1) {
        for lon in range(math.floor(west), math.floor(east) + 1) {
            ns = f"{'N' if lat >= 0 else 'S'}{abs(lat):02d}";
            ew = f"{'E' if lon >= 0 else 'W'}{abs(lon):03d}";
            names.append((ns, f"{ns}{ew}"));
        }
    }
    return names;
}

def step_srtm(force: bool, client: any = None) -> bool {
    out = dem_path();
    if out.exists() and not force {
        log(f"srtm: {out} present, skipping");
        return False;
    }
    import rasterio;
    import from rasterio.merge { merge }

    tiles_dir = ensure_dir(raw_dir() / "srtm");
    hgts: list[Path] = [];
    for (ns, name) in tile_names(DEM_BBOX) {
        hgt = tiles_dir / f"{name}.hgt";
        if not hgt.exists() {
            gz = download(SKADI_URL.format(ns=ns, name=name), tiles_dir / f"{name}.hgt.gz", client=client);
            with gzip.open(gz, "rb") as src {
                with hgt.open("wb") as dst {
                    shutil.copyfileobj(src, dst);
                }
            }
            gz.unlink();
        }
        hgts.append(hgt);
        log(f"srtm: tile {name} ready");
    }

    sources: list[any] = [rasterio.open(p) for p in hgts];
    mosaic: any = None;
    transform: any = None;
    profile: any = None;
    try {
        merged: any = merge(sources, bounds=DEM_BBOX);
        mosaic = merged[0];
        transform = merged[1];
        profile = sources[0].profile.copy();
    } finally {
        for s in sources {
            s.close();
        }
    }
    profile.update(
        driver="GTiff", height=mosaic.shape[1], width=mosaic.shape[2],
        transform=transform, count=1, compress="deflate", nodata=-32768
    );
    ensure_dir(out.parent);
    tmp = out.with_name(out.name + ".part");
    with rasterio.open(tmp, "w", **profile) as dst {
        dst.write(mosaic[0], 1);
    }
    tmp.replace(out);
    log(f"srtm: wrote {out} ({mosaic.shape[2]}x{mosaic.shape[1]} cells)");
    return True;
}

def step_roads(force: bool) -> bool {
    out = road_graph_path();
    built = False;
    if out.exists() and not force {
        log(f"roads: {out} present, skipping build");
    } else {
        log("roads: downloading OSM drive network via OSMnx (a few minutes)...");
        tracemalloc.start();
        g: any = build_graph(KELANI_BBOX);
        traced: any = tracemalloc.get_traced_memory();
        peak: float = traced[1];
        tracemalloc.stop();
        save_graph(g, out);
        log(
            f"roads: built {g.number_of_nodes()} nodes / {g.number_of_edges()} edges, "
            f"peak python heap {peak / 1e9:.2f} GB"
        );
        built = True;
    }
    t = time.perf_counter();
    g2: any = load_graph(out);
    log(f"roads: pickle loads in {time.perf_counter() - t:.2f}s, hash {graph_hash(g2)[:12]}");
    return built;
}

def step_waterways(force: bool) -> bool {
    out = waterways_path();
    if out.exists() and not force {
        log(f"waterways: {out} present, skipping");
        return False;
    }
    collection = fetch_waterways(KELANI_BBOX);
    save_waterways(collection, out);
    log(f"waterways: {len(collection.get('features', []))} lines -> {out}");
    return True;
}

"""Source column -> published column for the GN divisions layer."""
glob GN_COLUMNS: dict[str, str] = {
    "adm4_pcode": "gn_id",
    "adm4_name": "name_en",
    "adm4_name1": "name_si",
    "adm4_name2": "name_ta",
    "adm3_name": "ds_division",
    "adm2_name": "district",
    "center_lat": "center_lat",
    "center_lon": "center_lon",
    "area_sqkm": "area_sqkm"
};

def step_gn(force: bool, client: any = None) -> bool {
    out = gn_boundaries_path();
    if out.exists() and not force {
        log(f"gn: {out} present, skipping");
        return False;
    }
    import geopandas as gpd;

    archive = download(HDX_GDB_URL, raw_dir() / "lka_admin_boundaries.gdb.zip", client=client);
    gdb = "";
    with zipfile.ZipFile(archive) as zf {
        for n in zf.namelist() {
            if n.rstrip("/").endswith(".gdb") {
                gdb = n.rstrip("/");
                break;
            }
        }
    }
    if not gdb {
        raise RuntimeError(f"no .gdb found in {archive}");
    }
    gdf: any = gpd.read_file(f"zip://{archive.as_posix()}!{gdb}", layer="lka_admin4", bbox=KELANI_BBOX);
    columns: list[str] = list(GN_COLUMNS.keys()) + ["geometry"];
    gdf = gdf[columns].rename(columns=GN_COLUMNS).to_crs("EPSG:4326");
    ensure_dir(out.parent);
    tmp = out.with_name(out.name + ".part");
    tmp.write_text(gdf.to_json(), encoding="utf-8");
    tmp.replace(out);
    log(f"gn: {len(gdf)} GN divisions -> {out}");
    return True;
}

"""Fetch a published flood extent to score our own hazard footprint against.

Small (45 KB) and it is the only ground truth in the repository that we did not
write ourselves, which is exactly why it is worth having.
"""
def step_flood_reference(force: bool, client: any = None) -> bool {
    out_dir = ensure_dir(flood_reference_dir());
    raster = out_dir / f"{ADAM_FLOOD_EVENT}.tiff";
    if raster.exists() and not force {
        log(f"flood reference: {raster} present, skipping");
        return False;
    }
    archive = download(ADAM_FLOOD_URL, out_dir / "lka_wfpadam_flood_20251201.zip", client=client);
    with zipfile.ZipFile(archive) as zf {
        for name in zf.namelist() {
            base = Path(name).name;
            if base.startswith(ADAM_FLOOD_EVENT) or base == "metadata.txt" {
                target = out_dir / base;
                target.write_bytes(zf.read(name));
            }
        }
    }
    log(f"flood reference: WFP ADAM {ADAM_FLOOD_EVENT} (NOAA VIIRS, 375 m) -> {raster}");
    return True;
}

"""Largest rolling 24 h total of an hourly series."""
def peak_24h(observed_mm: list[float]) -> float {
    best = 0.0;
    for i in range(max(1, len(observed_mm) - 23)) {
        best = max(best, sum(observed_mm[i:i + 24]));
    }
    return best;
}

"""One JSON file per scenario and station; `weather` is any `WeatherPort` (the live
Open-Meteo archive by default)."""
def step_rainfall(force: bool, weather: any = None) -> bool {
    out_dir = ensure_dir(raw_dir() / "rainfall");
    source: any = weather if weather is not None else OpenMeteoWeather(offline=False);
    wrote = False;
    for (scenario, window) in SCENARIO_WINDOWS.items() {
        for (station, point) in RAIN_STATIONS.items() {
            out = out_dir / f"{scenario}_{station}.json";
            if out.exists() and not force {
                continue;
            }
            series: any = source.historical(point[0], point[1], window[0], window[1]);
            record: dict[str, any] = {"scenario": scenario, "station": station};
            body: dict[str, any] = to_json(series);
            for (k, v) in body.items() {
                record[k] = v;
            }
            record["source"] = RAINFALL_SOURCE;
            out.write_text(json.dumps(record, indent=1), encoding="utf-8");
            log(f"rainfall: {scenario}/{station}: {len(series.observed_mm)} h, peak 24h {peak_24h(series.observed_mm):.0f} mm");
            wrote = True;
        }
    }
    if not wrote {
        log(f"rainfall: all {len(SCENARIO_WINDOWS) * len(RAIN_STATIONS)} series present, skipping");
    }
    return wrote;
}

"""Run one named step. Raises `KeyError` for a name that is not a step."""
def run_step(name: str, force: bool) -> bool {
    if name == "srtm" {
        return step_srtm(force);
    }
    if name == "roads" {
        return step_roads(force);
    }
    if name == "waterways" {
        return step_waterways(force);
    }
    if name == "gn" {
        return step_gn(force);
    }
    if name == "rainfall" {
        return step_rainfall(force);
    }
    if name == "flood_reference" {
        return step_flood_reference(force);
    }
    raise KeyError(name);
}

"""Run `names` (all steps when empty) in order; a failed step does not stop the
others. Returns the names of the steps that failed."""
def run_steps(names: list[str], force: bool) -> list[str] {
    failed: list[str] = [];
    for name in (names if names else STEP_NAMES) {
        t = time.perf_counter();
        try {
            run_step(name, force);
        } except Exception as exc {  # keep going: one failed source should not block the rest
            failed.append(name);
            log(f"{name}: FAILED - {exc}");
        } else {
            log(f"{name}: done in {time.perf_counter() - t:.1f}s");
        }
    }
    if failed {
        log(f"failed steps: {', '.join(failed)} (re-run with --only {' '.join(failed)})");
    }
    return failed;
}
