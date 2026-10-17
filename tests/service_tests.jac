"""The incident service over the real loop, agents and synthetic world, offline.

Writes are queued; `service.process_pending()` runs them synchronously so each test
sees a deterministic outcome without a background writer. The endpoints are called
directly: `act_as(role)` makes the caller a member of the roster (the caller is the
member whose `root_id` is the caller's own root), and `anonymous()` removes that, so the
public / signed-in / commander distinctions are exercised exactly where they are
enforced."""

import json;
import time;
import uuid;
import networkx as nx;
import from pathlib { Path }
import from shapely.geometry { LineString }
import from datetime { datetime, timedelta, UTC }
import from resqmesh.adapters.geo.roads { iter_edge_ids }
import from resqmesh.contracts.enums { ApprovalDecision, IncidentStatus, LocationSource, SourceChannel }
import from resqmesh.contracts.models { ActionTier, RawSignal, TraceEvent, evolve }
import from resqmesh.contracts.state { copy_state, new_state }
import from resqmesh.service.app { Runtime, _RUNTIME, build_service }
import from resqmesh.service.auth { AuthSettings, AuthState, Member, members, require, roster }
import from resqmesh.service.core {
    COMMAND_LOG, DEDUPE_WINDOW_S, Command, IncidentService, ServiceError
}
import from resqmesh.service.endpoints {
    decide, get_incident, halt, health, open_incident, place_report, public_alerts, responder_update,
    resume, sitrep_pdf, stand_down, submit_report, telegram_webhook
}
import from resqmesh.service.view { TRACE_TAIL, blocked_road_features, build_view }

glob GOAL: str = "coordinate the response to flooding in the Kelani basin";
glob SALT: str = "test-salt";
glob TG_SECRET: str = "tg-secret";

# Two sources per place: one uncorroborated report scores 0.40, below the 0.50 dispatch
# floor, so a single report never produces an assignment to act on.
glob REPORTS: list[tuple[str, str]] = [
    ("Flooding in Kolonnawa, 12 people trapped, elderly couple on the roof. Urgent!", "0771111111"),
    ("Water rising fast at Kolonnawa, children stranded", "0772222222"),
    ("Kolonnawa families stranded, water above knee level", "0773333333"),
    ("Patient needs dialysis at Hanwella, 3 people cannot leave. Critical", "0774444444"),
    ("Hanwella dialysis patient confirmed, urgent medical help", "0775555555")
];

# ------------------------------------------------------------------ helpers

"""A fresh offline service over the synthetic world, installed as the runtime the
endpoints serve. `mode` is the deployment's auth mode."""
def fresh(mode: str = "static") -> IncidentService {
    svc = build_service(llm_mode="offline", persisted=False);
    settings = AuthSettings(mode=mode, salt=SALT, telegram_secret=TG_SECRET);
    _RUNTIME["runtime"] = Runtime(service=svc, auth=AuthState(settings=settings));
    return svc;
}

"""Make the test's own root a signed-in member with this role. Any earlier member bound
to the same root is switched off, so the caller is always exactly the last one made."""
def act_as(role: str, vehicle_id: str | None = None) -> Member {
    rid = jid(root);
    for m in members() {
        if m.root_id == rid {
            m.disabled = True;
        }
    }
    who = Member(
        user_id=f"u-{uuid.uuid4().hex[:8]}", root_id=rid, username=f"{role}-{uuid.uuid4().hex[:8]}",
        display_name=f"{role} on duty", role=role, vehicle_id=vehicle_id
    );
    roster() ++> who;
    return who;
}

"""Sign out: no member is bound to the caller's root."""
def anonymous() -> None {
    rid = jid(root);
    for m in members() {
        if m.root_id == rid {
            m.disabled = True;
        }
    }
}

"""The HTTP-meaning status of the refusal a `testraises(ServiceError) as ei` block caught."""
def status_of(caught: any) -> int {
    err: any = caught.value;
    return err.status;
}

"""A commander opens the incident and five reports from four sources arrive; the loop
runs until it needs a decision. Returns the incident view."""
def at_gate(svc: IncidentService) -> dict[str, any] {
    act_as("commander");
    open_incident(GOAL);
    svc.process_pending();
    for (text, phone) in REPORTS {
        submit_report(text, source=phone);
    }
    svc.process_pending();
    return get_incident();
}

"""At the gate, then the commander approves the current plan (alerts published when asked).
Returns the view after the release."""
def approved(svc: IncidentService, publish: bool = False) -> dict[str, any] {
    view = at_gate(svc);
    decide("approved", view["plan"]["version"], None, publish);
    svc.process_pending();
    return get_incident();
}

def open_only(svc: IncidentService) -> None {
    act_as("commander");
    open_incident(GOAL);
    svc.process_pending();
}

def signal(n: int, body: str, source: str = "src-x") -> RawSignal {
    return RawSignal(
        signal_id=f"SIG-{n}", channel=SourceChannel.WEB_FORM, source_id=source, body=body,
        received_at=datetime.now(UTC)
    );
}

def events(view: dict[str, any], action: str) -> list[dict[str, any]] {
    return [e for e in view["trace"] if e["action"] == action];
}

# ------------------------------------------------------------------ the lifecycle

