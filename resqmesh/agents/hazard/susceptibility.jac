"""Landslide susceptibility from terrain slope and antecedent rainfall.

Follows the structure of the NBRO (National Building Research Organisation) landslide
early-warning practice: rainfall sets a warning *level*, and the level sets how steep
a slope must be before it is flagged. Wetter conditions -> gentler slopes fail.

====================  ==========================  ==================
NBRO level            trigger (either)            flag slopes >=
====================  ==========================  ==================
none                  24 h < 75 mm, 72 h < 150    — (empty surface)
Level 1 "watch"       24 h >= 75 mm or 72 h >= 150    30 deg
Level 2 "alert"       24 h >= 100 mm or 72 h >= 200   25 deg
Level 3 "evacuate"    24 h >= 150 mm or 72 h >= 250   20 deg
====================  ==========================  ==================

The slope cut-offs are our judgement, chosen against the Sri Lankan literature
placing most rainfall-induced failures on 20-40 deg slopes. Aspect is returned for
the record but not used to gate: on a 30 m DEM its signal is weaker than its noise.
"""

import numpy as np;
import from shapely.geometry { shape }
import from shapely.ops { unary_union }
import from resqmesh.adapters.geo.shapes { collection_from_geometry, empty_collection }
import from resqmesh.adapters.geo.terrain { Dem, slope_degrees }

"""(level, 24 h threshold mm, 72 h threshold mm, slope cut-off deg), most severe first."""
glob NBRO_LEVELS: list[tuple[int, float, float, float]] = [
    (3, 150.0, 250.0, 20.0),
    (2, 100.0, 200.0, 25.0),
    (1, 75.0, 150.0, 30.0)
];

"""Connected groups smaller than this many cells are noise, not a slope (~5 ha at 30 m).
Also keeps the hill-country polygon small enough to checkpoint every tick."""
glob MIN_CELLS: int = 60;
glob SIMPLIFY_DEG: float = 0.0006;  # ~66 m

obj SusceptibilityResult {
    has level: int,
        slope_cutoff_deg: float | None,
        collection: dict[str, any];
}

def nbro_level(rain_24h_mm: float, rain_72h_mm: float) -> tuple[int, float | None] {
    for (level, t24, t72, cutoff) in NBRO_LEVELS {
        if rain_24h_mm >= t24 or rain_72h_mm >= t72 {
            return (level, cutoff);
        }
    }
    return (0, None);
}

def susceptibility_surface(dem: Dem | None, rain_24h_mm: float, rain_72h_mm: float) -> SusceptibilityResult {
    lc: any = nbro_level(rain_24h_mm, rain_72h_mm);
    level: int = lc[0];
    cutoff: float | None = lc[1];
    if dem is None or cutoff is None {
        return SusceptibilityResult(level=level, slope_cutoff_deg=cutoff, collection=empty_collection());
    }

    import rasterio.features;

    slope: any = slope_degrees(dem);
    # NaN cells (outside the DEM) are never flagged.
    flagged: any = np.logical_and(np.logical_not(np.isnan(slope)), slope >= cutoff);
    mask: any = flagged.astype("uint8");
    if not mask.any() {
        return SusceptibilityResult(level=level, slope_cutoff_deg=cutoff, collection=empty_collection());
    }
    mask = rasterio.features.sieve(mask, size=MIN_CELLS, connectivity=8);
    polys = [
        shape(geom)
        for (geom, val) in rasterio.features.shapes(mask, mask=mask.astype(bool), transform=dem.transform)
        if val == 1
    ];
    if not polys {
        return SusceptibilityResult(level=level, slope_cutoff_deg=cutoff, collection=empty_collection());
    }
    merged = unary_union(polys).simplify(SIMPLIFY_DEG, preserve_topology=True);
    return SusceptibilityResult(
        level=level,
        slope_cutoff_deg=cutoff,
        collection=collection_from_geometry(
            merged, kind="landslide_susceptibility", nbro_level=level, slope_cutoff_deg=cutoff,
            rain_24h_mm=round(rain_24h_mm, 1), rain_72h_mm=round(rain_72h_mm, 1)
        )
    );
}
