"""The public bulletin lifecycle: expiry, supersession, and the all-clear.

A published alert must not be immutable and eternal (composed once, pushed, then on
/news for good). An evacuation order has to be able to be stood down, and a flood
warning must not outlive the flood, which teaches people to ignore the channel. These
tests pin the way out."""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.agents.comms.alerts { UNLIMITED_TEMPLATES, AlertRateLimiter, fill_template }
import from resqmesh.agents.comms.lifecycle { current, latest, retire, superseded_by }
import from resqmesh.contracts.enums { AlertStatus }
import from resqmesh.contracts.models { CommunityAlert }

glob NOW: datetime = datetime(2026, 5, 17, 6, 0, tzinfo=UTC);

def alert(
    alert_id: str,
    template: str = "flood_warning",
    gn: str = "KLN-001",
    issued: datetime = NOW,
    expires: datetime | None = None,
    status: AlertStatus = AlertStatus.PUBLISHED
) -> CommunityAlert {
    (si, ta, en) = fill_template(template, {"area": "Kolonnawa", "shelter": "Maha Vidyalaya", "capacity": "400"});
    return CommunityAlert(
        alert_id=alert_id, template_id=template, slots={"area": "Kolonnawa"},
        text_si=si, text_ta=ta, text_en=en, target_gn_ids=[gn], approval_id="AP-1",
        issued_at=issued, expires_at=expires, status=status
    );
}

# --------------------------------------------------------------------------- #
# The fold
# --------------------------------------------------------------------------- #

test "the latest record per bulletin wins" {
    # Alerts are append-only, so a status change is a new record with the same id.
    log = [alert("AL-1"), retire(alert("AL-1"), AlertStatus.CANCELLED, stood_down_by="cmdr-01")];

    assert latest(log)["AL-1"].status == AlertStatus.CANCELLED;
    assert current(log, NOW) == [];
}

test "an expired bulletin leaves the public page without anybody recording it" {
    # Otherwise a stale warning stays up purely because no tick happened to run.
    log = [alert("AL-1", expires=NOW + timedelta(hours=6))];

    assert len(current(log, NOW)) == 1;
    assert current(log, NOW + timedelta(hours=7)) == [];
}

test "the public page shows the newest first" {
    log = [alert("AL-1", gn="KLN-001"), alert("AL-2", gn="KLN-002", issued=NOW + timedelta(minutes=5))];

    assert [a.alert_id for a in current(log, NOW + timedelta(minutes=6))] == ["AL-2", "AL-1"];
}

# --------------------------------------------------------------------------- #
# Supersession
# --------------------------------------------------------------------------- #

test "a second warning for one area replaces the first" {
    existing = [alert("AL-1")];
    fresh = [alert("AL-2", issued=NOW + timedelta(minutes=30))];

    out = superseded_by(existing, fresh, NOW + timedelta(minutes=30));
    assert len(out) == 1;
    retired = out[0];
    assert retired.alert_id == "AL-1";
    assert retired.status == AlertStatus.SUPERSEDED and retired.superseded_by == "AL-2";
}

test "a flood warning does not quietly retire an evacuation order" {
    # They say different things, and the stronger one has to be stood down on purpose.
    # Matching on area alone would let a routine warning cancel an evacuation order for
    # the same place: the system deciding, with nobody's authority, that it is safe to
    # come home.
    existing = [alert("AL-EVAC", template="evacuate_area")];
    fresh = [alert("AL-WARN", template="flood_warning", issued=NOW + timedelta(minutes=30))];

    assert superseded_by(existing, fresh, NOW + timedelta(minutes=30)) == [];
}

test "a bulletin does not supersede itself" {
    existing = [alert("AL-1")];
    assert superseded_by(existing, existing, NOW) == [];
}

# --------------------------------------------------------------------------- #
# Rate limiting
# --------------------------------------------------------------------------- #

test "a cooldown suppresses a repeat but never an all clear" {
    # The cooldown exists to stop alert fatigue. Telling people a danger is over is the
    # one message that must never be held back because they heard from us recently.
    limiter = AlertRateLimiter(min_interval=timedelta(minutes=10));
    limiter.record(["KLN-001"], NOW);

    (allowed, suppressed) = limiter.filter_allowed(["KLN-001"], NOW + timedelta(minutes=2), "flood_warning");
    assert allowed == [] and suppressed == ["KLN-001"];

    (allowed2, suppressed2) = limiter.filter_allowed(["KLN-001"], NOW + timedelta(minutes=2), "stand_down");
    assert allowed2 == ["KLN-001"] and suppressed2 == [];
    assert "stand_down" in UNLIMITED_TEMPLATES;
}

test "cooldowns survive a restart" {
    # Held only in process memory, a redeploy would reset every cooldown and the next
    # tick could alert an area that had just been alerted.
    before = AlertRateLimiter();
    before.record(["KLN-001"], NOW);

    after = AlertRateLimiter();
    after.seed(before.cooldowns());

    assert after.filter_allowed(["KLN-001"], NOW + timedelta(minutes=1), "flood_warning")[1] == ["KLN-001"];
}

test "seeding never moves a cooldown backwards" {
    limiter = AlertRateLimiter();
    limiter.record(["KLN-001"], NOW + timedelta(minutes=30));
    limiter.seed({"KLN-001": NOW});  # a stale checkpoint

    assert limiter.cooldowns()["KLN-001"] == NOW + timedelta(minutes=30);
}

# --------------------------------------------------------------------------- #
# Every template is usable
# --------------------------------------------------------------------------- #

test "every template fills in all three languages" {
    for template in ["evacuate_area", "shelter_open", "stand_down", "flood_warning"] {
        (si, ta, en) = fill_template(template, {"area": "Kolonnawa", "shelter": "Maha Vidyalaya", "capacity": "400"});

        assert "Kolonnawa" in si and "Kolonnawa" in ta and "Kolonnawa" in en;
        assert "{" not in si + ta + en, "an unfilled slot would publish a hole to the public";
    }
}
