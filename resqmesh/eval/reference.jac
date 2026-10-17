"""Ground truth we did not write ourselves.

Every label in `scenarios.jac` was written alongside the scenario it scores, which
makes the scorecard a regression check and nothing more. This module scores the
hazard footprint against an **independently published flood extent**: the WFP ADAM
rapid impact analysis for the Cyclone Ditwah floods of late November 2025, derived
from a NOAA VIIRS five-day composite at 375 m and published on HDX under CC BY-SA.
Fetch it with `scripts/fetch_data.jac --only flood_reference`.

The comparison is at **divisional secretariat granularity**, not per pixel, and that
is deliberate. A 375 m optical composite and a 30 m HAND surface disagree about every
shoreline; what an operator actually needs to be right is *which divisions are under
water*, because that is the unit alerts and dispatch work in. The areal overlap is
reported alongside as a diagnostic, not as the headline.

Two ways this comparison can lie, both guarded here:

* **Cloud.** VIIRS is optical, so a cyclone can hide the ground. Cells the satellite
  could not see are excluded from both sides, and if too much of the basin is
  obscured the comparison refuses to report a number at all.
* **Permanent water.** The Kelani river and the Muthurajawela marshes are wet on a
  dry day. Scoring them as correctly predicted flood would inflate every run. The
  reference masks permanent water, and so must we.
"""

import json;
import numpy as np;
import rasterio;
import from pathlib { Path }
import from rasterio.features { geometry_mask }
import from rasterio.windows { from_bounds }
import from shapely.geometry { shape }
import from shapely.ops { unary_union }
import from shapely.strtree { STRtree }
import from resqmesh.adapters.geo.paths { KELANI_BBOX, flood_reference_dir, gn_boundaries_path }

"""WFP ADAM band values (`metadata.txt` in the fetched archive): the share of the cell
detected as water, low / moderate / high."""
glob FLOOD_CLASSES: list[int] = [1, 2, 3];
glob CLOUD_CLASS: int = 9;
glob LAND_CLASS: int = 10;
"""Undocumented in the product metadata but consistent with the masked permanent water
bodies (MOD44W): in this basin it traces the Kelani channel and the coastal marshes
exactly. Treated as *not* flooded, which is the conservative reading."""
glob PERMANENT_WATER_CLASS: int = 11;

"""The event the fetched reference describes."""
glob REFERENCE_EVENT: str = "FL-20251201-LKA-00";
glob REFERENCE_CITATION: str = (
    "WFP ADAM rapid impact analysis FL-20251201-LKA-00 (NOAA VIIRS five-day flood "
    "composite, 375 m), Cyclone Ditwah, Sri Lanka, 1 December 2025; published on HDX "
    "under CC BY-SA."
);
"""Where the flood composite sits in time. The reference is a five-day composite, so the
model is run at the end of the window it covers."""
glob REFERENCE_MOMENT: str = "2025-11-30T18:00:00+00:00";

"""A quiet day, for the control run: the north-east monsoon has passed the west coast and
no flood was reported in the basin. The footprint must come out empty here, or high
recall against a real flood means nothing."""
glob CONTROL_MOMENT: str = "2026-02-20T18:00:00+00:00";

"""Above this share of obscured cells the comparison is not reportable."""
glob MAX_CLOUD_FRACTION: float = 0.20;

def reference_raster() -> Path {
    return flood_reference_dir() / f"{REFERENCE_EVENT}.tiff";
}

"""A published flood extent, clipped to the basin.

`obscured_gn` is the divisions the satellite could not see well enough to judge
either way."""
obj FloodReference {
    has flooded_gn: set[str],
        obscured_gn: set[str],
        cloud_fraction: float,
        flooded_cells: int,
        total_cells: int;

    def reportable -> bool {
        return self.cloud_fraction <= MAX_CLOUD_FRACTION and self.flooded_cells > 0;
    }
}

"""Our hazard footprint against the published one, by division.

`iou()` is over division *sets*: the divisions both call flooded, over the divisions
either calls flooded. Obscured divisions are excluded from both sides rather than
counted as agreement."""
obj FootprintComparison {
    has predicted_gn: set[str],
        observed_gn: set[str],
        judged_divisions: int,
        cloud_fraction: float,
        citation: str = REFERENCE_CITATION;

    def intersection -> int {
        return len(self.predicted_gn & self.observed_gn);
    }

    def iou -> float | None {
        union = len(self.predicted_gn | self.observed_gn);
        return None if union == 0 else round(self.intersection() / union, 4);
    }

    """Share of really-flooded divisions we flagged. The one that matters most."""
    def recall -> float | None {
        if not self.observed_gn {
            return None;
        }
        return round(self.intersection() / len(self.observed_gn), 4);
    }

    def precision -> float | None {
        if not self.predicted_gn {
            return None;
        }
        return round(self.intersection() / len(self.predicted_gn), 4);
    }

    """Flooded and not flagged: the failures that would cost lives."""
    def missed_gn -> set[str] {
        return self.observed_gn - self.predicted_gn;
    }

    def false_alarm_gn -> set[str] {
        return self.predicted_gn - self.observed_gn;
    }
}

