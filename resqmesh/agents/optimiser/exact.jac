"""Exact optimum runner — the offline reference for the optimality-gap metric.

Same model, same cost, no time budget. Run by the evaluation harness, never on the
live decision path. Table 7 target: live plan within 5 % of this.
"""

import from resqmesh.agents.optimiser.cpsat { Solution, solve_cpsat }
import from resqmesh.agents.optimiser.problem { DispatchProblem }
import from resqmesh.contracts.enums { SolverStatus }

def solve_exact(problem: DispatchProblem, workers: int = 8) -> Solution {
    solution = solve_cpsat(problem, time_budget_s=None, workers=workers);
    if solution.status != SolverStatus.OPTIMAL {  # cannot happen without a time limit
        raise RuntimeError("exact solve did not prove optimality");
    }
    return solution;
}

"""Relative gap of a live plan against the proven optimum (0.0 = optimal)."""
def gap_to_exact(live_objective: float, exact_objective: float) -> float {
    if exact_objective <= 0 {
        return 0.0 if live_objective <= 0 else 1.0;
    }
    return max(0.0, (live_objective - exact_objective) / exact_objective);
}
