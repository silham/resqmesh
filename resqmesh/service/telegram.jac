"""Telegram: the field reporters' channel.

A reporter sends a message or a photograph to a Telegram bot in whichever language is
natural to them. No form, no app installation, no training. This module turns those
messages into raw signals for A1. Two ways in, same result:

* Polling (`TelegramPoller`): the server asks Telegram for new messages on a schedule.
  Needs no public URL, so it works on a laptop or any demo machine.
* Webhook (`telegram_webhook` endpoint): Telegram pushes to us. Needs a public HTTPS
  URL. Telegram allows one or the other: while a webhook is set, polling is refused.

The bot token lives in the URL path (`/bot<token>/getUpdates`). Nothing here logs a
URL, and `quiet_http_logging` stops httpx from logging request URLs at INFO, where it
would otherwise write the token into the server log.
"""

import logging;
import uuid;
import from datetime { datetime, UTC }
import httpx;
import from resqmesh.agents.ingest.redact { pseudonymise_source }
import from resqmesh.contracts.enums { LocationSource, SourceChannel }
import from resqmesh.contracts.models { RawSignal }

glob log: any = logging.getLogger("resqmesh.service.telegram");

glob API: str = "https://api.telegram.org";

"""Sent in reply to /start and /help. Trilingual, because reporters use all three."""
glob HELP_TEXT: str = "ResQ-Mesh field reports\n\n"
    + "Send what you see and where: the place name, how many people, anyone elderly, "
    + "injured or with children. A photo with a caption helps too.\n\n"
    + "ඔබ දකින දේ සහ ස්ථානය එවන්න: ස්ථානයේ නම, පුද්ගලයින් ගණන.\n\n"
    + "நீங்கள் பார்ப்பதையும் இடத்தையும் அனுப்புங்கள்: இடத்தின் பெயர், எத்தனை பேர்.";

glob NO_INCIDENT_TEXT: str = "No incident is active right now, so this report was not recorded. "
    + "If lives are at risk, call 117 (Disaster Management Centre).";

def ack_text(ref: str) -> str {
    return f"Report received. Ref {ref}\nවාර්තාව ලැබුණි · அறிக்கை பெறப்பட்டது";
}

"""httpx logs every request URL at INFO. Telegram's contain the bot token."""
def quiet_http_logging() -> None {
    for name in ["httpx", "httpcore"] {
        logging.getLogger(name).setLevel(logging.WARNING);
    }
}

"""A Telegram Update -> a raw signal. Text, photo captions, and Telegram's own location
and venue attachments.

The sender's Telegram id is pseudonymised immediately; the raw id is never stored.
`received_at` is the message's own timestamp, so a report that sat in Telegram's queue
during an outage keeps its true time. The signal id is derived from Telegram's
`update_id`, so an update delivered twice becomes the same signal, and A1 ignores the
repeat."""
def signal_from_telegram(update: dict[str, any], salt: str) -> RawSignal | None {
    msg: any = update.get("message") or update.get("edited_message");
    if not isinstance(msg, dict) {
        return None;
    }
    # The "share location" button is the lowest-friction way a reporter has of saying
    # exactly where they are. A venue also carries a name worth keeping as the text.
    venue: any = msg.get("venue") if isinstance(msg.get("venue"), dict) else None;
    point: any = (venue or {}).get("location") or msg.get("location");
    lat: float | None = None;
    lon: float | None = None;
    if isinstance(point, dict) and point.get("latitude") is not None {
        lat = float(point["latitude"]);
        lon = float(point["longitude"]);
    }
    text: str = msg.get("text") or msg.get("caption") or "";
    if not text.strip() and venue {
        text = " ".join([str(venue.get(k, "")) for k in ["title", "address"]]).strip();
    }
    if lat is None and (not text.strip() or text.strip().startswith("/")) {
        return None;
    }
    sender = (msg.get("from") or {}).get("id") or (msg.get("chat") or {}).get("id");
    if sender is None {
        return None;
    }
    sent = msg.get("date");
    accuracy: float | None = None;
    if isinstance(point, dict) and point.get("horizontal_accuracy") is not None {
        # Telegram reports accuracy only for live locations; absent means unknown,
        # which the locator treats as usable rather than refusing the fix.
        accuracy = float(point["horizontal_accuracy"]);
    }
    return RawSignal(
        signal_id=f"TG-{update.get('update_id', uuid.uuid4().hex[:10])}",
        channel=SourceChannel.TELEGRAM,
        source_id=pseudonymise_source(f"tg:{sender}", salt),
        body=text or "(location shared, no description)",
        received_at=datetime.fromtimestamp(sent, UTC) if isinstance(sent, int) else datetime.now(UTC),
        lat=lat,
        lon=lon,
        accuracy_m=accuracy,
        location_source=LocationSource.TELEGRAM if lat is not None else LocationSource.NONE
    );
}

