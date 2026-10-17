"""A1 — Signal Ingest and Verification.

No model, no network, no geospatial stack beyond scipy's linkage: these run
everywhere.
"""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.adapters.fakes { FakeGazetteer, StubLLM }
import from resqmesh.agents.ingest.agent { IngestAgent, unprocessed_signals }
import from resqmesh.agents.ingest.extraction { ExtractedReport, VisionReading, SchemaValidationError, extract_report }
import from resqmesh.agents.ingest.fusion {
    Evidence, FusionConfig, assign_ids, build_cluster, classify, fuse, haversine_km, present,
    weigh_evidence
}
import from resqmesh.agents.ingest.redact { pseudonymise_source, redact }
import from resqmesh.contracts.enums {
    ClusterState, HazardType, LLMProvider, LocationSource, SourceChannel, VulnerabilityFlag
}
import from resqmesh.contracts.models {
    AdaptationSnapshot, IncidentCluster, IncidentReport, LocationFix, RawSignal,
    SourceTrust, to_json
}
import from resqmesh.contracts.ports { ExtractionResult }
import from resqmesh.contracts.state { IncidentState, apply_update, resolve_cluster_id }

glob T0: datetime = datetime(2026, 9, 21, 6, 0, tzinfo=UTC);
glob GAZ: FakeGazetteer = FakeGazetteer();

# fuse() returns a FusionResult (clusters + the id aliases a merge produced). Most of
# these tests are about the clusters, so unwrap once here.
def clusters_of(
    reports: list[IncidentReport], trust: dict[str, SourceTrust]
) -> list[IncidentCluster] {
    return fuse(reports, trust).clusters;
}

def sig(n: int, body: str, source: str = "src:x", minutes: float = 0) -> RawSignal {
    return RawSignal(
        signal_id=f"S{n}", channel=SourceChannel.TELEGRAM, source_id=source, body=body,
        received_at=T0 + timedelta(minutes=minutes)
    );
}

def rep(
    n: int,
    source: str,
    gn: str = "KLN-001",
    severity: int = 2,
    minutes: float = 0,
    hazard: HazardType = HazardType.FLOOD,
    lat: float = 6.9497,
    lon: float = 79.9853
) -> IncidentReport {
    return IncidentReport(
        report_id=f"R{n}", signal_id=f"S{n}", source_id=source, hazard_type=hazard,
        description="x", raw_place_text="x", resolved_gn_id=gn, lat=lat, lon=lon,
        severity_claim=severity, observed_at=T0 + timedelta(minutes=minutes)
    );
}

def located_signal(
    signal_id: str = "S-LOC",
    body: str = "water rising, two people on a roof",
    lat: float | None = None,
    lon: float | None = None,
    accuracy_m: float | None = None,
    location_source: LocationSource = LocationSource.NONE
) -> RawSignal {
    return RawSignal(
        signal_id=signal_id, channel=SourceChannel.WEB_FORM, source_id="src:x", body=body,
        received_at=T0, lat=lat, lon=lon, accuracy_m=accuracy_m,
        location_source=location_source
    );
}

def state_of(signals: list[RawSignal], reports: list[IncidentReport] | None = None) -> IncidentState {
    return IncidentState(
        raw_signals=list(signals), reports=list(reports or []), adaptation=AdaptationSnapshot()
    );
}

# --------------------------------------------------------------------------- #
# Test doubles
# --------------------------------------------------------------------------- #

obj RecordingLLM(StubLLM) {
    has seen: list[str] = [];

    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        self.seen.append(text);
        return super.extract(text, schema, lang_hint=lang_hint);
    }
}

obj BrokenLLM(StubLLM) {
    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        raise TimeoutError("provider down");
    }
}

obj GarbageLLM(StubLLM) {
    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        return ExtractionResult(
            payload={"hazard_type": "tsunami", "severity_claim": 9}, provider=LLMProvider.STUB
        );
    }
}

