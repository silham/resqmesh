#!/bin/sh
# Put the real Kelani basin data where the server reads it. Run it on the host that serves
# the app (in a container: its terminal), then restart the app with RESQMESH_WORLD=real.
#
#   sh scripts/get_data.sh            # fetch what is missing
#   sh scripts/get_data.sh --force    # fetch again even if the files are there
#
# With RESQMESH_DATA_URL set it downloads that prepared bundle (a .tar.gz whose paths start
# with data/, such as data/raw/dem_kelani.tif) and unpacks it into the data directory.
# Without it, it builds the data from the public sources with scripts/fetch_data.jac,
# which downloads about 250 MB and needs spare memory while the road network is built.
set -eu

DATA="${RESQMESH_DATA_DIR:-$(cd "$(dirname "$0")/.." && pwd)/data}"
NEEDED="raw/dem_kelani.tif raw/gn_divisions_kelani.geojson raw/waterways_kelani.geojson cache/roads_kelani.pkl"

complete() {
    for f in $NEEDED; do
        [ -s "$DATA/$f" ] || return 1
    done
    return 0
}

if complete && [ "${1:-}" != "--force" ]; then
    echo "Kelani data already in $DATA"
    exit 0
fi

mkdir -p "$DATA"

if [ -n "${RESQMESH_DATA_URL:-}" ]; then
    echo "Downloading $RESQMESH_DATA_URL"
    bundle="$(mktemp)"
    curl -fL --retry 3 -o "$bundle" "$RESQMESH_DATA_URL"
    tar xzf "$bundle" -C "$DATA" --strip-components=1
    rm -f "$bundle"
else
    echo "No RESQMESH_DATA_URL set: fetching from the public sources"
    cd "$(dirname "$0")/.."
    if [ "${1:-}" = "--force" ]; then
        jac run --no-takeover scripts/fetch_data.jac --force --only srtm roads waterways gn
    else
        jac run --no-takeover scripts/fetch_data.jac --only srtm roads waterways gn
    fi
fi

if complete; then
    echo "Done. Restart the app with RESQMESH_WORLD=real."
else
    echo "Some files are still missing from $DATA:" >&2
    for f in $NEEDED; do
        [ -s "$DATA/$f" ] || echo "  $f" >&2
    done
    exit 1
fi
