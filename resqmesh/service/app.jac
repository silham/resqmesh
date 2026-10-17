"""Assemble the running application: world, runner, service, auth and the Telegram
channel, built once at server start and shared by every request and scheduled task.

Configuration comes from the environment (see `.env.example`):

    RESQMESH_DEMO=1            open the synthetic incident with its first wave of reports
    RESQMESH_WORLD=real        the fetched Kelani basin instead of the synthetic world
    RESQMESH_AT=2016-05-14T06:00   replay clock for the real world (UTC)
    RESQMESH_LLM=offline       no hosted-model calls at all (default: live chain from env)
    RESQMESH_TELEGRAM=off      do not poll the bot (e.g. a webhook is configured)
"""

import logging;
import os;
import tempfile;
import threading;
import from datetime { datetime, timedelta, UTC }
import from dotenv { load_dotenv }
import from pathlib { Path }
import from resqmesh.adapters.broadcast.telegram { TelegramChannelBroadcaster }
import from resqmesh.adapters.fakes { StubLLM }
import from resqmesh.adapters.geo.paths { data_dir, dem_path }
import from resqmesh.adapters.geo.roads { load_graph }
import from resqmesh.adapters.llm.config { router_from_env }
import from resqmesh.adapters.llm.router { ProviderRouter }
import from resqmesh.contracts.enums { LLMProvider }
import from resqmesh.contracts.models { RawSignal }
import from resqmesh.graph.loop { AgentSet, Incident, IncidentRunner }
import from resqmesh.graph.supervisor { SupervisorConfig }
import from resqmesh.graph.world { DIVISIONS, opening_signals, real_world, synthetic_world }
import from resqmesh.memory.adaptation { graph_store }
import from resqmesh.service.auth { AuthState, provision, settings_from_env }
import from resqmesh.service.core { IncidentService, ServiceError, divisions_from }
import from resqmesh.service.telegram { NotOpen, TelegramClient, TelegramPoller, quiet_http_logging }

glob log: any = logging.getLogger("resqmesh.service.app");

glob DEMO_GOAL: str = "coordinate the response to flooding in the Kelani basin";
glob INCIDENT_ID: str = "KLN-2026-014";

def truthy(name: str) -> bool {
    return os.environ.get(name, "").strip().lower() in ["1", "true", "yes", "on"];
}

"""The LLM chain's status as the console shows it."""
def llm_status_for(llm: any, skipped: list[str]) -> dict[str, any] {
    if isinstance(llm, ProviderRouter) {
        providers = [
            {
                "provider": h.provider.value, "circuit_open": h.open,
                "consecutive_failures": h.consecutive_failures, "vision": h.vision
            }
            for h in llm.health()
        ];
        return {"chain": [p["provider"] for p in providers], "skipped": skipped, "providers": providers, "offline_fallback": True};
    }
    return {"chain": [LLMProvider.STUB.value], "skipped": skipped, "providers": [], "offline_fallback": True};
}

"""The persisted incident node on the shared graph, created on first use."""
def shared_incident() -> Incident {
    found = [n for n in [root.shared -->] if isinstance(n, Incident)];
    if found {
        return found[0];
    }
    inc = Incident(incident_id=INCIDENT_ID);
    root.shared ++> inc;
    return inc;
}

"""Build the incident service over the chosen world. `llm_mode` is "live" (the provider
chain from the environment, with rules as the last tier) or "offline" (the stub)."""
def build_service(
    llm_mode: str = "offline", world_kind: str = "synthetic", at: datetime | None = None,
    persisted: bool = True
) -> IncidentService {
    skipped: list[str] = [];
    llm: any = None;
    if llm_mode == "live" {
        (llm, plan) = router_from_env();
        skipped = [f"{name}: {why}" for (name, why) in plan.skipped];
    } else {
        llm = StubLLM();
    }
    out_dir = Path(tempfile.mkdtemp(prefix="resqmesh-graphs-"));
    world: any = None;
    divisions: dict[str, dict[str, any]] = {};
    if world_kind == "real" {
        # Rainfall replayed at a past moment, so the console shows a real event rather
        # than today's (probably dry) weather.
        moment = at or datetime(2016, 5, 14, 6, 0, tzinfo=UTC);
        def replay_clock() -> datetime {
            return moment;
        }
        world = real_world(out_dir, clock=replay_clock, llm=llm);
    } else {
        world = synthetic_world(out_dir, llm=llm);
    }
    divisions = divisions_from(world.divisions);
    runner = IncidentRunner(agents=world.agents, incident_id=INCIDENT_ID, cfg=SupervisorConfig());
    if persisted {
        # Learned priors live in the graph beside the incident, so they carry from one
        # incident to the next on the same deployment.
        runner.store = graph_store(root.shared);
        runner.baseline = runner.store.load();
    }
    def status() -> dict[str, any] {
        return llm_status_for(llm, skipped);
    }
    return IncidentService(
        runner=runner, divisions=divisions, vehicles=world.vehicles, shelters=world.shelters,
        llm_status=status, graph_loader=load_graph,
        base_graph_loader=getattr(world.agents.hazard, "graph_loader", None),
        incident_provider=shared_incident if persisted else None
    );
}