test "no incident is not found until opened" {
    svc = fresh();
    act_as("commander");
    with testraises(ServiceError) as ei {
        get_incident();
    }
    assert status_of(ei) == 404 and "not_found" in str(ei.value);
    assert svc.view() is None and not svc.is_open();
    open_incident(GOAL);
    svc.process_pending();
    assert get_incident()["goal"] == GOAL and svc.is_open();
}

test "a second open is refused, even while the first is still queued" {
    svc = fresh();
    act_as("commander");
    open_incident(GOAL);
    with testraises(ServiceError) as queued {
        svc.open("a different goal entirely");
    }
    assert status_of(queued) == 409;
    svc.process_pending();
    with testraises(ServiceError) as opened {
        open_incident("another goal after it opened");
    }
    assert status_of(opened) == 409 and "already open" in str(opened.value);
}

test "reports before opening are refused" {
    svc = fresh();
    with testraises(ServiceError) as ei {
        submit_report("Flooding in Kolonnawa");
    }
    assert status_of(ei) == 404;
    assert svc.queued() == [];
}

test "reports drive the loop to the gate" {
    svc = fresh();
    view = at_gate(svc);
    assert view["status"] == IncidentStatus.AWAITING_APPROVAL.value;
    assert view["awaiting_decision"]["plan_version"] == view["plan"]["version"];
    assert view["awaiting_decision"]["plan_id"] == view["plan"]["plan_id"];
    assert view["verdict"]["passed"] is True;
    assert {c["gn_id"] for c in view["clusters"]} == {"KLN-003", "KLN-004"};
    assert view["busy"] is False;
}

test "consecutive reports are batched into one loop pass" {
    svc = fresh();
    view = at_gate(svc);
    ingests = [e for e in view["trace"] if e["agent"] == "A1"];
    assert len(ingests) == 1;
    assert ingests[0]["detail"].startswith("ingested 5 signal(s)");
    # five report commands, each logged once and finished by that single pass
    reports = [c for c in view["commands"] if c["kind"] == "report"];
    assert len(reports) == 5 and all([c["status"] == "done" for c in reports]);
}

test "reports separated by another command are not batched together" {
    svc = fresh();
    open_only(svc);
    svc.submit_report(signal(1, "Flooding in Kolonnawa, 12 people trapped"));
    svc.halt();
    svc.submit_report(signal(2, "Flooding in Hanwella, 6 people trapped"));
    svc.process_pending();
    view = svc.view();
    assert view is not None;
    # the halt froze the loop between the two groups, so the second group was not ingested
    assert len([r for r in view["reports"] if r["signal_id"] == "SIG-1"]) == 1;
    assert len([r for r in view["reports"] if r["signal_id"] == "SIG-2"]) == 0;
    assert len(events(view, "signals_ingested")) == 1;
}

test "the view is everything the console needs" {
    svc = fresh();
    view = at_gate(svc);
    assert view["queue"] and all(["components" in q and "weights" in q for q in view["queue"]]);
    assert view["divisions"]["KLN-003"]["name"] == "Kolonnawa";
    assert view["hazard"]["inundation_geojson"]["type"] == "FeatureCollection";
    assert len(view["vehicles"]) == 5;
    assert view["llm"]["chain"] == ["stub"];
    assert view["commands"][0]["kind"] == "report" and view["commands"][0]["status"] == "done";
    assert view["incident_id"] and view["updated_at"];
}

test "routes follow the road graph" {
    svc = fresh();
    view = at_gate(svc);
    assert view["routes"] and len(view["routes"]) == len(view["plan"]["assignments"]);
    for route in view["routes"] {
        assert len(route["coordinates"]) >= 2 or route["approximate"];
        # GeoJSON order: [lon, lat]
        lon = route["coordinates"][0][0];
        lat = route["coordinates"][0][1];
        assert 79.8 < lon < 80.0 and 6.8 < lat < 7.0;
    }
}

test "blocked roads include edges removed from the routing graph" {
    svc = fresh();
    view = at_gate(svc);
    blocked = set(view["hazard"]["impassable_edge_ids"]);
    assert blocked;
    features = view["blocked_roads_geojson"]["features"];
    assert {f["properties"]["edge_id"] for f in features} == blocked;
    assert all([f["properties"]["status"] == "impassable" for f in features]);
    road_graph = svc.routing_graph(svc.runner.state());
    assert road_graph is not None;
    # impassable edges are gone from the pruned graph, which is why the view needs the original
    assert blocked.isdisjoint(set(iter_edge_ids(road_graph)));
    for feature in features {
        lon = feature["geometry"]["coordinates"][0][0];
        lat = feature["geometry"]["coordinates"][0][1];
        assert 79.8 < lon < 80.0 and 6.8 < lat < 7.0;
    }
}

test "blocked roads unavailable is distinct from clear" {
    svc = fresh();
    at_gate(svc);
    assert get_incident()["hazard"]["impassable_edge_ids"];
    # no original graph: the geometry is unavailable, which is not the same as no blocked roads
    svc.base_graph_loader = None;
    svc.publish();
    view = get_incident();
    assert view["hazard"]["impassable_edge_ids"];
    assert view["blocked_roads_geojson"] is None;
    # a hazard with nothing impassable is a real, empty collection even without the graph
    state = copy_state(svc.runner.state());
    assert state.hazard is not None;
    state.hazard = evolve(state.hazard, impassable_edge_ids=[]);
    assert svc.blocked_roads(state) == {"type": "FeatureCollection", "features": []};
    # and no hazard surface at all is unavailable again
    state.hazard = None;
    assert svc.blocked_roads(state) is None;
}

