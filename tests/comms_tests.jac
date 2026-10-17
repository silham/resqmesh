"""A6 unit tests: SITREP assembly and hashing, alert templating, rate limiting,
place names and trilingual text, the release entry point, and the ReportLab PDF.

Deterministic throughout: no network, and the PDF test only checks that a real file
lands on disk."""

import tempfile;
import from datetime { timedelta }
import from pathlib { Path }
import from resqmesh.adapters.fakes { MockBroadcast }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.comms.agent { CommsAgent, UnapprovedBroadcast }
import from resqmesh.agents.comms.alerts { AlertRateLimiter, MissingSlot, UnknownTemplate, fill_template }
import from resqmesh.agents.comms.sitrep {
    ReportLabRenderer, assemble_claims, compute_hash, degraded_notice_for, known_source_refs
}
import from resqmesh.contracts.enums { AlertStatus, HazardMethod }
import from resqmesh.contracts.models { HazardSurface, SourcedClaim, evolve }
import from tests.support.baseline { NOW, clusters, gazetteer, hazard, valid_plan }
import from tests.support.comms_fixtures { approval_for, comms_state, shelter }

def tmp_dir() -> Path {
    return Path(tempfile.mkdtemp());
}

def make_comms(out_dir: Path | None = None) -> CommsAgent {
    if out_dir is None {
        return CommsAgent(guardrail=GuardrailAgent(gazetteer=gazetteer()));
    }
    return CommsAgent(guardrail=GuardrailAgent(gazetteer=gazetteer()), out_dir=out_dir);
}

# --- claim assembly + source binding --------------------------------------- #

test "assembled claims are all sourced" {
    claims = assemble_claims(clusters(), hazard(), valid_plan());
    refs = known_source_refs(clusters(), hazard(), valid_plan());

    assert claims;
    assert all([c.source_ref in refs for c in claims]);
}

test "build sitrep produces a hashed sourced report" {
    tmp = tmp_dir();
    h = hazard();
    plan = valid_plan();
    claims = assemble_claims(clusters(), h, plan);
    refs = known_source_refs(clusters(), h, plan);

    (sitrep, check) = make_comms().build_sitrep(
        sitrep_id="SR-1", claims=claims, known_refs=refs,
        hazard_method=h.method, plan_version=plan.version,
        out_dir=tmp, now=NOW
    );

    assert check.passed;
    assert sitrep.hash;
    assert sitrep.plan_version == 1;
    assert len(sitrep.claims) == len(claims);
    assert tmp.joinpath("SR-1.txt").exists();
}

test "degraded notice surfaces buffer proxy" {
    proxy = HazardSurface(
        surface_id="HS-2", version=1, generated_at=NOW, method=HazardMethod.BUFFER_PROXY,
        confidence_0_1=0.4,
        inundation_geojson={"type": "FeatureCollection", "features": []},
        susceptibility_geojson={"type": "FeatureCollection", "features": []}
    );
    assert "buffer-proxy" in (degraded_notice_for(proxy) or "");
    assert degraded_notice_for(None) is None;
}

# --- hash chaining --------------------------------------------------------- #

test "sitreps form a tamper evident chain" {
    tmp = tmp_dir();
    comms = make_comms();
    h = hazard();
    claims = assemble_claims(clusters(), h, valid_plan());
    refs = known_source_refs(clusters(), h, valid_plan());

    first = comms.build_sitrep(
        sitrep_id="SR-1", claims=claims, known_refs=refs,
        hazard_method=h.method, out_dir=tmp, now=NOW
    )[0];
    second = comms.build_sitrep(
        sitrep_id="SR-2", claims=claims, known_refs=refs,
        hazard_method=h.method, out_dir=tmp, prev_hash=first.hash,
        now=NOW + timedelta(minutes=5)
    )[0];

    assert second.prev_hash == first.hash;
    assert second.hash != first.hash;
}

test "tampering with a claim breaks the hash" {
    claims = [SourcedClaim(sentence="Ward 4 is flooding.", source_ref="R-1")];
    tampered = [SourcedClaim(sentence="Ward 4 is fine.", source_ref="R-1")];

    h1 = compute_hash("SR-1", NOW, claims, HazardMethod.HAND, None, None);
    h2 = compute_hash("SR-1", NOW, tampered, HazardMethod.HAND, None, None);

    assert h1 != h2;
}

