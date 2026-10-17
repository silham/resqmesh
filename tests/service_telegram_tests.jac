"""The Telegram path through the incident service: a bot message becomes a located
cluster on the map, a redelivered update is not a second report, and the poller and the
service agree about an incident that is not open. The Bot API is a fake transport: no
network, no sleeping."""

import json;
import os;
import httpx;
import from datetime { datetime, UTC }
import from resqmesh.contracts.enums { SourceChannel }
import from resqmesh.contracts.models { RawSignal }
import from resqmesh.service.app {
    DEMO_GOAL, Runtime, _RUNTIME, build_service, make_poller, wire_alert_broadcast
}
import from resqmesh.service.auth { AuthSettings, AuthState }
import from resqmesh.service.core { IncidentService, ServiceError }
import from resqmesh.service.telegram {
    HELP_TEXT, NO_INCIDENT_TEXT, NotOpen, TelegramClient, TelegramPoller
}
import from resqmesh.service.endpoints { telegram_webhook }

glob TOKEN: str = "123456789:AAtest-token-must-never-leak-xyz";
glob SALT: str = "test-salt";
glob SECRET: str = "tg-secret";
glob ENV_NAMES: list[str] = ["TELEGRAM_BOT_TOKEN", "RESQMESH_TELEGRAM", "RESQMESH_ALERT_TELEGRAM_CHAT"];

# ------------------------------------------------------------------ the fake Bot API

def message(uid: int, text: str, sender: int = 5550001) -> dict[str, any] {
    body: dict[str, any] = {"message_id": uid, "date": 1790000000, "from": {"id": sender}, "chat": {"id": sender}, "text": text};
    return {"update_id": uid, "message": body};
}

"""Plays back getUpdates batches; records sendMessage calls."""
obj FakeBotAPI {
    has batches: list[any] = [],
        sent: list[tuple[any, str]] = [],
        offsets: list[int | None] = [];

    def handler(request: any) -> any {
        body = json.loads(request.content);
        if request.url.path.endswith("/getUpdates") {
            self.offsets.append(body.get("offset"));
            nxt: any = self.batches.pop(0) if self.batches else [];
            return httpx.Response(200, json={"ok": True, "result": nxt});
        }
        if request.url.path.endswith("/sendMessage") {
            self.sent.append((body["chat_id"], body["text"]));
            return httpx.Response(200, json={"ok": True, "result": {}});
        }
        return httpx.Response(404, json={"ok": False});
    }
}

def no_sleep(s: float) -> None {}

# ------------------------------------------------------------------ helpers

def set_env(values: dict[str, str]) -> dict[str, str | None] {
    saved: dict[str, str | None] = {};
    for name in ENV_NAMES {
        saved[name] = os.environ.get(name);
        os.environ.pop(name, None);
    }
    for (key, value) in values.items() {
        os.environ[key] = value;
    }
    return saved;
}

def restore_env(saved: dict[str, str | None]) -> None {
    for (name, value) in saved.items() {
        if value is None {
            os.environ.pop(name, None);
        } else {
            os.environ[name] = value;
        }
    }
}

"""The poller the application would build, or None, for this environment."""
def build_poller(svc: IncidentService, env: dict[str, str], webhook: bool = False) -> TelegramPoller | None {
    saved = set_env(env);
    try {
        return make_poller(svc, SALT, webhook);
    } finally {
        restore_env(saved);
    }
}

"""The application's own poller, talking to the fake Bot API instead of Telegram."""
def poller_over(svc: IncidentService, api: FakeBotAPI) -> TelegramPoller {
    built = build_poller(svc, {"TELEGRAM_BOT_TOKEN": TOKEN});
    assert built is not None;
    built.client = TelegramClient(token=TOKEN, transport=httpx.MockTransport(api.handler));
    built.sleep = no_sleep;
    return built;
}

def signal(signal_id: str, body: str) -> RawSignal {
    return RawSignal(
        signal_id=signal_id, channel=SourceChannel.TELEGRAM, source_id="src:abc", body=body,
        received_at=datetime.now(UTC)
    );
}

def service() -> IncidentService {
    svc = build_service(llm_mode="offline", persisted=False);
    _RUNTIME["runtime"] = Runtime(
        service=svc, auth=AuthState(settings=AuthSettings(mode="open", salt=SALT, telegram_secret=SECRET))
    );
    return svc;
}

def open_service() -> IncidentService {
    svc = service();
    svc.open(DEMO_GOAL);
    svc.process_pending();
    return svc;
}

