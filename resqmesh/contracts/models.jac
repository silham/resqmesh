"""The payload contracts every agent reads and writes.

Two conventions hold everywhere:

* Contracts are treated as immutable. Agents construct new objects (see `evolve`)
  rather than mutating shared ones, which is what makes the single-writer rule in
  `resqmesh.contracts.state` enforceable rather than merely agreed.
* Every quantity is produced by deterministic code. The language model extracts
  structure; it never computes a number that reaches a decision.

Validation runs in `postinit`: bounds on scores and coordinates, timezone-aware
timestamps, and the structural invariants (one vehicle per plan, weights that cover
every component, a verdict that ran at least one check, a claim bound to a source).
"""

import from datetime { datetime }
import from enum { Enum }
import from resqmesh.contracts.enums {
    SCHEMA_VERSION, ActionTier, AlertStatus, ApprovalDecision, ClusterState,
    CommitmentStatus, HazardMethod, HazardType, LocationSource, SolverStatus,
    SourceChannel, VulnerabilityFlag, commitment_is_open
}

"""Raised when a contract is constructed with values that break its invariants."""
class ContractError(ValueError) {}

"""Base for every payload. Carries no fields; marks the type for serialisation."""
obj Contract {}

# ------------------------------------------------------------------ validators

def check_score(name: str, value: float | None) -> None {
    if value is not None and not (0.0 <= value <= 1.0) {
        raise ContractError(f"{name} must be within [0, 1], got {value}");
    }
}

def check_range(name: str, value: float | None, lo: float, hi: float) -> None {
    if value is not None and not (lo <= value <= hi) {
        raise ContractError(f"{name} must be within [{lo}, {hi}], got {value}");
    }
}

def check_min(name: str, value: float | None, lo: float) -> None {
    if value is not None and value < lo {
        raise ContractError(f"{name} must be >= {lo}, got {value}");
    }
}

def check_positive(name: str, value: float) -> None {
    if value <= 0 {
        raise ContractError(f"{name} must be > 0, got {value}");
    }
}

"""All timestamps are timezone-aware UTC. A naive one is a bug, not a default."""
def check_aware(name: str, value: datetime | None) -> None {
    if value is not None and value.tzinfo is None {
        raise ContractError(f"{name}: timestamps must be timezone-aware (UTC)");
    }
}

def check_lat(name: str, value: float | None) -> None {
    check_range(name, value, -90.0, 90.0);
}

def check_lon(name: str, value: float | None) -> None {
    check_range(name, value, -180.0, 180.0);
}

def strip(value: str | None) -> str | None {
    return value.strip() if isinstance(value, str) else value;
}

# ------------------------------------------------------------------ helpers

"""A copy of `item` with some fields replaced. Contracts are never edited in place."""
def evolve(item: any, **changes: any) -> any {
    fields = dict(vars(item));
    for (k, v) in changes.items() {
        if k not in fields {
            raise ContractError(f"{type(item).__name__} has no field {k}");
        }
        fields[k] = v;
    }
    return type(item)(**fields);
}

"""JSON-shaped form of any contract value: enums by value, datetimes as ISO UTC,
tuples as lists, contracts as dicts stamped with the schema version."""
def to_json(value: any) -> any {
    if value is None or isinstance(value, (bool, int, float, str)) {
        if isinstance(value, Enum) {
            return value.value;
        }
        return value;
    }
    if isinstance(value, Enum) {
        return value.value;
    }
    if isinstance(value, datetime) {
        return value.isoformat().replace("+00:00", "Z");
    }
    if isinstance(value, Contract) {
        out: dict[str, any] = {"schema_version": SCHEMA_VERSION};
        for (k, v) in vars(value).items() {
            out[k] = to_json(v);
        }
        return out;
    }
    if isinstance(value, dict) {
        return {str(k): to_json(v) for (k, v) in value.items()};
    }
    if isinstance(value, (list, tuple, set, frozenset)) {
        return [to_json(v) for v in value];
    }
    if hasattr(value, "__jac_fields__") {
        return {k: to_json(v) for (k, v) in vars(value).items()};
    }
    return value;
}

# ======================================================== A1 — ingest and verification

"""Untyped input as it arrived. Append-only evidence; never edited, never deleted."""
obj RawSignal(Contract) {
    has signal_id: str,
        channel: SourceChannel,
        source_id: str,
        received_at: datetime,
        body: str = "",
        media_ref: str | None = None,
        lang_hint: str = "unknown",
        lat: float | None = None,
        lon: float | None = None,
        accuracy_m: float | None = None,
        location_source: LocationSource = LocationSource.NONE;

    def postinit {
        self.channel = SourceChannel(self.channel);
        self.location_source = LocationSource(self.location_source);
        self.body = strip(self.body) or "";
        if self.lang_hint not in ["si", "ta", "en", "unknown"] {
            raise ContractError(f"lang_hint must be si, ta, en or unknown, got {self.lang_hint}");
        }
        check_aware("received_at", self.received_at);
        check_lat("lat", self.lat);
        check_lon("lon", self.lon);
        check_min("accuracy_m", self.accuracy_m, 0.0);
    }
}