test "a failing graph loader leaves blocked road geometry unavailable" {
    svc = fresh();
    at_gate(svc);
    def broken() -> any {
        raise RuntimeError("graph file missing");
    }
    svc.base_graph_loader = broken;
    svc.publish();
    assert get_incident()["blocked_roads_geojson"] is None;
}

test "blocked road geometry preserves bends and ignores unknown edges" {
    g = nx.MultiDiGraph();
    g.add_node(1, x=79.9, y=6.9);
    g.add_node(2, x=79.92, y=6.91);
    shape = LineString([(79.9, 6.9), (79.915, 6.905), (79.92, 6.91)]);
    g.add_edge(1, 2, key=0, geometry=shape);
    g.add_edge(2, 1, key=0);
    features = blocked_road_features(g, ["1-2-0", "missing-edge-0"])["features"];
    assert len(features) == 1;
    assert features[0]["geometry"] == {
        "type": "LineString", "coordinates": [[79.9, 6.9], [79.915, 6.905], [79.92, 6.91]]
    };
    assert features[0]["properties"] == {"edge_id": "1-2-0", "status": "impassable"};
    assert blocked_road_features(g, [])["features"] == [];
    # an edge with no stored geometry is the straight segment between its nodes
    straight = blocked_road_features(g, ["2-1-0"])["features"][0]["geometry"];
    assert straight == {"type": "LineString", "coordinates": [[79.92, 6.91], [79.9, 6.9]]};
}

test "approval releases the plan" {
    svc = fresh();
    view = at_gate(svc);
    out = decide("approved", view["plan"]["version"]);
    assert out["status"] == "queued" and out["command_id"].startswith("CMD-");
    svc.process_pending();
    after = get_incident();
    assert after["status"] == IncidentStatus.EXECUTING.value;
    assert after["awaiting_decision"] is None;
    assert len(events(after, "dispatch_released")) >= 1;
}

test "a stale decision is refused immediately" {
    svc = fresh();
    view = at_gate(svc);
    with testraises(ServiceError) as ei {
        decide("approved", view["plan"]["version"] + 1);
    }
    assert status_of(ei) == 409 and "stale decision" in str(ei.value);
    assert svc.queued() == [];
}

test "rejection resolves under the constraint" {
    svc = fresh();
    view = at_gate(svc);
    used = view["plan"]["assignments"][0]["vehicle_id"];
    decide("rejected", view["plan"]["version"], f"exclude_vehicle: {used}");
    svc.process_pending();
    after = get_incident();
    assert after["plan"]["version"] == view["plan"]["version"] + 1;
    assert used not in [a["vehicle_id"] for a in after["plan"]["assignments"]];
    assert after["awaiting_decision"]["plan_version"] == after["plan"]["version"];
}

test "halt and resume" {
    svc = fresh();
    at_gate(svc);
    halt();
    svc.process_pending();
    assert get_incident()["status"] == IncidentStatus.HALTED.value;
    submit_report("Flooding in Pahathgama, 8 people trapped", source="x");
    svc.process_pending();
    # frozen: nothing processed
    assert len(get_incident()["reports"]) == len(REPORTS);
    resume();
    svc.process_pending();
    assert len(get_incident()["reports"]) == len(REPORTS) + 1;
}

test "a halted incident invites no decision" {
    svc = fresh();
    view = at_gate(svc);
    assert view["awaiting_decision"] is not None;
    halt();
    svc.process_pending();
    assert get_incident()["awaiting_decision"] is None;
}

test "a failed command is recorded not fatal" {
    svc = fresh();
    at_gate(svc);
    # Queued past the up-front checks: a bulletin that does not exist cannot be stood down.
    svc.submit(Command(kind="stand_down", payload={"alert_id": "AL-nope", "author": "cmdr-x"}));
    svc.process_pending();
    view = get_incident();
    cmd = view["commands"][0];
    assert cmd["kind"] == "stand_down" and cmd["status"] == "failed";
    assert "LookupError" in cmd["detail"] and "AL-nope" in cmd["detail"];
    assert view["status"] == IncidentStatus.AWAITING_APPROVAL.value;
    # the writer survived and carries on
    submit_report("Flooding in Pahathgama, 8 people trapped", source="y");
    svc.process_pending();
    assert get_incident()["commands"][0]["status"] == "done";
    assert get_incident()["commands"][0]["kind"] == "report";
    assert svc.busy is False;
}

test "invalid requests are 422" {
    svc = fresh();
    act_as("commander");
    for goal in ["x", "    ", "g" * 501] {
        with testraises(ServiceError) as ei {
            open_incident(goal);
        }
        assert status_of(ei) == 422 and "invalid" in str(ei.value);
    }
    assert svc.queued() == [];
    view = at_gate(svc);
    version = view["plan"]["version"];
    with testraises(ServiceError) as zero {
        decide("approved", 0);
    }
    assert status_of(zero) == 422;
    with testraises(ServiceError) as long_note {
        decide("rejected", version, "c" * 501);
    }
    assert status_of(long_note) == 422;
}

