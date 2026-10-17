"""A3 triage: decomposition, determinism, fairness, and ranking behaviour.

No LLM, no network. Every assertion is about the explicit weighted model.
"""

import json;
import from datetime { datetime, timedelta, UTC }
import from shapely.geometry { box }
import from resqmesh.adapters.geo.shapes { collection_from_geometry, empty_collection }
import from resqmesh.agents.triage.agent { TriageAgent, rank_clusters }
import from resqmesh.agents.triage.weights { DEFAULT_WEIGHTS, resolve_weights }
import from resqmesh.agents.triage.scorer { vulnerability, weighted_sum }
import from resqmesh.contracts.enums { ClusterState, HazardMethod, HazardType, VulnerabilityFlag }
import from resqmesh.contracts.models {
    AdaptationSnapshot, DamageObservation, HazardSurface, IncidentCluster, IncidentReport,
    PriorityItem, ScoreComponents, SCORE_COMPONENTS, to_json
}
import from resqmesh.contracts.state { IncidentState }

glob NOW: datetime = datetime(2016, 5, 17, 6, 0, tzinfo=UTC);
glob WET: tuple[float, float] = (6.94, 79.90);  # inside the fixture flood polygon
glob DRY: tuple[float, float] = (6.99, 80.10);

def make_hazard(rain: float = 180.0) -> HazardSurface {
    return HazardSurface(
        surface_id="HS-1", version=1, generated_at=NOW, method=HazardMethod.HAND, confidence_0_1=0.75,
        inundation_geojson=collection_from_geometry(box(79.88, 6.92, 79.92, 6.96)),
        susceptibility_geojson=empty_collection(), driving_rainfall_mm_24h=rain
    );
}

def make_report(rid: str, **kw: any) -> IncidentReport {
    base: dict[str, any] = {
        "report_id": rid, "signal_id": f"S-{rid}", "source_id": "src-a", "hazard_type": HazardType.FLOOD,
        "description": "water rising", "raw_place_text": "Kolonnawa", "resolved_gn_id": "GN-1",
        "lat": WET[0], "lon": WET[1], "severity_claim": 3, "reported_people_affected": 10,
        "observed_at": NOW - timedelta(hours=1)
    };
    base.update(kw);
    return IncidentReport(**base);
}

def make_cluster(cid: str, rids: list[str], at: tuple[float, float] = WET, **kw: any) -> IncidentCluster {
    base: dict[str, any] = {
        "cluster_id": cid, "member_report_ids": rids, "centroid_lat": at[0], "centroid_lon": at[1],
        "gn_id": "GN-1", "hazard_type": HazardType.FLOOD, "confidence_0_1": 0.8,
        "state": ClusterState.CORROBORATED, "corroborating_source_count": 2,
        "first_seen": NOW - timedelta(hours=1), "last_seen": NOW
    };
    base.update(kw);
    return IncidentCluster(**base);
}

def rank(clusters: list[IncidentCluster], reports: list[IncidentReport]) -> list[PriorityItem] {
    return rank_clusters(clusters, reports, make_hazard(), None, NOW);
}

def approx(a: float, b: float, tol: float = 1e-6) -> bool {
    return abs(a - b) <= tol;
}

# --------------------------------------------------------------------------- #
# Weights
# --------------------------------------------------------------------------- #

test "default weights cover exactly the components and sum to one" {
    assert set(DEFAULT_WEIGHTS.keys()) == set(SCORE_COMPONENTS);
    assert approx(sum(resolve_weights().values()), 1.0, 1e-5);
}

test "learned nudges are applied clamped and renormalised" {
    snap = AdaptationSnapshot(
        triage_weights={"vulnerability": 0.10, "cluster_confidence": -5.0, "bogus": 9.0}
    );
    w = resolve_weights(snap);
    assert approx(sum(w.values()), 1.0, 1e-5);
    assert w["vulnerability"] > resolve_weights()["vulnerability"];
    assert w["cluster_confidence"] > 0;  # clamped, never learned to zero
    assert "bogus" not in w;
}