"""Vision reading of a damage photograph. Bounded: never the sole basis for Tier C."""
obj DamageObservation(Contract) {
    has report_id: str,
        severity_0_4: int,
        model_confidence: float,
        tags: list[str] = [];

    def postinit {
        check_range("severity_0_4", self.severity_0_4, 0, 4);
        check_score("model_confidence", self.model_confidence);
    }
}

"""One structured report extracted from a raw signal.

`resolved_gn_id` is None when the gazetteer could not match the place. Such a report
is held in the unresolved queue: never guessed at, never silently dropped.
"""
obj IncidentReport(Contract) {
    has report_id: str,
        signal_id: str,
        source_id: str,
        hazard_type: HazardType,
        description: str,
        raw_place_text: str,
        observed_at: datetime,
        resolved_gn_id: str | None = None,
        lat: float | None = None,
        lon: float | None = None,
        location_source: LocationSource = LocationSource.PLACE_TEXT,
        location_accuracy_m: float | None = None,
        severity_claim: int | None = None,
        reported_people_affected: int | None = None,
        vulnerability_flags: list[VulnerabilityFlag] = [],
        extraction_confidence: float = 1.0;

    def postinit {
        self.hazard_type = HazardType(self.hazard_type);
        self.location_source = LocationSource(self.location_source);
        self.vulnerability_flags = [VulnerabilityFlag(f) for f in self.vulnerability_flags];
        self.description = strip(self.description) or "";
        self.raw_place_text = strip(self.raw_place_text) or "";
        check_aware("observed_at", self.observed_at);
        check_lat("lat", self.lat);
        check_lon("lon", self.lon);
        check_min("location_accuracy_m", self.location_accuracy_m, 0.0);
        check_range("severity_claim", self.severity_claim, 0, 4);
        check_min("reported_people_affected", self.reported_people_affected, 0);
        check_score("extraction_confidence", self.extraction_confidence);
    }

    def is_located -> bool {
        return self.resolved_gn_id is not None and self.lat is not None;
    }
}

"""Spatio-temporally clustered reports with a trust-weighted confidence."""
obj IncidentCluster(Contract) {
    has cluster_id: str,
        member_report_ids: list[str],
        centroid_lat: float,
        centroid_lon: float,
        gn_id: str,
        hazard_type: HazardType,
        confidence_0_1: float,
        state: ClusterState,
        first_seen: datetime,
        last_seen: datetime,
        contradiction_flag: bool = False,
        corroborating_source_count: int = 0,
        merged_from: list[str] = [];

    def postinit {
        self.hazard_type = HazardType(self.hazard_type);
        self.state = ClusterState(self.state);
        check_lat("centroid_lat", self.centroid_lat);
        check_lon("centroid_lon", self.centroid_lon);
        check_score("confidence_0_1", self.confidence_0_1);
        check_min("corroborating_source_count", self.corroborating_source_count, 0);
        check_aware("first_seen", self.first_seen);
        check_aware("last_seen", self.last_seen);
    }

    """An unresolved cluster may be triaged but cannot alone justify Tier C."""
    def unresolved -> bool {
        return self.state == ClusterState.UNRESOLVED;
    }
}

# ======================================================== A2 — spatial hazard

"""Physical picture: where the water is and which roads have failed.

Consumed by A4 as a hard constraint, not as advisory colour on a map.
"""
obj HazardSurface(Contract) {
    has surface_id: str,
        version: int,
        generated_at: datetime,
        method: HazardMethod,
        confidence_0_1: float,
        inundation_geojson: dict[str, any],
        susceptibility_geojson: dict[str, any],
        impassable_edge_ids: list[str] = [],
        no_go_gn_ids: list[str] = [],
        driving_rainfall_mm_24h: float | None = None;

    def postinit {
        self.method = HazardMethod(self.method);
        check_min("version", self.version, 1);
        check_aware("generated_at", self.generated_at);
        check_score("confidence_0_1", self.confidence_0_1);
    }
}

"""Pointer to the routing graph with hazard-intersecting edges removed."""
obj PrunedGraphRef(Contract) {
    has graph_path: str,
        base_graph_hash: str,
        surface_version: int,
        removed_edge_count: int,
        node_count: int,
        version: int;

    def postinit {
        check_min("surface_version", self.surface_version, 1);
        check_min("removed_edge_count", self.removed_edge_count, 0);
        check_min("node_count", self.node_count, 0);
        check_min("version", self.version, 1);
    }
}