test "countermanded is not a commander decision" {
    svc = fresh();
    view = at_gate(svc);
    with testraises(ServiceError) as ei {
        decide("countermanded", view["plan"]["version"]);
    }
    assert status_of(ei) == 422;
    assert svc.queued() == [];
}

test "a public report is validated before it is queued" {
    svc = fresh();
    open_only(svc);
    anonymous();
    bad: list[dict[str, any]] = [
        {"text": "   "},
        {"text": "t" * 4001},
        {"text": "ok", "source": "s" * 201},
        {"text": "ok", "lang": "fr"},
        {"text": "ok", "lat": 91.0},
        {"text": "ok", "lon": -181.0},
        {"text": "ok", "accuracy_m": -1.0},
        {"text": "ok", "channel": "pigeon"},
        {"text": "ok", "location_source": "guess"}
    ];
    for kwargs in bad {
        with testraises(ServiceError) as ei {
            submit_report(**kwargs);
        }
        assert status_of(ei) == 422, f"{kwargs} should be invalid";
    }
    assert svc.queued() == [];
    assert submit_report("t" * 4000)["status"] == "queued";
    assert submit_report("water at the bridge", lat=6.9, lon=79.9, accuracy_m=0.0)["status"] == "queued";
    assert len(svc.queued()) == 2;
}

# ------------------------------------------------------------------ privacy

test "reporter numbers never appear in the view" {
    svc = fresh();
    view = at_gate(svc);
    blob = json.dumps(view);
    for (_, phone) in REPORTS {
        assert phone not in blob;
    }
    assert all([r["source_id"].startswith("src:") for r in view["reports"]]);
    # the same number is the same pseudonym, so corroboration still works without the number
    first = submit_report("Kolonnawa again, water higher", source="0771111111");
    svc.process_pending();
    ids = [r["source_id"] for r in get_incident()["reports"]];
    assert ids[0] == ids[-1];
    assert first["status"] == "queued";
}

# ------------------------------------------------------------------ auth: only a commander can authorise

test "health reports whether auth is on and which scheme" {
    for (mode, auth, needs_setup) in [("open", "open", False), ("static", "token", False)] {
        fresh(mode);
        out = health();
        assert out["status"] == "ok" and out["incident_open"] is False;
        assert out["auth"] == auth and out["auth_mode"] == mode;
        # neither mode has an account store, so neither offers first-run setup
        assert out["needs_setup"] is needs_setup;
    }
}

test "health says starting until the application has booted" {
    _RUNTIME.pop("runtime", None);
    out = health();
    assert out["status"] == "starting" and out["incident_open"] is False and out["needs_setup"] is False;
    # everything else answers unavailable, which clients retry
    with testraises(ServiceError) as ei {
        submit_report("Flooding in Kolonnawa");
    }
    assert status_of(ei) == 503 and "unavailable" in str(ei.value);
}

test "the tactical picture needs a session" {
    svc = fresh();
    open_only(svc);
    anonymous();
    for status in [1, 2, 3, 4, 5] {
        # every protected endpoint refuses the anonymous caller the same way
        try {
            if status == 1 { get_incident(); }
            elif status == 2 { open_incident(GOAL); }
            elif status == 3 { halt(); }
            elif status == 4 { resume(); }
            else { decide("approved", 1); }
            assert False, "an anonymous caller must be refused";
        } except ServiceError as exc {
            assert exc.status == 401, f"endpoint {status}: {exc}";
            assert "unauthorized" in str(exc);
        }
    }
    with testraises(ServiceError) as ei {
        require("viewer");
    }
    assert status_of(ei) == 401;
}

test "a viewer can read but not decide" {
    svc = fresh();
    view = at_gate(svc);
    act_as("dispatcher");
    assert get_incident()["goal"] == GOAL;
    with testraises(ServiceError) as decided {
        decide("approved", view["plan"]["version"]);
    }
    assert status_of(decided) == 403 and "forbidden" in str(decided.value);
    with testraises(ServiceError) as halted {
        halt();
    }
    assert status_of(halted) == 403;
    with testraises(ServiceError) as opened {
        open_incident("a new goal should not be possible");
    }
    assert status_of(opened) == 403;
    assert svc.queued() == [];
}

test "an account that may not read the picture is refused" {
    svc = fresh();
    at_gate(svc);
    act_as("citizen");
    with testraises(ServiceError) as ei {
        get_incident();
    }
    assert status_of(ei) == 403;
}

# ------------------------------------------------------------------ the public routes

test "the public can report without a token" {
    svc = fresh("static");
    open_only(svc);
    anonymous();
    out = submit_report("Flooding in Kolonnawa, 12 trapped");
    assert out["status"] == "queued";
    svc.process_pending();
    act_as("commander");
    reports = get_incident()["reports"];
    assert any(["Kolonnawa" in r["description"] for r in reports]);
}