# --- alert templating ------------------------------------------------------ #

test "fill template fills all three languages" {
    (si, ta, en) = fill_template("evacuate_area", {"area": "Biyagama", "shelter": "Zone A"});

    assert "Biyagama" in en and "Zone A" in en;
    assert "Biyagama" in si and "Biyagama" in ta;
}

test "fill template rejects unknown template" {
    with testraises(UnknownTemplate) {
        fill_template("nuke_from_orbit", {});
    }
}

test "fill template rejects missing slot" {
    with testraises(MissingSlot) {
        fill_template("evacuate_area", {"area": "Biyagama"});  # no shelter
    }
}

# --- rate limiting --------------------------------------------------------- #

test "rate limiter suppresses a repeat inside the window" {
    rl = AlertRateLimiter(min_interval=timedelta(minutes=10));
    allowed = rl.filter_allowed(["KLN-001", "KLN-002"], NOW)[0];
    assert allowed == ["KLN-001", "KLN-002"];

    rl.record(allowed, NOW);

    (allowed2, suppressed2) = rl.filter_allowed(["KLN-001", "KLN-003"], NOW + timedelta(minutes=2));
    assert allowed2 == ["KLN-003"];  # 001 still cooling down, 003 is fresh
    assert suppressed2 == ["KLN-001"];
}

test "rate limiter allows again after the window" {
    rl = AlertRateLimiter(min_interval=timedelta(minutes=10));
    rl.record(["KLN-001"], NOW);
    allowed = rl.filter_allowed(["KLN-001"], NOW + timedelta(minutes=11))[0];
    assert allowed == ["KLN-001"];
}

# --- broadcast gating ------------------------------------------------------ #

test "compose alert requires an approval" {
    with testraises(UnapprovedBroadcast) {
        make_comms().compose_alert(
            alert_id="AL-1", template_id="flood_warning", slots={"area": "Biyagama"},
            target_gn_ids=["KLN-001"], approval_id=""
        );
    }
}

test "broadcast sends then rate limits" {
    comms = make_comms();
    alert = comms.compose_alert(
        alert_id="AL-1", template_id="flood_warning", slots={"area": "Biyagama"},
        target_gn_ids=["KLN-001"], approval_id="AP-1", now=NOW
    );
    port = MockBroadcast();

    first = comms.broadcast(alert, port, now=NOW);
    assert first == 1;
    assert len(port.broadcasts) == 1;

    # immediate re-broadcast to the same area is suppressed
    second = comms.broadcast(alert, port, now=NOW + timedelta(minutes=1));
    assert second == 0;
    assert len(port.broadcasts) == 1;
}

# --- place names and real trilingual text ---------------------------------- #

test "assemble claims uses division names" {
    names = {"KLN-001": "Biyagama", "KLN-002": "Kaduwela", "KLN-003": "Kolonnawa"};
    claims = assemble_claims(clusters(), None, None, division_names=names);
    text = " ".join([c.sentence for c in claims]);
    assert "Kolonnawa" in text or "Biyagama" in text;
    # the raw id must not leak into a claim when a name is known
    assert "KLN-001:" not in text;
}

test "assemble claims falls back to id when name missing" {
    claims = assemble_claims(clusters(), None, None);  # no names
    text = " ".join([c.sentence for c in claims]);
    assert "KLN-" in text;  # id shown when no mapping given
}

test "alerts are real trilingual not placeholders" {
    (si, ta, en) = fill_template("flood_warning", {"area": "Hanwella"});
    assert "[SI-REVIEW]" not in si and "[TA-REVIEW]" not in ta;
    # genuine Sinhala / Tamil script (non-ASCII), with the slot filled in each
    assert any([ord(ch) > 127 for ch in si]);
    assert any([ord(ch) > 127 for ch in ta]);
    assert all(["Hanwella" in x for x in [si, ta, en]]);
}

# --- the release entry point ----------------------------------------------- #

test "approving a dispatch does not publish a broadcast" {
    # Two decisions, not one. A crew being sent is not a message to every phone.
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    out = comms.run(comms_state(plan, clusters(), hazard(), [approval_for(plan, publish_alerts=False)]));

    assert len(out["sitreps"]) == 1;
    assert out["alerts"] == [];
}

