"""Within-incident learning: which sources turned out to be right.

Proposal section 4.5: "When a report is subsequently corroborated by an independent
source or confirmed by a responder on scene, the success parameter increments; when
it is contradicted by confirmed ground truth, the failure parameter increments… A
source that has been wrong three times stops driving the queue."

Three rules keep this honest:

* **Only a decided cluster teaches anything.** Corroboration by independent
  sources, or a corroborated denial, is ground truth enough. A single-source or
  unresolved cluster teaches nothing: nobody has confirmed or denied it, and
  inventing a verdict there would just amplify whoever spoke first.
* **One cluster, one vote per source.** A caller who sends four messages about the
  same culvert earns the credit once, exactly as they only counted once toward its
  confidence.
* **Recomputed, never accumulated.** The posterior is the stored prior plus a fresh
  count over the whole evidence set, so running A1 again over the same reports
  changes nothing. An incrementing counter could not promise that, and this loop
  feeds its own input: trust raises confidence, which decides corroboration, which
  would raise trust again.
"""

import from resqmesh.agents.ingest.fusion { by_time, is_negating }
import from resqmesh.contracts.enums { ClusterState }
import from resqmesh.contracts.models { IncidentCluster, IncidentReport, SourceTrust }

"""Distinct sources that must agree before a cluster counts as settled."""
glob CORROBORATION_THRESHOLD: int = 2;

"""One report per source: their most recent word, as fusion counts it."""
def latest_by_source(members: list[IncidentReport]) -> dict[str, IncidentReport] {
    latest: dict[str, IncidentReport] = {};
    for r in sorted(members, key=by_time) {
        latest[r.source_id] = r;
    }
    return latest;
}

"""`source_id -> (times right, times wrong)` over the incident so far."""
def evidence_from(
    clusters: list[IncidentCluster], reports: list[IncidentReport]
) -> dict[str, tuple[int, int]] {
    by_id: dict[str, IncidentReport] = {r.report_id: r for r in reports};
    tally: dict[str, list[int]] = {};

    for cluster in clusters {
        members = [by_id[rid] for rid in cluster.member_report_ids if rid in by_id];
        if not members {
            continue;
        }
        latest = latest_by_source(members);
        affirming = {s for (s, r) in latest.items() if not is_negating(r)};
        negating = {s for (s, r) in latest.items() if is_negating(r)};

        # Which side, if either, is settled by independent agreement?
        right: set[str];
        wrong: set[str];
        if cluster.state == ClusterState.CORROBORATED and len(affirming) >= CORROBORATION_THRESHOLD {
            right = affirming;
            wrong = negating;
        } elif cluster.state == ClusterState.CONTRADICTED and len(negating) >= CORROBORATION_THRESHOLD {
            right = negating;
            wrong = affirming;
        } else {
            continue;  # single-source or unresolved: nobody has confirmed or denied it
        }

        for source in right {
            tally.setdefault(source, [0, 0])[0] += 1;
        }
        for source in wrong {
            tally.setdefault(source, [0, 0])[1] += 1;
        }
    }

    return {source: (counts[0], counts[1]) for (source, counts) in tally.items()};
}

"""Stored priors plus this incident's evidence. Pure, and safe to re-run.

Only sources with evidence are returned, so the merge reducer leaves every other
prior untouched.
"""
def recompute_trust(
    clusters: list[IncidentCluster],
    reports: list[IncidentReport],
    priors: dict[str, SourceTrust]
) -> dict[str, SourceTrust] {
    out: dict[str, SourceTrust] = {};
    for (source, counts) in evidence_from(clusters, reports).items() {
        prior = priors.get(source) or SourceTrust(source_id=source);
        out[source] = SourceTrust(
            source_id=source, alpha=prior.alpha + counts[0], beta=prior.beta + counts[1]
        );
    }
    return out;
}