test "public alerts need no token and leak no tactical state" {
    svc = fresh();
    anonymous();
    # no incident yet: an empty list, not an error
    assert public_alerts() == [];
    view = at_gate(svc);
    decide("approved", view["plan"]["version"], None, True);
    svc.process_pending();
    anonymous();
    alerts = public_alerts();
    assert alerts, "an approved plan should publish at least one bulletin";
    for alert in alerts {
        # every bulletin is approval-gated and trilingual
        assert alert["approval_id"];
        assert alert["text_si"] and alert["text_ta"] and alert["text_en"];
        # and carries nothing the public has no business seeing
        assert len({"clusters", "plan", "vehicles", "trace", "reports"}.intersection(set(alert.keys()))) == 0;
    }
}

test "approving without publish_alerts publishes no bulletin" {
    svc = fresh();
    approved(svc, False);
    anonymous();
    assert public_alerts() == [];
}

# ------------------------------------------------------------------ telegram webhook

def update(uid: int, text: str, sender: int = 424242) -> dict[str, any] {
    return {
        "message_id": uid, "date": 1790000000, "text": text, "from": {"id": sender}, "chat": {"id": sender}
    };
}

test "the webhook rejects a bad secret" {
    svc = fresh();
    at_gate(svc);
    anonymous();
    with testraises(ServiceError) as ei {
        telegram_webhook("wrong", update_id=1, message=update(1, "Flooding in Pahathgama"));
    }
    assert status_of(ei) == 401;
    assert svc.queued() == [];
}

test "the webhook is disabled without a secret" {
    svc = fresh();
    _RUNTIME["runtime"] = Runtime(service=svc, auth=AuthState(settings=AuthSettings(mode="open", salt=SALT)));
    with testraises(ServiceError) as ei {
        telegram_webhook("", update_id=1, message=update(1, "x"));
    }
    assert status_of(ei) == 503;
}

test "the webhook ingests and pseudonymises the sender" {
    svc = fresh();
    at_gate(svc);
    anonymous();
    out = telegram_webhook(TG_SECRET, update_id=7, message=update(7, "Flooding in Pahathgama, 8 people trapped"));
    assert out == {"ok": True};
    svc.process_pending();
    act_as("commander");
    view = get_incident();
    tg = [r for r in view["reports"] if r["signal_id"] == "TG-7"];
    assert tg and tg[0]["resolved_gn_id"] == "KLN-008";
    assert "424242" not in json.dumps(view);
}

test "the webhook ignores non-text updates" {
    svc = fresh();
    at_gate(svc);
    before = len(get_incident()["reports"]);
    anonymous();
    out = telegram_webhook(TG_SECRET, update_id=9);
    assert out == {"ok": True};
    svc.process_pending();
    act_as("commander");
    assert len(get_incident()["reports"]) == before;
}

test "the webhook answers ok but records nothing while no incident is open" {
    svc = fresh();
    out = telegram_webhook(TG_SECRET, update_id=3, message=update(3, "Flooding in Pahathgama"));
    assert out == {"ok": True};
    assert svc.queued() == [] and svc.view() is None;
}

# ------------------------------------------------------------------ responders

def first_assignment(view: dict[str, any]) -> dict[str, any] {
    assert view["plan"]["assignments"];
    return view["plan"]["assignments"][0];
}

test "responder complete frees the cluster" {
    svc = fresh();
    a = first_assignment(approved(svc));
    out = responder_update(a["vehicle_id"], a["cluster_id"], "complete");
    assert out["status"] == "queued";
    svc.process_pending();
    view = get_incident();
    assert a["cluster_id"] in view["completed_cluster_ids"];
    assert len([e for e in view["trace"] if e["agent"] == "OPS" and e["action"] == "responder_complete"]) == 1;
}

test "responder status is recorded without completing" {
    svc = fresh();
    a = first_assignment(approved(svc));
    responder_update(a["vehicle_id"], a["cluster_id"], "en_route", "leaving the depot");
    svc.process_pending();
    view = get_incident();
    assert view["completed_cluster_ids"] == [];
    assert len(events(view, "responder_en_route")) == 1;
}

test "a responder cannot report on a dispatch that was never made" {
    svc = fresh();
    view = approved(svc);
    a = first_assignment(view);
    other = [v["vehicle_id"] for v in view["vehicles"] if v["vehicle_id"] != a["vehicle_id"]][0];
    with testraises(ServiceError) as ei {
        responder_update(other, a["cluster_id"], "complete");
    }
    assert status_of(ei) == 409 and "no dispatch in progress" in str(ei.value);
    assert get_incident()["completed_cluster_ids"] == [];
    assert svc.queued() == [];
}

test "a responder update for an unknown vehicle is not found" {
    svc = fresh();
    approved(svc);
    with testraises(ServiceError) as ei {
        responder_update("HOVERCRAFT-99", "CL-1", "complete");
    }
    assert status_of(ei) == 404 and "unknown vehicle" in str(ei.value);
}

test "a responder update before the gate has no dispatch to report on" {
    svc = fresh();
    view = at_gate(svc);
    a = first_assignment(view);
    # planned, not released: an assignment alone is not authority to report
    with testraises(ServiceError) as ei {
        responder_update(a["vehicle_id"], a["cluster_id"], "complete");
    }
    assert status_of(ei) == 409;
}