# ======================================================== A3 — triage

glob SCORE_COMPONENTS: list[str] = [
    "hazard_severity", "population_exposure", "vulnerability", "time_criticality",
    "cluster_confidence"
];

"""The decomposition of a priority score into its contributing evidence."""
obj ScoreComponents(Contract) {
    has hazard_severity: float,
        population_exposure: float,
        vulnerability: float,
        time_criticality: float,
        cluster_confidence: float;

    def postinit {
        for name in SCORE_COMPONENTS {
            check_score(name, getattr(self, name));
        }
    }
}

"""One entry of the ranked demand queue."""
obj PriorityItem(Contract) {
    has cluster_id: str,
        rank: int,
        score_0_1: float,
        components: ScoreComponents,
        weights: dict[str, float],
        rationale_text: str;

    def postinit {
        check_min("rank", self.rank, 1);
        check_score("score_0_1", self.score_0_1);
        if sorted(self.weights.keys()) != sorted(SCORE_COMPONENTS) {
            raise ContractError(
                f"weights must cover exactly {sorted(SCORE_COMPONENTS)}, got {sorted(self.weights.keys())}"
            );
        }
    }
}

# ======================================================== A4 — resource optimiser

obj Vehicle(Contract) {
    has vehicle_id: str,
        kind: str,
        capacity: int,
        depot_gn_id: str,
        depot_lat: float,
        depot_lon: float,
        available: bool = True;

    def postinit {
        check_min("capacity", self.capacity, 0);
        check_lat("depot_lat", self.depot_lat);
        check_lon("depot_lon", self.depot_lon);
    }
}

"""One vehicle committed to one demand cluster.

`access_segments` are the off-graph legs as (lat1, lon1, lat2, lon2): depot to the
nearest drivable node, and the staging node to the demand point.
"""
obj Assignment(Contract) {
    has vehicle_id: str,
        cluster_id: str,
        route_edge_ids: list[str],
        eta_minutes: float,
        distance_km: float,
        load: int,
        access_segments: list[list[float]] = [];

    def postinit {
        self.access_segments = [[float(x) for x in seg] for seg in self.access_segments];
        check_min("eta_minutes", self.eta_minutes, 0.0);
        check_min("distance_km", self.distance_km, 0.0);
        check_min("load", self.load, 0);
    }
}

"""An operator placing a held report on the map by hand. Recorded beside the report."""
obj LocationFix(Contract) {
    has report_id: str,
        lat: float,
        lon: float,
        placed_by: str,
        placed_at: datetime;

    def postinit {
        check_lat("lat", self.lat);
        check_lon("lon", self.lon);
        check_aware("placed_at", self.placed_at);
    }
}

"""A crew that was actually sent. Append-only: each status change is a new record."""
obj Commitment(Contract) {
    has commitment_id: str,
        plan_id: str,
        plan_version: int,
        assignment: Assignment,
        status: CommitmentStatus,
        released_at: datetime,
        closed_at: datetime | None = None,
        note: str | None = None;

    def postinit {
        self.status = CommitmentStatus(self.status);
        check_min("plan_version", self.plan_version, 1);
        check_aware("released_at", self.released_at);
        check_aware("closed_at", self.closed_at);
    }

    def vehicle_id -> str {
        return self.assignment.vehicle_id;
    }

    def cluster_id -> str {
        return self.assignment.cluster_id;
    }

    def is_open -> bool {
        return commitment_is_open(self.status);
    }
}

"""Vehicle-to-incident assignment over the hazard-pruned graph. A4 is the sole writer."""
obj DispatchPlan(Contract) {
    has plan_id: str,
        version: int,
        generated_at: datetime,
        assignments: list[Assignment],
        objective_value: float,
        solver_status: SolverStatus,
        solve_seconds: float,
        warm_started: bool,
        input_surface_version: int,
        input_queue_hash: str,
        unassigned_cluster_ids: list[str] = [],
        optimality_gap: float | None = None,
        commander_constraints: list[str] = [];

    def postinit {
        self.solver_status = SolverStatus(self.solver_status);
        check_min("version", self.version, 1);
        check_aware("generated_at", self.generated_at);
        check_score("optimality_gap", self.optimality_gap);
        check_min("solve_seconds", self.solve_seconds, 0.0);
        check_min("input_surface_version", self.input_surface_version, 1);
        seen = [a.vehicle_id for a in self.assignments];
        if len(seen) != len(set(seen)) {
            raise ContractError("a vehicle appears in two assignments");
        }
    }
}

# ======================================================== A5 — guardrail

obj GuardrailCheck(Contract) {
    has name: str,
        passed: bool,
        detail: str = "";
}

