"""Measurements that need no external ground truth.

Four of Table 7's metrics would otherwise be reported as "not measured" because
nobody had computed them, not because they need labels. Each one here is a real
experiment over the same scenario the harness already runs:

* **response time improvement**: replay the whole scenario with the greedy
  nearest-available baseline that current practice approximates, and compare the two
  runs on the cost function both solvers share;
* **re-plan latency**: wall-clock from handing the system a wave of reports to a
  plan standing at the gate;
* **degraded-mode continuity**: the same scenario with every hosted provider
  unreachable, so extraction falls to the deterministic offline tier: how much of the
  decision-making survives;
* **tool-call success**: provider requests made against those that failed with no
  recovery, which is only meaningful when a real provider chain is in play.

Each returns None rather than a flattering number when the experiment could not be
run, exactly as the label-scored metrics do.
"""

import time;
import from resqmesh.contracts.models { DispatchPlan, PriorityItem }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.predicates { GATE_REQUESTED }
import from resqmesh.eval.metrics { priority_weighted_response_time, response_time_improvement }

"""Wall-clock from a wave of reports to a plan waiting at the gate."""
obj Timings {
    has latencies_s: list[float] = [];

    def record(seconds: float) -> None {
        self.latencies_s.append(seconds);
    }

    """95th percentile, nearest-rank. None with nothing to measure."""
    def p95 -> float | None {
        if not self.latencies_s {
            return None;
        }
        ordered = sorted(self.latencies_s);
        index = max(0, min(len(ordered) - 1, round(0.95 * len(ordered)) - 1));
        return round(ordered[index], 2);
    }
}

"""Call `action` and return (its result, elapsed seconds)."""
def timed(action: any) -> tuple[any, float] {
    started = time.perf_counter();
    result = action();
    return (result, time.perf_counter() - started);
}

# --------------------------------------------------------------------------- #
# Response time against the greedy baseline
# --------------------------------------------------------------------------- #

"""Priority-weighted mean arrival time for a plan. None if it dispatched nothing.

Unserved demand is deliberately *not* counted as zero: a plan that reaches one victim
quickly and abandons three others must not score better than one that reaches all
four. Coverage is reported separately, alongside."""
def weighted_response_time(plan: DispatchPlan | None, queue: list[PriorityItem]) -> float | None {
    if plan is None or not plan.assignments {
        return None;
    }
    priorities = {q.cluster_id: q.score_0_1 for q in queue};
    etas = {a.cluster_id: a.eta_minutes for a in plan.assignments};
    return priority_weighted_response_time(etas, priorities);
}

"""The optimiser against greedy nearest-available over a whole incident.

Two things about how this is measured, both learned the hard way.

*It compares replays, not re-solves.* Handing greedy the final state and asking it to
re-solve is not a baseline: the live plan was built incrementally, wave by wave,
committing vehicles before later reports arrived, while the re-solve gets the
finished picture and an idle fleet. Greedy "wins" that by 60% on cost alone. So the
baseline is the same scenario replayed from the first report with only the solver
swapped: the comparison current practice would actually make.

*It compares on the cost function both solvers share* (A4's `plan_cost`):
priority-weighted response time with unserved demand charged as a long delay.
Averaging arrival times over only the demands a plan chose to serve rewards
abandoning the far ones: reach one victim in two minutes, leave three, and you would
"beat" the plan that reaches all four.

`comparable` is False when the two replays did not face the same demand, in which
case the costs describe different problems and `improvement()` is None."""
obj BaselineComparison {
    has system_cost: float | None,
        baseline_cost: float | None,
        system_dispatched: int,
        baseline_dispatched: int,
        # Mean arrival over served demand only, a diagnostic, never the headline.
        system_minutes: float | None = None,
        baseline_minutes: float | None = None,
        comparable: bool = True;

    """Fraction better than greedy on the shared objective."""
    def improvement -> float | None {
        sys_cost = self.system_cost;
        base_cost = self.baseline_cost;
        if not self.comparable or sys_cost is None or base_cost is None {
            return None;
        }
        return round(response_time_improvement(sys_cost, base_cost), 4);
    }
}

"""Score two finished replays of one scenario against each other."""
def compare_plans(system: IncidentState, baseline: IncidentState) -> BaselineComparison | None {
    ours = system.plan;
    theirs = baseline.plan;
    if ours is None or theirs is None {
        return None;
    }
    our_queue = list(system.queue or []);
    their_queue = list(baseline.queue or []);
    return BaselineComparison(
        system_cost=ours.objective_value,
        baseline_cost=theirs.objective_value,
        system_dispatched=len(ours.assignments),
        baseline_dispatched=len(theirs.assignments),
        system_minutes=weighted_response_time(ours, our_queue),
        baseline_minutes=weighted_response_time(theirs, their_queue),
        comparable=(
            set([q.cluster_id for q in our_queue]) == set([q.cluster_id for q in their_queue])
        )
    );
}

# --------------------------------------------------------------------------- #
# Degraded mode
# --------------------------------------------------------------------------- #

"""The same scenario with every hosted provider unreachable.

`continuity()` is the share of the normal run's decisions that still happen when
extraction falls back to the deterministic offline tier: plans reaching the gate, and
demand located well enough to rank."""
obj DegradedComparison {
    has normal_plans: int,
        degraded_plans: int,
        normal_located: int,
        degraded_located: int;

    def continuity -> float | None {
        if self.normal_plans == 0 {
            return None;
        }
        plans = min(1.0, self.degraded_plans / self.normal_plans);
        located = 1.0 if self.normal_located == 0 else min(1.0, self.degraded_located / self.normal_located);
        return round((plans + located) / 2, 4);
    }
}

"""(plans that reached the gate, demand clusters located) for one run."""
def decisions_in(state: IncidentState, trace: list[any]) -> tuple[int, int] {
    ids: set[str] = set();
    for e in trace {
        if e.agent == "gate" and e.action == GATE_REQUESTED {
            ids.add(e.detail.split()[1]);
        }
    }
    return (len(ids), len(state.clusters or []));
}

# --------------------------------------------------------------------------- #
# Tool calls
# --------------------------------------------------------------------------- #

"""Provider calls attempted against those that failed with no recovery.

Only meaningful with a real provider chain: the offline scenario makes no calls, and
a rate computed over zero calls is not a 100% success rate."""
obj ToolCalls {
    has attempted: int = 0,
        unrecovered: int = 0;

    def success_rate -> float | None {
        if self.attempted == 0 {
            return None;
        }
        return round((self.attempted - self.unrecovered) / self.attempted, 4);
    }
}

"""Read the provider router's own request tally, if there is a router at all.

The offline scenario routes through no provider, so there is no tally and the metric
stays unmeasured. A rate computed over zero calls is not a 100% success rate, and
reporting it as one would be the easiest number on the scorecard to fake."""
def tool_calls_from(llm: any) -> ToolCalls {
    tally = getattr(llm, "tally", None);
    if tally is None {
        return ToolCalls();
    }
    return ToolCalls(attempted=tally.requests, unrecovered=tally.unrecovered);
}
