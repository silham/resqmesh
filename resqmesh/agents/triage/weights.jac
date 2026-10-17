"""The triage weight vector: a learnable object with a defensible starting point.

Initial values (judgement call, documented in the README):

=====================  ======  ===================================================
component              weight  why
=====================  ======  ===================================================
hazard_severity         0.25   the physical threat is the first reason to go
population_exposure     0.20   how many people are there
vulnerability           0.20   functional need: who cannot self-evacuate
time_criticality        0.20   how fast the situation worsens if unattended
cluster_confidence      0.15   evidence quality; low enough that a real but
                               single-source emergency still ranks
=====================  ======  ===================================================

`AdaptationSnapshot.triage_weights` carries **additive nudges** written by A0's
adaptation store (e.g. `{"vulnerability": +0.03}`). They are applied to the
defaults, each weight is clamped to `[MIN_WEIGHT, MAX_WEIGHT]` so no single
component can be learned to zero or to dominance, and the vector is renormalised to
sum to 1, which keeps every score in 0-1. Unknown keys are ignored.
"""

import from resqmesh.contracts.models { AdaptationSnapshot, SCORE_COMPONENTS }

"""The scored components, in their canonical order."""
glob COMPONENTS: list[str] = list(SCORE_COMPONENTS);

glob DEFAULT_WEIGHTS: dict[str, float] = {
    "hazard_severity": 0.25,
    "population_exposure": 0.20,
    "vulnerability": 0.20,
    "time_criticality": 0.20,
    "cluster_confidence": 0.15
};

glob MIN_WEIGHT: float = 0.02;
glob MAX_WEIGHT: float = 0.60;

"""Clamp every component weight into bounds and rescale the vector to sum to 1."""
def normalise(weights: dict[str, float]) -> dict[str, float] {
    clamped: dict[str, float] = {
        k: min(MAX_WEIGHT, max(MIN_WEIGHT, float(weights[k]))) for k in COMPONENTS
    };
    total = sum(clamped.values());
    return {k: round(v / total, 6) for (k, v) in clamped.items()};
}

"""Defaults plus any learned nudges, clamped and renormalised."""
def resolve_weights(adaptation: AdaptationSnapshot | None = None) -> dict[str, float] {
    nudges: dict[str, float] = adaptation.triage_weights if adaptation is not None else {};
    return normalise({k: DEFAULT_WEIGHTS[k] + float(nudges.get(k, 0.0)) for k in COMPONENTS});
}