# --------------------------------------------------------------------------- #
# Decomposition and determinism
# --------------------------------------------------------------------------- #

test "score is exactly the weighted sum of its components" {
    q = rank([make_cluster("C1", ["R1"])], [make_report("R1")]);
    item = q[0];
    assert approx(item.score_0_1, weighted_sum(item.components, item.weights));
    assert 0.0 <= item.score_0_1 <= 1.0;
}

test "same input same queue" {
    clusters = [make_cluster(f"C{i}", [f"R{i}"]) for i in range(5)];
    reports = [make_report(f"R{i}", reported_people_affected=i * 7) for i in range(5)];
    forward = to_json(rank(clusters, reports));
    backward = to_json(rank(list(reversed(clusters)), list(reversed(reports))));
    assert forward == backward;
}

test "ranks are contiguous and sorted with stable ties" {
    clusters = [
        make_cluster("C-b", ["R1"]), make_cluster("C-a", ["R2"]), make_cluster("C-c", ["R3"], at=DRY)
    ];
    reports = [make_report("R1"), make_report("R2"), make_report("R3")];
    q = rank(clusters, reports);
    assert [i.rank for i in q] == [1, 2, 3];
    assert [i.score_0_1 for i in q] == sorted([i.score_0_1 for i in q], reverse=True);
    assert [i.cluster_id for i in q[:2]] == ["C-a", "C-b"];  # identical scores: id order
}

test "rationale names the drivers and the evidence" {
    q = rank(
        [make_cluster("C1", ["R1"])],
        [make_report("R1", vulnerability_flags=[VulnerabilityFlag.MEDICAL_DEPENDENCY])]
    );
    text = q[0].rationale_text;
    assert text.startswith("#1 flood at GN-1");
    assert "inside modelled flood extent" in text and "10 people reported" in text;
    assert "medical dependency" in text;
}

# --------------------------------------------------------------------------- #
# Behaviour
# --------------------------------------------------------------------------- #

test "inside the flood outranks outside" {
    q = rank(
        [make_cluster("DRY", ["R1"], at=DRY), make_cluster("WET", ["R2"])],
        [make_report("R1"), make_report("R2")]
    );
    assert q[0].cluster_id == "WET";
    assert q[0].components.hazard_severity > q[1].components.hazard_severity;
}

test "medical dependency outranks the same incident without it" {
    q = rank(
        [make_cluster("PLAIN", ["R1"]), make_cluster("NEEDS", ["R2"])],
        [make_report("R1"), make_report("R2", vulnerability_flags=[VulnerabilityFlag.MEDICAL_DEPENDENCY])]
    );
    assert q[0].cluster_id == "NEEDS";
}

test "unresolved evidence is damped" {
    q = rank(
        [make_cluster("SURE", ["R1"]), make_cluster("DISPUTED", ["R2"], state=ClusterState.UNRESOLVED)],
        [make_report("R1"), make_report("R2")]
    );
    assert q[0].cluster_id == "SURE";
    assert approx(q[1].components.cluster_confidence, 0.8 * 0.5);
}

test "duplicate reports do not inflate exposure" {
    one = rank([make_cluster("C", ["R1"])], [make_report("R1", reported_people_affected=20)]);
    dup = rank(
        [make_cluster("C", ["R1", "R2"])],
        [make_report("R1", reported_people_affected=20), make_report("R2", reported_people_affected=20)]
    );
    assert one[0].components.population_exposure == dup[0].components.population_exposure;
}

test "waiting demand escalates but is capped" {
    fresh = rank([make_cluster("C", ["R1"], first_seen=NOW)], [make_report("R1")])[0];
    stale = rank(
        [make_cluster("C", ["R1"], first_seen=NOW - timedelta(hours=48))], [make_report("R1")]
    )[0];
    assert approx(stale.components.time_criticality - fresh.components.time_criticality, 0.15);
}

