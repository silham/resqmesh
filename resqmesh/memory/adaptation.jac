"""The adaptation store: what the system carries from one incident to the next.

Learning happens inside the incident ("a flood lasts days; the useful learning signal
arrives within hours") and the learned parameters persist, so the system that
responds to next season's flood begins better calibrated than the one that responded
to this one.

Two layers, and the split is what makes the learning safe to recompute:

* Priors live here, keyed by source. They are what an incident starts with.
* Within-incident evidence is recomputed from the full evidence set on every A1 run,
  never accumulated by incrementing counters. Running A1 twice over the same reports
  yields the same trust, which an incrementing counter could never promise.

The store is written when an incident finishes (or the server shuts down), not on
every tick: it holds the baseline each tick is measured against.
"""

import from datetime { datetime, UTC }
import from resqmesh.contracts.models { AdaptationSnapshot, SourceTrust, TravelTimeResidual }

"""Durable learned parameters, persisted in the graph. Upserts only: nothing is deleted."""
node LearnedPriors {
    has source_trust: dict[str, SourceTrust] = {},
        travel_residuals: dict[str, TravelTimeResidual] = {},
        triage_weights: dict[str, float] = {},
        updated_at: datetime | None = None;

    # App-owned structure: every request and the scheduler may read and update it.
    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

"""Where learned priors live. `load` returns the snapshot a new incident starts from;
`save` upserts a snapshot into it."""
obj AdaptationStore {
    def load -> AdaptationSnapshot {
        return AdaptationSnapshot();
    }

    def save(snapshot: AdaptationSnapshot | None) -> None {}

    """Convenience for inspection and the console."""
    def reliability_of(source_id: str) -> float {
        trust = self.load().source_trust.get(source_id);
        return trust.reliability() if trust else SourceTrust(source_id=source_id).reliability();
    }
}

"""Upsert `incoming` over `current`, field by field. Nothing is ever deleted."""
def upsert(current: AdaptationSnapshot, incoming: AdaptationSnapshot) -> AdaptationSnapshot {
    return AdaptationSnapshot(
        source_trust={**current.source_trust, **incoming.source_trust},
        travel_residuals={**current.travel_residuals, **incoming.travel_residuals},
        triage_weights={**current.triage_weights, **incoming.triage_weights},
        updated_at=datetime.now(UTC)
    );
}

"""Priors held in process memory: tests, scripted replays, offline evaluation."""
obj MemoryAdaptationStore(AdaptationStore) {
    has snapshot: AdaptationSnapshot = AdaptationSnapshot();

    override def load -> AdaptationSnapshot {
        return AdaptationSnapshot(
            source_trust=dict(self.snapshot.source_trust),
            travel_residuals=dict(self.snapshot.travel_residuals),
            triage_weights=dict(self.snapshot.triage_weights)
        );
    }

    override def save(snapshot: AdaptationSnapshot | None) -> None {
        if snapshot is not None {
            self.snapshot = upsert(self.snapshot, snapshot);
        }
    }
}

"""Priors persisted in a LearnedPriors node, so they survive restarts and carry from
one incident to the next on the same deployment."""
obj GraphAdaptationStore(AdaptationStore) {
    has priors: LearnedPriors;

    override def load -> AdaptationSnapshot {
        return AdaptationSnapshot(
            source_trust=dict(self.priors.source_trust),
            travel_residuals=dict(self.priors.travel_residuals),
            triage_weights=dict(self.priors.triage_weights)
        );
    }

    override def save(snapshot: AdaptationSnapshot | None) -> None {
        if snapshot is None {
            return;
        }
        merged = upsert(self.load(), snapshot);
        self.priors.source_trust = merged.source_trust;
        self.priors.travel_residuals = merged.travel_residuals;
        self.priors.triage_weights = merged.triage_weights;
        self.priors.updated_at = merged.updated_at;
    }
}

"""The deployment's priors node, hung off `anchor` (the shared graph), created on first use."""
def graph_store(anchor: Root) -> GraphAdaptationStore {
    found = [n for n in [anchor -->] if isinstance(n, LearnedPriors)];
    if found {
        return GraphAdaptationStore(priors=found[0]);
    }
    priors = LearnedPriors();
    anchor ++> priors;
    return GraphAdaptationStore(priors=priors);
}