"""Adversarial verdict on a plan, produced before any commander sees it."""
obj GuardrailVerdict(Contract) {
    has plan_id: str,
        plan_version: int,
        passed: bool,
        checks: list[GuardrailCheck],
        evaluated_at: datetime,
        violated_constraint: str | None = None,
        remediation_hint: str | None = None;

    def postinit {
        check_min("plan_version", self.plan_version, 1);
        check_aware("evaluated_at", self.evaluated_at);
        if not self.checks {
            raise ContractError("a verdict with no checks is a silent pass; run the suite");
        }
    }
}

# ======================================================== human approval gate

"""Attributed authorisation: who approved, exactly which plan version, and when."""
obj ApprovalRecord(Contract) {
    has approval_id: str,
        plan_id: str,
        plan_version: int,
        tier: ActionTier,
        decision: ApprovalDecision,
        commander_id: str,
        decided_at: datetime,
        constraint_note: str | None = None,
        publish_alerts: bool = False;

    def postinit {
        self.tier = ActionTier(self.tier);
        self.decision = ApprovalDecision(self.decision);
        check_min("plan_version", self.plan_version, 1);
        check_aware("decided_at", self.decided_at);
    }
}

# ======================================================== A6 — communications

"""One factual sentence bound to the evidence that supports it."""
obj SourcedClaim(Contract) {
    has sentence: str,
        source_ref: str;

    def postinit {
        self.sentence = strip(self.sentence) or "";
        self.source_ref = strip(self.source_ref) or "";
        if len(self.source_ref) < 1 {
            raise ContractError("source_ref must name the evidence (min length 1)");
        }
    }
}

"""Timestamped situation report, hash-chained so silent revision is detectable."""
obj Sitrep(Contract) {
    has sitrep_id: str,
        generated_at: datetime,
        pdf_path: str,
        claims: list[SourcedClaim],
        hazard_method: HazardMethod,
        hash: str,
        plan_version: int | None = None,
        degraded_notice: str | None = None,
        prev_hash: str | None = None;

    def postinit {
        self.hazard_method = HazardMethod(self.hazard_method);
        check_aware("generated_at", self.generated_at);
        check_min("plan_version", self.plan_version, 1);
    }
}

"""Trilingual public message, always from a reviewed template with slot filling."""
obj CommunityAlert(Contract) {
    has alert_id: str,
        template_id: str,
        slots: dict[str, str],
        text_si: str,
        text_ta: str,
        text_en: str,
        target_gn_ids: list[str],
        approval_id: str,
        issued_at: datetime,
        status: AlertStatus = AlertStatus.PUBLISHED,
        expires_at: datetime | None = None,
        superseded_by: str | None = None,
        stood_down_by: str | None = None;

    def postinit {
        self.status = AlertStatus(self.status);
        check_aware("issued_at", self.issued_at);
        check_aware("expires_at", self.expires_at);
    }
}

"""A relief centre an evacuation order can send people to."""
obj Shelter(Contract) {
    has shelter_id: str,
        name: str,
        gn_id: str,
        lat: float,
        lon: float,
        capacity: int,
        open: bool = True;

    def postinit {
        check_lat("lat", self.lat);
        check_lon("lon", self.lon);
        check_min("capacity", self.capacity, 0);
    }
}

# ======================================================== adaptation

"""Beta posterior over a source's historical accuracy."""
obj SourceTrust(Contract) {
    has source_id: str,
        alpha: float = 1.0,
        beta: float = 1.0;

    def postinit {
        check_positive("alpha", self.alpha);
        check_positive("beta", self.beta);
    }

    def reliability -> float {
        return self.alpha / (self.alpha + self.beta);
    }
}

"""Exponentially weighted correction to free-flow speed, per road class and rainfall band."""
obj TravelTimeResidual(Contract) {
    has road_class: str,
        rainfall_band: str,
        correction_factor: float = 1.0,
        sample_count: int = 0;

    def postinit {
        check_positive("correction_factor", self.correction_factor);
        check_min("sample_count", self.sample_count, 0);
    }
}

"""Learned parameters, persisted across incidents."""
obj AdaptationSnapshot(Contract) {
    has source_trust: dict[str, SourceTrust] = {},
        travel_residuals: dict[str, TravelTimeResidual] = {},
        triage_weights: dict[str, float] = {},
        updated_at: datetime | None = None;

    def postinit {
        check_aware("updated_at", self.updated_at);
    }
}

# ======================================================== audit trail

"""One state transition. The autonomy metric counts agent steps between human touches."""
obj TraceEvent(Contract) {
    has event_id: str,
        agent: str,
        action: str,
        tier: ActionTier,
        occurred_at: datetime,
        human_touch: bool = False,
        detail: str = "";

    def postinit {
        self.tier = ActionTier(self.tier);
        check_aware("occurred_at", self.occurred_at);
    }
}
