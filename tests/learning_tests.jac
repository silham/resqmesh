"""Within-incident learning: who turned out to be right, and what that changes."""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.adapters.fakes { FakeGazetteer, StubLLM }
import from resqmesh.agents.ingest.agent { IngestAgent }
import from resqmesh.agents.ingest.fusion { fuse }
import from resqmesh.agents.ingest.learning { evidence_from, recompute_trust }
import from resqmesh.contracts.enums { ClusterState, HazardType, SourceChannel }
import from resqmesh.contracts.models {
    AdaptationSnapshot, IncidentCluster, IncidentReport, RawSignal, SourceTrust, to_json
}
import from resqmesh.contracts.state { IncidentState }

glob T0: datetime = datetime(2026, 9, 23, 6, 0, tzinfo=UTC);

# Three places far enough apart to stay separate clusters.
glob PLACES: dict[str, tuple[str, float, float]] = {
    "A": ("KLN-001", 6.9497, 79.9853),
    "B": ("KLN-002", 6.9339, 79.9836),
    "C": ("KLN-005", 6.9544, 80.2097)
};

# fuse() returns a FusionResult (clusters + the id aliases a merge produced). These
# tests are about the clusters, so unwrap once here.
def clusters_of(
    reports: list[IncidentReport], trust: dict[str, SourceTrust]
) -> list[IncidentCluster] {
    return fuse(reports, trust).clusters;
}

def rep(n: int, source: str, place: str = "A", severity: int = 3, minutes: float = 0) -> IncidentReport {
    spot = PLACES[place];
    return IncidentReport(
        report_id=f"R{n}", signal_id=f"S{n}", source_id=source, hazard_type=HazardType.FLOOD,
        description="x", raw_place_text=place, resolved_gn_id=spot[0], lat=spot[1], lon=spot[2],
        severity_claim=severity, observed_at=T0 + timedelta(minutes=minutes)
    );
}

def learn(
    reports: list[IncidentReport], priors: dict[str, SourceTrust] | None = None
) -> dict[str, SourceTrust] {
    known = priors or {};
    return recompute_trust(clusters_of(reports, known), reports, known);
}

def sig(n: int, body: str, source: str, minutes: float = 0) -> RawSignal {
    return RawSignal(
        signal_id=f"S{n}", channel=SourceChannel.TELEGRAM, source_id=source, body=body,
        received_at=T0 + timedelta(minutes=minutes)
    );
}

# --------------------------------------------------------------------------- #
# What counts as evidence
# --------------------------------------------------------------------------- #

test "independent corroboration credits both sources" {
    trust = learn([rep(1, "alice"), rep(2, "bob", minutes=5)]);
    assert trust["alice"].alpha == 2.0 and trust["alice"].beta == 1.0;  # Beta(1,1) prior + one success
    assert trust["bob"].reliability() > 0.5;
}

test "a lone report teaches nothing" {
    # Nobody has confirmed or denied it. Inventing a verdict would just amplify
    # whoever spoke first.
    assert learn([rep(1, "alice")]) == {};
}

test "a balanced contradiction teaches nothing" {
    # One says flooded, one says clear, and the system says it does not know.
    reports = [rep(1, "alice"), rep(2, "bob", severity=0, minutes=5)];
    assert clusters_of(reports, {})[0].state == ClusterState.UNRESOLVED;
    assert learn(reports) == {};
}

test "a corroborated denial settles it the other way" {
    # Two independent sources say the road is clear; the one who said otherwise is
    # marked wrong.
    reports = [
        rep(1, "alice"), rep(2, "bob", severity=0, minutes=5),
        rep(3, "carol", severity=0, minutes=8)
    ];
    cluster = clusters_of(reports, {})[0];
    assert cluster.state == ClusterState.CONTRADICTED;
    trust = recompute_trust([cluster], reports, {});
    assert trust["bob"].alpha == 2.0 and trust["carol"].alpha == 2.0;
    assert trust["alice"].beta == 2.0 and trust["alice"].reliability() < 0.5;
}

test "repetition earns credit once" {
    # Four messages from one caller about one culvert is one vote, exactly as it was
    # one vote toward the cluster's confidence.
    spam = [rep(i, "alice", minutes=i) for i in range(4)];
    trust = learn([*spam, rep(9, "bob", minutes=6)]);
    assert trust["alice"].alpha == 2.0;
}

test "evidence is counted per cluster" {
    # Being right in three separate places counts three times.
    reports: list[IncidentReport] = [];
    for (i, place) in enumerate(["A", "B", "C"]) {
        reports.append(rep(2 * i + 1, "alice", place));
        reports.append(rep(2 * i + 2, "bob", place, minutes=5));
    }
    assert evidence_from(clusters_of(reports, {}), reports)["alice"] == (3, 0);
}

