"""The replay harness: drive a scenario through the real graph, then score it.

Two halves, split so the scoring is testable without the agent stack:

* `score_run` is pure: it turns a finished incident state and its trace into a
  `MetricsReport`, recomputing the hard constraints itself rather than trusting the
  run. Unit-tested against a fabricated state.
* `run_scenario` / `evaluate` drive `IncidentRunner` over the synthetic world and run
  in CI where the geo and optimisation dependencies are installed.

Metrics that need a reference not yet in the repo (the greedy baseline for
response-time improvement, a second run for degraded-mode continuity, tool-call
telemetry, re-plan latency timing) are reported as None (not measured) rather than
guessed.
"""

import json;
import tempfile;
import from pathlib { Path }
import from shapely.geometry { Point, shape }
import from shapely.ops { unary_union }
import from resqmesh.adapters.llm.rules { RuleBasedExtractor }
import from resqmesh.agents.comms.sitrep { known_source_refs }
import from resqmesh.agents.guardrail.checks { unsourced_claims }
import from resqmesh.agents.optimiser.agent { OptimiserAgent, OptimiserConfig }
import from resqmesh.contracts.enums { ApprovalDecision, ClusterState, IncidentStatus }
import from resqmesh.contracts.models { PriorityItem, TraceEvent }
import from resqmesh.contracts.ports { GeocodePort }
import from resqmesh.contracts.state { IncidentState }
import from resqmesh.eval.measurements {
    BaselineComparison, DegradedComparison, Timings, ToolCalls, compare_plans,
    decisions_in, timed, tool_calls_from
}
import from resqmesh.eval.metrics {
    Metric, f1_score, human_intervention_rate, iou, mean_chain_length, ndcg_at_k
}
import from resqmesh.eval.scenarios { Scenario, ScenarioLabels, synthetic_scenario }
import from resqmesh.graph.loop { IncidentRunner }
import from resqmesh.graph.supervisor { SupervisorConfig }
import from resqmesh.graph.world { synthetic_world }

"""The scorecard of one scenario. `reference` is what the label-scored numbers are
measured *against*. The synthetic scenario is self-consistency (a regression check),
not an accuracy claim: this line is what stops anyone quoting its IoU as accuracy."""
obj MetricsReport {
    has scenario: str,
        metrics: list[Metric],
        reference: str = "unspecified";

    def get(name: str) -> Metric {
        for m in self.metrics {
            if m.name == name {
                return m;
            }
        }
        raise LookupError(f"no metric named {name}");
    }

    """No hard constraint may be *violated*. A single violation fails the layer
    irrespective of every other number (proposal section 8.2).

    Not-measured (`meets is None`) is not a violation: it means the constraint had
    nothing to check, which is reported honestly but does not fail the gate."""
    def hard_constraints_pass -> bool {
        return all([m.meets is not False for m in self.metrics if m.hard_constraint]);
    }

    def as_dict -> dict[str, any] {
        return {
            "scenario": self.scenario,
            "reference": self.reference,
            "metrics": [m.as_dict() for m in self.metrics]
        };
    }

    def to_json -> str {
        return json.dumps(self.as_dict(), indent=2);
    }

    def write(path: Path) -> None {
        path.parent.mkdir(parents=True, exist_ok=True);
        path.write_text(self.to_json(), encoding="utf-8");
    }
}

def _rank_of(item: PriorityItem) -> int {
    return item.rank;
}

