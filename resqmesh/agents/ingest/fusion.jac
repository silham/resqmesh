"""Spatio-temporal clustering and trust-weighted confidence.

Two failures from proposal section 2.1 are handled here:

* **Fragmentation** — the same collapsed culvert logged four times as four
  incidents. Reports close in space and time with the same hazard type collapse
  into one cluster.
* **Contradiction** — one caller says the road is passable, another says it is
  gone. Disagreement is *modelled*, not averaged away: a cluster carries both sides
  of the evidence and says `UNRESOLVED` when they genuinely balance.

Everything here is deterministic and explainable. There is no model in this file.

Clustering is complete-linkage agglomeration within one hazard type and one GN
division: two reports can share a cluster only when every pair in it lies within
`eps_km` and falls within `window_hours` of each other.
"""

import math;
import numpy as np;
import from collections { Counter }
import from datetime { datetime, timedelta }
import from scipy.cluster.hierarchy { fcluster, linkage }
import from resqmesh.contracts.enums { ClusterState }
import from resqmesh.contracts.models { IncidentCluster, IncidentReport, SourceTrust }

obj FusionConfig {
    # Neighbourhood radius. 1.5 km keeps two streets together and keeps a distinct
    # emergency "two kilometres away" (proposal section 2.1) apart.
    has eps_km: float = 1.5,
        window_hours: float = 6.0,
        # How much one source's reliability counts as evidence. Calibrated so a lone
        # source with no history (reliability 0.5) scores 0.40 — below the 0.50 Tier C
        # floor — while two independent unknown sources clear it at 0.64.
        evidence_weight: float = 0.8,
        # Affirming and negating evidence closer than this is a genuine stand-off.
        unresolved_margin: float = 0.2,
        # Prior for a source we have never heard from: Beta(1, 1), mean 0.5.
        default_trust: SourceTrust = SourceTrust(source_id="*");
}

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    r = 6371.0088;
    p1 = math.radians(lat1);
    p2 = math.radians(lat2);
    dp = p2 - p1;
    dl = math.radians(lon2 - lon1);
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2;
    return 2 * r * math.asin(math.sqrt(a));
}

"""A report that says the hazard is *not* there — "road passable", "water receded".

Severity zero is the extraction schema's way of saying it.
"""
def is_negating(r: IncidentReport) -> bool {
    return r.severity_claim == 0;
}

"""The canonical evidence order: when it happened, then report id as a tie-break."""
def by_time(r: IncidentReport) -> tuple[datetime, str] {
    return (r.observed_at, r.report_id);
}

"""A value that only located reports reach. Their location is guaranteed present."""
def present(value: any) -> any {
    assert value is not None;
    return value;
}

# --------------------------------------------------------------------------- #
# Clustering
# --------------------------------------------------------------------------- #

"""Distance standing in for "these two can never be in one cluster". Large enough
that complete linkage will never merge across it at any sane eps_km."""
glob UNMERGEABLE_KM: float = 1.0e6;

"""Condensed distance matrix in km, with out-of-window pairs made unmergeable."""
def pairwise(members: list[IncidentReport], cfg: FusionConfig) -> any {
    window = timedelta(hours=cfg.window_hours);
    out: list[float] = [];
    for i in range(len(members)) {
        for j in range(i + 1, len(members)) {
            a = members[i];
            b = members[j];
            if abs(a.observed_at - b.observed_at) > window {
                out.append(UNMERGEABLE_KM);
            } else {
                out.append(haversine_km(present(a.lat), present(a.lon), present(b.lat), present(b.lon)));
            }
        }
    }
    return np.array(out, dtype=float);
}

"""Split one division's reports so that *every* pair in a cluster is within eps.

Single linkage — plain connected components of the "close enough" relation — lets
clusters chain: A near B, B near C, C near D, and a cluster forms whose ends are
nowhere near each other. With reports strung along a flooded river, which is the
shape real flood reports take, twelve separate emergencies 1.2 km apart collapse
into one cluster spanning 13 km, with a centroid 6.5 km from either end and a single
vehicle sent to it. That is the exact failure the proposal promises to prevent —
"a genuinely distinct emergency two kilometres away is missed entirely".

Complete linkage bounds the cluster's own diameter instead of the gap between
neighbours, so the chain cannot form.
"""
def complete_linkage(members: list[IncidentReport], cfg: FusionConfig) -> list[list[IncidentReport]] {
    if len(members) < 2 {
        return [members];
    }
    tree: any = linkage(pairwise(members, cfg), method="complete");
    labels: any = fcluster(tree, t=cfg.eps_km, criterion="distance");
    grouped: dict[int, list[IncidentReport]] = {};
    for i in range(len(members)) {
        grouped.setdefault(int(labels[i]), []).append(members[i]);
    }
    return [grouped[k] for k in sorted(grouped)];
}

