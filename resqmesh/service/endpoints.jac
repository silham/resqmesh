"""The server API: the console's backend, the public report and bulletin endpoints, and
the Telegram webhook.

Every write that changes the incident returns `{command_id, status: "queued"}` and is
executed by the single incident writer; the outcome shows up in the next
`get_incident` poll, in `commands` and `busy`. Refusals that are decidable up front
(stale plan, unknown vehicle, nothing to decide) are raised immediately as errors whose
message starts with a short code: `unauthorized`, `forbidden`, `not_found`, `conflict`,
`invalid`.

Visibility is per declaration:

* `def:pub` endpoints serve the public rather than the command post: reporting an
  emergency, reading approved bulletins, health, and the sign-in helpers.
* `def:protect` endpoints need a signed-in session, and each one then checks the
  caller's role. Only a commander can authorise a Tier C action.

Reporting is deliberately unauthenticated, like the Telegram bot beside it. In a flood
you cannot ask a caller to sign up, and a credential shipped in a public page is not a
secret anyway. It is also the least dangerous write in the system: a report is
evidence, not an instruction. A single uncorroborated source scores 0.40, below the
0.50 dispatch floor, so no volume of anonymous reports from one source can commit a
crew. What this does not defend against is volume: put a rate limit at the reverse
proxy before exposing an instance to the public internet.
"""

import hmac;
import uuid;
import from datetime { datetime, UTC }
import from http { HTTPMethod }
import from pathlib { Path }
import from resqmesh.agents.ingest.redact { pseudonymise_source }
import from resqmesh.contracts.enums { ApprovalDecision, LocationSource, SourceChannel }
import from resqmesh.contracts.models { RawSignal, to_json }
import from resqmesh.service.app { auth_state, booted, runtime, service }
import from resqmesh.service.auth {
    bootstrap as bootstrap_commander, caller, create_member, disable_member, enrol as enrol_device,
    find_member, issue_enrolment as issue_code, member_json, members, require, random_password
}
import from resqmesh.service.core { ServiceError, utc_now }
import from resqmesh.service.telegram { signal_from_telegram }

glob LANGS: list[str] = ["si", "ta", "en", "unknown"];
glob DECISIONS: list[str] = ["approved", "rejected", "modified"];
glob RESPONDER_STATUSES: list[str] = ["en_route", "on_scene", "complete", "declined"];
glob SYSTEM_ACCOUNTS: list[str] = ["shared-commander", "shared-viewer", "local"];

def invalid(message: str) -> ServiceError {
    return ServiceError(422, message);
}

def accepted(command_id: str) -> dict[str, str] {
    return {"command_id": command_id, "status": "queued"};
}

# ------------------------------------------------------------------ public

def:pub health() -> dict[str, any] {
    rt = booted();
    if rt is None {
        return {"status": "starting", "incident_open": False, "auth": "open", "auth_mode": "open", "needs_setup": False};
    }
    return {
        "status": "ok",
        "incident_open": rt.service.is_open(),
        "auth": "token" if rt.auth.settings.auth_enabled() else "open",
        "auth_mode": rt.auth.settings.mode,
        "needs_setup": rt.auth.needs_setup()
    };
}

"""Open mode only: the credentials the console signs in with, so no form is needed.
Anywhere else this answers nothing."""
def:pub open_session() -> dict[str, str] | None {
    return auth_state().local_credentials();
}

"""Create the first commander. Available exactly once, with the setup code printed in
the server log at startup."""
def:pub bootstrap(code: str, username: str, password: str, display_name: str = "") -> dict[str, str] {
    return bootstrap_commander(auth_state(), code, username, password, display_name);
}

"""Spend a one-time enrolment code. Returns credentials the device signs in with."""
def:pub enrol(code: str, label: str = "") -> dict[str, str] {
    return enrol_device(code, label.strip()[:80]);
}