test "photo contributes but is bounded" {
    cluster = make_cluster("C", ["R1"], at=DRY);
    rep = make_report("R1", severity_claim=0);
    without = rank_clusters([cluster], [rep], make_hazard(), None, NOW)[0];
    worst = DamageObservation(report_id="R1", severity_0_4=4, model_confidence=0.9);
    withp = rank_clusters(
        [cluster], [rep], make_hazard(), None, NOW,
        lambda (rid: str) -> list[DamageObservation] { return [worst]; }
    )[0];
    gain = withp.components.hazard_severity - without.components.hazard_severity;
    assert 0 < gain <= 0.15 + 1e-9;  # vision's share of the blend, at most
}

test "no hazard surface still produces a queue" {
    state = IncidentState(clusters=[make_cluster("C", ["R1"])], reports=[make_report("R1")]);
    out = TriageAgent().run(state, now=NOW);
    assert len(out["queue"]) == 1;
    assert out["queue"][0].components.hazard_severity < 1.0;
    assert "no hazard surface" in out["trace"][0].detail;
}

test "missing member reports degrade gracefully" {
    q = rank([make_cluster("C", ["GONE"])], []);
    assert approx(q[0].components.population_exposure, 0.25);
}

# --------------------------------------------------------------------------- #
# Fairness: functional need only (proposal section 10.4)
# --------------------------------------------------------------------------- #

test "vulnerability ignores anything outside the whitelist" {
    base = vulnerability([VulnerabilityFlag.ELDERLY])[0];
    polluted = vulnerability(
        [VulnerabilityFlag.ELDERLY, "religion", "ethnicity:x", "language_ta", 42]
    )[0];
    assert polluted == base;
}

test "contracts refuse non functional flags at the boundary" {
    with testraises(ValueError) {
        make_report("R1", vulnerability_flags=["religion"]);
    }
}

test "proxy fields cannot move a score" {
    proxies: list[dict[str, any]] = [
        {"description": "Tamil-speaking family near the kovil"},
        {"raw_place_text": "near the mosque, Kolonnawa"},
        {"source_id": "a-completely-different-reporter"}
    ];
    for proxy in proxies {
        before = rank([make_cluster("C", ["R1"])], [make_report("R1")]);
        after = rank([make_cluster("C", ["R1"])], [make_report("R1", **proxy)]);
        assert to_json(before[0].components) == to_json(after[0].components);
        assert before[0].score_0_1 == after[0].score_0_1;
    }
}

test "priority item round trips through its contract" {
    item = rank([make_cluster("C", ["R1"])], [make_report("R1")])[0];
    wire: dict[str, any] = json.loads(json.dumps(to_json(item)));
    wire.pop("schema_version");
    comps: dict[str, any] = wire.pop("components");
    comps.pop("schema_version");
    rebuilt = PriorityItem(**{**wire, "components": ScoreComponents(**comps)});
    assert to_json(rebuilt) == to_json(item);
}

# --------------------------------------------------------------------------- #
# Rationale text: exact template
# --------------------------------------------------------------------------- #

test "rationale text is the exact deterministic template" {
    reports = [
        make_report(
            "R1", severity_claim=2, reported_people_affected=12,
            vulnerability_flags=[VulnerabilityFlag.ELDERLY, VulnerabilityFlag.CHILDREN_PRESENT]
        )
    ];
    cluster = make_cluster(
        "C1", ["R1"], at=DRY, gn_id="KLN-003", confidence_0_1=0.78, corroborating_source_count=3,
        first_seen=NOW - timedelta(minutes=40)
    );
    hz = make_hazard(rain=137.0);
    item = rank_clusters([cluster], reports, hz, None, NOW)[0];
    assert item.rationale_text == (
        "#1 flood at KLN-003, score 0.51, driven by time criticality 0.77x0.20 and "
        "evidence confidence 0.78x0.15. reported severity 2/4; 12 people reported; "
        "needs: children present, elderly; heavy rain (137 mm/24 h); "
        "confidence 0.78 (corroborated, 3 sources)."
    );
}
