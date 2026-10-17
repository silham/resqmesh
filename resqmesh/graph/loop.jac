"""The incident graph, and the walker that drives it.

Topology is hub-and-spoke. The incident node anchors a hub station (A0, the
supervisor) and one station per specialist; every spoke leads back to the hub, and the
hub alone decides what runs next. There are no specialist-to-specialist edges, so the
order of work is never baked into the wiring: it falls out of the state, which is what
lets the loop re-enter at the affected stage instead of starting over.

              +-------- A1 ingest --------+
              +-------- A2 hazard --------+
   Incident -> A0 <---- A3 triage --------+
              +-------- A4 optimiser -----+
              +-------- A5 guardrail -----+
              +-------- gate -> stop      |  (a human answers later)
              +-------- A6 release -------+

A `Supervise` walker is spawned on the incident for every input. At the hub it records
any new commander decisions, routes, and walks to the chosen station; the station runs
its specialist, folds the update into the incident state, and walks back to the hub.
The run stops when the supervisor routes to the end, or at the gate.

Every station returns only the fields it owns, plus trace events: the single-writer
rule from `resqmesh.contracts.state`, checked on every write.
"""

import uuid;
import from datetime { datetime }
import from resqmesh.contracts.enums {
    ActionTier, AlertStatus, ApprovalDecision, CommitmentStatus, IncidentStatus,
    alert_is_current
}
import from resqmesh.contracts.models {
    ApprovalRecord, LocationFix, RawSignal, Shelter, TraceEvent, Vehicle, evolve
}
import from resqmesh.contracts.state {
    IncidentState, apply_update, check_ownership, copy_state, new_state
}
import from resqmesh.graph.commitments { close, find_open, release_records }
import from resqmesh.graph.predicates {
    APPROVAL_RECEIVED, A5_REJECTED, A5_VERIFIED, GATE_REQUESTED, RELEASED, REPORT_PLACED,
    approval_for_current_plan, release_due, released_event_id, trace_of, unrecorded_approvals
}
import from resqmesh.graph.supervisor { A1, A2, A3, A4, A5, A6, END, GATE, SupervisorConfig, decide }
import from resqmesh.contracts.models { AdaptationSnapshot }
import from resqmesh.memory.adaptation { AdaptationStore, MemoryAdaptationStore }

glob ROUTE_PREFIX: str = "route:";
glob HUB: str = "A0";
glob STATIONS: list[str] = ["A1", "A2", "A3", "A4", "A5", "gate", "A6"];