def reports_of(svc: IncidentService, signal_id: str) -> list[dict[str, any]] {
    view = svc.view();
    assert view is not None;
    return [r for r in view["reports"] if r["signal_id"] == signal_id];
}

# ------------------------------------------------------------------ building the poller

test "polling is off without a token, when disabled, and when a webhook is set" {
    svc = service();
    assert build_poller(svc, {}) is None;
    assert build_poller(svc, {"TELEGRAM_BOT_TOKEN": "   "}) is None;
    assert build_poller(svc, {"TELEGRAM_BOT_TOKEN": TOKEN, "RESQMESH_TELEGRAM": "off"}) is None;
    assert build_poller(svc, {"TELEGRAM_BOT_TOKEN": TOKEN, "RESQMESH_TELEGRAM": " OFF "}) is None;
    # Telegram refuses polling while a webhook is set, so the poller steps aside
    assert build_poller(svc, {"TELEGRAM_BOT_TOKEN": TOKEN}, True) is None;
}

test "the poller is built with short long-polls and the shared salt" {
    svc = service();
    for env in [{"TELEGRAM_BOT_TOKEN": TOKEN}, {"TELEGRAM_BOT_TOKEN": TOKEN, "RESQMESH_TELEGRAM": "on"}] {
        built = build_poller(svc, env);
        assert built is not None;
        # the scheduler runs the poll every few seconds, so a poll must not outlast it
        assert built.long_poll_s == 4 and built.salt == SALT and built.offset is None;
    }
}

# ------------------------------------------------------------------ through the real service and loop

test "a telegram report lands on the map" {
    svc = open_service();
    api = FakeBotAPI(batches=[[
        message(21, "Flooding in Pahathgama, 8 people trapped, wheelchair user"),
        message(22, "Pahathgama flood, urgent, family with baby", 5550002)
    ]]);
    assert poller_over(svc, api).poll_once() == 2;
    svc.process_pending();
    view = svc.view();
    assert view is not None;
    tg = [r for r in view["reports"] if r["signal_id"].startswith("TG-")];
    assert len(tg) == 2;
    assert {r["resolved_gn_id"] for r in tg} == {"KLN-008"};
    # located: a cluster for that division now exists and holds the reports
    clusters = [c for c in view["clusters"] if c["gn_id"] == "KLN-008"];
    assert len(clusters) == 1;
    assert {r["report_id"] for r in tg}.issubset(set(clusters[0]["member_report_ids"]));
    # and each reporter was acknowledged with their reference
    assert sorted([c for (c, _) in api.sent]) == [5550001, 5550002];
    assert all(["Ref TG-" in text for (_, text) in api.sent]);
    assert "Ref TG-21" in [text for (chat, text) in api.sent if chat == 5550001][0];
}

test "a redelivered update is not a second report" {
    # after a restart Telegram re-sends unconfirmed updates; update_id makes them idempotent
    svc = open_service();
    api = FakeBotAPI(batches=[[message(30, "Flooding in Pahathgama")], [message(30, "Flooding in Pahathgama")]]);
    first = poller_over(svc, api);
    first.poll_once();
    svc.process_pending();
    # a new process: no offset, so Telegram offers the same update again
    fresh = poller_over(svc, api);
    assert fresh.offset is None and fresh.poll_once() == 1;
    svc.process_pending();
    assert len(reports_of(svc, "TG-30")) == 1;
    view = svc.view();
    assert view is not None;
    assert len([r for r in view["reports"] if r["signal_id"].startswith("TG-")]) == 1;
}

test "an update delivered by the poller and again by the webhook is one report" {
    svc = open_service();
    update = message(31, "Flooding in Pahathgama, 8 people trapped");
    poller_over(svc, FakeBotAPI(batches=[[update]])).poll_once();
    svc.process_pending();
    out = telegram_webhook(SECRET, update_id=31, message=update["message"]);
    assert out == {"ok": True};
    svc.process_pending();
    assert len(reports_of(svc, "TG-31")) == 1;
}

test "the poller and the webhook pseudonymise the same sender to the same id" {
    svc = open_service();
    poller_over(svc, FakeBotAPI(batches=[[message(40, "Flooding in Pahathgama", 777000111)]])).poll_once();
    telegram_webhook(SECRET, update_id=41, message=message(41, "Water rising in Pahathgama", 777000111)["message"]);
    telegram_webhook(SECRET, update_id=42, message=message(42, "Water rising in Pahathgama", 888000222)["message"]);
    svc.process_pending();
    by_poller = reports_of(svc, "TG-40")[0]["source_id"];
    by_webhook = reports_of(svc, "TG-41")[0]["source_id"];
    other = reports_of(svc, "TG-42")[0]["source_id"];
    assert by_poller == by_webhook and by_poller != other;
    view = svc.view();
    assert view is not None;
    blob = json.dumps(view);
    assert "777000111" not in blob and "888000222" not in blob;
}

