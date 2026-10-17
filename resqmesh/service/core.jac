"""The incident service: one writer, many readers.

Telegram, the public form and the console all change the incident. If each ran the
agent loop in its own request, two walks could overlap on the same incident and fork
its record, and a commander's approval would wait behind thirty seconds of extraction.
So:

* Every change is a queued command, validated when it is submitted and executed in
  order by a single writer (the scheduled drain task). Single writer by construction.
* Reads never touch the runner. After each command the writer publishes a view
  snapshot; `get_incident` returns it instantly.
* Consecutive reports are batched into one walk: twenty Telegram messages arriving
  together cost one triage and one solve, not twenty.
* When idle, a heartbeat queues a tick so time-based triggers (hazard TTL) still fire.
"""

import logging;
import json;
import queue;
import threading;
import time;
import uuid;
import from datetime { datetime, UTC }
import from resqmesh.contracts.enums { ApprovalDecision, commitment_is_open }
import from resqmesh.contracts.models { RawSignal, to_json }
import from resqmesh.graph.loop { IncidentRunner }
import from resqmesh.service.view { blocked_road_features, build_view, plan_routes }

glob log: any = logging.getLogger(__name__);

"""How many commands the console's command log keeps."""
glob COMMAND_LOG: int = 25;

"""How long an identical command is collapsed into the one already queued."""
glob DEDUPE_WINDOW_S: float = 8.0;

glob COMMAND_KINDS: list[str] = [
    "open", "report", "decision", "halt", "resume", "tick", "responder", "place", "stand_down"
];

"""A command refused before it was queued. `status` keeps the HTTP meaning (404 not
found, 409 conflict, 403 forbidden, 422 invalid, 401 unauthenticated) and the message
starts with its short code, so a client can tell them apart."""
class ServiceError(Exception) {
    def init(self: ServiceError, status: int, message: str) {
        super.init(f"{ServiceError.code_for(status)}: {message}");
        self.status = status;
        self.detail = message;
    }

    static def code_for(status: int) -> str {
        codes = {401: "unauthorized", 403: "forbidden", 404: "not_found", 409: "conflict", 422: "invalid", 503: "unavailable"};
        return codes.get(status, "error");
    }
}

def utc_now() -> datetime {
    return datetime.now(UTC);
}

obj Command {
    has kind: str,
        payload: any = None,
        command_id: str = "",
        submitted_at: datetime | None = None;

    def postinit {
        if not self.command_id {
            self.command_id = f"CMD-{uuid.uuid4().hex[:10]}";
        }
        if self.submitted_at is None {
            self.submitted_at = utc_now();
        }
    }
}

