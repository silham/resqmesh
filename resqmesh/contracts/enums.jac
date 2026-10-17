"""Closed vocabularies shared by every agent.

Append-only: a new member may be added, an existing one is never renamed or removed.
Every enum is string-valued, so a member compares equal to its wire value.
"""

"""Stamped onto every contract payload so a replay can be validated later."""
glob SCHEMA_VERSION: str = "1.0.0";

"""Autonomy classification.

The tier of an action is decided before it is proposed, and the supervisor routes on
it. A Tier C action is unexecutable without an attributed ApprovalRecord.
"""
enum ActionTier: str {
    TIER_A = "A",   # reversible, internal: ingest, dedupe, recompute hazard, re-rank, re-solve
    TIER_B = "B",   # autonomous but announced: raise risk class, publish a SITREP
    TIER_C = "C"    # irreversible: dispatch a crew, evacuation order, public broadcast
}

"""How a raw signal reached us. Drives the per-source trust prior."""
enum SourceChannel: str {
    TELEGRAM = "telegram",
    SMS = "sms",
    WEB_FORM = "web_form",
    RADIO = "radio",
    FIELD_RESPONDER = "field_responder",
    OFFICIAL_ADVISORY = "official_advisory",
    TELEMETRY = "telemetry",
    REPLAY = "replay"
}

enum HazardType: str {
    FLOOD = "flood",
    LANDSLIDE = "landslide",
    ROAD_BLOCKED = "road_blocked",
    STRUCTURAL_DAMAGE = "structural_damage",
    MEDICAL = "medical",
    UNKNOWN = "unknown"
}

"""Which estimation path produced a hazard surface.

BUFFER_PROXY is the documented degradation: when the HAND model fails we fall back to
a distance buffer around watercourses and the SITREP says so.
"""
enum HazardMethod: str {
    HAND = "hand",
    BUFFER_PROXY = "buffer_proxy"
}

"""Lifecycle of the whole incident. Only A0 may write RESOLVED."""
enum IncidentStatus: str {
    OPEN = "open",
    PLANNING = "planning",
    AWAITING_APPROVAL = "awaiting_approval",
    EXECUTING = "executing",
    HALTED = "halted",
    ESCALATED = "escalated",
    RESOLVED = "resolved"
}

"""Where a public bulletin stands. CANCELLED is a deliberate stand-down."""
enum AlertStatus: str {
    PUBLISHED = "published",
    SUPERSEDED = "superseded",
    EXPIRED = "expired",
    CANCELLED = "cancelled"
}

"""How a report's coordinates were obtained (where, not whether)."""
enum LocationSource: str {
    GPS = "gps",
    MAP_PIN = "map_pin",
    TELEGRAM = "telegram",
    PLACE_TEXT = "place_text",
    NONE = "none"
}

"""Where a released dispatch has got to. released..on_scene are open."""
enum CommitmentStatus: str {
    RELEASED = "released",
    EN_ROUTE = "en_route",
    ON_SCENE = "on_scene",
    COMPLETE = "complete",
    DECLINED = "declined",
    RECALLED = "recalled"
}

"""Fusion outcome for an incident cluster. UNRESOLVED is first-class, not a failure."""
enum ClusterState: str {
    CORROBORATED = "corroborated",
    SINGLE_SOURCE = "single_source",
    CONTRADICTED = "contradicted",
    UNRESOLVED = "unresolved"
}

"""Functional-need indicators only. This is the whitelist: nothing else enters a score."""
enum VulnerabilityFlag: str {
    MOBILITY_LIMITED = "mobility_limited",
    MEDICAL_DEPENDENCY = "medical_dependency",
    ELDERLY = "elderly",
    CHILDREN_PRESENT = "children_present",
    LARGE_HOUSEHOLD = "large_household"
}

"""Solver outcome, reported honestly."""
enum SolverStatus: str {
    OPTIMAL = "optimal",
    FEASIBLE = "feasible",
    GREEDY_FALLBACK = "greedy_fallback",
    GREEDY_BASELINE = "greedy_baseline",
    INFEASIBLE = "infeasible"
}

enum ApprovalDecision: str {
    APPROVED = "approved",
    REJECTED = "rejected",
    MODIFIED = "modified",
    COUNTERMANDED = "countermanded"
}

"""Which extractor actually served a call."""
enum LLMProvider: str {
    GEMINI = "gemini",
    GROQ = "groq",
    OLLAMA = "ollama",
    STUB = "stub",
    DEEPSEEK = "deepseek",
    RULES = "rules"
}

glob OPEN_COMMITMENTS: list[CommitmentStatus] = [
    CommitmentStatus.RELEASED, CommitmentStatus.EN_ROUTE, CommitmentStatus.ON_SCENE
];

"""True while the crew is committed and A4 may not reassign them."""
def commitment_is_open(status: CommitmentStatus) -> bool {
    return status in OPEN_COMMITMENTS;
}

"""Only a published bulletin is current."""
def alert_is_current(status: AlertStatus) -> bool {
    return status == AlertStatus.PUBLISHED;
}