test "a responder update needs an open incident" {
    svc = fresh();
    act_as("commander");
    with testraises(ServiceError) as ei {
        responder_update("BOAT-01", "X", "complete");
    }
    assert status_of(ei) == 404;
}

test "a responder update is validated" {
    svc = fresh();
    a = first_assignment(approved(svc));
    with testraises(ServiceError) as status {
        responder_update(a["vehicle_id"], a["cluster_id"], "teleported");
    }
    assert status_of(status) == 422;
    with testraises(ServiceError) as note {
        responder_update(a["vehicle_id"], a["cluster_id"], "declined", "n" * 301);
    }
    assert status_of(note) == 422;
    assert svc.queued() == [];
}

test "a declined dispatch hands the job back without completing it" {
    svc = fresh();
    a = first_assignment(approved(svc));
    responder_update(a["vehicle_id"], a["cluster_id"], "declined", "boat engine failure");
    svc.process_pending();
    view = get_incident();
    assert a["cluster_id"] not in view["completed_cluster_ids"];
    assert len(events(view, "responder_declined")) == 1;
}

# ------------------------------------------------------------------ held reports

test "a held report can be placed and then enters the queue" {
    svc = fresh();
    at_gate(svc);
    submit_report("behind the temple, water everywhere, three children");
    svc.process_pending();
    held = get_incident()["unresolved"];
    # an unplaceable report is held rather than guessed at
    assert held;
    report_id = held[0]["report_id"];
    who = act_as("commander");
    out = place_report(report_id, 6.9060, 79.9070);
    assert out["status"] == "queued";
    svc.process_pending();
    view = get_incident();
    assert report_id not in [u["report_id"] for u in view["unresolved"]];
    assert any([report_id in c["member_report_ids"] for c in view["clusters"]]);
    placed = [e for e in view["trace"] if e["action"] == "report_placed"];
    assert len(placed) == 1 and placed[0]["human_touch"] is True;
    # attributed to the signed-in commander
    assert who.username in placed[0]["detail"];
}

test "placing a report that is not held is refused" {
    svc = fresh();
    at_gate(svc);
    with testraises(ServiceError) as ei {
        place_report("R-nope", 6.9060, 79.9070);
    }
    assert status_of(ei) == 404 and "not in the held queue" in str(ei.value);
    assert svc.queued() == [];
}

test "placing a report needs commander authority and a real coordinate" {
    svc = fresh();
    at_gate(svc);
    with testraises(ServiceError) as range_error {
        place_report("R-nope", 91.0, 79.9);
    }
    assert status_of(range_error) == 422;
    act_as("dispatcher");
    with testraises(ServiceError) as desk {
        place_report("R-nope", 6.9, 79.9);
    }
    assert status_of(desk) == 403;
    anonymous();
    with testraises(ServiceError) as nobody {
        place_report("R-nope", 6.9, 79.9);
    }
    assert status_of(nobody) == 401;
}

test "a reported coordinate reaches the cluster" {
    svc = fresh();
    at_gate(svc);
    submit_report(
        "water rising fast", lat=6.9060, lon=79.9070, accuracy_m=12.0,
        location_source=LocationSource.GPS.value
    );
    svc.process_pending();
    view = get_incident();
    gps = [r for r in view["reports"] if r["location_source"] == "gps"];
    assert len(gps) == 1;
    assert gps[0]["lat"] == 6.9060 and gps[0]["lon"] == 79.9070;
    assert gps[0]["resolved_gn_id"];
    assert any([gps[0]["report_id"] in c["member_report_ids"] for c in view["clusters"]]);
}

# ------------------------------------------------------------------ bulletins

test "a bulletin can be stood down and the public is told" {
    svc = fresh();
    approved(svc, True);
    published = public_alerts();
    # an approved broadcast publishes at least one bulletin
    assert published;
    first = published[0];
    who = act_as("commander");
    out = stand_down(first["alert_id"]);
    assert out["status"] == "queued";
    svc.process_pending();
    anonymous();
    ids = {a["alert_id"]: a for a in public_alerts()};
    # the cancelled warning is off the public page
    assert first["alert_id"] not in ids;
    clear = ids[f"{first['alert_id']}-CLEAR"];
    assert clear["template_id"] == "stand_down";
    assert clear["text_si"] and clear["text_ta"] and clear["text_en"];
    # an all-clear has nothing to stop being true
    assert clear["expires_at"] is None;
    # Tier C and attributed, like issuing one
    act_as("commander");
    stood = events(get_incident(), "alert_stood_down");
    assert len(stood) == 1;
    assert stood[0]["tier"] == ActionTier.TIER_C.value and stood[0]["human_touch"] is True;
    assert f"cancelled by {who.username}" in stood[0]["detail"];
}

test "standing down a bulletin that is not current is refused" {
    svc = fresh();
    at_gate(svc);
    with testraises(ServiceError) as ei {
        stand_down("AL-nope");
    }
    assert status_of(ei) == 404 and "not a current bulletin" in str(ei.value);
    assert svc.queued() == [];
}

test "a stood down bulletin cannot be stood down again" {
    svc = fresh();
    approved(svc, True);
    first = public_alerts()[0];
    act_as("commander");
    stand_down(first["alert_id"]);
    svc.process_pending();
    with testraises(ServiceError) as ei {
        stand_down(first["alert_id"]);
    }
    assert status_of(ei) == 404;
}