"""A field report: from the public form, or typed in by an operator."""
def:pub submit_report(
    text: str, lang: str = "unknown", lat: float | None = None, lon: float | None = None,
    accuracy_m: float | None = None, location_source: str = "none", source: str | None = None,
    channel: str = "web_form"
) -> dict[str, str] {
    body = text.strip();
    if len(body) < 1 or len(body) > 4000 {
        raise invalid("text must be 1 to 4000 characters");
    }
    if source is not None and len(source) > 200 {
        raise invalid("source must be at most 200 characters");
    }
    if lang not in LANGS {
        raise invalid("lang must be si, ta, en or unknown");
    }
    if lat is not None and not (-90.0 <= lat <= 90.0) or lon is not None and not (-180.0 <= lon <= 180.0) {
        raise invalid("coordinates out of range");
    }
    if accuracy_m is not None and accuracy_m < 0 {
        raise invalid("accuracy_m must be >= 0");
    }
    try {
        chan = SourceChannel(channel);
        where = LocationSource(location_source);
    } except ValueError {
        raise invalid("unknown channel or location_source");
    }
    rt = runtime();
    signal = RawSignal(
        signal_id=f"WEB-{uuid.uuid4().hex[:10]}", channel=chan,
        source_id=pseudonymise_source(source or "web-form", rt.auth.settings.salt),
        body=body, received_at=utc_now(), lang_hint=lang, lat=lat, lon=lon,
        accuracy_m=accuracy_m, location_source=where
    );
    return accepted(rt.service.submit_report(signal));
}

"""The approved public bulletins, newest first. Unauthenticated by design: this is what
the /news page reads, so a member of the public never needs the incident picture (the
clusters, the plan, the roster and the agent trace are none of their business). Every
alert here already passed the Tier C gate and was composed from a reviewed template, so
it is published information by construction. No incident means an empty list, because
"nothing to announce" is a normal state."""
def:pub public_alerts(nonce: int = 0) -> list[dict[str, any]] {
    view = service().view();
    return list(view["alerts"]) if view is not None else [];
}

"""Telegram Bot API webhook. Authenticated by the secret in the URL path, set with
setWebhook. Always answers ok so Telegram does not redeliver."""
@restspec(method=HTTPMethod.POST, path="/telegram/webhook/{secret}")
def:pub telegram_webhook(
    secret: str, update_id: int = 0, message: dict[str, any] | None = None,
    edited_message: dict[str, any] | None = None
) -> dict[str, bool] {
    rt = runtime();
    expected = rt.auth.settings.telegram_secret;
    if not expected {
        raise ServiceError(503, "telegram webhook not configured");
    }
    if not hmac.compare_digest(secret.encode(), expected.encode()) {
        raise ServiceError(401, "bad webhook secret");
    }
    update: dict[str, any] = {"update_id": update_id};
    if message is not None {
        update["message"] = message;
    }
    if edited_message is not None {
        update["edited_message"] = edited_message;
    }
    signal = signal_from_telegram(update, rt.auth.settings.salt);
    if signal is not None and rt.service.is_open() {
        rt.service.submit_report(signal);
    }
    return {"ok": True};
}

# ------------------------------------------------------------------ any signed-in reader

def:protect me() -> dict[str, any] {
    who = require("viewer");
    return {
        "role": who.role, "username": who.username, "display_name": who.display_name,
        "vehicle_id": who.vehicle_id, "auth_mode": auth_state().settings.mode
    };
}

"""The whole picture in one poll. Cheap: served from the latest snapshot. `nonce` only
varies the call so the client never answers a poll from its response cache."""
def:protect get_incident(nonce: int = 0) -> dict[str, any] {
    require("viewer");
    view = service().view();
    if view is None {
        raise ServiceError(404, "no incident is open");
    }
    return view;
}

"""A field responder reports on their dispatch (en route / on scene / complete /
declined). A responder account is bound to one call sign and may only report on that
one. Commanders and dispatchers may report on any vehicle, because the ops room
relaying a radio call is how most of these updates will actually arrive. Never Tier C:
`complete` frees a vehicle by closing a commitment and `declined` hands the job back;
neither can authorise a new dispatch."""
def:protect responder_update(
    vehicle_id: str, cluster_id: str, status: str, reason: str | None = None
) -> dict[str, str] {
    who = require("viewer");
    if status not in RESPONDER_STATUSES {
        raise invalid("status must be en_route, on_scene, complete or declined");
    }
    if reason is not None and len(reason) > 300 {
        raise invalid("reason must be at most 300 characters");
    }
    if who.role == "responder" and who.vehicle_id != vehicle_id {
        raise ServiceError(403, f"you are {who.vehicle_id}, not {vehicle_id}");
    }
    return accepted(service().responder(vehicle_id, cluster_id, status, reason));
}

