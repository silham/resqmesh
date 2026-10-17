"""Run one incident end to end, offline, no API key, no download.

    jac run -b python --no-takeover scripts/demo.jac                  # scripted: approve, second wave, reject
    jac run -b python --no-takeover scripts/demo.jac --interactive    # you are the commander at each gate
    jac run -b python --no-takeover scripts/demo.jac --llm live       # real providers from .env
    jac run -b python --no-takeover scripts/demo.jac --world real     # the fetched Kelani basin, 2016 rainfall

The commander states one goal; everything up to the approval gate is the system's own
decision, and the printout is the trace it wrote while making them.
"""

import argparse;
import sys;
import tempfile;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.contracts.enums { ApprovalDecision, IncidentStatus }
import from resqmesh.contracts.models { DispatchPlan }
import from resqmesh.graph.loop { IncidentRunner }
import from resqmesh.graph.supervisor { SupervisorConfig }
import from resqmesh.graph.world { follow_up_signals, opening_signals, real_world, synthetic_world }

glob GOAL: str = "coordinate the response to flooding in the Kelani basin";

"""Simulated incident time. Advanced explicitly so the run is reproducible."""
obj Clock {
    has now: datetime;

    def call -> datetime {
        return self.now;
    }

    def advance(minutes: float) -> None {
        self.now = self.now + timedelta(minutes=minutes);
    }
}

obj Printer {
    has runner: IncidentRunner,
        seen: int = 0;

    def new_events(title: str) -> None {
        state = self.runner.state();
        print(f"\n== {title}  [status: {state.status.value}]");
        for e in state.trace[self.seen:] {
            tag = "  HUMAN " if e.human_touch else "        ";
            print(f"{tag}{e.agent:<5} {e.action:<20} {e.detail}");
        }
        self.seen = len(state.trace);
    }

    def gate_panel -> None {
        state = self.runner.state();
        plan = current_plan(self.runner);
        where = {c.cluster_id: c.gn_id for c in state.clusters};
        print(f"\n   +-- TIER C: APPROVAL REQUIRED -- plan {plan.plan_id} v{plan.version} (solver {plan.solver_status.value}, gap {plan.optimality_gap})");
        for a in plan.assignments {
            print(f"   |  {a.vehicle_id:<8} -> {a.cluster_id:<12} {where.get(a.cluster_id, '?'):<8} ETA {a.eta_minutes:5.1f} min  load {a.load}");
        }
        for cid in plan.unassigned_cluster_ids {
            print(f"   |  held     {cid:<12} {where.get(cid, '?')}");
        }
        print("   +--");
    }
}

def current_plan(runner: IncidentRunner) -> DispatchPlan {
    plan = runner.state().plan;
    if plan is None {
        raise RuntimeError("the gate was reached without a plan; this is a supervisor bug");
    }
    return plan;
}

"""The autonomy claim, measured from the trace rather than asserted: consecutive
autonomous steps between human touches (target >= 12)."""
def autonomy_summary(runner: IncidentRunner) -> str {
    chains: list[int] = [];
    current = 0;
    trace = runner.state().trace;
    for e in trace {
        if e.human_touch {
            chains.append(current);
            current = 0;
        } elif e.agent in ["A0", "A1", "A2", "A3", "A4", "A5"] {
            current += 1;
        }
    }
    chains.append(current);
    humans = len([e for e in trace if e.human_touch]);
    mean = sum(chains) / len(chains);
    return f"{len(trace)} trace events, {humans} human decision(s); autonomous steps between human touches: {chains} (mean {mean:.1f})";
}