"""One incident's state, persisted in the graph."""
node Incident {
    has incident_id: str,
        state: IncidentState = IncidentState(),
        # What the incident started with, held apart from the running posterior. A1
        # recomputes learning from the whole evidence set each run, so it must read this
        # every time: feeding it back its own posterior would double-count. Kept on the
        # node so a restart resumes with the same baseline.
        baseline: AdaptationSnapshot | None = None;

    # App-owned structure: every authenticated request and the scheduler work on the
    # one incident; who may do what is decided by role, not by graph ownership.
    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

"""A desk in the incident room: the supervisor hub or one specialist."""
node Station {
    has name: str;

    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

"""Raised when one invocation takes more steps than the configured limit."""
class RecursionLimitError(RuntimeError) {}

"""The six specialists, each constructed by its own module and injected here.
A1-A4 and A6 expose `run(state, now) -> update`; A5 exposes `verify_plan`."""
obj AgentSet {
    has ingest: any,
        hazard: any,
        triage: any,
        optimiser: any,
        guardrail: any,
        comms: any = None;
}

def new_event(
    agent: str, action: str, tier: ActionTier, detail: str, now: datetime,
    event_id: str | None = None, human_touch: bool = False
) -> TraceEvent {
    return TraceEvent(
        event_id=event_id or f"EV-{uuid.uuid4().hex[:12]}",
        agent=agent, action=action, tier=tier, human_touch=human_touch, detail=detail,
        occurred_at=now
    );
}

"""Walks the incident graph for one invocation: hub, station, hub, ... until the
supervisor stops or the gate asks a human."""
walker Supervise {
    has runner: any,
        steps: int = 0;

    can begin with Incident entry {
        visit [s for s in [here -->] if isinstance(s, Station) and s.name == HUB];
    }

    can act with Station entry {
        self.steps += 1;
        if self.steps > self.runner.cfg.recursion_limit {
            raise RecursionLimitError(
                f"incident loop exceeded {self.runner.cfg.recursion_limit} steps without converging"
            );
        }
        if here.name == HUB {
            target = self.runner.supervise();
            if target == END {
                disengage;
            }
            visit [s for s in [here -->] if isinstance(s, Station) and s.name == target];
        } elif here.name == GATE {
            # The gate does not block waiting for an answer. It records the request and
            # the run ends; the commander's decision arrives later as an input.
            self.runner.request_approval();
            disengage;
        } else {
            self.runner.run_station(here.name);
            visit [s for s in [here -->] if isinstance(s, Station) and s.name == HUB];
        }
    }
}

"""One incident, driven through its graph. Every method is an input to the loop
followed by one walk; the loop decides what that input means. Nothing here tells the
system what to do next."""
glob MAX_CHECKPOINTS: int = 400;

obj IncidentRunner {
    has agents: AgentSet,
        incident_id: str,
        cfg: SupervisorConfig = SupervisorConfig(),
        store: AdaptationStore = MemoryAdaptationStore(),
        proposer: any = None,
        incident: Incident | None = None,
        # The incident's baseline, held apart from the running posterior. A1 recomputes
        # learning from the whole evidence set each run, so it must read the baseline
        # every time: feeding it back its own posterior would double-count.
        baseline: any = None,
        checkpoints: list[IncidentState] = [];

    def postinit {
        if self.incident is None {
            self.incident = Incident(incident_id=self.incident_id, state=new_state(self.incident_id, ""));
        }
        self.adopt(self.incident);
    }

    """Work on this persisted incident node: lay out its stations and resume its baseline
    (or, for a new incident, what previous incidents learned)."""
    def adopt(inc: Incident) -> None {
        self.incident = inc;
        self.wire();
        held = inc.baseline;
        self.baseline = held if held is not None else self.store.load();
    }

    """Lay out the stations once: incident -> hub, hub <-> each specialist."""
    def wire -> None {
        inc = self.incident;
        if inc is None {
            return;
        }
        hubs = [s for s in [inc -->] if isinstance(s, Station) and s.name == HUB];
        if hubs {
            return;
        }
        hub = Station(name=HUB);
        inc ++> hub;
        for name in STATIONS {
            spoke = Station(name=name);
            hub ++> spoke;
            spoke ++> hub;
        }
    }

    def now -> datetime {
        return self.cfg.clock();
    }

    """The current state. Readers get a shallow copy, never the live lists."""
    def state -> IncidentState {
        inc = self.incident;
        return copy_state(inc.state) if inc else new_state(self.incident_id, "");
    }

    """Remember a transition. A long incident writes thousands of them, so the history keeps
    the most recent `MAX_CHECKPOINTS`; the incident node itself always holds the current state."""
    def checkpoint(state: IncidentState) -> None {
        self.checkpoints.append(state);
        if len(self.checkpoints) > MAX_CHECKPOINTS {
            self.checkpoints = self.checkpoints[-MAX_CHECKPOINTS:];
        }
    }

    """Every recorded transition, newest first: the reconstructable audit trail."""
    def history -> list[IncidentState] {
        return list(reversed(self.checkpoints));
    }

    """Fold one writer's update into the incident and checkpoint the result."""
    def commit(writer: str, update: dict[str, any]) -> None {
        if not update {
            return;
        }
        check_ownership(writer, update);
        inc = self.incident;
        if inc is None {
            return;
        }
        fresh = apply_update(inc.state, update);
        inc.state = fresh;
        self.checkpoint(fresh);
    }

    """An input followed by one walk. The baseline is re-asserted on every input, so
    learning is always baseline + all evidence."""
    def invoke(update: dict[str, any]) -> IncidentState {
        payload = dict(update);
        if "adaptation" not in payload {
            payload["adaptation"] = self.baseline;
        }
        inc = self.incident;
        if inc is not None {
            fresh = apply_update(inc.state, payload);
            inc.state = fresh;
            self.checkpoint(fresh);
            inc spawn Supervise(runner=self);
        }
        return self.state();
    }

    # ------------------------------------------------------------ stations

    """A0: record new commander decisions, then route. The decision is written into the
    trace as the hub's last event and returned, so the recorded decision and the edge
    taken can never disagree."""
    def supervise -> str {
        now = self.now();
        current = self.state();
        events: list[TraceEvent] = [];
        for a in unrecorded_approvals(current) {
            detail = f"{a.decision.value} plan {a.plan_id} v{a.plan_version} by {a.commander_id}";
            if a.constraint_note {
                detail += f"; constraint: {a.constraint_note}";
            }
            events.append(new_event("gate", APPROVAL_RECEIVED, a.tier, detail, now, event_id=f"APR-{a.approval_id}", human_touch=True));
        }
        # Decide on the state including those events, so a rejection recorded this tick
        # is visible to the re-solve predicate on the same tick.
        view = apply_update(current, {"trace": events}) if events else current;
        decision = decide(view, self.cfg, now, self.proposer);
        detail = decision.reason + (" [model-proposed]" if decision.proposed_by_model else "");
        events.append(new_event(HUB, f"{ROUTE_PREFIX}{decision.target}", decision.tier, detail, now));
        update: dict[str, any] = {"trace": events};
        if decision.status is not None {
            update["status"] = decision.status;
        }
        self.commit(HUB, update);
        return decision.target;
    }

    """Run one specialist station and fold its update in."""
    def run_station(name: str) -> None {
        now = self.now();
        current = self.state();
        if name == A1 {
            self.commit(A1, self.agents.ingest.run(current, now));
        } elif name == A2 {
            self.commit(A2, self.agents.hazard.run(current, now));
        } elif name == A3 {
            self.commit(A3, self.agents.triage.run(current, now));
        } elif name == A4 {
            self.commit(A4, self.agents.optimiser.run(current, now));
        } elif name == A5 {
            self.commit(A5, self.verify(current, now));
        } elif name == A6 {
            self.commit("A6", self.release(current, now));
        } else {
            raise RuntimeError(f"unknown station {name}");
        }
    }

    """A5: verify the current plan. Writes the verdict only."""
    def verify(current: IncidentState, now: datetime) -> dict[str, any] {
        plan = current.plan;
        if plan is None {
            raise RuntimeError("routing invariant broken: A5 reached with no plan in state");
        }
        verdict = self.agents.guardrail.verify_plan(plan, list(current.clusters), current.hazard, list(current.vehicles), now=now);
        passed = len([c for c in verdict.checks if c.passed]);
        detail = f"plan {plan.plan_id} v{plan.version}: {passed}/{len(verdict.checks)} checks passed";
        if not verdict.passed {
            detail += f"; violated {verdict.violated_constraint} -> {verdict.remediation_hint}";
        }
        action = A5_VERIFIED if verdict.passed else A5_REJECTED;
        return {"verdict": verdict, "trace": [new_event("A5", action, ActionTier.TIER_A, detail, now)]};
    }

    """The gate: the only point at which a human is consulted. It records the request;
    the decision arrives later as an ApprovalRecord picked up by the next walk."""
    def request_approval -> None {
        now = self.now();
        current = self.state();
        plan = current.plan;
        verdict = current.verdict;
        if plan is None or verdict is None {
            raise RuntimeError("routing invariant broken: gate reached without a verified plan");
        }
        checks = ", ".join([c.name for c in verdict.checks if c.passed]);
        detail = f"plan {plan.plan_id} v{plan.version}: {len(plan.assignments)} dispatch(es), "
            + f"solver {plan.solver_status.value} gap={plan.optimality_gap}; guardrails passed: {checks}";
        self.commit("gate", {"trace": [new_event("gate", GATE_REQUESTED, ActionTier.TIER_C, detail, now)]});
    }

    """A6 release: an approved plan is released, exactly once per version. Refuses
    outright without an approval: a second, independent lock on the only irreversible
    act the system performs."""
    def release(current: IncidentState, now: datetime) -> dict[str, any] {
        if not release_due(current) {
            raise PermissionError("release refused: current plan version has no APPROVED record");
        }
        plan = current.plan;
        approval = approval_for_current_plan(current);
        if plan is None or approval is None {
            raise PermissionError("release refused: current plan version has no APPROVED record");
        }
        released = new_event(
            "A6", RELEASED, ActionTier.TIER_C,
            f"plan {plan.plan_id} v{plan.version}: {len(plan.assignments)} dispatch order(s) released "
                + f"under approval {approval.approval_id} ({approval.commander_id})",
            now, event_id=released_event_id(plan)
        );
        # The released assignments become commitments: from here A4 may not re-task
        # these crews, because they are moving.
        update: dict[str, any] = {"trace": [released]};
        opened = release_records(current, plan.assignments, plan.plan_id, plan.version, now);
        if opened {
            update["commitments"] = opened;
        }
        if self.agents.comms is not None {
            out = dict(self.agents.comms.run(current, now));
            update["trace"] = [released] + list(out.pop("trace", []));
            for (k, v) in out.items() {
                if k == "commitments" and "commitments" in update {
                    update["commitments"] = list(update["commitments"]) + list(v);
                } else {
                    update[k] = v;
                }
            }
        }
        return update;
    }

    # ------------------------------------------------------------ inputs

    """The commander states the objective once. Everything after is the system's. The
    incident starts from what previous incidents learned."""
    def open(goal: str, vehicles: list[Vehicle], shelters: list[Shelter] | None = None) -> IncidentState {
        self.baseline = self.store.load();
        inc = self.incident;
        if inc is not None {
            inc.state = new_state(self.incident_id, goal, vehicles, shelters);
            inc.baseline = self.baseline;
        }
        return self.invoke({"adaptation": self.baseline});
    }

    def ingest(signals: list[RawSignal]) -> IncidentState {
        return self.invoke({"raw_signals": signals});
    }

    """Heartbeat: lets time-based triggers (the hazard TTL) fire."""
    def tick -> IncidentState {
        return self.invoke({});
    }

    """Record the commander's decision on the plan version they were shown. If a newer
    plan exists, raise rather than attach their decision to a plan they never saw."""
    def decide(
        decision: ApprovalDecision, commander_id: str, plan_version: int,
        constraint: str | None = None, publish_alerts: bool = False, now: datetime | None = None
    ) -> IncidentState {
        plan = self.state().plan;
        if plan is None {
            raise LookupError("no plan to decide on");
        }
        if plan.version != plan_version {
            raise ValueError(
                f"stale decision: commander saw plan v{plan_version}, current is v{plan.version}; "
                + "re-present the current plan"
            );
        }
        record = ApprovalRecord(
            approval_id=f"APV-{uuid.uuid4().hex[:10]}", plan_id=plan.plan_id, plan_version=plan.version,
            tier=ActionTier.TIER_C, decision=decision, commander_id=commander_id,
            constraint_note=constraint, publish_alerts=publish_alerts, decided_at=now or self.now()
        );
        return self.invoke({"approvals": [record]});
    }

    """An operator says where a held report actually is. Tier A and reversible: the
    cluster it creates still has to clear triage, the confidence floor and the gate."""
    def place_report(report_id: str, lat: float, lon: float, placed_by: str, now: datetime | None = None) -> IncidentState {
        moment = now or self.now();
        fix = LocationFix(report_id=report_id, lat=lat, lon=lon, placed_by=placed_by, placed_at=moment);
        event = new_event("OPS", REPORT_PLACED, ActionTier.TIER_A, f"{report_id} placed at {lat:.5f}, {lon:.5f} by {placed_by}", moment, human_touch=True);
        return self.invoke({"location_fixes": [fix], "trace": [event]});
    }

    """Cancel a public bulletin and tell the people who got it that it is over. Tier C,
    like issuing one: two records are written, the cancelled bulletin and an all-clear
    for the same areas, because retiring a warning silently leaves everyone who read it
    still believing it."""
    def stand_down(alert_id: str, commander_id: str, now: datetime | None = None) -> IncidentState {
        import from resqmesh.agents.comms.alerts { fill_template }
        import from resqmesh.agents.comms.lifecycle { latest, retire }
        moment = now or self.now();
        live = latest(self.state().alerts or []);
        alert = live.get(alert_id);
        if alert is None {
            raise LookupError(f"no bulletin {alert_id}");
        }
        if not alert_is_current(alert.status) {
            raise ValueError(f"{alert_id} is already {alert.status.value}");
        }
        cancelled = retire(alert, AlertStatus.CANCELLED, stood_down_by=commander_id);
        texts = fill_template("stand_down", {"area": alert.slots.get("area", "")});
        all_clear = evolve(
            alert, alert_id=f"{alert_id}-CLEAR", template_id="stand_down", status=AlertStatus.PUBLISHED,
            issued_at=moment, expires_at=None, superseded_by=None, stood_down_by=None,
            text_si=texts[0], text_ta=texts[1], text_en=texts[2]
        );
        event = new_event(
            "A6", "alert_stood_down", ActionTier.TIER_C,
            f"{alert_id} ({alert.template_id}) cancelled by {commander_id}; "
                + f"all-clear issued to {', '.join(alert.target_gn_ids)}",
            moment, human_touch=True
        );
        return self.invoke({"alerts": [cancelled, all_clear], "trace": [event]});
    }

    """Emergency halt: freeze all autonomous execution, keep the whole picture."""
    def halt -> IncidentState {
        return self.invoke({"status": IncidentStatus.HALTED});
    }

    def resume -> IncidentState {
        return self.invoke({"status": IncidentStatus.OPEN});
    }

    """A field responder reports on their dispatch: en route, on scene, done, or
    declined. Advances the crew's commitment; every status is a Tier A operational
    event that can never move the system toward a Tier C action."""
    def responder_update(
        vehicle_id: str, cluster_id: str, status: str, note: str | None = None, now: datetime | None = None
    ) -> IncidentState {
        moment = now or self.now();
        record = find_open(self.state(), vehicle_id, cluster_id);
        if record is None {
            raise LookupError(f"{vehicle_id} has no open dispatch to {cluster_id}");
        }
        advanced = close(record, CommitmentStatus(status), moment, note);
        detail = f"{vehicle_id}: {status.replace('_', ' ')} — {cluster_id}" + (f" ({note})" if note else "");
        event = new_event("OPS", f"responder_{status}", ActionTier.TIER_A, detail, moment);
        return self.invoke({"trace": [event], "commitments": [advanced]});
    }

    """Carry this incident's learning into the store, for the next one. Called when an
    incident finishes or the server shuts down, never mid-incident: the store holds the
    baseline each tick is measured against."""
    def persist_learning -> None {
        self.store.save(self.state().adaptation);
    }
}