"""Located reports -> groups. One hazard type and one GN division per group.

Requiring a single division is a deliberate second bound on cluster size. It costs
the case of one emergency straddling a boundary, which then reads as two; it buys a
cluster that can be named, alerted and reported at the granularity the DMC actually
works in, and a centroid that means something.

Output order and membership depend only on the reports, never on arrival order, so
re-running over the same evidence always gives the same groups.
"""
def group_reports(reports: list[IncidentReport], cfg: FusionConfig) -> list[list[IncidentReport]] {
    located = sorted([r for r in reports if r.is_located()], key=by_time);
    by_place: dict[tuple[str, str], list[IncidentReport]] = {};
    for r in located {
        by_place.setdefault((r.hazard_type.value, str(r.resolved_gn_id)), []).append(r);
    }

    groups: list[list[IncidentReport]] = [];
    for key in sorted(by_place) {
        groups.extend(complete_linkage(by_place[key], cfg));
    }
    groups.sort(key=lambda (g: list[IncidentReport]) -> tuple[datetime, str] { return by_time(g[0]); });
    return groups;
}

# --------------------------------------------------------------------------- #
# Confidence
# --------------------------------------------------------------------------- #

obj Evidence {
    has affirm: float,
        negate: float,
        affirming_sources: int,
        negating_sources: int;

    def confidence -> float {
        return self.affirm * (1.0 - self.negate);
    }
}

"""P(at least one independent source is right), each discounted by `weight`."""
def noisy_or(reliabilities: list[float], weight: float) -> float {
    miss = 1.0;
    for p in reliabilities {
        miss *= 1.0 - weight * p;
    }
    return 1.0 - miss;
}

"""Trust-weighted evidence for and against a cluster.

Two rules keep this honest:

* **One vote per source.** The same caller reporting the same culvert four times is
  one piece of evidence, not four. Repetition is not corroboration.
* **A source's latest word wins.** A caller who said "flooded" and later "it's
  receded" is counted once, on the side of their most recent report.
"""
def weigh_evidence(
    members: list[IncidentReport], trust: dict[str, SourceTrust], cfg: FusionConfig
) -> Evidence {
    latest: dict[str, IncidentReport] = {};
    for r in sorted(members, key=by_time) {
        latest[r.source_id] = r;
    }

    def reliability(source_id: str) -> float {
        return trust.get(source_id, cfg.default_trust).reliability();
    }

    affirming = [reliability(s) for (s, r) in latest.items() if not is_negating(r)];
    negating = [reliability(s) for (s, r) in latest.items() if is_negating(r)];
    return Evidence(
        affirm=noisy_or(affirming, cfg.evidence_weight),
        negate=noisy_or(negating, cfg.evidence_weight),
        affirming_sources=len(affirming),
        negating_sources=len(negating)
    );
}

"""Name the fusion outcome. `UNRESOLVED` is an answer, not a failure."""
def classify(ev: Evidence, cfg: FusionConfig) -> ClusterState {
    if ev.affirming_sources and ev.negating_sources {
        if abs(ev.affirm - ev.negate) < cfg.unresolved_margin {
            return ClusterState.UNRESOLVED;
        }
        if ev.negate > ev.affirm {
            return ClusterState.CONTRADICTED;
        }
    }
    if ev.affirming_sources == 0 {
        return ClusterState.CONTRADICTED;
    }
    return ClusterState.CORROBORATED if ev.affirming_sources >= 2 else ClusterState.SINGLE_SOURCE;
}

# --------------------------------------------------------------------------- #
# Identity
# --------------------------------------------------------------------------- #

"""Format of new cluster ids. Deliberately not derived from any member report:
keying on the earliest member meant a report that arrived late but happened earlier
— a Telegram message queued through an outage, whose true timestamp this system
preserves on purpose — silently renamed the cluster, and every approval, completion
and commander constraint pointing at the old id dangled."""
glob CLUSTER_ID_FORMAT: str = "CL-{:04d}";

def id_suffix(cluster_id: str) -> int {
    tail = cluster_id.rsplit("-", 1)[-1];
    return int(tail) if tail.isdigit() else 0;
}