"""The situation report as the commander distributes it. The id is matched against the
SITREPs in state rather than used to build a path, so a traversal in the id cannot
reach a file A6 did not write."""
@restspec(method=HTTPMethod.GET, path="/sitreps/{sitrep_id}/pdf", produces="application/pdf", envelope=False)
def:protect sitrep_pdf(sitrep_id: str) -> bytes {
    require("viewer");
    view = service().view();
    matches = [s for s in (view["sitreps"] if view is not None else []) if s["sitrep_id"] == sitrep_id];
    if not matches {
        raise ServiceError(404, f"no SITREP {sitrep_id}");
    }
    path = Path(matches[0]["pdf_path"]);
    if not path.is_file() {
        raise ServiceError(404, f"{sitrep_id} was rendered to {path.name}, which is no longer there");
    }
    return path.read_bytes();
}

# ------------------------------------------------------------------ commander

"""State the objective once. Everything after that is the system's own decision."""
def:protect open_incident(goal: str) -> dict[str, str] {
    require("commander");
    text = goal.strip();
    if len(text) < 5 or len(text) > 500 {
        raise invalid("goal must be 5 to 500 characters");
    }
    return accepted(service().open(text));
}

"""Approve, reject or modify the plan at the gate: the only Tier C authority. Who
approved is taken from the session, not the request: two commanders on duty are
distinguishable, and one cannot sign in the other's name."""
def:protect decide(
    decision: str, plan_version: int, constraint: str | None = None, publish_alerts: bool = False
) -> dict[str, str] {
    who = require("commander");
    if decision not in DECISIONS {
        raise invalid("decision must be approved, rejected or modified");
    }
    if plan_version < 1 {
        raise invalid("plan_version must be >= 1");
    }
    if constraint is not None and len(constraint) > 500 {
        raise invalid("constraint must be at most 500 characters");
    }
    return accepted(service().decide(ApprovalDecision(decision), plan_version, constraint, publish_alerts, who.username));
}

"""Place a report the gazetteer could not, so it can finally enter the queue. Commander
authority, because placing a report is what lets it be dispatched to; still only Tier A,
because the cluster it creates has to clear triage, the confidence floor and the gate."""
def:protect place_report(report_id: str, lat: float, lon: float) -> dict[str, str] {
    who = require("commander");
    if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lon <= 180.0) {
        raise invalid("coordinates out of range");
    }
    return accepted(service().place(report_id, lat, lon, who.username));
}

"""Cancel a public bulletin and issue the all-clear for the same areas. Tier C, like
issuing one: an all-clear is a public statement about safety, and a wrong one sends
people back into water."""
def:protect stand_down(alert_id: str) -> dict[str, str] {
    who = require("commander");
    return accepted(service().stand_down(alert_id, who.username));
}

"""Emergency halt: freeze all autonomous execution. The incident picture is kept."""
def:protect halt() -> dict[str, str] {
    require("commander");
    return accepted(service().halt());
}

def:protect resume() -> dict[str, str] {
    require("commander");
    return accepted(service().resume());
}

"""A one-time link code binding a device to a call sign."""
def:protect issue_enrolment(vehicle_id: str) -> dict[str, any] {
    require("commander");
    view = service().view();
    known = [v["vehicle_id"] for v in view["vehicles"]] if view is not None else [v.vehicle_id for v in service().vehicles];
    if vehicle_id not in known {
        raise ServiceError(404, f"unknown vehicle {vehicle_id}");
    }
    return issue_code(vehicle_id);
}

"""Every account and device that can sign in. Losing a phone is the normal case in this
domain, so the commander can see them all."""
def:protect list_devices() -> list[dict[str, any]] {
    require("commander");
    return [member_json(m) for m in members() if m.username not in SYSTEM_ACCOUNTS];
}

"""Switch an account off and rotate its password, so nothing issued before still works.
A commander cannot revoke the account they are signed in with."""
def:protect revoke_device(username: str) -> dict[str, bool] {
    who = require("commander");
    target = find_member(username);
    if target is None or target.disabled {
        raise ServiceError(404, "no such live account");
    }
    if target.username == who.username {
        raise ServiceError(409, "you cannot revoke the account you are signed in with");
    }
    disable_member(target);
    return {"ok": True};
}

"""Create a named account. Responder accounts are issued by enrolment link instead."""
def:protect create_account(
    username: str, password: str, role: str, display_name: str = ""
) -> dict[str, any] {
    require("commander");
    if role not in ["commander", "dispatcher", "citizen"] {
        raise invalid("role must be commander, dispatcher or citizen; responders enrol with a link");
    }
    if len(password) < 8 {
        raise invalid("password must be at least 8 characters");
    }
    return member_json(create_member(username, password, role, display_name or username));
}

def:protect list_accounts() -> list[dict[str, any]] {
    require("commander");
    return [member_json(m) for m in members()];
}