obj IncidentService {
    has runner: IncidentRunner,
        # GN id -> {"name", "lat", "lon"} for the console's place names.
        divisions: dict[str, dict[str, any]],
        vehicles: list[any],
        # Current LLM chain status, sampled after every command.
        llm_status: any,
        # Relief centres an evacuation order can name.
        shelters: list[any] = [],
        # Loads a road graph pickle by path, for route geometry. None disables it.
        graph_loader: any = None,
        # The original graph: impassable edges no longer exist in the pruned one.
        base_graph_loader: any = None,
        # Called once per newly published alert, for the last-hop broadcast.
        alert_sink: any = None,
        # Returns the persisted incident node before each batch (the server's shared
        # graph); None keeps the runner's own node.
        incident_provider: any = None,
        pending: any = None,
        snapshot: dict[str, any] | None = None,
        commands: list[dict[str, any]] = [],
        busy: bool = False,
        graphs: dict[str, any] = {},
        broadcast_ids: set[str] = set(),
        # Identical commands re-submitted within seconds collapse into one: the runtime
        # may re-run an endpoint after a write conflict, and a double-click is the same.
        recent: dict[str, tuple[str, float]] = {},
        # Guards the published snapshot and command log: requests record commands
        # while the writer publishes.
        lock: any = None;

    def postinit {
        self.pending = queue.Queue();
        self.lock = threading.Lock();
        self.attach();
        state = self.runner.state();
        # A restart resumes the persisted incident; publish it before serving.
        if state.goal {
            self.publish();
        }
        # Alerts already in a resumed incident were broadcast before; never re-send.
        self.broadcast_ids = {a.alert_id for a in state.alerts or []};
    }

    """Point the runner at the persisted incident node for this context."""
    def attach -> None {
        if self.incident_provider is not None {
            self.runner.adopt(self.incident_provider());
        }
    }

    # ------------------------------------------------------------ reads

    def view -> dict[str, any] | None {
        with self.lock {
            return self.snapshot;
        }
    }

    def is_open -> bool {
        return self.view() is not None;
    }

    # ------------------------------------------------------------ writes: validate now, execute later

    def open(goal: str) -> str {
        if self.is_open() or any([c.kind == "open" for c in self.queued()]) {
            raise ServiceError(409, "an incident is already open");
        }
        return self.submit(Command(kind="open", payload=goal));
    }

    def submit_report(signal: RawSignal) -> str {
        self.require_open();
        return self.submit(Command(kind="report", payload=signal));
    }

    """Refused at once if the commander is looking at a stale plan. Re-checked when the
    command runs, too: the plan can move between queueing and execution."""
    def decide(
        decision: ApprovalDecision, plan_version: int, constraint: str | None, publish_alerts: bool, author: str
    ) -> str {
        view = self.require_open();
        plan = view.get("plan");
        if plan is None {
            raise ServiceError(404, "there is no plan to decide on");
        }
        if plan["version"] != plan_version {
            raise ServiceError(409, f"stale decision: you saw plan v{plan_version}, current is v{plan['version']}. Refresh and decide on the current plan.");
        }
        payload = {"decision": decision, "plan_version": plan_version, "constraint": constraint, "publish_alerts": publish_alerts, "author": author};
        return self.submit(Command(kind="decision", payload=payload));
    }

    """Refused unless this vehicle really has a dispatch in progress. An open commitment
    is the whole authority to report: it exists only for a dispatch that passed the gate
    and was released, and closes when the job does."""
    def responder(vehicle_id: str, cluster_id: str, status: str, reason: str | None) -> str {
        view = self.require_open();
        if not any([v["vehicle_id"] == vehicle_id for v in view["vehicles"]]) {
            raise ServiceError(404, f"unknown vehicle {vehicle_id}");
        }
        if not any([c["assignment"]["vehicle_id"] == vehicle_id and c["status"] in ["released", "en_route", "on_scene"] for c in view["commitments"]]) {
            raise ServiceError(409, f"{vehicle_id} has no dispatch in progress");
        }
        payload = {"vehicle_id": vehicle_id, "cluster_id": cluster_id, "status": status, "reason": reason};
        return self.submit(Command(kind="responder", payload=payload));
    }

    """Refused unless that report is actually one of the held ones."""
    def place(report_id: str, lat: float, lon: float, author: str) -> str {
        view = self.require_open();
        if not any([r["report_id"] == report_id for r in view["unresolved"]]) {
            raise ServiceError(404, f"{report_id} is not in the held queue");
        }
        return self.submit(Command(kind="place", payload={"report_id": report_id, "lat": lat, "lon": lon, "author": author}));
    }

    """Refused unless that bulletin is one the public is currently being shown."""
    def stand_down(alert_id: str, author: str) -> str {
        view = self.require_open();
        if alert_id not in {a["alert_id"] for a in view["alerts"]} {
            raise ServiceError(404, f"{alert_id} is not a current bulletin");
        }
        return self.submit(Command(kind="stand_down", payload={"alert_id": alert_id, "author": author}));
    }

    def halt -> str {
        self.require_open();
        return self.submit(Command(kind="halt"));
    }

    def resume -> str {
        self.require_open();
        return self.submit(Command(kind="resume"));
    }

    """Heartbeat: queue a tick when an incident is open and nothing else is waiting."""
    def heartbeat -> None {
        if self.is_open() and self.pending.empty() {
            self.pending.put(Command(kind="tick"));
        }
    }

    def require_open -> dict[str, any] {
        view = self.view();
        if view is None {
            raise ServiceError(404, "no incident is open; open one first");
        }
        return view;
    }

    def queued -> list[Command] {
        with self.pending.mutex {
            return list(self.pending.queue);
        }
    }

    def dedupe_key(cmd: Command) -> str {
        p = cmd.payload;
        if isinstance(p, RawSignal) {
            return f"report|{p.body}|{p.source_id}|{p.lat}|{p.lon}";
        }
        return f"{cmd.kind}|{json.dumps(to_json(p), sort_keys=True, `default=str)}";
    }

    def submit(cmd: Command) -> str {
        now = time.monotonic();
        key = self.dedupe_key(cmd);
        with self.lock {
            self.recent = {k: v for (k, v) in self.recent.items() if now - v[1] < DEDUPE_WINDOW_S};
            seen = self.recent.get(key);
            if seen is not None {
                return seen[0];
            }
            self.recent[key] = (cmd.command_id, now);
        }
        self.record(cmd, "queued");
        self.pending.put(cmd);
        return cmd.command_id;
    }

    # ------------------------------------------------------------ the writer

    def drain -> list[Command] {
        out: list[Command] = [];
        while True {
            try {
                out.append(self.pending.get_nowait());
            } except queue.Empty {
                return out;
            }
        }
        return out;
    }

    """Run everything queued, on the calling thread. The scheduled drain task calls
    this; tests and one-shot scripts call it directly."""
    def process_pending -> None {
        batch = self.drain();
        if batch {
            self.execute(batch);
        }
    }

    def execute(batch: list[Command]) -> None {
        self.attach();
        self.busy = True;
        self.publish_busy();
        try {
            i = 0;
            while i < len(batch) {
                cmd = batch[i];
                if cmd.kind == "report" {
                    # Batch consecutive reports into one walk.
                    j = i;
                    while j < len(batch) and batch[j].kind == "report" {
                        j += 1;
                    }
                    self.apply_group(batch[i:j]);
                    i = j;
                } else {
                    self.apply_group([cmd]);
                    i += 1;
                }
            }
        } finally {
            self.busy = False;
            self.publish();
            self.broadcast_new();
            self.save_learning();
        }
    }

    """Carry what this incident learned into the store, for the next one. Safe mid-incident:
    the baseline an incident is measured against is held on the incident, not re-read."""
    def save_learning -> None {
        try {
            self.runner.persist_learning();
        } except Exception {
            log.exception("could not persist learned priors");
        }
    }

    def apply_group(group: list[Command]) -> None {
        try {
            if group[0].kind == "report" {
                self.runner.ingest([c.payload for c in group]);
            } else {
                self.run_one(group[0]);
            }
        } except Exception as exc {
            # a failed command must never kill the writer
            log.exception("command %s failed", group[0].kind);
            for c in group {
                self.record(c, "failed", f"{type(exc).__name__}: {exc}");
            }
            self.publish();
            return;
        }
        for c in group {
            if c.kind != "tick" {
                self.record(c, "done");
            }
        }
        self.publish();
    }

    def run_one(cmd: Command) -> None {
        p = cmd.payload;
        if cmd.kind == "open" {
            self.runner.open(p, self.vehicles, self.shelters);
        } elif cmd.kind == "decision" {
            # The author is the authenticated principal, never a field in the request.
            self.runner.decide(p["decision"], p["author"], plan_version=p["plan_version"], constraint=p["constraint"], publish_alerts=p["publish_alerts"]);
        } elif cmd.kind == "responder" {
            self.runner.responder_update(p["vehicle_id"], p["cluster_id"], p["status"], note=p["reason"]);
        } elif cmd.kind == "place" {
            self.runner.place_report(p["report_id"], p["lat"], p["lon"], p["author"]);
        } elif cmd.kind == "stand_down" {
            self.runner.stand_down(p["alert_id"], p["author"]);
        } elif cmd.kind == "halt" {
            self.runner.halt();
        } elif cmd.kind == "resume" {
            self.runner.resume();
        } elif cmd.kind == "tick" {
            self.runner.tick();
        }
    }

    """Hand each not-yet-sent alert to the sink, exactly once. Best-effort."""
    def broadcast_new -> None {
        if self.alert_sink is None {
            return;
        }
        for alert in self.runner.state().alerts or [] {
            if alert.alert_id in self.broadcast_ids {
                continue;
            }
            self.broadcast_ids.add(alert.alert_id);   # add first: a bad alert is not retried forever
            try {
                self.alert_sink(alert);
            } except Exception {
                log.exception("alert sink failed for %s", alert.alert_id);
            }
        }
    }

    def record(cmd: Command, status: str, detail: str = "") -> None {
        if cmd.kind == "tick" {
            return;
        }
        row = {
            "command_id": cmd.command_id, "kind": cmd.kind, "status": status, "detail": detail,
            "submitted_at": to_json(cmd.submitted_at),
            "finished_at": None if status == "queued" else to_json(utc_now())
        };
        # Replace the queued entry in place so the log shows one line per command.
        with self.lock {
            kept = [c for c in self.commands if c["command_id"] != cmd.command_id];
            self.commands = ([row] + kept)[:COMMAND_LOG];
            if self.snapshot is not None {
                self.snapshot = {**self.snapshot, "commands": list(self.commands)};
            }
        }
    }

    # ------------------------------------------------------------ snapshots

    def publish_busy -> None {
        with self.lock {
            if self.snapshot is not None {
                self.snapshot = {**self.snapshot, "busy": True};
            }
        }
    }

    """Writer only. The expensive build happens outside the lock."""
    def publish -> None {
        state = self.runner.state();
        if not state.goal {
            return;
        }
        fresh = build_view(
            state, busy=self.busy, commands=[], divisions=self.divisions, llm=self.llm_status(),
            routes=plan_routes(state, self.routing_graph(state)), blocked_roads=self.blocked_roads(state)
        );
        with self.lock {
            self.snapshot = {**fresh, "commands": list(self.commands), "busy": self.busy};
        }
    }

    def blocked_roads(state: any) -> dict[str, any] | None {
        hazard = state.hazard;
        if hazard is None {
            return None;
        }
        if not hazard.impassable_edge_ids {
            return {"type": "FeatureCollection", "features": []};
        }
        if self.base_graph_loader is None {
            return None;
        }
        try {
            return blocked_road_features(self.base_graph_loader(), hazard.impassable_edge_ids);
        } except Exception as exc {
            log.warning("blocked road geometry unavailable (%s)", exc);
            return None;
        }
    }

    def routing_graph(state: any) -> any {
        ref = state.pruned_graph;
        if ref is None or self.graph_loader is None {
            return None;
        }
        if ref.graph_path not in self.graphs {
            try {
                self.graphs = {ref.graph_path: self.graph_loader(ref.graph_path)};   # keep only the latest
            } except Exception as exc {
                log.warning("route geometry unavailable (%s); drawing straight lines", exc);
                return None;
            }
        }
        return self.graphs[ref.graph_path];
    }
}

"""GN id -> (name, lat, lon) as the console's division table."""
def divisions_from(table: dict[str, tuple[str, float, float]]) -> dict[str, dict[str, any]] {
    return {gid: {"name": name, "lat": lat, "lon": lon} for (gid, (name, lat, lon)) in table.items()};
}
