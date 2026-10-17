"""Where the geospatial layer keeps its data, resolved the same way on every OS.

Everything under `data/raw` and `data/cache` is regenerable by `scripts/fetch_data.jac`
and gitignored. `RESQMESH_DATA_DIR` overrides the location; otherwise the project's own
`data/` directory is used, so the path does not depend on the working directory.
"""

import os;
import from pathlib { Path }

"""Operational bounding box of the lower/middle Kelani basin, EPSG:4326, as
(west, south, east, north): Colombo harbour to just past Avissawella."""
glob KELANI_BBOX: tuple[float, float, float, float] = (79.84, 6.84, 80.26, 7.03);

"""The project root: the nearest ancestor holding jac.toml."""
def project_root() -> Path {
    here = Path(__file__).resolve();
    for parent in here.parents {
        if (parent / "jac.toml").exists() {
            return parent;
        }
    }
    return Path.cwd();
}

def data_dir() -> Path {
    env_dir = os.environ.get("RESQMESH_DATA_DIR");
    return Path(env_dir).expanduser().resolve() if env_dir else project_root() / "data";
}

"""Downloaded source data: SRTM tiles, GN boundaries, waterways."""
def raw_dir() -> Path {
    return data_dir() / "raw";
}

"""Derived artefacts: pickled road graphs, pruned graphs, API response caches."""
def cache_dir() -> Path {
    return data_dir() / "cache";
}

"""Generated reports (SITREPs) and evaluation results."""
def outputs_dir() -> Path {
    env_dir = os.environ.get("RESQMESH_OUTPUTS_DIR");
    return Path(env_dir).expanduser().resolve() if env_dir else project_root() / "outputs";
}

def ensure_dir(path: Path) -> Path {
    path.mkdir(parents=True, exist_ok=True);
    return path;
}

"""`RESQMESH_OFFLINE=1` forces degraded mode: no adapter may touch the network."""
def is_offline() -> bool {
    return os.environ.get("RESQMESH_OFFLINE", "0").strip().lower() in ["1", "true", "yes", "on"];
}

def dem_path() -> Path {
    return raw_dir() / "dem_kelani.tif";
}

def road_graph_path() -> Path {
    return cache_dir() / "roads_kelani.pkl";
}

def waterways_path() -> Path {
    return raw_dir() / "waterways_kelani.geojson";
}

def gn_boundaries_path() -> Path {
    return raw_dir() / "gn_divisions_kelani.geojson";
}

"""Independently published flood extents: evaluation ground truth only. Nothing in
the incident path reads these; a reference the system could see would stop being one."""
def flood_reference_dir() -> Path {
    return raw_dir() / "flood_reference";
}
