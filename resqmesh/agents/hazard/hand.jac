"""HAND (Height Above Nearest Drainage) inundation from the SRTM DEM.

Pipeline, all deterministic, via `pysheds`:

1. condition the DEM — fill pits, fill depressions, resolve flats — so every cell
   drains somewhere;
2. D8 flow direction and flow accumulation;
3. drainage network = cells whose upstream area exceeds `channel_threshold_cells`
   (default 150 000 cells, about 140 km² — the Kelani main stem and its major
   tributaries). A small threshold was tried first and rejected: at ~2 km² every
   Colombo canal becomes a "river" and a 60 mm day floods 200 km² of city;
4. HAND = each cell's elevation above the drainage cell it flows into.

Steps 1-4 do not depend on rainfall, so the HAND raster is computed once per DEM
and cached in memory and on disk. Each tick only applies the rainfall-driven depth:

    inundated  <=>  HAND < stage_m(rain_24h)

`stage_m` is our judgement call, documented in the README: no out-of-bank water
below the NBRO watch level of 75 mm/24 h, then 2 cm of effective stage per extra
millimetre, capped at 8 m. At the May 2016 peak (262 mm/24 h in the Open-Meteo
archive) that is ~3.7 m above drainage and ~70 km² of lower-basin land — the order of
the reported 2016 inundation. The constants are tuned on Scenarios A and B only —
Scenario C is held out.

`pysheds` is GPL-licensed and optional: it is imported only inside `compute_hand`, so
the rest of the system loads without it, and the agent falls back to the buffer proxy
when it is missing.
"""

import importlib;
import numpy as np;
import from pathlib { Path }
import from shapely.geometry { shape }
import from shapely.ops { unary_union }
import from resqmesh.adapters.geo.paths { cache_dir, dem_path, ensure_dir }
import from resqmesh.adapters.geo.shapes { collection_from_geometry, empty_collection }

glob STAGE_TRIGGER_MM: float = 75.0;
glob STAGE_M_PER_MM: float = 0.02;
glob STAGE_MAX_M: float = 8.0;
glob DEFAULT_CHANNEL_THRESHOLD_CELLS: int = 150000;
glob SEA_LEVEL_M: float = 0.0;
glob MIN_CELLS: int = 12;  # sieve: isolated low patches smaller than ~1 ha are noise
glob SIMPLIFY_DEG: float = 0.0002;  # ~22 m

"""Effective flood stage above drainage for a 24-hour rainfall total."""
def stage_m(rain_24h_mm: float) -> float {
    if rain_24h_mm < STAGE_TRIGGER_MM {
        return 0.0;
    }
    return min(STAGE_MAX_M, STAGE_M_PER_MM * (rain_24h_mm - STAGE_TRIGGER_MM));
}

def _isin_flat(a: any, b: any, **kw: any) -> any {
    return np.isin(np.ravel(a), b, **kw);
}

"""pysheds 0.5 still calls `np.in1d`, removed in numpy 2.4. `np.isin` on the
flattened input is the documented equivalent; patch it in only if missing."""
def _numpy_compat() -> None {
    if not hasattr(np, "in1d") {
        setattr(np, "in1d", _isin_flat);
    }
}

"""HAND raster (metres, NaN outside data) and its affine transform."""
def compute_hand(dem_file: Path, channel_threshold_cells: int) -> tuple[any, any] {
    _numpy_compat();
    # Resolved at call time only: pysheds is GPL and optional.
    Grid: any = importlib.import_module("pysheds.grid").Grid;

    grid: any = Grid.from_raster(str(dem_file));
    dem: any = grid.read_raster(str(dem_file));
    conditioned: any = grid.resolve_flats(grid.fill_depressions(grid.fill_pits(dem)));
    fdir: any = grid.flowdir(conditioned);
    acc: any = grid.accumulation(fdir);
    channels: any = acc > channel_threshold_cells;
    hand: any = grid.compute_hand(fdir, dem, channels);
    out: any = np.asarray(hand, dtype="float64");
    out[~np.isfinite(out)] = np.nan;
    # Cells below their drainage cell are pits: genuinely low ground, so they flood
    # first (HAND 0). The sieve at vectorisation removes the isolated SRTM noise ones.
    # (HAND on the *conditioned* DEM was tried and rejected: depression filling turns
    # the lower-Kelani marshes into flats at channel level and over-floods them.)
    out[out < 0] = 0.0;
    raw: any = np.asarray(dem, dtype="float64");
    nodata = getattr(dem, "nodata", None);
    if nodata is not None {
        out[raw == nodata] = np.nan;
    }
    out[raw <= SEA_LEVEL_M] = np.nan;  # the sea is not a flood
    return (out, grid.affine);
}

