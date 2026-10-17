"""The Telegram poller, against a mocked Bot API. No real request is made."""

import json;
import logging;
import httpx;
import from resqmesh.contracts.models { RawSignal }
import from resqmesh.service.telegram {
    HELP_TEXT, NO_INCIDENT_TEXT, NotOpen, TelegramClient, TelegramPoller, quiet_http_logging,
    signal_from_telegram
}

glob TOKEN: str = "123456789:AAtest-token-must-never-leak-xyz";

def message(uid: int, text: str, sender: int = 5550001, chat: int | None = None, caption: bool = False) -> dict[str, any] {
    body: dict[str, any] = {"message_id": uid, "date": 1790000000, "from": {"id": sender}, "chat": {"id": chat or sender}};
    body["caption" if caption else "text"] = text;
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
            if isinstance(nxt, int) {
                return httpx.Response(nxt, json={"ok": False, "description": "nope"});
            }
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

def make_poller(api: FakeBotAPI, submit: any) -> TelegramPoller {
    client = TelegramClient(token=TOKEN, transport=httpx.MockTransport(api.handler));
    return TelegramPoller(client=client, submit=submit, salt="s", sleep=no_sleep);
}

obj Sink {
    has signals: list[RawSignal] = [],
        is_open: bool = True;

    def call(signal: RawSignal) -> str {
        if not self.is_open {
            raise NotOpen();
        }
        self.signals.append(signal);
        return "CMD-1";
    }
}

test "a report is queued and acknowledged" {
    api = FakeBotAPI(batches=[[message(10, "Flooding in Kolonnawa, 12 people trapped")]]);
    sink = Sink();
    assert make_poller(api, sink.call).poll_once() == 1;
    assert [s.signal_id for s in sink.signals] == ["TG-10"];
    assert len(api.sent) == 1;
    (chat, text) = api.sent[0];
    assert chat == 5550001 and "Ref TG-10" in text;
}

test "offset advances so updates are confirmed" {
    api = FakeBotAPI(batches=[[message(10, "a Kolonnawa"), message(11, "b Kolonnawa")], []]);
    p = make_poller(api, Sink().call);
    p.poll_once();
    p.poll_once();
    assert api.offsets == [None, 12];
}

test "start and help reply with instructions and ingest nothing" {
    for cmd in ["/start", "/help", "/start@resqmeshbot"] {
        api = FakeBotAPI(batches=[[message(1, cmd)]]);
        sink = Sink();
        make_poller(api, sink.call).poll_once();
        assert sink.signals == [] and api.sent == [(5550001, HELP_TEXT)];
    }
}

test "no open incident tells the reporter instead of silently dropping" {
    api = FakeBotAPI(batches=[[message(1, "Flooding in Kolonnawa")]]);
    make_poller(api, Sink(is_open=False).call).poll_once();
    assert api.sent == [(5550001, NO_INCIDENT_TEXT)];
}

test "photo captions are ingested" {
    api = FakeBotAPI(batches=[[message(3, "Kolonnawa, water in houses", caption=True)]]);
    sink = Sink();
    make_poller(api, sink.call).poll_once();
    assert sink.signals[0].body == "Kolonnawa, water in houses";
}

test "non text updates are skipped but still confirmed" {
    sticker = {"update_id": 5, "message": {"message_id": 5, "date": 1, "chat": {"id": 9}, "sticker": {}}};
    api = FakeBotAPI(batches=[[sticker], []]);
    sink = Sink();
    p = make_poller(api, sink.call);
    p.poll_once();
    p.poll_once();
    assert sink.signals == [] and api.sent == [] and api.offsets[-1] == 6;
}

def flaky(signal: RawSignal) -> str {
    if signal.signal_id == "TG-7" {
        raise RuntimeError("boom");
    }
    return "ok";
}

test "one bad update cannot wedge the queue" {
    api = FakeBotAPI(batches=[[message(7, "Kolonnawa"), message(8, "Kolonnawa again")], []]);
    p = make_poller(api, flaky);
    p.poll_once();
    p.poll_once();
    assert api.offsets == [None, 9];
    assert [c for (c, _) in api.sent] == [5550001];
}

obj SleepLog {
    has slept: list[float] = [];

    def call(s: float) -> None {
        self.slept.append(s);
    }
}

test "api errors back off and never raise" {
    for status in [401, 409, 502] {
        api = FakeBotAPI(batches=[status]);
        sl = SleepLog();
        p = TelegramPoller(client=TelegramClient(token=TOKEN, transport=httpx.MockTransport(api.handler)), submit=Sink().call, salt="s", backoff_s=5.0, sleep=sl.call);
        assert p.poll_once() == 0 and sl.slept == [5.0];
    }
}

def down(request: any) -> any {
    raise httpx.ConnectError(f"cannot reach {request.url}");
}

test "network errors never expose the token" {
    client = TelegramClient(token=TOKEN, transport=httpx.MockTransport(down));
    rendered = "";
    try {
        client.get_updates(None);
    } except Exception as exc {
        rendered = repr(exc) + str(exc) + str(exc.__cause__) + str(exc.__context__ or "");
    }
    assert rendered and TOKEN not in rendered;
}

obj Capture(logging.Handler) {
    has lines: list[str] = [];

    override def emit(record: any) -> None {
        self.lines.append(record.getMessage());
    }
}

test "the token never reaches the logs" {
    quiet_http_logging();
    cap = Capture();
    logging.Handler.__init__(cap);
    root_logger = logging.getLogger();
    old_level = root_logger.level;
    root_logger.addHandler(cap);
    root_logger.setLevel(logging.DEBUG);
    try {
        api = FakeBotAPI(batches=[[message(1, "Flooding in Kolonnawa")], 502]);
        p = make_poller(api, Sink().call);
        p.poll_once();
        p.poll_once();
    } finally {
        root_logger.removeHandler(cap);
        root_logger.setLevel(old_level);
    }
    text = "\n".join(cap.lines);
    assert cap.lines;
    assert TOKEN not in text and TOKEN.split(":")[1] not in text;
}

test "the sender id is pseudonymised" {
    s = signal_from_telegram(message(1, "Kolonnawa", sender=987654321), "salt");
    assert s is not None and "987654321" not in s.source_id;
}

test "commands never become reports" {
    assert signal_from_telegram(message(1, "/status"), "salt") is None;
}

test "telegram location and venue attachments are ingested" {
    loc = {"update_id": 40, "message": {"message_id": 40, "date": 1790000000, "from": {"id": 1}, "chat": {"id": 1}, "location": {"latitude": 6.9295, "longitude": 79.888, "horizontal_accuracy": 12.0}}};
    s = signal_from_telegram(loc, "salt");
    assert s is not None and s.lat == 6.9295 and s.accuracy_m == 12.0;
    assert s.body == "(location shared, no description)";
    venue = {"update_id": 41, "message": {"message_id": 41, "date": 1790000000, "from": {"id": 1}, "chat": {"id": 1}, "venue": {"title": "Kolonnawa temple", "address": "Main St", "location": {"latitude": 6.93, "longitude": 79.89}}}};
    v = signal_from_telegram(venue, "salt");
    assert v is not None and v.body == "Kolonnawa temple Main St" and v.lon == 79.89;
}