def commander(
    printer: Printer, runner: IncidentRunner, clock: Clock, interactive: bool,
    decision: ApprovalDecision, constraint: str | None
) -> None {
    printer.gate_panel();
    if interactive {
        answer = input("   approve / reject / modify? [a/r/m] ").strip().lower()[:1];
        choices = {"a": ApprovalDecision.APPROVED, "r": ApprovalDecision.REJECTED, "m": ApprovalDecision.MODIFIED};
        decision = choices.get(answer, ApprovalDecision.REJECTED);
        constraint = None if decision == ApprovalDecision.APPROVED else (input("   constraint (e.g. 'exclude_vehicle: BOAT-01'): ").strip() or None);
    } else {
        print(f"   commander (scripted): {decision.value}" + (f" -- {constraint}" if constraint else ""));
    }
    clock.advance(1);
    runner.decide(decision, "cmdr-01", plan_version=current_plan(runner).version, constraint=constraint);
}

def main(argv: list[str]) -> int {
    ap = argparse.ArgumentParser(description="Run one ResQ-Mesh incident end to end.");
    ap.add_argument("--interactive", action="store_true", help="decide at each gate yourself");
    ap.add_argument("--rain", type=float, `default=8.0, help="synthetic rainfall peak, mm/h (synthetic world only)");
    ap.add_argument("--world", choices=["synthetic", "real"], `default="synthetic");
    ap.add_argument("--at", `default="2016-05-14T06:00", help="replay clock for the real world's rainfall archive (UTC)");
    ap.add_argument("--llm", choices=["offline", "live"], `default="offline");
    args = ap.parse_args(argv);

    llm: any = None;
    if args.llm == "live" {
        import from dotenv { load_dotenv }
        import from resqmesh.adapters.llm.config { router_from_env }
        load_dotenv();
        (router, chain) = router_from_env();
        llm = router;
        active = " -> ".join([p.value for p in chain.active]) or "none";
        print(f"LLM chain: {active} -> offline rules");
        for (name, why) in chain.skipped {
            print(f"  skipped {name}: {why}");
        }
    }

    out_dir = Path(tempfile.mkdtemp(prefix="resqmesh-"));
    clock = Clock(now=datetime(2026, 9, 21, 6, 0, tzinfo=UTC));
    world: any = None;
    if args.world == "real" {
        clock = Clock(now=datetime.fromisoformat(args.at).replace(tzinfo=UTC));
        print(f"World: real Kelani basin, rainfall replayed at {clock.now:%Y-%m-%d %H:%M} UTC");
        world = real_world(out_dir, clock=clock.call, llm=llm);
        print(f"  {len(world.gazetteer.divisions)} GN divisions · {len(world.vehicles)} vehicles");
    } else {
        world = synthetic_world(out_dir, rain_peak_mm=args.rain, llm=llm);
    }
    runner = IncidentRunner(agents=world.agents, incident_id="KLN-2026-014", cfg=SupervisorConfig(clock=clock.call));
    out = Printer(runner=runner);

    print(f'ResQ-Mesh -- Kelani incident (offline).\nCommander goal, stated once: "{GOAL}"');
    runner.open(GOAL, world.vehicles);
    out.new_events("incident opened");

    wave1 = opening_signals(clock.now);
    clock.advance(15);   # the reports arrived over the last quarter hour
    runner.ingest(wave1);
    out.new_events(f"{len(wave1)} field reports received");
    if runner.state().status == IncidentStatus.AWAITING_APPROVAL {
        commander(out, runner, clock, args.interactive, ApprovalDecision.APPROVED, None);
        out.new_events("commander decided");
    }

    wave2 = follow_up_signals(clock.now);
    clock.advance(10);
    runner.ingest(wave2);
    out.new_events(f"{len(wave2)} new reports mid-incident -> re-plan");
    if runner.state().status == IncidentStatus.AWAITING_APPROVAL {
        commander(out, runner, clock, args.interactive, ApprovalDecision.REJECTED, "exclude_vehicle: BOAT-01");
        out.new_events("commander decided");
    }

    print(f"\n{autonomy_summary(runner)}");
    print(f"{len(runner.history())} checkpoints written");
    return 0;
}

with entry {
    argv = [a for a in sys.argv[1:] if not a.endswith(".jac")];
    exit_code = main(argv);
}