"""Score a finished run against its labels. Pure and recomputable.

A label-scored metric with *nothing to check* is reported as None ("not measured"),
never as a perfect score: an empty ranking, an unlabelled inundation or a scenario
with no contradictions has not earned a 1.0. `predicted_inundation_gn` is the
divisions the hazard model placed inside the inundation, computed by the caller from
the polygon geometry (None when geometry was unavailable)."""
def score_run(
    scenario_name: str,
    state: IncidentState,
    trace: list[TraceEvent],
    labels: ScenarioLabels,
    gazetteer: GeocodePort,
    predicted_inundation_gn: set[str] | None = None,
    reference: str = "unspecified",
    sitrep_known_refs: dict[str, set[str]] | None = None,
    baseline: BaselineComparison | None = None,
    latency_p95_s: float | None = None,
    degraded: DegradedComparison | None = None,
    tools: ToolCalls | None = None
) -> MetricsReport {
    clusters = state.clusters;
    queue = state.queue;
    plan = state.plan;
    hazard = state.hazard;
    approvals = state.approvals;
    sitreps = state.sitreps;
    reports = state.reports;

    gn_by_cluster = {c.cluster_id: c.gn_id for c in clusters};

    # --- ranking, hazard, contradiction (label-scored; None when vacuous) --
    ranked_gns = [gn_by_cluster.get(q.cluster_id, "") for q in sorted(queue, key=_rank_of)];
    ndcg: float | None = None;
    if queue and labels.relevance_by_gn {
        ndcg = ndcg_at_k(ranked_gns, labels.relevance_by_gn);
    }

    hazard_iou: float | None = None;
    if predicted_inundation_gn is not None and labels.observed_inundation_gn {
        hazard_iou = iou(predicted_inundation_gn, labels.observed_inundation_gn);
    }

    predicted_contradicted: set[str] = set(
        [
            c.gn_id for c in clusters
            if c.contradiction_flag or c.state in [ClusterState.CONTRADICTED, ClusterState.UNRESOLVED]
        ]
    );
    # F1 is meaningful only when the scenario actually injected contradictions to resolve.
    contra_f1: float | None = None;
    if labels.contradicted_gn {
        contra_f1 = f1_score(predicted_contradicted, labels.contradicted_gn);
    }

    # --- dispatch quality --------------------------------------------------
    gap: float | None = plan.optimality_gap if plan is not None else None;

    # --- hard constraints, recomputed --------------------------------------
    gazetteer_violations = 0;
    if plan is not None {
        for a in plan.assignments {
            gn = gn_by_cluster.get(a.cluster_id);
            if gn is None or not gazetteer.contains(gn) {
                gazetteer_violations += 1;
            }
        }
    }

    # Vacuous until a SITREP exists: with zero reports checked, "0 unsourced" is
    # unearned. Report None until A6 actually publishes a report.
    # A SITREP is judged against the sources that existed when it was *published*,
    # not the final state: plans and hazard surfaces are replaced as the incident
    # moves on, so checking an early SITREP against the last plan would flag every
    # claim citing the plan the commander actually approved. `sitrep_known_refs`
    # carries the publication-time sets; without it, fall back to the final state.
    known = known_source_refs(clusters, hazard, plan, extra=[r.report_id for r in reports]);
    per: dict[str, set[str]] = sitrep_known_refs or {};
    unsourced: float | None = None;
    if sitreps {
        total = 0;
        for s in sitreps {
            total += len(unsourced_claims(s.claims, per.get(s.sitrep_id, known)));
        }
        unsourced = float(total);
    }

    # --- autonomy, from the trace ------------------------------------------
    chain = mean_chain_length(trace);
    human_rate = human_intervention_rate(trace);
    approved = any([a.decision == ApprovalDecision.APPROVED for a in approvals]);

    improvement: float | None = baseline.improvement() if baseline is not None else None;
    continuity: float | None = degraded.continuity() if degraded is not None else None;
    tool_rate: float | None = tools.success_rate() if tools is not None else None;

    metrics: list[Metric] = [
        Metric("autonomous_task_completion", 1.0 if approved else 0.0, ">= 0.90 (rate)", approved),
        Metric("autonomous_decision_chain_length", chain, ">= 12", chain >= 12.0),
        Metric("human_intervention_rate", human_rate, "< 0.10, Tier C only", human_rate < 0.10),
        Metric("triage_ndcg_at_10", ndcg, ">= 0.80", None if ndcg is None else ndcg >= 0.80),
        Metric(
            "hazard_footprint_iou", hazard_iou, ">= 0.60",
            None if hazard_iou is None else hazard_iou >= 0.60
        ),
        Metric("dispatch_optimality_gap", gap, "<= 0.05", None if gap is None else gap <= 0.05),
        Metric(
            "contradiction_resolution_f1", contra_f1, ">= 0.85",
            None if contra_f1 is None else contra_f1 >= 0.85
        ),
        Metric("gazetteer_violations", float(gazetteer_violations), "== 0", gazetteer_violations == 0, True),
        Metric("unsourced_sitrep_claims", unsourced, "== 0", None if unsourced is None else unsourced == 0.0, True),
        Metric("operating_cost_usd", 0.0, "== 0", True),
        # Measured, not assumed: each is None when its experiment could not run.
        Metric(
            "response_time_improvement", improvement, ">= 0.25 vs greedy",
            None if improvement is None else improvement >= 0.25
        ),
        Metric(
            "replan_latency_p95_s", latency_p95_s, "< 90",
            None if latency_p95_s is None else latency_p95_s < 90.0
        ),
        Metric(
            "tool_call_success_rate", tool_rate, ">= 0.95",
            None if tool_rate is None else tool_rate >= 0.95
        ),
        Metric(
            "degraded_mode_continuity", continuity, ">= 0.80",
            None if continuity is None else continuity >= 0.80
        )
    ];
    return MetricsReport(scenario=scenario_name, metrics=metrics, reference=reference);
}

