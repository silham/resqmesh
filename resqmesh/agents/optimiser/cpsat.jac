"""OR-Tools CP-SAT over the shared dispatch model.

Model: one boolean x[v,c] per *feasible* pair only (unreachable pairs do not exist, so
an infeasible route is unrepresentable), one boolean u[c] per demand,

    for each c:  sum_v x[v,c] + u[c] == 1        (served once, or explicitly not)
    for each v:  sum_c x[v,c] <= 1               (a vehicle is in one place)
    minimise     sum cost[v,c] * x[v,c] + sum penalty[c] * u[c]

Capacity is inside the cost (load = min(people, capacity), shortfall penalised), so
every assignment respects it by construction. Costs are scaled to integers
(`COST_SCALE`) because CP-SAT is an integer solver; reported objectives are unscaled.

The greedy incumbent is passed as a solution hint, and the solve is capped at the time
budget. If the budget runs out we return the best incumbent with its real gap —
`FEASIBLE` with `gap = (objective - bound) / objective` — never nothing.
"""

import time;
import from resqmesh.agents.optimiser.problem { DispatchProblem, plan_cost }
import from resqmesh.contracts.enums { SolverStatus }

glob COST_SCALE: int = 100;

obj Solution {
    has assignment: dict[str, str],
        objective: float,
        status: SolverStatus,
        optimality_gap: float | None,
        bound: float | None,
        solve_seconds: float,
        warm_started: bool;
}

"""Solve; raises only on genuine solver failure (the agent falls back to greedy)."""
def solve_cpsat(
    problem: DispatchProblem,
    time_budget_s: float | None = 10.0,
    hint: dict[str, str] | None = None,
    workers: int = 8,
    seed: int = 0
) -> Solution {
    import from ortools.sat.python { cp_model }

    t0 = time.perf_counter();
    pairs = problem.pairs();
    if not pairs or not problem.demands {
        # Nothing assignable: "serve nobody" is the unique, trivially optimal answer.
        empty: dict[str, str] = {};
        cost = plan_cost(problem, empty);
        return Solution(
            assignment=empty, objective=cost, status=SolverStatus.OPTIMAL, optimality_gap=0.0,
            bound=cost, solve_seconds=time.perf_counter() - t0, warm_started=False
        );
    }

    model: any = cp_model.CpModel();
    x: dict[tuple[str, str], any] = {p: model.new_bool_var(f"x_{p[0]}_{p[1]}") for p in pairs};
    u: dict[str, any] = {d.cluster_id: model.new_bool_var(f"u_{d.cluster_id}") for d in problem.demands};
    for d in problem.demands {
        model.add(sum([x[p] for p in pairs if p[1] == d.cluster_id]) + u[d.cluster_id] == 1);
    }
    for v in problem.vehicles {
        mine = [x[p] for p in pairs if p[0] == v.vehicle_id];
        if mine {
            model.add(sum(mine) <= 1);
        }
    }
    model.minimize(
        sum([round(problem.pair_cost(p[0], p[1]) * COST_SCALE) * x[p] for p in pairs])
        + sum([round(problem.unserved_cost(c) * COST_SCALE) * u[c] for c in u])
    );

    warm = bool(hint);
    if hint {
        chosen = {(v, c) for (v, c) in hint.items()};
        for (p, var) in x.items() {
            model.add_hint(var, p in chosen);
        }
        served = set(hint.values());
        for (c, var) in u.items() {
            model.add_hint(var, c not in served);
        }
    }

    solver: any = cp_model.CpSolver();
    if time_budget_s is not None {
        solver.parameters.max_time_in_seconds = float(time_budget_s);
    }
    solver.parameters.num_workers = workers;
    solver.parameters.random_seed = seed;
    code = solver.solve(model);
    elapsed = time.perf_counter() - t0;

    if code == cp_model.UNKNOWN and hint {
        # Budget ran out before CP-SAT adopted any solution of its own. The greedy
        # incumbent is still feasible by construction: return it, gap stated against
        # whatever lower bound the search proved.
        obj_value = plan_cost(problem, hint);
        bound = max(0.0, solver.best_objective_bound / COST_SCALE);
        gap = max(0.0, min(1.0, (obj_value - bound) / obj_value)) if obj_value > 0 else 0.0;
        return Solution(
            assignment=dict(hint), objective=obj_value, status=SolverStatus.FEASIBLE,
            optimality_gap=round(gap, 6), bound=bound, solve_seconds=elapsed, warm_started=True
        );
    }
    if code not in [cp_model.OPTIMAL, cp_model.FEASIBLE] {
        raise RuntimeError(f"CP-SAT returned {solver.status_name(code)}");
    }

    result: dict[str, str] = {};
    for (p, var) in x.items() {
        if solver.value(var) {
            result[p[0]] = p[1];
        }
    }
    objective = plan_cost(problem, result);
    scaled_obj = solver.objective_value;
    scaled_bound = solver.best_objective_bound;
    status = SolverStatus.FEASIBLE;
    gap = 0.0;
    if code == cp_model.OPTIMAL {
        status = SolverStatus.OPTIMAL;
    } else {
        gap = max(0.0, min(1.0, (scaled_obj - scaled_bound) / scaled_obj)) if scaled_obj > 0 else 0.0;
    }
    return Solution(
        assignment=result,
        objective=objective,
        status=status,
        optimality_gap=round(gap, 6),
        bound=scaled_bound / COST_SCALE,
        solve_seconds=elapsed,
        warm_started=warm
    );
}
