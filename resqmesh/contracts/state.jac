"""The shared incident state and its merge reducers.

Agents do not exchange natural-language messages. They read from and write to this
object, and each field has exactly one owning writer:

    field               writer      reducer
    raw_signals         A1          append-only
    reports             A1          append-only
    unresolved_queue    A1          replace
    clusters            A1          replace
    hazard              A2          versioned (last-write-wins, version must rise)
    pruned_graph        A2          versioned
    queue               A3          replace
    plan                A4          versioned (sole writer, structural)
    verdict             A5          replace
    approvals           gate        append-only
    sitreps / alerts    A6          append-only (one record per status change)
    alert_cooldowns     A6          merge (division -> last broadcast, never backwards)
    shelters            open        replace
    cluster_aliases     A1          merge (absorbed cluster id -> surviving id)
    location_fixes      ops         append-only
    commitments         A6/ops/A4   append-only (one record per status change)
    adaptation          A0/A1/A4    merge
    trace               all         append-only

An agent returns an update: a `dict[str, any]` keyed by field name. `apply_update`
folds it into a new state with the field's reducer. Observations are append-only so
evidence is never lost; derived artefacts are versioned so a stale result arriving
late cannot overwrite a fresher one.
"""

import from datetime { datetime }
import from resqmesh.contracts.enums { IncidentStatus }
import from resqmesh.contracts.models {
    AdaptationSnapshot, ApprovalRecord, Commitment, CommunityAlert, DispatchPlan,
    GuardrailVerdict, HazardSurface, IncidentCluster, IncidentReport, LocationFix,
    PriorityItem, PrunedGraphRef, RawSignal, Shelter, Sitrep, TraceEvent, Vehicle
}

# ------------------------------------------------------------------ reducers

"""Accumulate evidence. Nothing written here is ever removed or overwritten."""
def append_only(current: list[any] | None, incoming: any) -> list[any] {
    base = list(current or []);
    if isinstance(incoming, (list, tuple)) {
        base.extend(incoming);
    } elif incoming is not None {
        base.append(incoming);
    }
    return base;
}

"""Wholesale substitution, for derived collections recomputed from scratch."""
def replace(current: any, incoming: any) -> any {
    return incoming;
}

"""Last-write-wins, but only forwards. An older or equal version is dropped."""
def versioned(current: any, incoming: any) -> any {
    if incoming is None {
        return current;
    }
    if current is None {
        return incoming;
    }
    return incoming if incoming.version > current.version else current;
}

"""Accumulate cluster renames. An alias is never removed: something may still cite it."""
def merge_aliases(current: dict[str, str] | None, incoming: dict[str, str] | None) -> dict[str, str] {
    return {**(current or {}), **(incoming or {})};
}

"""Follow a chain of merges to the cluster that is live now. Cycle-guarded."""
def resolve_cluster_id(aliases: dict[str, str], cluster_id: str) -> str {
    seen: set[str] = set();
    while cluster_id in aliases and cluster_id not in seen {
        seen.add(cluster_id);
        cluster_id = aliases[cluster_id];
    }
    return cluster_id;
}

"""Keep the later broadcast per division. Never moves a cooldown backwards."""
def merge_cooldowns(
    current: dict[str, datetime] | None, incoming: dict[str, datetime] | None
) -> dict[str, datetime] {
    out = dict(current or {});
    for (gn, when) in (incoming or {}).items() {
        if gn not in out or when > out[gn] {
            out[gn] = when;
        }
    }
    return out;
}

"""Field-wise merge of learned parameters from writers that never share a key."""
def merge_adaptation(
    current: AdaptationSnapshot | None, incoming: AdaptationSnapshot | None
) -> AdaptationSnapshot {
    if current is None and incoming is None {
        return AdaptationSnapshot();
    }
    if current is None {
        return incoming or AdaptationSnapshot();
    }
    if incoming is None {
        return current;
    }
    return AdaptationSnapshot(
        source_trust={**current.source_trust, **incoming.source_trust},
        travel_residuals={**current.travel_residuals, **incoming.travel_residuals},
        triage_weights={**current.triage_weights, **incoming.triage_weights},
        updated_at=incoming.updated_at or current.updated_at
    );
}

# ------------------------------------------------------------------ the state

