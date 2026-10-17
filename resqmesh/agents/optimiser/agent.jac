"""A4 — Resource Optimiser Agent. The **sole writer** of `DispatchPlan`.

State fields read: `queue` (A3), `clusters`, `reports` (A1), `vehicles`, `hazard`,
`pruned_graph` (A2), `adaptation` (travel residuals), `plan` (its own previous
version), `verdict` (A5), `approvals` (gate), `commitments`.
State field written: `plan` — and a `trace` event (plus `commitments` records for
crews a commander recalled). Nothing else, ever.

Pipeline per cycle:

1. **Constraints** — the last verdict on the last plan and every commander rejection
   become exclusions (`constraints`): a *targeted* re-solve, not a retry.
2. **Dispatchable demand** — queue clusters that are resolved, above the Tier C
   confidence floor, (optionally) in the gazetteer and not excluded. The rest go to
   `unassigned_cluster_ids`; A4 does not propose what A5 would have to reject.
3. **Travel** — legs on the hazard-pruned graph only (`travel`). A pair with no path
   does not exist in the model.
4. **Solve** — greedy incumbent, then CP-SAT warm-started from it within the time
   budget. Solver error -> greedy with `GREEDY_FALLBACK` and an unknown gap;
   `mode="greedy"` asks for the baseline itself and says `GREEDY_BASELINE`.
5. **Publish** — version + 1, honest `solver_status` / `optimality_gap`.

No network anywhere in this path, and no language model: every ETA, distance, load and
assignment can be recomputed by A5 from the same state.
"""

import hashlib;
import time;
import uuid;
import from datetime { datetime, UTC }
import from pathlib { Path }
import from resqmesh.adapters.geo.roads { load_graph }
import from resqmesh.adapters.geo.shapes { prepared, union_of }
import from resqmesh.agents.hazard.pruning { prune_graph }
import from resqmesh.agents.optimiser.constraints {
    SolveConstraints, apply_commander_notes, apply_verdict
}
import from resqmesh.agents.optimiser.cpsat { Solution, solve_cpsat }
import from resqmesh.agents.optimiser.exact { solve_exact }
import from resqmesh.agents.optimiser.greedy { solve_greedy }
import from resqmesh.agents.optimiser.problem {
    MIN_PRIORITY, UNSERVED_PENALTY_MIN, Demand, DispatchProblem, Fleet, plan_cost
}
import from resqmesh.agents.optimiser.travel {
    BOAT_ACCESS_KPH, BOAT_MAX_ACCESS_M, MAX_ACCESS_M, Leg, TravelModel
}
import from resqmesh.agents.guardrail.agent { GuardrailConfig }
import from resqmesh.contracts.enums { ActionTier, ClusterState, CommitmentStatus, SolverStatus }
import from resqmesh.contracts.models {
    AdaptationSnapshot, ApprovalRecord, Assignment, Commitment, DispatchPlan,
    GuardrailVerdict, HazardSurface, IncidentCluster, IncidentReport, PriorityItem,
    PrunedGraphRef, TraceEvent, Vehicle
}
import from resqmesh.contracts.ports { GeocodePort }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.graph.commitments {
    close as close_commitment, declined_commitments, open_commitments, served_cluster_ids
}

"""Solver modes: "cpsat" (live), "greedy" (the baseline), "exact" (offline reference)."""
glob MODES: list[str] = ["cpsat", "greedy", "exact"];

obj OptimiserConfig {
    has time_budget_s: float = 10.0,
        # Solver the graph node uses. "greedy" makes this agent the nearest-available
        # baseline that current practice approximates, which is how the evaluation
        # harness measures what the optimiser is worth over a whole incident.
        mode: str = "cpsat",
        # None -> the guardrail's own default floor, so A4 never proposes what A5 rejects.
        min_dispatch_confidence: float | None = None,
        max_access_m: float = MAX_ACCESS_M,
        boat_access_m: float = BOAT_MAX_ACCESS_M,
        unserved_penalty_min: float = UNSERVED_PENALTY_MIN,
        workers: int = 8;

    def floor -> float {
        if self.min_dispatch_confidence is not None {
            return self.min_dispatch_confidence;
        }
        return GuardrailConfig().tier_c_confidence_floor;
    }
}