test "a viewer cannot stand down a bulletin" {
    # An all-clear is a public statement about safety: a wrong one sends people back
    # into water. It is not the harmless half of the pair.
    svc = fresh();
    at_gate(svc);
    act_as("dispatcher");
    with testraises(ServiceError) as ei {
        stand_down("AL-anything");
    }
    assert status_of(ei) == 403;
}

test "each new alert reaches the sink once" {
    svc = fresh();
    sent: list[str] = [];
    def sink(alert: any) -> None {
        sent.append(alert.alert_id);
    }
    svc.alert_sink = sink;
    approved(svc, True);
    live = [a["alert_id"] for a in public_alerts()];
    assert live and set(live).issubset(set(sent));
    count = len(sent);
    assert count == len(set(sent));
    # more writes, no new bulletin: nothing is re-sent
    halt();
    svc.process_pending();
    assert len(sent) == count;
}

test "a failing alert sink never stops the writer" {
    svc = fresh();
    calls: list[str] = [];
    def sink(alert: any) -> None {
        calls.append(alert.alert_id);
        raise RuntimeError("telegram is down");
    }
    svc.alert_sink = sink;
    view = approved(svc, True);
    assert view["status"] == IncidentStatus.EXECUTING.value;
    assert calls;
    n = len(calls);
    # a bad alert is attempted once, not retried forever
    halt();
    svc.process_pending();
    assert len(calls) == n and get_incident()["status"] == IncidentStatus.HALTED.value;
}

# ------------------------------------------------------------------ the SITREP

test "the sitrep pdf is reachable and cannot be traversed" {
    svc = fresh();
    view = approved(svc);
    assert view["sitreps"], "an approved plan publishes a SITREP";
    body = sitrep_pdf(view["sitreps"][0]["sitrep_id"]);
    # reportlab, or the plain-text fallback
    assert body[:4] == b"%PDF" or body[:4] == b"RESQ";
    # the id names a SITREP in state; it never builds a path
    for bad in ["../../../etc/passwd", "..%2f..%2fetc%2fpasswd", "/etc/passwd", "SR-nope"] {
        with testraises(ServiceError) as ei {
            sitrep_pdf(bad);
        }
        assert status_of(ei) == 404;
    }
}

test "a sitrep whose file is gone is not found" {
    svc = fresh();
    view = approved(svc);
    sitrep = view["sitreps"][0];
    Path(sitrep["pdf_path"]).unlink();
    with testraises(ServiceError) as ei {
        sitrep_pdf(sitrep["sitrep_id"]);
    }
    assert status_of(ei) == 404 and "no longer there" in str(ei.value);
}

test "the sitrep needs a session" {
    svc = fresh();
    view = approved(svc);
    sitrep_id = view["sitreps"][0]["sitrep_id"];
    anonymous();
    with testraises(ServiceError) as ei {
        sitrep_pdf(sitrep_id);
    }
    assert status_of(ei) == 401;
}

# ------------------------------------------------------------------ routes and the view

test "a vehicle already on site is not an approximate route" {
    svc = fresh();
    view = at_gate(svc);
    on_site = {a["vehicle_id"] for a in view["plan"]["assignments"] if not a["route_edge_ids"]};
    for route in view["routes"] {
        if route["vehicle_id"] in on_site {
            assert route["approximate"] is False;
            # a real, zero-length trip between the depot and the cluster
            assert len(route["coordinates"]) == 2;
        }
    }
}

test "missing route geometry is drawn as an approximate straight line" {
    svc = fresh();
    view = at_gate(svc);
    assert [a for a in view["plan"]["assignments"] if a["route_edge_ids"]], "the scenario must have a real road route";
    # without the graph a routed assignment can only be a dashed straight line
    svc.graph_loader = None;
    svc.publish();
    after = get_incident();
    by_vehicle = {r["vehicle_id"]: r for r in after["routes"]};
    for a in view["plan"]["assignments"] {
        route = by_vehicle[a["vehicle_id"]];
        assert route["approximate"] is bool(a["route_edge_ids"]);
        assert len(route["coordinates"]) == 2;
    }
}

def lost_graph(path: str) -> any {
    raise FileNotFoundError(f"road graph not found at {path}");
}

test "a routing graph that is gone from disk is rebuilt, so routes keep their road geometry" {
    svc = fresh();
    view = at_gate(svc);
    routed = {a["vehicle_id"] for a in view["plan"]["assignments"] if a["route_edge_ids"]};
    assert routed, "the scenario must have a real road route";
    before = {r["vehicle_id"]: r["coordinates"] for r in view["routes"]};
    # a resumed incident whose pruned graph file no longer exists
    svc.graph_loader = lost_graph;
    svc.graphs = {};
    svc.publish();
    after = {r["vehicle_id"]: r for r in get_incident()["routes"]};
    for vid in routed {
        assert after[vid]["approximate"] is False;
        assert after[vid]["coordinates"] == before[vid];
    }
}