"""Everything known about one incident. The commander sets `goal` once; everything
after that is the system's own doing until a Tier C proposal reaches the gate."""
obj IncidentState {
    has incident_id: str = "",
        goal: str = "",
        status: IncidentStatus = IncidentStatus.OPEN,
        vehicles: list[Vehicle] = [],
        raw_signals: list[RawSignal] = [],
        reports: list[IncidentReport] = [],
        unresolved_queue: list[IncidentReport] = [],
        clusters: list[IncidentCluster] = [],
        hazard: HazardSurface | None = None,
        pruned_graph: PrunedGraphRef | None = None,
        queue: list[PriorityItem] = [],
        plan: DispatchPlan | None = None,
        verdict: GuardrailVerdict | None = None,
        approvals: list[ApprovalRecord] = [],
        sitreps: list[Sitrep] = [],
        alerts: list[CommunityAlert] = [],
        alert_cooldowns: dict[str, datetime] = {},
        shelters: list[Shelter] = [],
        cluster_aliases: dict[str, str] = {},
        location_fixes: list[LocationFix] = [],
        commitments: list[Commitment] = [],
        adaptation: AdaptationSnapshot = AdaptationSnapshot(),
        trace: list[TraceEvent] = [];
}

"""The reducer for each field. Fields missing here are plain overwrites."""
glob REDUCERS: dict[str, any] = {
    "raw_signals": append_only,
    "reports": append_only,
    "unresolved_queue": replace,
    "clusters": replace,
    "hazard": versioned,
    "pruned_graph": versioned,
    "queue": replace,
    "plan": versioned,
    "verdict": replace,
    "approvals": append_only,
    "sitreps": append_only,
    "alerts": append_only,
    "alert_cooldowns": merge_cooldowns,
    "shelters": replace,
    "cluster_aliases": merge_aliases,
    "location_fixes": append_only,
    "commitments": append_only,
    "adaptation": merge_adaptation,
    "trace": append_only
};

"""The fields each writer may touch. A write outside its column is a design bug."""
glob OWNERSHIP: dict[str, list[str]] = {
    "A0": ["status", "trace"],
    "A1": ["raw_signals", "reports", "unresolved_queue", "clusters", "cluster_aliases", "adaptation", "trace"],
    "A2": ["hazard", "pruned_graph", "trace"],
    "A3": ["queue", "trace"],
    "A4": ["plan", "commitments", "trace"],
    "A5": ["verdict", "trace"],
    "A6": ["sitreps", "alerts", "alert_cooldowns", "commitments", "trace"],
    "gate": ["approvals", "trace"]
};

glob STATE_FIELDS: list[str] = [
    "incident_id", "goal", "status", "vehicles", "raw_signals", "reports",
    "unresolved_queue", "clusters", "hazard", "pruned_graph", "queue", "plan", "verdict",
    "approvals", "sitreps", "alerts", "alert_cooldowns", "shelters", "cluster_aliases",
    "location_fixes", "commitments", "adaptation", "trace"
];

"""Raised when an agent writes a field it does not own."""
class OwnershipError(RuntimeError) {}

"""Reject an update that strays outside the writer's column."""
def check_ownership(writer: str, update: dict[str, any]) -> None {
    allowed = OWNERSHIP.get(writer);
    if allowed is None {
        return;
    }
    stray = sorted([k for k in update if k not in allowed]);
    if stray {
        raise OwnershipError(f"{writer} may not write {stray}");
    }
}

"""Fold an update into a new state. The input state is never mutated."""
def apply_update(state: IncidentState, update: dict[str, any]) -> IncidentState {
    fields = {name: getattr(state, name) for name in STATE_FIELDS};
    for (key, value) in update.items() {
        if key not in fields {
            raise KeyError(f"IncidentState has no field {key}");
        }
        reducer = REDUCERS.get(key);
        fields[key] = reducer(fields[key], value) if reducer else value;
    }
    return IncidentState(**fields);
}

"""A shallow copy of the state, so a reader can never alias a writer's lists."""
def copy_state(state: IncidentState) -> IncidentState {
    return IncidentState(**{name: getattr(state, name) for name in STATE_FIELDS});
}

"""An empty incident. The only human input the system needs to begin."""
def new_state(
    incident_id: str,
    goal: str,
    vehicles: list[Vehicle] | None = None,
    shelters: list[Shelter] | None = None
) -> IncidentState {
    return IncidentState(
        incident_id=incident_id,
        goal=goal,
        status=IncidentStatus.OPEN,
        vehicles=list(vehicles or []),
        shelters=list(shelters or [])
    );
}
