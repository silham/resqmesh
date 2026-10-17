"""A3: Triage and Prioritisation Agent.

Ranks every incident cluster into the demand queue A4 dispatches against.

State fields read: `clusters`, `reports` (A1), `hazard` (A2), `adaptation`
(learned weight nudges). State field written: `queue`, plus a `trace` event.

Failure path: with no hazard surface the location term is simply 0 for everyone
and the queue is still produced from the reported evidence: a ranking with less
information, stated in the trace, never an empty queue. A cluster whose member
reports are missing from state is scored on the cluster alone.
"""

import uuid;
import from datetime { datetime, UTC }
import from resqmesh.agents.triage.scorer { ClusterScore, HazardGeometry, rationale, score_cluster }
import from resqmesh.agents.triage.weights { resolve_weights }
import from resqmesh.contracts.enums { ActionTier }
import from resqmesh.contracts.models {
    AdaptationSnapshot, DamageObservation, HazardSurface, IncidentCluster, IncidentReport,
    PriorityItem, TraceEvent
}
import from resqmesh.contracts.state { IncidentState }

def _queue_order(pair: tuple[IncidentCluster, ClusterScore]) -> tuple[float, str] {
    return (-pair[1].score, pair[0].cluster_id);
}

"""Score, sort (score desc, cluster_id asc for determinism) and rank from 1.

`damage_for`, when given, maps a report id to the vision readings for that report.
"""
def rank_clusters(
    clusters: list[IncidentCluster],
    reports: list[IncidentReport],
    hazard: HazardSurface | None,
    adaptation: AdaptationSnapshot | None,
    now: datetime,
    damage_for: any = None
) -> list[PriorityItem] {
    weights = resolve_weights(adaptation);
    geometry = HazardGeometry.from_surface(hazard);
    by_id: dict[str, IncidentReport] = {r.report_id: r for r in reports};

    scored: list[tuple[IncidentCluster, ClusterScore]] = [];
    for cluster in clusters {
        members = [by_id[rid] for rid in cluster.member_report_ids if rid in by_id];
        damage: list[DamageObservation] = [];
        if damage_for is not None {
            for rid in cluster.member_report_ids {
                damage.extend(damage_for(rid));
            }
        }
        scored.append((cluster, score_cluster(cluster, members, geometry, weights, now, damage)));
    }

    scored.sort(key=_queue_order);
    queue: list[PriorityItem] = [];
    for (i, pair) in enumerate(scored) {
        rank = i + 1;
        (cluster, s) = pair;
        queue.append(
            PriorityItem(
                cluster_id=cluster.cluster_id,
                rank=rank,
                score_0_1=s.score,
                components=s.components,
                weights=dict(weights),
                rationale_text=rationale(rank, cluster, s, weights)
            )
        );
    }
    return queue;
}

obj TriageAgent {
    # Optional source of vision readings per report id (A1's DamageObservation):
    # a callable taking a report id and returning a list of DamageObservation.
    has damage_for: any = None;

    """Graph node: returns only `queue` plus one trace event."""
    def run(state: IncidentState, now: datetime | None = None) -> dict[str, any] {
        now = now or datetime.now(UTC);
        hazard = state.hazard;
        queue = rank_clusters(
            state.clusters or [],
            state.reports or [],
            hazard,
            state.adaptation,
            now,
            self.damage_for
        );
        top = ", ".join([f"{q.cluster_id}={q.score_0_1:.2f}" for q in queue[:3]]);
        detail = f"ranked {len(queue)} clusters; top: {top or 'none'}";
        if hazard is None {
            detail += " | no hazard surface: location term 0 for all";
        }
        event = TraceEvent(
            event_id=f"EV-{uuid.uuid4().hex[:12]}",
            agent="A3",
            action="queue_reranked",
            tier=ActionTier.TIER_A,
            detail=detail,
            occurred_at=now
        );
        return {"queue": queue, "trace": [event]};
    }
}