test "a no go division gets an evacuation order naming a shelter" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    flooded = evolve(hazard(), no_go_gn_ids=["KLN-001"]);
    sh = shelter();

    out = comms.run(comms_state(plan, clusters(), flooded, [approval_for(plan)], shelters=[sh]));

    by_template = {a.template_id: a for a in out["alerts"]};
    assert "evacuate_area" in by_template, "the no-go division is told to evacuate";
    order = by_template["evacuate_area"];
    assert sh.name in order.text_en;
    assert order.target_gn_ids == ["KLN-001"];
    # The divisions that are merely at risk still get the warning, not an order.
    assert any([a.template_id == "flood_warning" for a in out["alerts"]]);
}

test "without a shelter registry no evacuation order is composed" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    flooded = evolve(hazard(), no_go_gn_ids=["KLN-001"]);

    out = comms.run(comms_state(plan, clusters(), flooded, [approval_for(plan)], shelters=[]));

    assert {a.template_id for a in out["alerts"]} == {"flood_warning"};
}

test "a repeat bulletin supersedes the one it replaces" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    first = comms.run(comms_state(plan, clusters(), hazard(), [approval_for(plan)]))["alerts"];
    assert first;

    replanned = evolve(plan, version=plan.version + 1);
    again = comms.run(
        comms_state(replanned, clusters(), hazard(), [approval_for(replanned)], alerts=list(first))
    )["alerts"];

    retired = [a for a in again if a.status == AlertStatus.SUPERSEDED];
    assert {a.alert_id for a in retired} == {a.alert_id for a in first};
    assert all([a.superseded_by and a.superseded_by != a.alert_id for a in retired]);
}

test "run produces sitrep alerts and trace" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    out = comms.run(comms_state(plan, clusters(), hazard(), [approval_for(plan)]));

    assert len(out["sitreps"]) == 1;
    assert len(out["trace"]) == 1 and out["trace"][0].agent == "A6";
    # valid_plan has 3 assignments to 3 distinct divisions -> 3 alerts
    assert len(out["alerts"]) == 3;
    assert all([a.approval_id == "AP-1" for a in out["alerts"]]);

    sitrep = out["sitreps"][0];
    assert sitrep.claims and all([c.source_ref for c in sitrep.claims]);
    assert sitrep.prev_hash is None;  # the first report in the chain
}

test "run chains hash from the previous sitrep" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    approval = approval_for(plan);
    first = comms.run(comms_state(plan, clusters(), hazard(), [approval]))["sitreps"][0];
    second = comms.run(comms_state(plan, clusters(), hazard(), [approval], sitreps=[first]))["sitreps"][0];

    assert second.prev_hash == first.hash;
}

test "run without approval makes a sitrep but no alerts" {
    plan = valid_plan();
    comms = make_comms(tmp_dir());
    out = comms.run(comms_state(plan, clusters(), hazard(), []));

    assert len(out["sitreps"]) == 1;
    assert out["alerts"] == [];
}

# --- the ReportLab PDF ----------------------------------------------------- #

test "reportlab renderer writes a pdf" {
    tmp = tmp_dir();
    claims = [
        SourcedClaim(sentence="Biyagama Ward 4: flood, 12 trapped.", source_ref="CL-1"),
        SourcedClaim(sentence="AMB-03 assigned, ETA 14 min.", source_ref="PLN-1")
    ];
    path = ReportLabRenderer().render(
        sitrep_id="SR-PDF", generated_at=NOW, claims=claims,
        hazard_method=HazardMethod.HAND, degraded_notice=None, out_dir=tmp
    );

    pdf = tmp / "SR-PDF.pdf";
    assert pdf.exists();
    assert pdf.stat().st_size > 0;
    assert path.endswith("SR-PDF.pdf");
    assert pdf.read_bytes().startswith(b"%PDF");
}

test "the sitrep hash input layout is stable" {
    # A pinned digest over the baseline claims: any change to the sentence templates
    # or to the hashed byte layout breaks verification of every stored chain.
    claims = assemble_claims(clusters(), hazard(), valid_plan());
    digest = compute_hash("SR-1", NOW, claims, HazardMethod.HAND, "notice", "prev");
    assert digest == "a5b4ecbf03ba5018b60d3729f7ac3350192e3b962b21826b412e53ff8ee36f25";
}