"""A finished replay. `timings` is the wall-clock from each wave of reports to a plan
standing at the gate; `world` is the world that ran it, so the greedy baseline can
re-solve the same demand."""
obj RunResult {
    has state: IncidentState,
        trace: list[TraceEvent],
        gazetteer: any,
        predicted_inundation_gn: set[str] | None,
        sitrep_known_refs: dict[str, set[str]] | None = None,
        timings: Timings = Timings(),
        world: any = None;
}

"""Which GN divisions fall inside the inundation polygon (division-granularity IoU).

`divisions` maps GN id -> (name, lat, lon). Returns None if the geometry cannot be
read, so the metric is reported as not-measured rather than a misleading zero."""
def divisions_in_inundation(
    inundation_geojson: dict[str, any], divisions: dict[str, tuple[str, float, float]]
) -> set[str] | None {
    try {
        features = inundation_geojson.get("features") or [];
        if not features {
            return set();
        }
        poly: any = unary_union([shape(f["geometry"]) for f in features]);
        # GeoJSON is (lon, lat); Point takes (x=lon, y=lat).
        inside: set[str] = set();
        for (gid, place) in divisions.items() {
            if poly.covers(Point(place[2], place[1])) {
                inside.add(gid);
            }
        }
        return inside;
    } except Exception {
        return None;
    }
}

"""Drive one scenario through the real seven-agent graph, offline."""
def run_scenario(scenario: Scenario, out_dir: Path | None = None, world: any = None) -> RunResult {
    if world is None {
        world = synthetic_world(
            out_dir or Path(tempfile.mkdtemp(prefix="resqmesh-eval-")),
            rain_peak_mm=scenario.rain_peak_mm
        );
    }
    runner = IncidentRunner(agents=world.agents, incident_id=scenario.incident_id, cfg=SupervisorConfig());
    runner.open(scenario.goal, world.vehicles);

    decisions = list(scenario.decisions);
    next_decision = 0;
    timings = Timings();
    for wave in scenario.waves {
        # New signal -> updated plan pending approval: the proposal's re-plan latency.
        # `timed` calls this immediately, so closing over `wave` is safe.
        outcome = timed(lambda -> IncidentState { return runner.ingest(wave); });
        current = runner.state();
        if current.plan is not None {
            timings.record(outcome[1]);
        }
        if current.status == IncidentStatus.AWAITING_APPROVAL and next_decision < len(decisions) {
            choice = decisions[next_decision];
            next_decision += 1;
            plan = current.plan;
            if plan is None {
                raise RuntimeError("the gate was reached without a plan");
            }
            runner.decide(choice[0], "eval-cmdr", plan_version=plan.version, constraint=choice[1]);
        }
    }

    final = runner.state();
    hazard = final.hazard;
    predicted: set[str] | None = None;
    if hazard is not None {
        predicted = divisions_in_inundation(hazard.inundation_geojson, world.divisions);
    }
    return RunResult(
        state=final, trace=list(final.trace), gazetteer=world.gazetteer,
        predicted_inundation_gn=predicted,
        sitrep_known_refs=publication_time_refs(runner.history()),
        timings=timings, world=world
    );
}

