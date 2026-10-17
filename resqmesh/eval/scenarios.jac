"""Replay scenarios and their ground-truth labels.

A scenario is a chronological set of report waves plus the commander decisions to
apply at each gate, and, crucially, the labels the run is scored against. A system
that completes every task can still be wrong about all of them, so the question the
harness asks is not "did it finish" but "was it right", and the labels here are the
reference for "right".

The **labels are pure** (this module imports nothing heavy to define them), so the
scoring in `resqmesh.eval.harness` is unit-testable without the agent stack. Building
the runnable scenario pulls the synthetic world lazily, because that path needs the
geospatial and optimisation dependencies.

Scenario A (2016) and B (2017) are the historical replays of proposal section 8.1;
they need reconstructed report logs and observed-inundation products that are not in
the repo yet, so they are declared here and left to assemble. The synthetic scenario
is fully self-contained and self-labelled, and is what runs in CI today.
"""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.contracts.enums { ApprovalDecision }
import from resqmesh.contracts.models { RawSignal }

"""The reference a run is scored against.

`relevance_by_gn` is expert-assigned priority per division (for nDCG);
`observed_inundation_gn` is the divisions actually inundated (for IoU); and
`contradicted_gn` is where reports genuinely conflict (for contradiction F1).
Keyed by GN division so a label survives whatever cluster id the run assigns."""
obj ScenarioLabels {
    has relevance_by_gn: dict[str, float] = {},
        observed_inundation_gn: set[str] = set(),
        contradicted_gn: set[str] = set();
}

"""The synthetic world (resqmesh.graph.world) encodes its own ground truth in the report
text; these labels read it out. Kolonnawa is corroborated and severe; Hanwella is a
corroborated critical medical case; Pahathgama (second wave) is severe with a
wheelchair user and an infant; Malabe is contested (flooded vs "receded"); the
riverside divisions Kolonnawa and Sedawatta sit inside the inundation."""
glob SYNTHETIC_LABELS: ScenarioLabels = ScenarioLabels(
    relevance_by_gn={
        "KLN-003": 3.0,  # Kolonnawa: 12 trapped, elderly + children, 3 sources
        "KLN-004": 3.0,  # Hanwella: critical dialysis, corroborated
        "KLN-008": 3.0,  # Pahathgama: 8 trapped, wheelchair user, infant
        "KLN-001": 1.5,  # Biyagama: road blocked, no lives reported
        "KLN-007": 1.0   # Malabe: contested, most-recent report says receded
    },
    observed_inundation_gn={"KLN-003", "KLN-009"},
    contradicted_gn={"KLN-007"}
);

"""One replay: waves of reports, decisions per gate, and the scoring labels.

`reference` is what the label-scored numbers are measured against, carried into the
scorecard."""
obj Scenario {
    has name: str,
        goal: str,
        incident_id: str,
        labels: ScenarioLabels,
        reference: str = "unspecified",
        waves: list[list[RawSignal]] = [],
        decisions: list[tuple[ApprovalDecision, str | None]] = [],
        rain_peak_mm: float = 8.0;
}

"""The self-contained offline scenario that runs in CI.

Imports the synthetic world lazily (heavy deps), so importing this module for its
labels alone stays cheap."""
def synthetic_scenario(t0: datetime | None = None) -> Scenario {
    import from resqmesh.graph.world { follow_up_signals, opening_signals }

    start = t0 or datetime(2026, 9, 21, 6, 0, tzinfo=UTC);
    return Scenario(
        name="synthetic-kelani",
        goal="coordinate the response to flooding in the Kelani basin",
        incident_id="KLN-2026-EVAL",
        labels=SYNTHETIC_LABELS,
        reference="synthetic self-consistency (regression check, not an accuracy claim)",
        waves=[opening_signals(start), follow_up_signals(start + timedelta(minutes=25))],
        decisions=[
            (ApprovalDecision.APPROVED, None),
            (ApprovalDecision.REJECTED, "exclude_vehicle: BOAT-01")
        ],
        # A flood-scale rainfall, not the dry demo default: at this peak the
        # buffer-proxy inundates the two riverside divisions the labels expect.
        rain_peak_mm=20.0
    );
}