"""Carry cluster ids across a re-fuse by continuity of membership.

Returns the id for each group, the ids each group absorbed, and the alias map from
absorbed id to survivor.

Each previous cluster is claimed by whichever group now holds most of its reports,
so a prior can be inherited by exactly one group — that is what makes a *split*
well defined. A group that claims several priors is a *merge*: it keeps the largest
prior's id and aliases the rest onto it. A group claiming none is genuinely new and
takes a fresh number.
"""
def assign_ids(
    groups: list[list[IncidentReport]], previous: list[IncidentCluster]
) -> tuple[list[str], list[list[str]], dict[str, str]] {
    prior_members: dict[str, set[str]] = {c.cluster_id: set(c.member_report_ids) for c in previous};
    prior_by_id: dict[str, IncidentCluster] = {c.cluster_id: c for c in previous};
    group_ids: list[set[str]] = [{r.report_id for r in g} for g in groups];

    owned: dict[int, list[str]] = {};
    for (pid, members) in prior_members.items() {
        # Most overlap wins; ties go to the earliest group, so the result does not
        # depend on dictionary order.
        best_overlap = 0;
        best_index = 0;
        if groups {
            scored = [(len(members & group_ids[i]), -i) for i in range(len(groups))];
            top = max(scored);
            best_overlap = top[0];
            best_index = -top[1];
        }
        if best_overlap > 0 {
            owned.setdefault(best_index, []).append(pid);
        }
    }

    next_n = 1 + max([id_suffix(c.cluster_id) for c in previous], `default=0);
    ids: list[str] = [];
    absorbed: list[list[str]] = [];
    aliases: dict[str, str] = {};

    def claim_order(pid: str) -> tuple[int, datetime, str] {
        return (-len(prior_members[pid]), prior_by_id[pid].first_seen, pid);
    }

    for i in range(len(groups)) {
        claims = sorted(owned.get(i, []), key=claim_order);
        if not claims {
            ids.append(CLUSTER_ID_FORMAT.format(next_n));
            absorbed.append([]);
            next_n += 1;
            continue;
        }
        keep = claims[0];
        rest = claims[1:];
        ids.append(keep);
        # Carry the survivor's own merge history forward, so the record of what was
        # absorbed does not reset every time A1 recomputes.
        absorbed.append(sorted(set(rest) | set(prior_by_id[keep].merged_from)));
        for pid in rest {
            aliases[pid] = keep;
        }
    }
    return (ids, absorbed, aliases);
}

def build_cluster(
    members: list[IncidentReport],
    trust: dict[str, SourceTrust],
    cfg: FusionConfig,
    cluster_id: str | None = None,
    merged_from: list[str] | None = None
) -> IncidentCluster {
    ordered = sorted(members, key=by_time);
    first = ordered[0];
    ev = weigh_evidence(ordered, trust, cfg);

    # The GN division most members resolved to; ties go to the earliest report.
    counts = Counter([r.resolved_gn_id for r in ordered]);
    top = max(counts.values());
    gn_id = next(iter([r.resolved_gn_id for r in ordered if counts[r.resolved_gn_id] == top]));

    lats = [r.lat for r in ordered if r.lat is not None];
    lons = [r.lon for r in ordered if r.lon is not None];
    return IncidentCluster(
        cluster_id=cluster_id or f"CL-{first.report_id}",
        merged_from=list(merged_from or []),
        member_report_ids=[r.report_id for r in ordered],
        centroid_lat=sum(lats) / len(lats),
        centroid_lon=sum(lons) / len(lons),
        gn_id=present(gn_id),
        hazard_type=first.hazard_type,
        confidence_0_1=round(ev.confidence(), 4),
        state=classify(ev, cfg),
        contradiction_flag=ev.affirming_sources > 0 and ev.negating_sources > 0,
        corroborating_source_count=ev.affirming_sources,
        first_seen=first.observed_at,
        last_seen=ordered[-1].observed_at
    );
}

"""The cluster set, plus what changed identity getting there."""
obj FusionResult {
    has clusters: list[IncidentCluster],
        # Absorbed cluster id -> the cluster that survived. Merged into state so an
        # approval or completion naming a superseded id still resolves.
        aliases: dict[str, str];
}

"""All located reports -> the current cluster set. Recomputed whole each time.

`previous` is the cluster set from the last run. Passing it is what keeps ids stable
across re-fuses; omitting it is only correct for a first run or a one-shot scoring
pass, and produces fresh ids every time.
"""
def fuse(
    reports: list[IncidentReport],
    trust: dict[str, SourceTrust],
    cfg: FusionConfig | None = None,
    previous: list[IncidentCluster] | None = None
) -> FusionResult {
    config = cfg or FusionConfig();
    groups = group_reports(reports, config);
    assigned = assign_ids(groups, list(previous or []));
    ids = assigned[0];
    absorbed = assigned[1];
    clusters = [
        build_cluster(groups[i], trust, config, cluster_id=ids[i], merged_from=absorbed[i])
        for i in range(len(groups))
    ];
    return FusionResult(clusters=clusters, aliases=assigned[2]);
}