test "a burst of messages from one poll is one loop pass" {
    svc = open_service();
    api = FakeBotAPI(batches=[[
        message(50, "Flooding in Kolonnawa, 12 people trapped", 5550001),
        message(51, "Water rising fast at Kolonnawa, children stranded", 5550002),
        message(52, "Kolonnawa families stranded, water above knee level", 5550003)
    ]]);
    assert poller_over(svc, api).poll_once() == 3;
    assert len(svc.queued()) == 3;
    svc.process_pending();
    view = svc.view();
    assert view is not None;
    ingests = [e for e in view["trace"] if e["agent"] == "A1"];
    assert len(ingests) == 1 and ingests[0]["detail"].startswith("ingested 3 signal(s)");
    assert {c["gn_id"] for c in view["clusters"]} == {"KLN-003"};
}

test "a shared location reaches the map as a located report" {
    svc = open_service();
    pin = {
        "update_id": 60, "message": {
            "message_id": 60, "date": 1790000000, "from": {"id": 5550001}, "chat": {"id": 5550001},
            "location": {"latitude": 6.9060, "longitude": 79.9070, "horizontal_accuracy": 15.0}
        }
    };
    poller_over(svc, FakeBotAPI(batches=[[pin]])).poll_once();
    svc.process_pending();
    found = reports_of(svc, "TG-60");
    assert len(found) == 1;
    assert found[0]["lat"] == 6.9060 and found[0]["lon"] == 79.9070;
    assert found[0]["location_source"] == "telegram" and found[0]["resolved_gn_id"];
}

# ------------------------------------------------------------------ the poller and an incident that is not open

test "while no incident is open the poller tells the reporter and queues nothing" {
    svc = service();
    api = FakeBotAPI(batches=[[message(70, "Flooding in Pahathgama")], []]);
    p = poller_over(svc, api);
    assert p.poll_once() == 1;
    assert api.sent == [(5550001, NO_INCIDENT_TEXT)];
    assert svc.queued() == [] and svc.view() is None;
    # the update was still confirmed, so Telegram does not offer it again
    p.poll_once();
    assert api.offsets == [None, 71];
}

test "the poller's report sink maps a closed incident to not open and an open one to a command" {
    svc = service();
    p = poller_over(svc, FakeBotAPI());
    sig = signal("TG-80", "Flooding in Pahathgama");
    with testraises(NotOpen) {
        p.submit(sig);
    }
    assert svc.queued() == [];
    svc.open(DEMO_GOAL);
    svc.process_pending();
    ref = p.submit(sig);
    assert ref.startswith("CMD-") and len(svc.queued()) == 1;
}

test "start and help are answered by the poller and never reach the service" {
    svc = open_service();
    api = FakeBotAPI(batches=[[message(90, "/start")]]);
    poller_over(svc, api).poll_once();
    assert api.sent == [(5550001, HELP_TEXT)];
    assert svc.queued() == [];
}

test "the webhook answers ok but queues nothing while no incident is open" {
    svc = service();
    out = telegram_webhook(SECRET, update_id=3, message=message(3, "Flooding in Pahathgama")["message"]);
    assert out == {"ok": True};
    assert svc.queued() == [] and svc.view() is None;
    with testraises(ServiceError) as ei {
        svc.submit_report(signal("TG-3", "Flooding in Pahathgama"));
    }
    err: any = ei.value;
    assert err.status == 404;
}

# ------------------------------------------------------------------ the last hop for bulletins

test "alert broadcast is wired only when a token and a channel are configured" {
    svc = service();
    for env in [{}, {"TELEGRAM_BOT_TOKEN": TOKEN}, {"RESQMESH_ALERT_TELEGRAM_CHAT": "@alerts"}] {
        saved = set_env(env);
        try {
            wire_alert_broadcast(svc);
        } finally {
            restore_env(saved);
        }
        assert svc.alert_sink is None;
    }
    saved = set_env({"TELEGRAM_BOT_TOKEN": TOKEN, "RESQMESH_ALERT_TELEGRAM_CHAT": "@alerts"});
    try {
        wire_alert_broadcast(svc);
    } finally {
        restore_env(saved);
    }
    # wiring makes no request: the sink is built and nothing has been sent
    assert svc.alert_sink is not None;
}