obj LeakyLLM(StubLLM) {
    override def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        payload: dict[str, any] = {
            "hazard_type": "flood",
            "raw_place_text": "Biyagama",
            "vulnerability_flags": ["elderly", "ethnicity:x", "religion", "children_present"]
        };
        return ExtractionResult(payload=payload, provider=LLMProvider.STUB);
    }
}

# --------------------------------------------------------------------------- #
# Pseudonymisation
# --------------------------------------------------------------------------- #

test "redact strips sri lankan phone numbers" {
    for phone in ["0771234567", "077 123 4567", "+94 77 123 4567", "+94771234567"] {
        assert phone not in redact(f"call me on {phone} please"), phone;
        assert "[phone]" in redact(f"call me on {phone} please"), phone;
    }
}

test "redact strips email and nic" {
    out = redact("mail a.b@example.lk, NIC 912345678V or 199012345678");
    assert "example.lk" not in out and "912345678V" not in out and "199012345678" not in out;
}

test "redact keeps the operational content" {
    # A headcount is not a phone number.
    assert redact("12 people trapped in Kolonnawa") == "12 people trapped in Kolonnawa";
}

test "pseudonym is stable and salted" {
    a = pseudonymise_source("077 123 4567", "salt-1");
    assert a == pseudonymise_source("077-123-4567", "salt-1");  # formatting-insensitive
    assert a != pseudonymise_source("077 123 4567", "salt-2");
    assert "0771234567" not in a;
}

