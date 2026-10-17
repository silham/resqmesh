"""Download and derive every geospatial input ResQ-Mesh needs, once.

    jac run -b python --no-takeover scripts/fetch_data.jac                 # everything
    jac run -b python --no-takeover scripts/fetch_data.jac --only srtm roads
    jac run -b python --no-takeover scripts/fetch_data.jac --force         # rebuild even if present

Idempotent and resumable: each step checks for its finished artefact and skips if
present, downloads go to `*.part` and are renamed only when complete. Nothing is
committed: `data/raw` and `data/cache` are gitignored (roadmap section 9.2).
Exit code 1 if any step failed; the others still run.

Steps
-----
srtm             SRTM 1 arc-second tiles (AWS Terrain Tiles "skadi", public, no key),
                 mosaicked and clipped to the basin -> data/raw/dem_kelani.tif
roads            OSM drivable network via OSMnx -> data/cache/roads_kelani.pkl
waterways        OSM river/stream/canal lines -> data/raw/waterways_kelani.geojson
gn               HDX Sri Lanka admin-4 (Grama Niladhari) boundaries clipped to the
                 basin -> data/raw/gn_divisions_kelani.geojson
rainfall         Open-Meteo archive hourly series for the Scenario A (May 2016) and
                 Scenario B (May 2017) windows at basin gauge points
                 -> data/raw/rainfall/<scenario>_<station>.json (for the replay harness)
flood_reference  WFP ADAM flood extent, the external reference for hazard accuracy
                 -> data/raw/flood_reference/
"""

import argparse;
import sys;
import from resqmesh.adapters.geo.fetch { STEP_NAMES, run_steps }

def main(argv: list[str]) -> int {
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    );
    ap.add_argument("--only", nargs="+", choices=sorted(STEP_NAMES), help="run just these steps");
    ap.add_argument("--force", action="store_true", help="rebuild artefacts that already exist");
    args = ap.parse_args(argv);
    only: list[str] = args.only if args.only else [];
    failed = run_steps(only, args.force);
    return 1 if failed else 0;
}

with entry {
    argv = [a for a in sys.argv[1:] if not a.endswith(".jac")];
    exit_code = main(argv);
    if exit_code != 0 {
        sys.exit(exit_code);
    }
}