"""For each SITREP, the source ids that existed when A6 published it.

`history` is the checkpoint list, newest first. A SITREP first appears in the
checkpoint written after the release step; the checkpoint just before that is exactly
the state A6 read, so its identifiers are the ones the SITREP's claims were allowed
to cite."""
def publication_time_refs(history: list[IncidentState]) -> dict[str, set[str]] {
    out: dict[str, set[str]] = {};
    before: IncidentState | None = None;
    for snap in reversed(history) {  # oldest first
        for sr in (snap.sitreps or []) {
            if sr.sitrep_id not in out {
                basis = before if before is not None else snap;
                out[sr.sitrep_id] = known_source_refs(
                    list(basis.clusters or []), basis.hazard, basis.plan,
                    extra=[r.report_id for r in (basis.reports or [])]
                );
            }
        }
        before = snap;
    }
    return out;
}

"""Run a scenario end to end and score it. Defaults to the synthetic scenario.

Three of the measurements are experiments rather than readings, so they happen here,
and two of them are extra replays of the same scenario: one with the greedy baseline
solver in place of CP-SAT, one with every hosted provider unreachable to see how much
of the decision-making survives."""
def evaluate(scenario: Scenario | None = None) -> MetricsReport {
    chosen = scenario or synthetic_scenario();
    r = run_scenario(chosen);

    baseline = greedy_run(chosen, r);
    degraded = degraded_run(chosen, r);
    tools = tool_calls_from(getattr(r.world.agents.ingest, "llm", None));

    return score_run(
        chosen.name, r.state, r.trace, chosen.labels, r.gazetteer,
        predicted_inundation_gn=r.predicted_inundation_gn,
        reference=chosen.reference,
        sitrep_known_refs=r.sitrep_known_refs,
        baseline=baseline,
        latency_p95_s=r.timings.p95(),
        degraded=degraded,
        tools=tools
    );
}

"""Replay the scenario with greedy nearest-available in place of CP-SAT.

A whole second incident, not a re-solve of the first one's final state: the baseline
has to commit vehicles under the same partial information, wave by wave, or it is
being handed a picture the optimiser never had. Returns None if the baseline replay
cannot run, rather than scoring its failure as a win."""
def greedy_run(scenario: Scenario, normal: RunResult) -> BaselineComparison | None {
    try {
        world = synthetic_world(
            Path(tempfile.mkdtemp(prefix="resqmesh-greedy-")), rain_peak_mm=scenario.rain_peak_mm
        );
        optimiser = world.agents.optimiser;
        if not isinstance(optimiser, OptimiserAgent) {
            return None;
        }
        live = optimiser.config;
        optimiser.config = OptimiserConfig(
            time_budget_s=live.time_budget_s, mode="greedy",
            min_dispatch_confidence=live.min_dispatch_confidence,
            max_access_m=live.max_access_m, boat_access_m=live.boat_access_m,
            unserved_penalty_min=live.unserved_penalty_min, workers=live.workers
        );
        greedy = run_scenario(scenario, world=world);
        return compare_plans(normal.state, greedy.state);
    } except Exception {
        return None;
    }
}

"""Replay the scenario with every hosted provider unreachable.

Extraction falls to the deterministic offline tier (no network, no model) and the
question is how much still gets decided. Returns None if the degraded replay cannot
run at all, rather than scoring the failure as continuity."""
def degraded_run(scenario: Scenario, normal: RunResult) -> DegradedComparison | None {
    try {
        world = synthetic_world(
            Path(tempfile.mkdtemp(prefix="resqmesh-degraded-")),
            rain_peak_mm=scenario.rain_peak_mm, llm=RuleBasedExtractor()
        );
        offline = run_scenario(scenario, world=world);
        normal_decisions = decisions_in(normal.state, normal.trace);
        degraded_decisions = decisions_in(offline.state, offline.trace);
        return DegradedComparison(
            normal_plans=normal_decisions[0], degraded_plans=degraded_decisions[0],
            normal_located=normal_decisions[1], degraded_located=degraded_decisions[1]
        );
    } except Exception {
        return None;
    }
}
