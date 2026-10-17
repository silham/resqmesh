"""Scoring against a published flood extent.

The arithmetic is tested on its own, then once end to end on a raster built here, so
the suite never depends on a download. The real reference lives outside the
repository; `scripts/validate_hazard.jac` is what scores against it."""

import json;
import tempfile;
import numpy as np;
import rasterio;
import from pathlib { Path }
import from rasterio.transform { from_origin }
import from resqmesh.eval.reference {
    CLOUD_CLASS, FLOOD_CLASSES, LAND_CLASS, FloodReference, FootprintComparison,
    compare_footprint, load_reference
}

def make_comparison(predicted: set[str], observed: set[str]) -> FootprintComparison {
    return FootprintComparison(
        predicted_gn=predicted, observed_gn=observed, judged_divisions=10, cloud_fraction=0.0
    );
}

test "a missed division is visible separately from a false alarm" {
    # Failing to warn a flooded division is not the same kind of error as over-warning.
    c = make_comparison({"A", "B", "X"}, {"A", "B", "C"});
    assert c.missed_gn() == {"C"};
    assert c.false_alarm_gn() == {"X"};
    assert c.recall() == round(2 / 3, 4);
    assert c.precision() == round(2 / 3, 4);
    assert c.iou() == 0.5;
}

test "flagging everything does not score well" {
    # High recall alone must not look like accuracy: precision and IoU catch it.
    c = make_comparison(set([f"D{i}" for i in range(100)]), {"D1", "D2"});
    assert c.recall() == 1.0;
    assert c.precision() == 0.02;
    assert c.iou() == 0.02;
}

test "nothing observed is unmeasured not perfect" {
    c = make_comparison({"A"}, set());
    assert c.recall() is None;
    assert c.iou() == 0.0;
}

test "a cloudy reference refuses to be scored" {
    # Unseen ground is not dry ground, so a clouded-out event is not reportable.
    cloudy = FloodReference(
        flooded_gn={"A"}, obscured_gn=set(), cloud_fraction=0.65, flooded_cells=10, total_cells=100
    );
    assert cloudy.reportable() is False;
    assert compare_footprint({"features": []}, cloudy) is None;
}

test "a reference with no water is not a reference" {
    dry = FloodReference(
        flooded_gn=set(), obscured_gn=set(), cloud_fraction=0.0, flooded_cells=0, total_cells=100
    );
    assert dry.reportable() is False;
}

test "obscured divisions are excluded from both sides" {
    reference = FloodReference(
        flooded_gn={"A", "B"}, obscured_gn={"B", "C"},
        cloud_fraction=0.05, flooded_cells=20, total_cells=100
    );
    assert reference.reportable();
    # 'B' is flooded but obscured, 'C' is obscured: neither may be scored.
    comparison = FootprintComparison(
        predicted_gn={"A", "C"} - reference.obscured_gn,
        observed_gn=reference.flooded_gn - reference.obscured_gn,
        judged_divisions=1, cloud_fraction=reference.cloud_fraction
    );
    assert comparison.predicted_gn == {"A"};
    assert comparison.observed_gn == {"A"};
    assert comparison.iou() == 1.0;
}

def square(gn_id: str, west: float, north: float, size: float = 0.009) -> dict[str, any] {
    return {
        "type": "Feature", "properties": {"gn_id": gn_id},
        "geometry": {
            "type": "Polygon",
            "coordinates": [[
                [west, north], [west + size, north],
                [west + size, north - size], [west, north - size], [west, north]
            ]]
        }
    };
}

test "reads divisions out of a real raster" {
    # One end-to-end read: two divisions, one wet, one dry, one clouded.
    tmp = Path(tempfile.mkdtemp(prefix="resqmesh-ref-"));

    # A 4x4 grid of 0.01 degree cells starting at (79.90, 7.00) going south.
    band: any = np.full((4, 4), LAND_CLASS, dtype="uint8");
    band[(0, 0)] = FLOOD_CLASSES[2];  # inside WET
    band[(3, 3)] = CLOUD_CLASS;  # inside CLOUDED
    raster = tmp / "ref.tiff";
    with rasterio.open(
        raster, "w", driver="GTiff", height=4, width=4, count=1, dtype="uint8", crs="EPSG:4326",
        transform=from_origin(79.90, 7.00, 0.01, 0.01)
    ) as dst {
        dst.write(band, 1);
    }

    boundaries = tmp / "gn.geojson";
    boundaries.write_text(
        json.dumps({
            "type": "FeatureCollection",
            "features": [
                square("WET", 79.9005, 6.9995),
                square("DRY", 79.9105, 6.9995),
                square("CLOUDED", 79.9305, 6.9705)
            ]
        }),
        encoding="utf-8"
    );

    reference = load_reference(raster=raster, boundaries=boundaries, bbox=(79.90, 6.96, 79.94, 7.00));
    assert "WET" in reference.flooded_gn;
    assert "DRY" not in reference.flooded_gn;
    assert "CLOUDED" in reference.obscured_gn;
}