test "pseudonym refuses an empty salt" {
    # An unsalted hash of a phone number is reversible by brute force.
    with testraises(ValueError, `match="salt") {
        pseudonymise_source("0771234567", "");
    }
}

# --------------------------------------------------------------------------- #
# Extraction
# --------------------------------------------------------------------------- #

test "phone numbers never reach the model" {
    # Proposal section 10.3: identifiers are stripped before any hosted-model call.
    llm = RecordingLLM();
    extract_report(sig(1, "Flooding in Biyagama, call 0771234567"), llm, GAZ);
    assert "0771234567" not in llm.seen[0];
}

test "extraction resolves a known division" {
    out = extract_report(sig(1, "Flooding in Biyagama, 12 people trapped"), StubLLM(), GAZ);
    r = out[0];
    assert out[1] is None;
    assert r.resolved_gn_id == "KLN-001" and r.is_located();
    assert r.hazard_type == HazardType.FLOOD;
    assert r.reported_people_affected == 12;
}

test "an unknown place is held not guessed" {
    r = extract_report(sig(1, "Water entering houses near the old temple"), StubLLM(), GAZ)[0];
    assert r.resolved_gn_id is None and not r.is_located();
}

test "report id is deterministic" {
    # Re-ingesting a signal can never create a second report.
    a = extract_report(sig(7, "Flooding in Biyagama"), StubLLM(), GAZ)[0];
    b = extract_report(sig(7, "Flooding in Biyagama"), StubLLM(), GAZ)[0];
    assert a.report_id == b.report_id == "R-S7";
}

test "extraction failure degrades instead of dropping" {
    # No single failure produces silence: the signal still becomes a report, and the
    # location still resolves from the raw text.
    for llm in [BrokenLLM(), GarbageLLM()] {
        out = extract_report(sig(1, "Help, flooding in Kaduwela"), llm, GAZ);
        r = out[0];
        assert out[1] is not None;
        assert r.hazard_type == HazardType.UNKNOWN;
        assert r.extraction_confidence == 0.0;
        assert r.resolved_gn_id == "KLN-002";
    }
}

test "provider failure names the exception" {
    failure = extract_report(sig(1, "Help, flooding in Kaduwela"), BrokenLLM(), GAZ)[1];
    assert failure == "provider: TimeoutError";
}

test "malformed values are not coerced" {
    # Severity 9 is invalid; it must not be clamped into a plausible-looking 4.
    out = extract_report(sig(1, "Kaduwela"), GarbageLLM(), GAZ);
    failure = out[1];
    assert failure is not None and failure.startswith("schema");
    assert failure == "schema: 2 invalid field(s)";
    assert out[0].severity_claim is None;
}

test "non functional vulnerability flags are discarded" {
    # Proposal section 10.4: only functional-need indicators may reach triage.
    out = extract_report(sig(1, "Biyagama"), LeakyLLM(), GAZ);
    assert out[1] is None;
    assert set(out[0].vulnerability_flags) == {VulnerabilityFlag.ELDERLY, VulnerabilityFlag.CHILDREN_PRESENT};
}

test "extracted report schema ignores extra keys and strips strings" {
    fields = ExtractedReport.from_payload(
        {"description": "  hi  ", "severity_claim": "3", "padding": 1, "extraction_confidence": 1}
    );
    assert fields.description == "hi" and fields.severity_claim == 3;
    assert fields.hazard_type == HazardType.UNKNOWN and fields.extraction_confidence == 1.0;
    with testraises(SchemaValidationError) {
        ExtractedReport.from_payload({"severity_claim": 3.5});
    }
    with testraises(SchemaValidationError) {
        ExtractedReport.from_payload({"reported_people_affected": -1});
    }
    with testraises(SchemaValidationError) {
        ExtractedReport.from_payload({"extraction_confidence": 1.5});
    }
    with testraises(SchemaValidationError) {
        ExtractedReport.from_payload(["not", "a", "mapping"]);
    }
}

test "vision reading schema requires a bounded severity" {
    v = VisionReading.from_payload({"severity_0_4": 2, "tags": ["roof"], "extra": True});
    assert v.severity_0_4 == 2 and v.tags == ["roof"] and v.model_confidence == 0.5;
    with testraises(SchemaValidationError) {
        VisionReading.from_payload({"tags": []});
    }
    with testraises(SchemaValidationError) {
        VisionReading.from_payload({"severity_0_4": 5});
    }
}

# --------------------------------------------------------------------------- #
# Fusion
# --------------------------------------------------------------------------- #

test "a lone unknown source stays below the dispatch floor" {
    # A single uncorroborated report from a source with no history cannot alone
    # justify committing a crew (proposal section 10.1). The Tier C floor is 0.50.
    out = clusters_of([rep(1, "a")], {});
    assert len(out) == 1;
    assert out[0].state == ClusterState.SINGLE_SOURCE;
    assert out[0].confidence_0_1 < 0.5;
}

test "two independent sources clear the floor" {
    out = clusters_of([rep(1, "a"), rep(2, "b", minutes=5)], {});
    assert len(out) == 1;
    c = out[0];
    assert c.state == ClusterState.CORROBORATED;
    assert c.confidence_0_1 >= 0.5;
    assert c.corroborating_source_count == 2;
}

test "repetition is not corroboration" {
    # The same culvert logged four times by one caller is one cluster, one vote.
    reports = [rep(i, "same-caller", minutes=i) for i in range(4)];
    out = clusters_of(reports, {});
    assert len(out) == 1;
    c = out[0];
    assert len(c.member_report_ids) == 4;
    assert c.corroborating_source_count == 1;
    assert c.confidence_0_1 == clusters_of([rep(0, "same-caller")], {})[0].confidence_0_1;
}

test "balanced contradiction is unresolved not averaged" {
    # One says flooded, one says receded, equal standing: say so, don't pick.
    out = clusters_of([rep(1, "a"), rep(2, "b", severity=0, minutes=10)], {});
    assert len(out) == 1;
    c = out[0];
    assert c.state == ClusterState.UNRESOLVED;
    assert c.contradiction_flag;
    assert c.unresolved();
}

test "a trusted denial outweighs an unknown claim" {
    trust = {"reliable": SourceTrust(source_id="reliable", alpha=9.0, beta=1.0)};
    out = clusters_of([rep(1, "unknown"), rep(2, "reliable", severity=0, minutes=5)], trust);
    assert len(out) == 1;
    assert out[0].state == ClusterState.CONTRADICTED;
}

test "a sources latest word wins" {
    # A caller who reported flooding and later reported it receded counts once, as receded.
    ev = weigh_evidence([rep(1, "a"), rep(2, "a", severity=0, minutes=30)], {}, FusionConfig());
    assert ev.affirming_sources == 0 and ev.negating_sources == 1;
}

test "trust raises confidence" {
    # A source with a good record moves the needle more than an unknown one.
    trusted = {"a": SourceTrust(source_id="a", alpha=9.0, beta=1.0)};
    assert clusters_of([rep(1, "a")], trusted)[0].confidence_0_1 > clusters_of([rep(1, "a")], {})[0].confidence_0_1;
}

test "a distinct emergency two km away is not merged" {
    # Proposal section 2.1: "a genuinely distinct emergency two kilometres away is missed entirely".
    near = rep(1, "a", lat=6.9497, lon=79.9853);
    far = rep(2, "b", gn="KLN-002", lat=6.9497 + 0.018, lon=79.9853);  # ~2 km north
    assert len(clusters_of([near, far], {})) == 2;
}

test "different hazards at one place stay separate" {
    flood = rep(1, "a");
    medical = rep(2, "b", hazard=HazardType.MEDICAL);
    assert {c.hazard_type for c in clusters_of([flood, medical], {})} == {HazardType.FLOOD, HazardType.MEDICAL};
}

test "reports outside the time window are separate incidents" {
    assert len(clusters_of([rep(1, "a"), rep(2, "b", minutes=60 * 7)], {})) == 2;
}

test "cluster id survives a new member joining" {
    # A3's queue, A4's plan and the commander's approval all key on the cluster id.
    before = clusters_of([rep(1, "a")], {})[0].cluster_id;
    after = clusters_of([rep(1, "a"), rep(2, "b", minutes=5)], {})[0].cluster_id;
    assert before == after;
}

test "fusion is order independent" {
    reports = [rep(1, "a"), rep(2, "b", minutes=3), rep(3, "c", minutes=1)];
    assert to_json(clusters_of(reports, {})) == to_json(clusters_of(list(reversed(reports)), {}));
}

test "coordinates beat a place name and keep the reporters own point" {
    # A resolved name gives the division's *centroid*, which can be kilometres from
    # the caller. That is a fine pin for a map at division granularity and a bad place
    # to send a crew, so a usable fix wins.
    r = extract_report(
        located_signal(lat=6.9450, lon=79.9800, accuracy_m=15, location_source=LocationSource.GPS),
        StubLLM(), FakeGazetteer()
    )[0];
    assert r.is_located();
    assert (r.lat, r.lon) == (6.9450, 79.9800);  # not the division centroid
    assert r.location_source == LocationSource.GPS;
    assert r.location_accuracy_m == 15;
}

test "a loose fix is not trusted over a name" {
    # A five-kilometre accuracy radius cannot pick a division; fall back to the text.
    r = extract_report(
        located_signal(
            body="flooding in Kolonnawa", lat=6.9450, lon=79.9800, accuracy_m=5000,
            location_source=LocationSource.GPS
        ),
        StubLLM(), FakeGazetteer()
    )[0];
    assert r.location_source == LocationSource.PLACE_TEXT;
    assert r.location_accuracy_m is None;
}

test "a coordinate outside every division is held not snapped" {
    # The gazetteer whitelist is not negotiable just because the input was precise.
    # Snapping to the nearest division would invent coverage this deployment does not
    # have, which is the same failure as a confidently invented place name.
    r = extract_report(
        located_signal(lat=5.0, lon=75.0, accuracy_m=10, location_source=LocationSource.GPS),
        StubLLM(), FakeGazetteer()
    )[0];
    assert not r.is_located();
    assert r.resolved_gn_id is None;
    assert r.location_source == LocationSource.NONE;
}

test "an operator can place a held report without inventing a second source" {
    # Re-entering the report with coordinates would create a second report under a
    # second pseudonym, and two independent sources corroborate: one person's word
    # would reach 0.64 confidence and clear the 0.50 dispatch floor on its own.
    agent = IngestAgent(StubLLM(), FakeGazetteer());
    st = IncidentState(raw_signals=[located_signal(body="behind the temple, water everywhere")]);
    st = apply_update(st, agent.run(st, now=T0));
    assert len(st.unresolved_queue) == 1;
    held = st.unresolved_queue[0];
    assert st.clusters == [];

    st.location_fixes = [
        LocationFix(report_id=held.report_id, lat=6.9497, lon=79.9853, placed_by="ops-1", placed_at=T0)
    ];
    out = agent.run(st, now=T0);

    assert len(out["clusters"]) == 1;
    c = out["clusters"][0];
    assert c.corroborating_source_count == 1;  # still one person's word
    assert c.confidence_0_1 < 0.5;  # and still below the dispatch floor
    # The stored report keeps the emptiness it arrived with; the fix lives beside it.
    assert not held.is_located();
}

test "reports along a river do not chain into one cluster" {
    # Single linkage grows a cluster along any chain of nearby reports, which is
    # exactly the shape flood reports take: strung out along the water. Twelve
    # emergencies 1.2 km apart would collapse into one cluster spanning 13 km.
    strung = [rep(i, f"s{i}", lat=6.90 + i * 0.0108, minutes=i) for i in range(12)];
    out = clusters_of(strung, {});

    assert len(out) >= 5;
    # No cluster may be wider than the neighbourhood radius it was built from.
    for c in out {
        members = [r for r in strung if r.report_id in c.member_report_ids];
        span = max([haversine_km(present(a.lat), present(a.lon), present(b.lat), present(b.lon)) for a in members for b in members]);
        assert span <= FusionConfig().eps_km;
    }
}

test "reports in different divisions never share a cluster" {
    # A second bound on cluster size, and the granularity the DMC reports in.
    here = rep(1, "a", gn="KLN-001", lat=6.9497, lon=79.9853);
    # 300 m away, but across a boundary: two clusters, named separately.
    next_door = rep(2, "b", gn="KLN-002", lat=6.9497, lon=79.9880, minutes=5);
    assert len({c.gn_id for c in clusters_of([here, next_door], {})}) == 2;
}

test "a late report with an earlier time does not rename the cluster" {
    # The Telegram adapter preserves a message's own timestamp on purpose, which
    # makes out-of-order arrival a designed case. An approval, a completion or a
    # commander constraint naming the old id would otherwise dangle.
    first_pass = fuse([rep(1, "a", minutes=30), rep(2, "b", minutes=40)], {});
    assert len(first_pass.clusters) == 1;
    before = first_pass.clusters[0];

    delayed = rep(3, "c", minutes=0);  # queued through an outage; truly earlier
    after = fuse(
        [rep(1, "a", minutes=30), rep(2, "b", minutes=40), delayed], {},
        previous=first_pass.clusters
    );

    assert [c.cluster_id for c in after.clusters] == [before.cluster_id];
    assert after.aliases == {};
}

test "a merge keeps the larger id and aliases the other" {
    # When two clusters become one, something must still resolve the id that went.
    groups = [[rep(1, "a"), rep(2, "b"), rep(3, "c")]];
    previous = [
        build_cluster([rep(1, "a"), rep(2, "b")], {}, FusionConfig(), cluster_id="CL-0001"),
        build_cluster([rep(3, "c")], {}, FusionConfig(), cluster_id="CL-0002")
    ];
    out = assign_ids(groups, previous);
    aliases = out[2];

    assert out[0] == ["CL-0001"];  # the larger prior keeps its identity
    assert out[1] == [["CL-0002"]];
    assert aliases == {"CL-0002": "CL-0001"};
    assert resolve_cluster_id(aliases, "CL-0002") == "CL-0001";
}

test "a split gives the new part a fresh id" {
    # A prior can be inherited by exactly one group; the rest are genuinely new.
    groups = [[rep(1, "a"), rep(2, "b")], [rep(3, "c")]];
    previous = [
        build_cluster([rep(1, "a"), rep(2, "b"), rep(3, "c")], {}, FusionConfig(), cluster_id="CL-0001")
    ];
    out = assign_ids(groups, previous);
    ids = out[0];

    assert ids[0] == "CL-0001" and ids[1] not in {"CL-0001"};
    assert out[2] == {};  # nothing was absorbed, so nothing needs redirecting
}

test "unlocated reports are never clustered" {
    unlocated = IncidentReport(
        report_id="R9", signal_id="S9", source_id="z", hazard_type=HazardType.FLOOD,
        description="x", raw_place_text="nowhere", observed_at=T0
    );
    assert clusters_of([unlocated], {}) == [];
}

test "classification table" {
    table = [
        (0.4, 0.0, 1, 0, ClusterState.SINGLE_SOURCE),
        (0.64, 0.0, 2, 0, ClusterState.CORROBORATED),
        (0.4, 0.4, 1, 1, ClusterState.UNRESOLVED),
        (0.4, 0.8, 1, 1, ClusterState.CONTRADICTED),
        (0.0, 0.4, 0, 1, ClusterState.CONTRADICTED)
    ];
    for (affirm, negate, a_n, n_n, expected) in table {
        assert classify(Evidence(affirm, negate, a_n, n_n), FusionConfig()) == expected;
    }
}

# --------------------------------------------------------------------------- #
# The node
# --------------------------------------------------------------------------- #

test "node writes only its own fields" {
    out = IngestAgent(StubLLM(), GAZ).run(state_of([sig(1, "Flooding in Biyagama")]), now=T0);
    assert set(out) == {"reports", "unresolved_queue", "clusters", "trace"};
    assert out["trace"][0].agent == "A1";
    assert out["trace"][0].action == "signals_ingested";
    assert out["trace"][0].event_id.startswith("EV-") and len(out["trace"][0].event_id) == 15;
}

test "node processes only new signals" {
    agent = IngestAgent(StubLLM(), GAZ);
    first = agent.run(state_of([sig(1, "Flooding in Biyagama")]), now=T0);
    second = agent.run(
        state_of(
            [sig(1, "Flooding in Biyagama"), sig(2, "Flooding in Kaduwela", "src:y")],
            reports=first["reports"]
        ),
        now=T0
    );
    assert [r.signal_id for r in second["reports"]] == ["S2"];
    assert len(second["clusters"]) == 2;  # recomputed over all evidence
}

test "node is idempotent when nothing is new" {
    agent = IngestAgent(StubLLM(), GAZ);
    first = agent.run(state_of([sig(1, "Flooding in Biyagama")]), now=T0);
    again = agent.run(state_of([sig(1, "Flooding in Biyagama")], reports=first["reports"]), now=T0);
    assert again["reports"] == [] and to_json(again["clusters"]) == to_json(first["clusters"]);
}

test "node holds unlocated reports and names degradation" {
    out = IngestAgent(BrokenLLM(), GAZ).run(
        state_of([sig(1, "near the old temple"), sig(2, "Kaduwela flooding")]), now=T0
    );
    assert [r.signal_id for r in out["unresolved_queue"]] == ["S1"];
    assert "degraded extraction" in out["trace"][0].detail;
}

test "node reads trust from the adaptation store" {
    trusted = AdaptationSnapshot(source_trust={"src:x": SourceTrust(source_id="src:x", alpha=9.0, beta=1.0)});
    plain = IngestAgent(StubLLM(), GAZ).run(state_of([sig(1, "Flooding in Biyagama")]), now=T0);
    boosted_state = state_of([sig(1, "Flooding in Biyagama")]);
    boosted_state.adaptation = trusted;
    boosted = IngestAgent(StubLLM(), GAZ).run(boosted_state, now=T0);
    assert boosted["clusters"][0].confidence_0_1 > plain["clusters"][0].confidence_0_1;
}

test "unprocessed signals helper" {
    s1 = sig(1, "a");
    s2 = sig(2, "b");
    done = rep(1, "x");
    assert unprocessed_signals(IncidentState(raw_signals=[s1, s2], reports=[done])) == [s2];
}