class TelegramError(RuntimeError) {
    def init(self: TelegramError, message: str, status: int | None = None) {
        super.init(message);
        self.status = status;
    }
}

"""The two Bot API calls we need. Never puts the token in an error message."""
obj TelegramClient {
    has token: str,
        transport: any = None,
        http: any = None;

    def client -> any {
        if self.http is None {
            # Long polls hold the connection for up to `timeout`; allow for it.
            self.http = httpx.Client(base_url=f"{API}/bot{self.token}/", timeout=40.0, transport=self.transport);
        }
        return self.http;
    }

    def call(method: str, payload: dict[str, any]) -> any {
        # httpx errors embed the request URL, and ours contains the token. Raise
        # outside the except block, leaving no exception chain at all.
        failure: str | None = None;
        response: any = None;
        try {
            response = self.client().post(method, json=payload);
        } except httpx.HTTPError as exc {
            failure = type(exc).__name__;
        }
        if failure is not None {
            raise TelegramError(f"{method}: {failure}");
        }
        body: dict[str, any] = response.json() if response.headers.get("content-type", "").startswith("application/json") else {};
        if response.status_code != 200 or not body.get("ok") {
            raise TelegramError(f"{method}: HTTP {response.status_code} {body.get('description', '')}".strip(), status=response.status_code);
        }
        return body["result"];
    }

    def get_updates(offset: int | None, timeout: int = 25) -> list[dict[str, any]] {
        payload: dict[str, any] = {"timeout": timeout, "allowed_updates": ["message", "edited_message"]};
        if offset is not None {
            payload["offset"] = offset;
        }
        return self.call("getUpdates", payload);
    }

    def send_message(chat_id: any, text: str) -> None {
        self.call("sendMessage", {"chat_id": chat_id, "text": text});
    }

    def close -> None {
        if self.http is not None {
            self.http.close();
            self.http = None;
        }
    }
}

"""Raised by the report sink when no incident is open."""
class NotOpen(Exception) {}

"""Polls Telegram and hands each report to the incident service. `submit` takes a raw
signal and returns a reference, or raises NotOpen. The scheduler calls `poll_once`."""
obj TelegramPoller {
    has client: TelegramClient,
        submit: any,
        salt: str,
        long_poll_s: int = 25,
        backoff_s: float = 5.0,
        sleep: any = None,
        offset: int | None = None;

    """One getUpdates round. Returns the number of updates handled. Never raises."""
    def poll_once -> int {
        updates: list[dict[str, any]] = [];
        try {
            updates = self.client.get_updates(self.offset, timeout=self.long_poll_s);
        } except TelegramError as exc {
            status = getattr(exc, "status", None);
            if status == 409 {
                log.error("telegram: a webhook is set, so polling is refused. Delete it (deleteWebhook) or set RESQMESH_TELEGRAM=off and use the webhook");
            } elif status == 401 {
                log.error("telegram: bot token rejected (401). Check TELEGRAM_BOT_TOKEN");
            } else {
                log.warning("telegram: %s; retrying in %.0fs", exc, self.backoff_s);
            }
            if self.sleep is not None {
                self.sleep(self.backoff_s);
            }
            return 0;
        }
        for update in updates {
            # Advance first: one bad update must never wedge the queue by being re-fetched forever.
            self.offset = int(update["update_id"]) + 1;
            try {
                self.handle(update);
            } except Exception {
                log.exception("telegram: failed to handle update %s", update.get("update_id"));
            }
        }
        return len(updates);
    }

    def handle(update: dict[str, any]) -> None {
        msg: dict[str, any] = update.get("message") or update.get("edited_message") or {};
        chat = (msg.get("chat") or {}).get("id");
        text: str = (msg.get("text") or "").strip();
        if chat is None {
            return;
        }
        # "/start", "/help", or "/start@resqmeshbot" when sent in a group
        command = text.split(maxsplit=1)[0].split("@")[0] if text.startswith("/") else "";
        if command in ["/start", "/help"] {
            self.reply(chat, HELP_TEXT);
            return;
        }
        signal = signal_from_telegram(update, self.salt);
        if signal is None {
            return;   # stickers, voice notes, other commands: nothing to ingest yet
        }
        try {
            self.submit(signal);
        } except NotOpen {
            self.reply(chat, NO_INCIDENT_TEXT);
            return;
        }
        self.reply(chat, ack_text(signal.signal_id));
        log.info("telegram: report %s queued", signal.signal_id);
    }

    def reply(chat_id: any, text: str) -> None {
        try {
            self.client.send_message(chat_id, text);
        } except TelegramError as exc {
            # the report is already in; a failed ack must not lose it
            log.warning("telegram: could not reply (%s)", exc);
        }
    }
}