"""Rainfall -> inundation polygon, with the expensive raster cached.

The raster is cached in memory after first use and on disk under the cache directory
as `hand_{dem stem}_{threshold}.tif`, reused while it is at least as new as the DEM."""
obj HandModel {
    has dem_file: Path | None = None,
        channel_threshold_cells: int = DEFAULT_CHANNEL_THRESHOLD_CELLS,
        cache_file: Path | None = None,
        _hand: any = None,
        _transform: any = None;

    def postinit {
        if self.dem_file is None {
            self.dem_file = dem_path();
        }
    }

    def _cache_path -> Path {
        if self.cache_file is not None {
            return self.cache_file;
        }
        dem_file: Path = self.dem_file or dem_path();
        return cache_dir() / f"hand_{dem_file.stem}_{self.channel_threshold_cells}.tif";
    }

    def raster -> tuple[any, any] {
        if self._hand is not None {
            return (self._hand, self._transform);
        }
        dem_file: Path = self.dem_file or dem_path();
        if not dem_file.exists() {
            raise FileNotFoundError(f"DEM not found at {dem_file}; run `jac run scripts/fetch_data.jac`");
        }
        import rasterio;

        cache = self._cache_path();
        if cache.exists() and cache.stat().st_mtime >= dem_file.stat().st_mtime {
            with rasterio.open(cache) as src {
                self._hand = src.read(1).astype("float64");
                self._transform = src.transform;
            }
            return (self._hand, self._transform);
        }

        computed: any = compute_hand(dem_file, self.channel_threshold_cells);
        hand: any = computed[0];
        transform: any = computed[1];
        ensure_dir(cache.parent);
        tmp = cache.with_name(cache.name + ".part");
        with rasterio.open(
            tmp, "w", driver="GTiff", height=hand.shape[0], width=hand.shape[1], count=1,
            dtype="float32", crs="EPSG:4326", transform=transform, compress="deflate", nodata=np.nan
        ) as dst {
            dst.write(hand.astype("float32"), 1);
        }
        tmp.replace(cache);
        self._hand = hand;
        self._transform = transform;
        return (hand, transform);
    }

    def inundation(rain_24h_mm: float) -> dict[str, any] {
        stage = stage_m(rain_24h_mm);
        if stage <= 0 {
            return empty_collection();
        }
        rt: any = self.raster();
        return inundation_from_hand(rt[0], rt[1], stage, rain_24h_mm=rain_24h_mm);
    }
}

def inundation_from_hand(hand: any, transform: any, stage: float, **properties: any) -> dict[str, any] {
    import from rasterio.features { shapes as raster_shapes, sieve }

    low: any = np.logical_and(np.logical_not(np.isnan(hand)), hand < stage);
    mask: any = low.astype("uint8");
    if not mask.any() {
        return empty_collection();
    }
    mask = sieve(mask, size=MIN_CELLS, connectivity=8);
    polys = [
        shape(g)
        for (g, v) in raster_shapes(mask, mask=mask.astype(bool), transform=transform)
        if v == 1
    ];
    if not polys {
        return empty_collection();
    }
    merged = unary_union(polys).simplify(SIMPLIFY_DEG, preserve_topology=True);
    extra = {k: round(v, 1) if isinstance(v, float) else v for (k, v) in properties.items()};
    return collection_from_geometry(merged, kind="inundation", method="hand", stage_m=round(stage, 2), **extra);
}