obj PlanResult {
    has plan: DispatchPlan,
        problem: DispatchProblem,
        solution: Solution,
        detail: str,
        # Commitments a commander constraint broke. The caller closes them; A4 does not
        # decide to recall a crew, it only honours the decision that they should be.
        recalled: list[Commitment] = [];
}

"""Fingerprint of the demand queue a plan was solved against (A0's staleness check)."""
def queue_hash(queue: list[PriorityItem]) -> str {
    body = "\n".join([f"{q.cluster_id}:{q.rank}:{q.score_0_1:.6f}" for q in queue]);
    return hashlib.sha256(body.encode()).hexdigest()[:16];
}

def is_boat(vehicle: Vehicle) -> bool {
    return "boat" in vehicle.kind.lower();
}

"""The inundation, prepared for repeated segment tests. None when dry."""
def water_geometry(hazard: HazardSurface) -> any {
    geom = union_of(hazard.inundation_geojson);
    return prepared(geom) if geom is not None and not geom.is_empty else None;
}

"""Largest reported head-count in the cluster (duplicates describe one event); 1 if unknown."""
def demand_people(cluster: IncidentCluster, reports_by_id: dict[str, IncidentReport]) -> int {
    counts: list[int] = [];
    for rid in cluster.member_report_ids {
        r = reports_by_id.get(rid);
        if r is not None and r.reported_people_affected is not None {
            counts.append(r.reported_people_affected);
        }
    }
    return max(1, max(counts, `default=1));
}

obj OptimiserAgent {
    # path -> graph. Default loads (and caches) the pickle A2 published.
    has graph_loader: any = load_graph,
        # Fallback when A2 has not published a pruned graph: the base graph.
        base_graph_loader: any = load_graph,
        gazetteer: GeocodePort | None = None,
        config: OptimiserConfig = OptimiserConfig(),
        _models: dict[tuple[any, ...], TravelModel] = {};

    # -- travel model, cached per graph generation ---------------------------------

    def _routing_graph(pruned: PrunedGraphRef | None, hazard: HazardSurface) -> tuple[tuple[any, ...], any] {
        if pruned is not None {
            p = Path(pruned.graph_path);
            mtime = p.stat().st_mtime_ns if p.exists() else 0;
            return (("pruned", pruned.graph_path, mtime), self.graph_loader(pruned.graph_path));
        }
        # Degraded: no pruned graph published. Never route on the raw graph — apply the
        # surface's impassable set in memory so water is still unrepresentable.
        base = self.base_graph_loader();
        return (("base", id(base), hazard.version), prune_graph(base, hazard.impassable_edge_ids));
    }

    def _travel_model(
        pruned: PrunedGraphRef | None,
        hazard: HazardSurface,
        adaptation: AdaptationSnapshot | None,
        avoid: frozenset[str]
    ) -> TravelModel {
        routed = self._routing_graph(pruned, hazard);
        graph_key = routed[0];
        g = routed[1];
        residuals = adaptation.travel_residuals if adaptation is not None else {};
        key = (
            graph_key,
            hazard.driving_rainfall_mm_24h,
            tuple(sorted([(k, r.correction_factor) for (k, r) in residuals.items()])),
            hash(avoid)
        );
        if key not in self._models {
            if len(self._models) > 4 {
                self._models.clear();
            }
            self._models[key] = TravelModel.build(
                g, rain_mm=hazard.driving_rainfall_mm_24h, residuals=residuals, forbidden_edges=avoid
            );
        }
        return self._models[key];
    }

    # -- the plan --------------------------------------------------------------------

    def plan(
        queue: list[PriorityItem],
        clusters: list[IncidentCluster],
        reports: list[IncidentReport],
        vehicles: list[Vehicle],
        hazard: HazardSurface,
        pruned_graph: PrunedGraphRef | None,
        adaptation: AdaptationSnapshot | None = None,
        previous: DispatchPlan | None = None,
        verdict: GuardrailVerdict | None = None,
        approvals: list[ApprovalRecord] = [],
        completed: list[str] = [],
        committed: list[Commitment] = [],
        declined: list[Commitment] = [],
        now: datetime | None = None,
        mode: str = "cpsat"
    ) -> PlanResult {
        now = now or datetime.now(UTC);
        t0 = time.perf_counter();
        by_cluster = {c.cluster_id: c for c in clusters};
        reports_by_id = {r.report_id: r for r in reports};
        floor = self.config.floor();

        constraints = SolveConstraints();
        apply_verdict(
            constraints, verdict, previous, clusters=clusters, vehicles=vehicles, hazard=hazard,
            confidence_floor=floor, gazetteer=self.gazetteer
        );
        apply_commander_notes(
            constraints, approvals, cluster_ids=by_cluster, vehicle_ids=[v.vehicle_id for v in vehicles]
        );
        if pruned_graph is not None and pruned_graph.surface_version < hazard.version {
            # A2 has a newer surface than the graph it last pruned: close the new water
            # now rather than wait for A5 to catch the crossing.
            constraints.avoid(hazard.impassable_edge_ids, hazard.version);
        }

        # Crews already on the road are not available to re-task. They are lifted out of
        # the problem entirely — vehicle and destination both — and their assignments
        # are carried into the new plan verbatim. Re-solving the rest of the fleet
        # around them keeps re-planning continuous; what it no longer does is silently
        # send a moving crew somewhere else.
        #
        # A commander constraint excluding the vehicle or the cluster is the one thing
        # that breaks a pin: that is a recall, and it is their call to make.
        pinned: dict[str, Commitment] = {};
        for c in committed {
            if c.vehicle_id() not in constraints.excluded_vehicles
            and c.cluster_id() not in constraints.excluded_clusters {
                pinned[c.vehicle_id()] = c;
            }
        }
        recalled = [c for c in committed if c.vehicle_id() not in pinned];
        pinned_clusters = {c.cluster_id() for c in pinned.values()};
        # A crew that handed a job back is the only source of ground truth about why it
        # could not be done — a road gone since A2 last looked, a bridge out. If that
        # never reached the solver it would propose the same pairing again on the next
        # tick, and the crew would decline it again.
        for handed_back in declined {
            constraints.forbid_pair(
                handed_back.vehicle_id(), handed_back.cluster_id(), handed_back.note or "declined by crew"
            );
        }

        done = set(completed);
        demands: list[Demand] = [];
        held: list[tuple[str, str]] = [];
        for item in queue {
            c = by_cluster.get(item.cluster_id);
            if item.cluster_id in done {
                held.append((item.cluster_id, "responder reported complete"));
                continue;
            }
            if item.cluster_id in pinned_clusters {
                held.append((item.cluster_id, "crew already committed"));
                continue;
            }
            reason = OptimiserAgent._hold_reason(c, item.cluster_id, constraints, floor, self.gazetteer);
            if reason or c is None {
                held.append((item.cluster_id, reason or "not in cluster set"));
                continue;
            }
            demands.append(
                Demand(
                    cluster_id=c.cluster_id,
                    priority=max(MIN_PRIORITY, item.score_0_1),
                    people=demand_people(c, reports_by_id),
                    rank=item.rank
                )
            );
        }
        fleet = [
            Fleet(vehicle_id=v.vehicle_id, capacity=v.capacity)
            for v in vehicles
            if v.available and v.vehicle_id not in constraints.excluded_vehicles
            and v.vehicle_id not in pinned
        ];

        model = self._travel_model(pruned_graph, hazard, adaptation, frozenset(constraints.avoid_edges));
        in_fleet = {f.vehicle_id for f in fleet};
        sites: dict[str, tuple[float, float]] = {
            d.cluster_id: (by_cluster[d.cluster_id].centroid_lat, by_cluster[d.cluster_id].centroid_lon)
            for d in demands
        };
        road: dict[str, tuple[float, float]] = {
            v.vehicle_id: (v.depot_lat, v.depot_lon)
            for v in vehicles
            if v.vehicle_id in in_fleet and not is_boat(v)
        };
        boats: dict[str, tuple[float, float]] = {
            v.vehicle_id: (v.depot_lat, v.depot_lon)
            for v in vehicles
            if v.vehicle_id in in_fleet and is_boat(v)
        };
        # The access legs are off-graph, so pruning cannot protect them. A road vehicle
        # may not wade; a boat's final leg *is* the water, which is the whole reason the
        # fleet has boats and what lets it reach demand no truck can.
        water = water_geometry(hazard);
        legs: dict[tuple[str, str], Leg] = {};
        legs.update(model.legs(road, sites, max_access_m=self.config.max_access_m, blocked=water));
        legs.update(
            model.legs(boats, sites, max_access_m=self.config.boat_access_m, access_kph=BOAT_ACCESS_KPH)
        );
        problem = DispatchProblem(
            demands=demands,
            vehicles=fleet,
            legs=legs,
            forbidden_pairs=frozenset(constraints.forbidden_pairs),
            penalty_min=self.config.unserved_penalty_min
        );

        solution = self._solve(problem, mode);

        def by_rank(vc: tuple[str, str]) -> int {
            return problem.demand(vc[1]).rank;
        }

        assignments: list[Assignment] = [c.assignment for c in pinned.values()];
        for (v, c) in sorted(solution.assignment.items(), key=by_rank) {
            leg = legs[(v, c)];
            assignments.append(
                Assignment(
                    vehicle_id=v,
                    cluster_id=c,
                    route_edge_ids=list(leg.edge_ids),
                    access_segments=leg.access_segments,
                    eta_minutes=leg.eta_minutes,
                    distance_km=leg.distance_km,
                    load=problem.load(v, c)
                )
            );
        }
        served = set(solution.assignment.values()) | pinned_clusters;
        unassigned = [
            d.cluster_id for d in sorted(demands, key=lambda (d: Demand) -> int { return d.rank; }) if d.cluster_id not in served
        ] + [h[0] for h in held];
        version = (previous.version + 1) if previous is not None else 1;
        plan = DispatchPlan(
            plan_id=f"PLN-{version:04d}",
            version=version,
            generated_at=now,
            assignments=assignments,
            unassigned_cluster_ids=unassigned,
            objective_value=round(solution.objective, 4),
            optimality_gap=solution.optimality_gap,
            solver_status=solution.status,
            solve_seconds=round(time.perf_counter() - t0, 3),
            warm_started=solution.warm_started,
            input_surface_version=hazard.version,
            input_queue_hash=queue_hash(queue),
            commander_constraints=list(constraints.tokens)
        );
        unreachable = [
            d.cluster_id for d in demands if not any([(f.vehicle_id, d.cluster_id) in legs for f in fleet])
        ];
        gap = "unknown" if solution.optimality_gap is None else f"{solution.optimality_gap:.3f}";
        detail = (
            f"{plan.plan_id}: {len(assignments)} assigned / {len(demands)} dispatchable / {len(queue)} queued, "
            + f"{solution.status.value} gap={gap} obj={plan.objective_value:.1f} in {plan.solve_seconds:.2f}s"
        );
        if pinned {
            detail += " | committed: " + ", ".join(
                [f"{v}->{c.cluster_id()}" for (v, c) in sorted(pinned.items())]
            );
        }
        if recalled {
            detail += " | recalled by commander: " + ", ".join(
                sorted([f"{c.vehicle_id()}->{c.cluster_id()}" for c in recalled])
            );
        }
        if held {
            detail += " | held: " + ", ".join([f"{h[0]} ({h[1]})" for h in held]);
        }
        if unreachable {
            detail += " | unreachable on pruned graph: " + ", ".join(unreachable);
        }
        stranded = [
            f.vehicle_id
            for f in fleet
            if demands and not any([(f.vehicle_id, d.cluster_id) in legs for d in demands])
        ];
        if stranded {
            detail += " | no route out of depot: " + ", ".join(stranded);
        }
        if constraints.tokens {
            detail += " | constraints: " + "; ".join(constraints.tokens);
        }
        return PlanResult(
            plan=plan, problem=problem, solution=solution, detail=detail, recalled=list(recalled)
        );
    }

    static def _hold_reason(
        cluster: IncidentCluster | None,
        cluster_id: str,
        constraints: SolveConstraints,
        floor: float,
        gazetteer: GeocodePort | None
    ) -> str | None {
        if cluster is None {
            return "not in cluster set";
        }
        if cluster_id in constraints.excluded_clusters {
            return "excluded by constraint";
        }
        if gazetteer is not None and not gazetteer.contains(cluster.gn_id) {
            return f"{cluster.gn_id} not in gazetteer";
        }
        if cluster.state == ClusterState.UNRESOLVED {
            return "unresolved evidence";
        }
        if cluster.confidence_0_1 < floor {
            return f"confidence {cluster.confidence_0_1:.2f} < {floor:.2f}";
        }
        return None;
    }

    def _solve(problem: DispatchProblem, mode: str) -> Solution {
        t0 = time.perf_counter();
        incumbent = solve_greedy(problem);
        if mode == "greedy" {
            return OptimiserAgent._greedy_solution(problem, incumbent, t0, SolverStatus.GREEDY_BASELINE);
        }
        try {
            if mode == "exact" {
                return solve_exact(problem, workers=self.config.workers);
            }
            return solve_cpsat(
                problem, time_budget_s=self.config.time_budget_s, hint=incumbent, workers=self.config.workers
            );
        } except Exception {  # solver missing or failed: the documented fallback
            return OptimiserAgent._greedy_solution(problem, incumbent, t0, SolverStatus.GREEDY_FALLBACK);
        }
    }

    static def _greedy_solution(
        problem: DispatchProblem, assignment: dict[str, str], t0: float, status: SolverStatus
    ) -> Solution {
        return Solution(
            assignment=assignment,
            objective=plan_cost(problem, assignment),
            status=status,
            optimality_gap=None,
            bound=None,
            solve_seconds=time.perf_counter() - t0,
            warm_started=False
        );
    }

    # -- graph node ------------------------------------------------------------------

    """Graph node: returns only `plan` plus one trace event (and the recall records)."""
    def run(state: IncidentState, now: datetime | None = None) -> dict[str, any] {
        now = now or datetime.now(UTC);
        hazard = state.hazard;
        if hazard is None {
            # Fail closed: no picture of the terrain, no routes. A0 re-runs A2 first.
            return {"trace": [OptimiserAgent._event(now, "plan_skipped", "no hazard surface; refusing to route blind")]};
        }
        result = self.plan(
            queue=state.queue or [],
            clusters=state.clusters or [],
            reports=state.reports or [],
            vehicles=state.vehicles or [],
            hazard=hazard,
            pruned_graph=state.pruned_graph,
            adaptation=state.adaptation,
            previous=state.plan,
            verdict=state.verdict,
            approvals=state.approvals or [],
            completed=served_cluster_ids(state),
            committed=open_commitments(state),
            declined=declined_commitments(state),
            now=now,
            mode=self.config.mode
        );
        update: dict[str, any] = {
            "plan": result.plan,
            "trace": [OptimiserAgent._event(now, "plan_solved", result.detail)]
        };
        if result.recalled {
            update["commitments"] = [
                close_commitment(c, CommitmentStatus.RECALLED, now, "commander constraint")
                for c in result.recalled
            ];
        }
        return update;
    }

    static def _event(now: datetime, action: str, detail: str) -> TraceEvent {
        return TraceEvent(
            event_id=f"EV-{uuid.uuid4().hex[:12]}",
            agent="A4",
            action=action,
            tier=ActionTier.TIER_A,  # re-solving is autonomous; *dispatching* is Tier C at the gate
            detail=detail,
            occurred_at=now
        );
    }
}
