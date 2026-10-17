"""What the system has actually committed crews to, folded out of the audit log.

`state.commitments` is append-only: one record per status change, newest last. That
keeps a dispatch honest (a crew that was sent somewhere was sent there, whatever
happened next), but nothing reads the list directly. Everything here folds it to the
position now.

Two questions the rest of the system asks:

* Is this vehicle already committed? A4 may not reassign a crew that is on the road.
* Is this cluster served? Served is a question about evidence: the crew reported done,
  and nothing newer has come in since. A completion closes that emergency, not that
  location for the rest of the incident.
"""

import from datetime { datetime }
import from resqmesh.contracts.enums { CommitmentStatus, commitment_is_open }
import from resqmesh.contracts.models { Assignment, Commitment, evolve }
import from resqmesh.contracts.state { IncidentState, resolve_cluster_id }

"""Stable across plan versions, so re-releasing an unchanged assignment does not open
a second commitment, or reset a crew already reported en route."""
def commitment_id(assignment: Assignment) -> str {
    return f"CMT-{assignment.vehicle_id}-{assignment.cluster_id}";
}

"""Commitment id -> its most recent record. Later records win by list order."""
def latest(state: IncidentState) -> dict[str, Commitment] {
    out: dict[str, Commitment] = {};
    for record in state.commitments or [] {
        out[record.commitment_id] = record;
    }
    return out;
}

"""The cluster this commitment now refers to, following any merges since."""
def effective_cluster(state: IncidentState, record: Commitment) -> str {
    return resolve_cluster_id(state.cluster_aliases or {}, record.cluster_id());
}

def by_commitment_id(c: Commitment) -> str {
    return c.commitment_id;
}

"""Crews currently committed, in a stable order."""
def open_commitments(state: IncidentState) -> list[Commitment] {
    return sorted([c for c in latest(state).values() if commitment_is_open(c.status)], key=by_commitment_id);
}

"""Jobs a crew handed back, so A4 stops proposing the same pairing. A standing
constraint: the reason a crew declined does not stop being true on the next tick."""
def declined_commitments(state: IncidentState) -> list[Commitment] {
    return sorted([c for c in latest(state).values() if c.status == CommitmentStatus.DECLINED], key=by_commitment_id);
}

"""The open commitment for this crew and destination, if there is one. Matches through
the alias map, so a responder reporting against the cluster id they were dispatched to
still resolves after that cluster was absorbed by a merge."""
def find_open(state: IncidentState, vehicle_id: str, cluster_id: str) -> Commitment | None {
    target = resolve_cluster_id(state.cluster_aliases or {}, cluster_id);
    for record in open_commitments(state) {
        if record.vehicle_id() == vehicle_id and effective_cluster(state, record) == target {
            return record;
        }
    }
    return None;
}

"""Clusters a crew reported complete, and where nothing has happened since. A report
arriving after the crew stood down is new evidence, and the cluster returns to demand."""
def served_cluster_ids(state: IncidentState) -> list[str] {
    clusters = {c.cluster_id: c for c in state.clusters or []};
    observed = {r.report_id: r.observed_at for r in state.reports or []};
    served: set[str] = set();
    for record in latest(state).values() {
        if record.status != CommitmentStatus.COMPLETE or record.closed_at is None {
            continue;
        }
        cluster = clusters.get(effective_cluster(state, record));
        if cluster is None {
            continue;
        }
        times = [observed[rid] for rid in cluster.member_report_ids if rid in observed];
        newest: datetime | None = max(times) if times else None;
        if newest is None or newest <= record.closed_at {
            served.add(cluster.cluster_id);
        }
    }
    return sorted(served);
}

"""Open a commitment for each newly released assignment. One that already has an open
commitment is skipped: A4 carries committed crews into every later plan version, so
re-releasing them would reset a crew reported on scene back to released."""
def release_records(
    state: IncidentState, assignments: list[Assignment], plan_id: str, plan_version: int, now: datetime
) -> list[Commitment] {
    already = {c.commitment_id for c in open_commitments(state)};
    return [
        Commitment(
            commitment_id=commitment_id(a), plan_id=plan_id, plan_version=plan_version,
            assignment=a, status=CommitmentStatus.RELEASED, released_at=now
        )
        for a in assignments
        if commitment_id(a) not in already
    ];
}

"""A new record advancing one commitment. The old one stays in the log."""
def close(record: Commitment, status: CommitmentStatus, now: datetime, note: str | None = None) -> Commitment {
    return evolve(record, status=status, closed_at=None if commitment_is_open(status) else now, note=note);
}
