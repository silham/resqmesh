"""A1 — Signal Ingest and Verification Agent.

Reads:  `raw_signals`, `reports`, `adaptation` (source trust), `location_fixes`
Writes: `reports` (append), `unresolved_queue`, `clusters`, `cluster_aliases`,
        `adaptation`, `trace`

Converts the unstructured world into typed observations: every new signal becomes
exactly one report, located reports are fused into clusters with a trust-weighted
confidence, and anything the gazetteer cannot place goes to the unresolved queue —
held explicitly, never guessed at, never dropped.

Idempotent by construction: a signal whose report already exists is skipped, and
clusters are recomputed from the full evidence each run, so running A1 twice over
the same state changes nothing.
"""

import uuid;
import from datetime { datetime, UTC }
import from resqmesh.agents.ingest.extraction { extract_report }
import from resqmesh.agents.ingest.fusion { FusionConfig, fuse }
import from resqmesh.agents.ingest.learning { recompute_trust }
import from resqmesh.contracts.enums { ActionTier, ClusterState, LocationSource }
import from resqmesh.contracts.models {
    AdaptationSnapshot, IncidentCluster, IncidentReport, LocationFix, RawSignal,
    SourceTrust, TraceEvent, evolve
}
import from resqmesh.contracts.ports { GeocodePort, LLMPort }
import from resqmesh.contracts.state { IncidentState }

"""Signals with no report yet. The supervisor's A1 predicate uses this too."""
def unprocessed_signals(state: IncidentState) -> list[RawSignal] {
    done = {r.signal_id for r in (state.reports or [])};
    return [s for s in (state.raw_signals or []) if s.signal_id not in done];
}

obj IngestAgent {
    has llm: LLMPort,
        gazetteer: GeocodePort,
        config: FusionConfig = FusionConfig();

    """One pass of A1: returns only A1's fields plus one trace event."""
    def run(state: IncidentState, now: datetime | None = None) -> dict[str, any] {
        at = now or datetime.now(UTC);
        pending = unprocessed_signals(state);

        new_reports: list[IncidentReport] = [];
        degraded: list[str] = [];
        for signal in pending {
            extracted = extract_report(signal, self.llm, self.gazetteer);
            new_reports.append(extracted[0]);
            failure = extracted[1];
            if failure {
                degraded.append(f"{signal.signal_id} ({failure})");
            }
        }

        everything = self.placed(
            [*(state.reports or []), *new_reports], list(state.location_fixes or [])
        );
        adaptation: AdaptationSnapshot = state.adaptation or AdaptationSnapshot();
        # The previous cluster set is what keeps ids stable: a group that still holds
        # a prior cluster's reports inherits its id rather than being renamed under
        # everything that already points at it.
        fused = fuse(
            everything, adaptation.source_trust, self.config,
            previous=list(state.clusters or [])
        );
        clusters = fused.clusters;
        unresolved = [r for r in everything if not r.is_located()];

        # Learn from what the evidence settled, then hand the updated posteriors back.
        # Recomputed from scratch over every report, so this is idempotent: the trust
        # that shaped these clusters is not double-counted by updating it.
        learned = recompute_trust(clusters, everything, adaptation.source_trust);

        update: dict[str, any] = {
            "reports": new_reports,
            "unresolved_queue": unresolved,
            "clusters": clusters,
            "trace": [
                IngestAgent.event(
                    at, len(new_reports), clusters, unresolved, degraded, learned,
                    fused.aliases
                )
            ]
        };
        if fused.aliases {
            update["cluster_aliases"] = fused.aliases;
        }
        if learned {
            update["adaptation"] = AdaptationSnapshot(source_trust=learned, updated_at=at);
        }
        return update;
    }

    """Apply operator placements to held reports, for this pass only.

    The stored report keeps the words and the emptiness it arrived with; the fix lives
    beside it. What fuses is the corrected copy, so a report an operator recognised
    finally enters the queue instead of sitting in a list nobody could act on. A fix
    that lands outside every division is ignored — the gazetteer whitelist is not
    negotiable, even for a human with a mouse.
    """
    def placed(reports: list[IncidentReport], fixes: list[LocationFix]) -> list[IncidentReport] {
        if not fixes {
            return reports;
        }
        latest: dict[str, LocationFix] = {f.report_id: f for f in fixes};
        out: list[IncidentReport] = [];
        for r in reports {
            fix = latest.get(r.report_id);
            if fix is None or r.is_located() {
                out.append(r);
                continue;
            }
            where = self.gazetteer.locate(fix.lat, fix.lon);
            if where.matched {
                out.append(
                    evolve(
                        r, lat=where.lat, lon=where.lon, resolved_gn_id=where.gn_id,
                        location_source=LocationSource.MAP_PIN
                    )
                );
            } else {
                out.append(r);
            }
        }
        return out;
    }

    static def event(
        now: datetime,
        n_new: int,
        clusters: list[IncidentCluster],
        unresolved: list[IncidentReport],
        degraded: list[str],
        learned: dict[str, SourceTrust] | None = None,
        aliases: dict[str, str] | None = None
    ) -> TraceEvent {
        states = {s: sum([1 for c in clusters if c.state == s]) for s in ClusterState};
        detail = (
            f"ingested {n_new} signal(s) -> {len(clusters)} cluster(s) "
            f"[{states[ClusterState.CORROBORATED]} corroborated, {states[ClusterState.SINGLE_SOURCE]} single-source, "
            f"{states[ClusterState.UNRESOLVED]} unresolved, {states[ClusterState.CONTRADICTED]} contradicted]; "
            f"{len(unresolved)} unlocated held"
        );
        if learned {
            worst = min(
                learned.values(),
                key=lambda (t: SourceTrust) -> float { return t.reliability(); }
            );
            detail += f" | source trust updated for {len(learned)} source(s), lowest now {worst.reliability():.2f}";
        }
        if aliases {
            merges = ", ".join([f"{old}->{new}" for (old, new) in sorted(aliases.items())]);
            detail += f" | merged {len(aliases)} cluster(s): {merges}";
        }
        if degraded {
            detail += f" | degraded extraction: {', '.join(degraded)}";
        }
        return TraceEvent(
            event_id=f"EV-{uuid.uuid4().hex[:12]}",
            agent="A1",
            action="signals_ingested",
            tier=ActionTier.TIER_A,
            detail=detail,
            occurred_at=now
        );
    }
}