# --------------------------------------------------------------------------- #
# The proposal's claim, tested directly
# --------------------------------------------------------------------------- #

test "a source wrong three times stops driving the queue" {
    # Proposal section 4.5. A reporter who is contradicted by corroborated ground
    # truth in three separate places ends up unable to raise a cluster on their own.
    reports: list[IncidentReport] = [];
    n = 0;
    for place in ["A", "B", "C"] {
        reports.append(rep(n + 1, "liar", place));
        reports.append(rep(n + 2, "x", place, severity=0, minutes=5));
        reports.append(rep(n + 3, "y", place, severity=0, minutes=8));
        n += 3;
    }
    trust = learn(reports);

    assert trust["liar"].beta == 4.0;  # Beta(1,1) prior + three failures
    assert trust["liar"].reliability() < 0.25;

    # Their word alone now sits well below the 0.50 Tier C dispatch floor.
    alone = clusters_of([rep(99, "liar", "A")], trust)[0];
    assert alone.confidence_0_1 < 0.25;
    assert alone.state == ClusterState.SINGLE_SOURCE;
}

test "a reliable source is believed sooner" {
    trusted = {"vet": SourceTrust(source_id="vet", alpha=9.0, beta=1.0)};
    assert clusters_of([rep(1, "vet")], trusted)[0].confidence_0_1 > clusters_of([rep(1, "new")], {})[0].confidence_0_1;
}

# --------------------------------------------------------------------------- #
# Safety of the loop: learning feeds its own input
# --------------------------------------------------------------------------- #

test "learning is idempotent" {
    # Trust raises confidence, which decides corroboration, which would raise trust
    # again. Recomputing from the whole evidence set stops that runaway.
    reports = [rep(1, "alice"), rep(2, "bob", minutes=5)];
    once = learn(reports);
    twice = recompute_trust(clusters_of(reports, once), reports, {});
    assert to_json(once) == to_json(twice);
}

test "priors are added to not replaced" {
    priors = {"alice": SourceTrust(source_id="alice", alpha=5.0, beta=2.0)};
    trust = recompute_trust(
        clusters_of([rep(1, "alice"), rep(2, "bob", minutes=5)], priors),
        [rep(1, "alice"), rep(2, "bob", minutes=5)], priors
    );
    assert trust["alice"].alpha == 6.0 and trust["alice"].beta == 2.0;
}

test "sources without evidence are left alone" {
    # Only changed sources are returned, so the merge reducer preserves the rest.
    priors = {"absent": SourceTrust(source_id="absent", alpha=3.0, beta=1.0)};
    assert "absent" not in learn([rep(1, "alice"), rep(2, "bob", minutes=5)], priors);
}

# --------------------------------------------------------------------------- #
# Through the agent
# --------------------------------------------------------------------------- #

test "the agent publishes what it learned" {
    agent = IngestAgent(StubLLM(), FakeGazetteer());
    out = agent.run(
        IncidentState(
            raw_signals=[
                sig(1, "Flooding in Kolonnawa", "alice"), sig(2, "Water rising at Kolonnawa", "bob", 5)
            ],
            reports=[], adaptation=AdaptationSnapshot()
        ),
        now=T0
    );
    assert set(out["adaptation"].source_trust) == {"alice", "bob"};
    assert "source trust updated for 2 source(s)" in out["trace"][0].detail;
}

test "the agent measures against the baseline not its own output" {
    # Feeding A1 its own posterior would count the same corroboration twice, and trust
    # would climb on every tick. The runner re-asserts the baseline each invocation;
    # given the same baseline, the answer is stable.
    agent = IngestAgent(StubLLM(), FakeGazetteer());
    signals = [sig(1, "Flooding in Kolonnawa", "alice"), sig(2, "Water rising at Kolonnawa", "bob", 5)];
    baseline = AdaptationSnapshot();
    first = agent.run(IncidentState(raw_signals=signals, reports=[], adaptation=baseline), now=T0);
    second = agent.run(
        IncidentState(raw_signals=signals, reports=first["reports"], adaptation=baseline), now=T0
    );
    assert to_json(second["adaptation"].source_trust) == to_json(first["adaptation"].source_trust);

    # And the failure this guards against, shown explicitly:
    fed_back = agent.run(
        IncidentState(raw_signals=signals, reports=first["reports"], adaptation=first["adaptation"]),
        now=T0
    );
    assert fed_back["adaptation"].source_trust["alice"].alpha > first["adaptation"].source_trust["alice"].alpha;
}

test "undecided clusters never teach" {
    for undecided in [ClusterState.SINGLE_SOURCE, ClusterState.UNRESOLVED] {
        assert all([c.state != undecided or not evidence_from([c], []) for c in clusters_of([rep(1, "alice")], {})]);
    }
}
