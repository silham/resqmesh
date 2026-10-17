"""Greedy nearest-available assignment.

Three jobs, one function:

1. the CP-SAT **warm start**, so a feasible incumbent exists from the first
   millisecond of the solve;
2. the documented **fallback** when the solver is unavailable or fails —
   `SolverStatus.GREEDY_FALLBACK`, gap reported as unknown;
3. the evaluation **baseline** for the "response time improvement >= 25 %" metric,
   requested with `mode="greedy"` and reported as `SolverStatus.GREEDY_BASELINE` so
   it is never mistaken for a fallback.

Walk the demand queue in rank order; give each cluster the cheapest still-free
feasible vehicle under the shared cost (which is ETA-dominated, i.e. "nearest").
"""

import from resqmesh.agents.optimiser.problem { Demand, DispatchProblem }

def _rank_order(d: Demand) -> tuple[int, str] {
    return (d.rank, d.cluster_id);
}

"""Returns `{vehicle_id: cluster_id}`."""
def solve_greedy(problem: DispatchProblem) -> dict[str, str] {
    free = {v.vehicle_id for v in problem.vehicles};
    assignment: dict[str, str] = {};
    for demand in sorted(problem.demands, key=_rank_order) {
        options = [
            (problem.pair_cost(v, demand.cluster_id), v)
            for v in sorted(free)
            if problem.feasible(v, demand.cluster_id)
        ];
        if not options {
            continue;
        }
        best = min(options)[1];
        assignment[best] = demand.cluster_id;
        free.discard(best);
    }
    return assignment;
}