"""Send approved alerts to a public Telegram channel, if one is configured: needs both
TELEGRAM_BOT_TOKEN and RESQMESH_ALERT_TELEGRAM_CHAT. Without them the alert is still
composed, approved and shown in the console and on /news; only the push is skipped."""
def wire_alert_broadcast(service: IncidentService) -> None {
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip();
    chat = os.environ.get("RESQMESH_ALERT_TELEGRAM_CHAT", "").strip();
    if not token or not chat {
        log.info("alert broadcast off%s", "" if token else " (no TELEGRAM_BOT_TOKEN)");
        return;
    }
    client = TelegramClient(token=token);
    service.alert_sink = TelegramChannelBroadcaster(chat_id=chat, send=client.send_message).broadcast;
    log.info("alerts will broadcast to Telegram %s", chat);
}

"""The poller for the bot, or None when polling is off: disabled, no token, or a webhook
is configured (Telegram refuses both)."""
def make_poller(service: IncidentService, salt: str, webhook: bool) -> TelegramPoller | None {
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip();
    mode = os.environ.get("RESQMESH_TELEGRAM", "auto").strip().lower();
    if mode == "off" or not token {
        log.info("telegram: polling off%s", "" if token else " (no TELEGRAM_BOT_TOKEN)");
        return None;
    }
    if webhook {
        log.info("telegram: TELEGRAM_WEBHOOK_SECRET is set, so reports arrive by webhook; not polling");
        return None;
    }
    def submit(signal: RawSignal) -> str {
        try {
            return service.submit_report(signal);
        } except ServiceError as exc {
            if exc.status == 404 {
                raise NotOpen();
            }
            raise;
        }
    }
    # Short long-polls: the scheduler runs this task every few seconds and never
    # overlaps it with itself.
    return TelegramPoller(client=TelegramClient(token=token), submit=submit, salt=salt, long_poll_s=4);
}

"""The storage layer notes, once per datetime field, that it saves a timestamp as text. The
value is stored and read back intact, but a single save of the incident repeats the note a
couple of hundred times and buries every other line of the log. Dropped here, at the
handlers, so it does not matter which logger raised it."""
class QuietTimestampNote(logging.Filter) {
    def filter(self: QuietTimestampNote, record: logging.LogRecord) -> bool {
        return "Falling back to str() for datetime" not in record.getMessage();
    }
}

def quiet_timestamp_note() -> None {
    quiet = QuietTimestampNote();
    seen: list[any] = [logging.getLogger()];
    for name in list(logging.Logger.manager.loggerDict.keys()) {
        seen.append(logging.getLogger(name));
    }
    for logger in seen {
        logger.addFilter(quiet);
        for handler in logger.handlers {
            handler.addFilter(quiet);
        }
    }
}

"""Everything a running server shares."""
obj Runtime {
    has service: IncidentService,
        auth: AuthState,
        poller: TelegramPoller | None = None;
}

glob _RUNTIME: dict[str, any] = {};
glob _BOOT_LOCK: any = threading.Lock();

"""The booted runtime, or None while the server is still starting."""
def booted() -> Runtime | None {
    return _RUNTIME.get("runtime");
}

"""The booted runtime. Endpoints use this: until the first scheduler tick has booted the
application it answers 'starting', which clients retry."""
def runtime() -> Runtime {
    rt = booted();
    if rt is None {
        raise ServiceError(503, "the server is still starting; retry in a moment");
    }
    return rt;
}

"""Boot the application once, from a scheduled task.

It must not run at module import: at that point `root.shared` is not the shared graph
that requests see, so the roster, the incident and the learned priors would be created
where nothing can find them. A scheduled task and every request see the same shared
graph."""
def boot() -> Runtime {
    existing = booted();
    if existing is not None {
        return existing;
    }
    with _BOOT_LOCK {
        existing = booted();
        if existing is not None {
            return existing;
        }
        load_dotenv();   # a .env beside the project supplies keys and settings; real environment wins
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s");
        quiet_http_logging();   # before any request: Telegram URLs carry the bot token
        quiet_timestamp_note();
        log.info("data directory %s (terrain %s, cwd %s)", data_dir(), "present" if dem_path().exists() else "missing", os.getcwd());
        settings = settings_from_env();
        if not settings.salt {
            # Resolve once and share, so the web form, webhook and poller pseudonymise the
            # same reporter to the same id.
            log.warning("RESQMESH_SALT not set: using a per-process salt; source trust will not survive a restart");
            settings.salt = os.urandom(16).hex();
        }
        auth = provision(settings, os.environ.get("RESQMESH_PUBLIC_HOST", "localhost:8000"));
        moment: datetime | None = None;
        at = os.environ.get("RESQMESH_AT", "").strip();
        if at {
            moment = datetime.fromisoformat(at).replace(tzinfo=UTC);
        }
        llm_mode = os.environ.get("RESQMESH_LLM", "live").strip().lower();
        if truthy("RESQMESH_OFFLINE") {
            llm_mode = "offline";
        }
        service = build_service(
            llm_mode=llm_mode, world_kind=os.environ.get("RESQMESH_WORLD", "synthetic").strip().lower(), at=moment
        );
        wire_alert_broadcast(service);
        if truthy("RESQMESH_DEMO") and not service.is_open() {
            service.open(DEMO_GOAL);
            service.process_pending();   # reports are refused until the incident is actually open
            # Stamp the reports in the recent past: they arrived before the operator opened the console.
            for signal in opening_signals(datetime.now(UTC) - timedelta(minutes=15)) {
                service.submit_report(signal);
            }
        }
        poller = make_poller(service, settings.salt, bool(settings.telegram_secret));
        _RUNTIME["runtime"] = Runtime(service=service, auth=auth, poller=poller);
        return _RUNTIME["runtime"];
    }
}

def service() -> IncidentService {
    return runtime().service;
}

def auth_state() -> AuthState {
    return runtime().auth;
}
