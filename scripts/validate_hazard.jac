"""Score the hazard footprint against an independently published flood extent.

    jac run -b python --no-takeover scripts/fetch_data.jac --only flood_reference gn srtm
    jac run -b python --no-takeover scripts/validate_hazard.jac

Everything in `outputs/metrics.json` is scored against labels we wrote ourselves,
which makes it a regression check. This is the one accuracy number in the project
measured against ground truth from someone else: the WFP ADAM / NOAA VIIRS flood
composite for the Cyclone Ditwah floods of late November 2025 (CC BY-SA, on HDX).

The model is given nothing but the date. It fetches the rainfall that actually fell
over the basin in that window from the Open-Meteo archive, computes its own HAND
inundation surface, and the two footprints are compared at divisional secretariat
granularity. The reference is never visible to the model.

The same code then runs on a quiet day as a control. A model that simply flagged the
whole basin would score perfect recall against any flood, so the control has to come
out empty for the recall above to mean anything.

Writes `outputs/hazard_validation.json`.
"""

import json;
import sys;
import tempfile;
import from datetime { datetime }
import from pathlib { Path }
import from resqmesh.adapters.geo.paths { outputs_dir }
import from resqmesh.agents.hazard.agent { HazardAssessment }
import from resqmesh.eval.reference {
    CONTROL_MOMENT, REFERENCE_CITATION, REFERENCE_EVENT, REFERENCE_MOMENT,
    compare_footprint, divisions_in_polygon, load_reference
}
import from resqmesh.graph.world { real_world }

"""Run the real A2 hazard agent at one moment, from rainfall alone."""
def _assess(moment: datetime) -> HazardAssessment {
    def clock() -> datetime {
        return moment;
    }
    world = real_world(Path(tempfile.mkdtemp(prefix="resqmesh-validate-")), clock=clock);
    return world.agents.hazard.assess(previous_surface=None, previous_graph=None, now=moment);
}

def _f(value: float | None) -> str {
    return "-" if value is None else f"{value:.3f}";
}

def main -> int {
    moment = datetime.fromisoformat(REFERENCE_MOMENT);
    print(f"Reference : {REFERENCE_CITATION}");
    print(f"Model run : {moment.strftime("%Y-%m-%d %H:%M")} UTC, from rainfall alone\n");

    try {
        reference = load_reference();
    } except FileNotFoundError as exc {
        print(f"cannot validate: {exc}", file=sys.stderr);
        return 2;
    }

    print(f"  reference flooded divisions   {len(reference.flooded_gn)}");
    print(
        f"  obscured by cloud             {len(reference.obscured_gn)} "
        + f"({reference.cloud_fraction:.0%} of cells)"
    );
    if not reference.reportable() {
        print("\nreference not usable: too much cloud, or no water detected in the basin", file=sys.stderr);
        return 2;
    }

    assessment = _assess(moment);
    surface = assessment.surface;
    print(f"\n  model: {assessment.detail}");

    comparison = compare_footprint(surface.inundation_geojson, reference);
    if comparison is None {
        print("comparison not reportable", file=sys.stderr);
        return 2;
    }

    print(f"\n  divisions judged              {comparison.judged_divisions}");
    print(f"  predicted flooded             {len(comparison.predicted_gn)}");
    print(f"  observed flooded              {len(comparison.observed_gn)}");
    print(f"  agreed                        {comparison.intersection()}");
    print();
    print(f"  division IoU                  {_f(comparison.iou())}   target >= 0.60");
    print(f"  recall (flooded, flagged)     {_f(comparison.recall())}");
    print(f"  precision                     {_f(comparison.precision())}");
    print(f"  missed divisions              {len(comparison.missed_gn())}");
    print(f"  false alarms                  {len(comparison.false_alarm_gn())}");

    # Without this, a model that flags everything would score 1.00 recall and look
    # excellent. Run the same code on a quiet day: it must flag nothing.
    control = datetime.fromisoformat(CONTROL_MOMENT);
    control_assessment = _assess(control);
    control_predicted = divisions_in_polygon(control_assessment.surface.inundation_geojson);
    verdict = "PASS" if not control_predicted else "FAIL - the footprint is not event-driven";
    print(
        f"\n  control, {control.strftime("%Y-%m-%d")} (no flood): "
        + f"predicted {len(control_predicted)} divisions   {verdict}"
    );
    print(f"    {control_assessment.detail}");

    out = outputs_dir() / "hazard_validation.json";
    out.parent.mkdir(parents=True, exist_ok=True);
    out.write_text(
        json.dumps(
            {
                "reference": REFERENCE_CITATION,
                "reference_event": REFERENCE_EVENT,
                "model_run_at": moment.isoformat(),
                "method": surface.method.value,
                "surface_confidence_0_1": surface.confidence_0_1,
                "cloud_fraction": comparison.cloud_fraction,
                "divisions_judged": comparison.judged_divisions,
                "predicted_flooded": len(comparison.predicted_gn),
                "observed_flooded": len(comparison.observed_gn),
                "agreed": comparison.intersection(),
                "division_iou": comparison.iou(),
                "recall": comparison.recall(),
                "precision": comparison.precision(),
                "missed_gn": sorted(comparison.missed_gn()),
                "false_alarm_gn": sorted(comparison.false_alarm_gn()),
                "control_run_at": control.isoformat(),
                "control_predicted_flooded": len(control_predicted)
            },
            indent=1
        ),
        encoding="utf-8"
    );
    print(f"\nWrote {out}");
    return 0;
}

with entry {
    sys.exit(main());
}