test "with neither the routing graph nor the road network the route is a dashed straight line" {
    svc = fresh();
    view = at_gate(svc);
    svc.graph_loader = lost_graph;
    svc.base_graph_loader = None;
    svc.graphs = {};
    svc.publish();
    for r in get_incident()["routes"] {
        a = [x for x in view["plan"]["assignments"] if x["vehicle_id"] == r["vehicle_id"]][0];
        assert r["approximate"] is bool(a["route_edge_ids"]);
    }
}

test "the trace tail is the newest 200 events" {
    assert TRACE_TAIL == 200;
    state = new_state("INC-T", "a goal");
    state.trace = [
        TraceEvent(
            event_id=f"E-{i:04d}", agent="OPS", action="note", tier=ActionTier.TIER_A,
            occurred_at=datetime(2026, 10, 1, 6, 0, tzinfo=UTC) + timedelta(seconds=i)
        )
        for i in range(250)
    ];
    view = build_view(state, False, [], {}, {}, [], None);
    assert len(view["trace"]) == 200;
    assert view["trace"][0]["event_id"] == "E-0050" and view["trace"][-1]["event_id"] == "E-0249";
    state.trace = state.trace[:10];
    assert len(build_view(state, False, [], {}, {}, [], None)["trace"]) == 10;
}

test "a real incident view carries no more than the trace tail" {
    svc = fresh();
    view = approved(svc);
    assert 0 < len(view["trace"]) <= TRACE_TAIL;
}

# ------------------------------------------------------------------ commands: log and dedupe

test "the command log keeps the newest 25 entries" {
    assert COMMAND_LOG == 25;
    svc = fresh();
    open_only(svc);
    ids: list[str] = [];
    for i in range(30) {
        ids.append(svc.submit(Command(kind="stand_down", payload={"alert_id": f"AL-{i}", "author": "cmdr-x"})));
    }
    # distinct commands, so none collapsed
    assert len(set(ids)) == 30;
    svc.process_pending();
    log = svc.view()["commands"];
    assert len(log) == COMMAND_LOG;
    # newest first, one line per command, the oldest dropped
    assert log[0]["command_id"] == ids[-1];
    assert [c["command_id"] for c in log] == list(reversed(ids))[:25];
    assert ids[0] not in [c["command_id"] for c in log];
    assert all([c["status"] == "failed" for c in log]);
}

test "an identical command inside the window collapses into the first" {
    assert DEDUPE_WINDOW_S == 8.0;
    svc = fresh();
    open_only(svc);
    sig = signal(1, "Flooding in Kolonnawa, 12 people trapped", "src-same");
    first = svc.submit_report(sig);
    # same body, source and place: a double click, or the runtime re-running an endpoint
    again = svc.submit_report(signal(2, "Flooding in Kolonnawa, 12 people trapped", "src-same"));
    assert again == first;
    assert len(svc.queued()) == 1;
    assert len([c for c in svc.view()["commands"] if c["kind"] == "report"]) == 1;
    # a different report is its own command
    other = svc.submit_report(signal(3, "Flooding in Hanwella, 6 people trapped", "src-same"));
    assert other != first and len(svc.queued()) == 2;
    # and the same command is still the same one after it has been executed, until the window closes
    svc.process_pending();
    assert svc.submit_report(sig) == first;
    assert svc.queued() == [];
}

test "control commands dedupe too" {
    svc = fresh();
    open_only(svc);
    one = svc.halt();
    two = svc.halt();
    assert one == two and len(svc.queued()) == 1;
    # a different kind with the same (empty) payload is not the same command
    assert svc.resume() != one;
    assert len(svc.queued()) == 2;
}

test "a command repeated after the window is a new command" {
    svc = fresh();
    open_only(svc);
    sig = signal(1, "Flooding in Kolonnawa, 12 people trapped", "src-same");
    first = svc.submit_report(sig);
    svc.process_pending();
    # age every remembered command past the window
    aged: dict[str, tuple[str, float]] = {};
    for (key, seen) in svc.recent.items() {
        aged[key] = (seen[0], time.monotonic() - DEDUPE_WINDOW_S - 1.0);
    }
    svc.recent = aged;
    later = svc.submit_report(signal(1, "Flooding in Kolonnawa, 12 people trapped", "src-same"));
    assert later != first;
    assert len(svc.queued()) == 1;
}

test "a heartbeat queues a tick only when open and idle" {
    svc = fresh();
    svc.heartbeat();
    assert svc.queued() == [];
    open_only(svc);
    svc.heartbeat();
    assert [c.kind for c in svc.queued()] == ["tick"];
    # something else is already waiting: no tick is added
    svc.halt();
    svc.process_pending();
    svc.resume();
    svc.heartbeat();
    assert [c.kind for c in svc.queued()] == ["resume"];
    # a tick never appears in the command log
    svc.process_pending();
    assert all([c["kind"] != "tick" for c in svc.view()["commands"]]);
}

test "decide carries the author from the caller and the refused one is never queued" {
    svc = fresh();
    view = at_gate(svc);
    who = act_as("commander");
    decide("approved", view["plan"]["version"]);
    queued = svc.queued();
    assert len(queued) == 1 and queued[0].kind == "decision";
    assert queued[0].payload["author"] == who.username;
    assert queued[0].payload["plan_version"] == view["plan"]["version"];
    assert queued[0].payload["decision"] == ApprovalDecision.APPROVED;
}