"""One GN division polygon."""
obj Division {
    has gn_id: str,
        geometry: any;
}

"""The GN division polygons, in EPSG:4326."""
def _divisions(boundaries: Path | None = None) -> list[Division] {
    path = boundaries or gn_boundaries_path();
    if not path.exists() {
        raise FileNotFoundError(f"{path} missing; run scripts/fetch_data.jac --only gn");
    }
    collection = json.loads(path.read_text(encoding="utf-8"));
    return [
        Division(gn_id=str(f["properties"]["gn_id"]), geometry=shape(f["geometry"]))
        for f in collection["features"]
    ];
}

"""Read the published flood composite and say which divisions it puts under water.

A division counts as flooded when any cell the satellite classified as water falls
inside its polygon, and as obscured when cloud covers it and no water was seen:
unseen is not the same as dry."""
def load_reference(
    raster: Path | None = None,
    boundaries: Path | None = None,
    bbox: tuple[float, float, float, float] = KELANI_BBOX
) -> FloodReference {
    path = raster or reference_raster();
    if not path.exists() {
        raise FileNotFoundError(
            f"{path} missing; run: jac run scripts/fetch_data.jac --only flood_reference"
        );
    }
    band: any = None;
    transform: any = None;
    with rasterio.open(path) as src {
        window: any = from_bounds(bbox[0], bbox[1], bbox[2], bbox[3], transform=src.transform);
        band = src.read(1, window=window);
        transform = src.window_transform(window);
    }

    wet: any = np.isin(band, FLOOD_CLASSES);
    cloud: any = band == CLOUD_CLASS;
    judged: any = band != 0;
    judged_cells = int(judged.sum());
    cloud_fraction = float(cloud.sum() / judged_cells) if judged_cells else 1.0;

    flooded: set[str] = set();
    obscured: set[str] = set();
    for division in _divisions(boundaries) {
        # A division smaller than one 375 m cell still has to be judged, so the mask
        # is taken with all_touched: any cell the polygon reaches counts.
        inside: any = ~geometry_mask(
            [division.geometry], out_shape=band.shape, transform=transform,
            invert=False, all_touched=True
        );
        if not inside.any() {
            continue;
        }
        if (wet & inside).any() {
            flooded.add(division.gn_id);
        } elif (cloud & inside).any() {
            obscured.add(division.gn_id);
        }
    }

    return FloodReference(
        flooded_gn=flooded,
        obscured_gn=obscured,
        cloud_fraction=round(cloud_fraction, 4),
        flooded_cells=int(wet.sum()),
        total_cells=judged_cells
    );
}

"""Which GN divisions our own inundation surface covers.

Intersection, not centroid containment: a division is at risk when water reaches any
part of it, and the synthetic world's centroid test would call a division of 30 km2
dry because its middle happens to be on a hill."""
def divisions_in_polygon(inundation_geojson: dict[str, any], boundaries: Path | None = None) -> set[str] {
    features = inundation_geojson.get("features") or [];
    if not features {
        return set();
    }
    flood: any = unary_union([shape(f["geometry"]) for f in features]);
    divisions = _divisions(boundaries);
    tree: any = STRtree([d.geometry for d in divisions]);
    hits: any = tree.query(flood, predicate="intersects");
    return set([divisions[int(i)].gn_id for i in hits]);
}

"""Score our footprint against the published one. None when not reportable."""
def compare_footprint(
    inundation_geojson: dict[str, any], reference: FloodReference, boundaries: Path | None = None
) -> FootprintComparison | None {
    if not reference.reportable() {
        return None;
    }
    predicted = divisions_in_polygon(inundation_geojson, boundaries);
    return FootprintComparison(
        predicted_gn=predicted - reference.obscured_gn,
        observed_gn=reference.flooded_gn - reference.obscured_gn,
        judged_divisions=len(_divisions(boundaries)) - len(reference.obscured_gn),
        cloud_fraction=reference.cloud_fraction
    );
}
