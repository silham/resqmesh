"""The dispatch problem, and the one cost function every solver shares.

Formulation (deliberately simple and provably correct):

* each available vehicle serves **at most one** demand cluster per plan, and each
  cluster receives **at most one** vehicle. The `DispatchPlan` contract already forces
  this — one `cluster_id` per `Assignment`, no vehicle twice — so a multi-stop VRP
  would have nowhere to put its answer. The plan is recomputed every cycle, so a
  vehicle freed from one job is re-assigned on the next re-plan.
* a pair (v, c) exists only if c is reachable from v's depot on the pruned graph;
* load = min(people at c, capacity of v); any shortfall is penalised pro rata;
* objective, minimised — **priority-weighted response time**:

      sum over assigned (v,c):  w_c * (eta_vc + P * shortfall_vc / demand_c)
    + sum over unserved c:      w_c * P

  with w_c the A3 priority score and P = `UNSERVED_PENALTY_MIN`. Leaving a cluster
  unserved costs as much as a P-minute delay, so the solver serves as many high
  priority clusters as it can, then minimises how long they wait.

Greedy, CP-SAT and the exact runner all evaluate this same `plan_cost`, which is what
makes their objective values — and the optimality gap — comparable.
"""

import from resqmesh.agents.optimiser.travel { Leg }

glob UNSERVED_PENALTY_MIN: float = 600.0;
glob MIN_PRIORITY: float = 0.01;

obj Demand {
    has cluster_id: str,
        priority: float,  # A3 score, floored at MIN_PRIORITY
        people: int,  # >= 1
        rank: int;
}

obj Fleet {
    has vehicle_id: str,
        capacity: int;
}

obj DispatchProblem {
    has demands: list[Demand],
        vehicles: list[Fleet],
        legs: dict[tuple[str, str], Leg],
        forbidden_pairs: frozenset[tuple[str, str]] = frozenset(),
        penalty_min: float = UNSERVED_PENALTY_MIN,
        _demand: dict[str, Demand] = {},
        _vehicle: dict[str, Fleet] = {};

    def postinit {
        self._demand = {d.cluster_id: d for d in self.demands};
        self._vehicle = {v.vehicle_id: v for v in self.vehicles};
    }

    def demand(cluster_id: str) -> Demand {
        return self._demand[cluster_id];
    }

    def vehicle(vehicle_id: str) -> Fleet {
        return self._vehicle[vehicle_id];
    }

    def feasible(vehicle_id: str, cluster_id: str) -> bool {
        return (
            (vehicle_id, cluster_id) in self.legs
            and (vehicle_id, cluster_id) not in self.forbidden_pairs
            and self._vehicle[vehicle_id].capacity >= 1
        );
    }

    def pairs -> list[tuple[str, str]] {
        return [
            (v.vehicle_id, d.cluster_id)
            for v in self.vehicles
            for d in self.demands
            if self.feasible(v.vehicle_id, d.cluster_id)
        ];
    }

    def load(vehicle_id: str, cluster_id: str) -> int {
        return min(self._demand[cluster_id].people, self._vehicle[vehicle_id].capacity);
    }

    def pair_cost(vehicle_id: str, cluster_id: str) -> float {
        d = self._demand[cluster_id];
        shortfall = d.people - self.load(vehicle_id, cluster_id);
        eta = self.legs[(vehicle_id, cluster_id)].eta_minutes;
        return d.priority * (eta + self.penalty_min * shortfall / d.people);
    }

    def unserved_cost(cluster_id: str) -> float {
        return self._demand[cluster_id].priority * self.penalty_min;
    }
}

"""Objective of an assignment `{vehicle_id: cluster_id}` under the shared model."""
def plan_cost(problem: DispatchProblem, assignment: dict[str, str]) -> float {
    served = set(assignment.values());
    total = sum([problem.pair_cost(v, c) for (v, c) in assignment.items()]);
    total += sum([problem.unserved_cost(d.cluster_id) for d in problem.demands if d.cluster_id not in served]);
    return total;
}
