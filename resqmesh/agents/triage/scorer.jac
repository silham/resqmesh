"""The triage scorer: an explicit weighted model, never a language-model judgement.

Every component is a pure function of typed evidence, in 0-1, so a commander can
expand any ranking into five numbers and five weights (proposal section 3.2,
"Explainable triage") and A5 can recompute any of them.

Fairness constraint (proposal section 10.4), enforced structurally here:

* vulnerability is computed **only** from `VulnerabilityFlag` members:
  mobility limitation, medical dependency, age, children, household size;
* no component reads free text (`description`, `raw_place_text`), the reporter
  (`source_id`) or the report language (`lang_hint`), the obvious proxies for
  ethnicity, religion or language. `tests/triage_tests.jac` asserts that changing
  any of them leaves every score unchanged.
"""

import math;
import from datetime { datetime }
import from shapely.geometry { Point }
import from resqmesh.adapters.geo.shapes { prepared, union_of }
import from resqmesh.contracts.enums { ClusterState, HazardType, VulnerabilityFlag }
import from resqmesh.contracts.models {
    DamageObservation, HazardSurface, IncidentCluster, IncidentReport, ScoreComponents
}

# --- hazard severity ---------------------------------------------------------
glob IN_INUNDATION: float = 1.0;
glob IN_SUSCEPTIBLE_SLOPE: float = 0.75;

"""Blend of location-in-hazard, reported severity and (bounded) vision severity.
A photograph can inform a score but never dominate it (proposal Table 6)."""
glob SEVERITY_BLEND: dict[str, float] = {"location": 0.50, "reported": 0.35, "vision": 0.15};

# --- exposure ----------------------------------------------------------------
"""Saturating curve 1 - exp(-people / scale): 1 person ~0.06, 10 ~0.49, 30 ~0.86."""
glob EXPOSURE_SCALE: float = 15.0;
glob EXPOSURE_UNKNOWN: float = 0.25;  # a report exists, so someone is there; how many is unknown

# --- vulnerability (functional need only) ------------------------------------
glob FLAG_WEIGHT: dict[VulnerabilityFlag, float] = {
    VulnerabilityFlag.MEDICAL_DEPENDENCY: 0.45,
    VulnerabilityFlag.MOBILITY_LIMITED: 0.35,
    VulnerabilityFlag.ELDERLY: 0.25,
    VulnerabilityFlag.CHILDREN_PRESENT: 0.20,
    VulnerabilityFlag.LARGE_HOUSEHOLD: 0.15
};

# --- time criticality ----------------------------------------------------------
glob TYPE_URGENCY: dict[HazardType, float] = {
    HazardType.MEDICAL: 0.85,
    HazardType.LANDSLIDE: 0.75,
    HazardType.FLOOD: 0.65,
    HazardType.STRUCTURAL_DAMAGE: 0.55,
    HazardType.UNKNOWN: 0.40,
    HazardType.ROAD_BLOCKED: 0.30
};
glob WAIT_ESCALATION_PER_HOUR: float = 0.03;  # unmet demand climbs so it cannot starve...
glob WAIT_ESCALATION_CAP: float = 0.15;  # ...but cannot overtake a genuinely worse emergency
glob RISING_WATER_BONUS: float = 0.10;
glob RISING_WATER_MM: float = 100.0;

# --- confidence ------------------------------------------------------------------
glob STATE_DAMPING: dict[ClusterState, float] = {
    ClusterState.CORROBORATED: 1.0,
    ClusterState.SINGLE_SOURCE: 1.0,
    ClusterState.CONTRADICTED: 0.6,
    ClusterState.UNRESOLVED: 0.5
};

glob LABELS: dict[str, str] = {
    "hazard_severity": "hazard severity",
    "population_exposure": "people exposed",
    "vulnerability": "vulnerability",
    "time_criticality": "time criticality",
    "cluster_confidence": "evidence confidence"
};

def _clamp(x: float) -> float {
    return max(0.0, min(1.0, x));
}

"""Prepared hazard polygons for fast point tests, built once per surface."""
obj HazardGeometry {
    has inundation: any = None,
        susceptibility: any = None,
        driving_rain_mm: float | None = None;

    static def from_surface(surface: HazardSurface | None) -> HazardGeometry {
        if surface is None {
            return HazardGeometry();
        }
        inund = union_of(surface.inundation_geojson);
        susc = union_of(surface.susceptibility_geojson);
        return HazardGeometry(
            inundation=prepared(inund) if inund is not None else None,
            susceptibility=prepared(susc) if susc is not None else None,
            driving_rain_mm=surface.driving_rainfall_mm_24h
        );
    }

    """Severity of the point's position, and the fact that explains it (or None)."""
    def location_severity(lat: float, lon: float) -> tuple[float, str | None] {
        pt = Point(lon, lat);
        if self.inundation is not None and self.inundation.intersects(pt) {
            return (IN_INUNDATION, "inside modelled flood extent");
        }
        if self.susceptibility is not None and self.susceptibility.intersects(pt) {
            return (IN_SUSCEPTIBLE_SLOPE, "on a landslide-susceptible slope");
        }
        return (0.0, None);
    }
}

"""One cluster's score, its decomposition, and the facts quoted in the rationale."""
obj ClusterScore {
    has cluster_id: str,
        score: float,
        components: ScoreComponents,
        facts: list[str];
}

# --------------------------------------------------------------------------- #
# Components
# --------------------------------------------------------------------------- #

def hazard_severity(
    cluster: IncidentCluster,
    members: list[IncidentReport],
    geometry: HazardGeometry,
    damage: list[DamageObservation] | None = None
) -> tuple[float, list[str]] {
    damage = list(damage or []);
    facts: list[str] = [];
    loc: tuple[float, str | None] = geometry.location_severity(cluster.centroid_lat, cluster.centroid_lon);
    location = loc[0];
    why = loc[1];
    if why {
        facts.append(why);
    }
    claims: list[int] = [r.severity_claim for r in members if r.severity_claim is not None];
    parts: list[tuple[float, float]] = [(location, SEVERITY_BLEND["location"])];
    if claims {
        parts.append((sum(claims) / len(claims) / 4.0, SEVERITY_BLEND["reported"]));
        facts.append(f"reported severity {max(claims)}/4");
    }
    if damage {
        sev: list[int] = [d.severity_0_4 for d in damage];
        parts.append((sum(sev) / len(sev) / 4.0, SEVERITY_BLEND["vision"]));
        facts.append(f"photo damage {max(sev)}/4");
    }
    total_w = sum([p[1] for p in parts]);
    return (_clamp(sum([p[0] * p[1] for p in parts]) / total_w), facts);
}

def population_exposure(members: list[IncidentReport]) -> tuple[float, list[str]] {
    counts: list[int] = [
        r.reported_people_affected for r in members if r.reported_people_affected is not None
    ];
    if not counts {
        return (EXPOSURE_UNKNOWN, ["number of people unknown"]);
    }
    # Reports in one cluster describe the same incident: take the largest count,
    # never the sum, or duplicate reports would inflate the exposure.
    people = max(counts);
    return (_clamp(1.0 - math.exp(-people / EXPOSURE_SCALE)), [f"{people} people reported"]);
}

def _flag_value(f: VulnerabilityFlag) -> str {
    return f.value;
}

"""Noisy-OR over functional-need flags. Anything not in the whitelist is dropped."""
def vulnerability(flags: list[any]) -> tuple[float, list[str]] {
    present: list[VulnerabilityFlag] = sorted(
        {f for f in flags if isinstance(f, VulnerabilityFlag)}, key=_flag_value
    );
    remaining = 1.0;
    for f in present {
        remaining *= 1.0 - FLAG_WEIGHT[f];
    }
    facts: list[str] = [];
    if present {
        facts = [f"needs: {', '.join([f.value.replace('_', ' ') for f in present])}"];
    }
    return (_clamp(1.0 - remaining), facts);
}

def time_criticality(
    cluster: IncidentCluster, geometry: HazardGeometry, now: datetime
) -> tuple[float, list[str]] {
    facts: list[str] = [];
    base = TYPE_URGENCY.get(cluster.hazard_type, TYPE_URGENCY[HazardType.UNKNOWN]);
    waited_h = max(0.0, (now - cluster.first_seen).total_seconds() / 3600.0);
    escalation = min(WAIT_ESCALATION_CAP, WAIT_ESCALATION_PER_HOUR * waited_h);
    if waited_h >= 1.0 {
        facts.append(f"waiting {waited_h:.0f} h");
    }
    rising = 0.0;
    rain = geometry.driving_rain_mm;
    if (
        cluster.hazard_type in [HazardType.FLOOD, HazardType.LANDSLIDE]
        and rain is not None
        and rain >= RISING_WATER_MM
    ) {
        rising = RISING_WATER_BONUS;
        facts.append(f"heavy rain ({rain:.0f} mm/24 h)");
    }
    return (_clamp(base + escalation + rising), facts);
}

def cluster_confidence(cluster: IncidentCluster) -> tuple[float, list[str]] {
    value = _clamp(cluster.confidence_0_1 * STATE_DAMPING[cluster.state]);
    sources = (
        f", {cluster.corroborating_source_count} sources"
        if cluster.corroborating_source_count
        else ""
    );
    return (value, [f"confidence {value:.2f} ({cluster.state.value}{sources})"]);
}

# --------------------------------------------------------------------------- #
# Composition
# --------------------------------------------------------------------------- #

def score_cluster(
    cluster: IncidentCluster,
    members: list[IncidentReport],
    geometry: HazardGeometry,
    weights: dict[str, float],
    now: datetime,
    damage: list[DamageObservation] | None = None
) -> ClusterScore {
    r1 = hazard_severity(cluster, members, geometry, damage);
    r2 = population_exposure(members);
    r3 = vulnerability([flag for r in members for flag in r.vulnerability_flags]);
    r4 = time_criticality(cluster, geometry, now);
    r5 = cluster_confidence(cluster);
    components = ScoreComponents(
        hazard_severity=round(r1[0], 6),
        population_exposure=round(r2[0], 6),
        vulnerability=round(r3[0], 6),
        time_criticality=round(r4[0], 6),
        cluster_confidence=round(r5[0], 6)
    );
    score = weighted_sum(components, weights);
    return ClusterScore(
        cluster_id=cluster.cluster_id,
        score=score,
        components=components,
        facts=r1[1] + r2[1] + r3[1] + r4[1] + r5[1]
    );
}

"""The score is exactly this and nothing else: A5 and the console can recompute it."""
def weighted_sum(components: ScoreComponents, weights: dict[str, float]) -> float {
    return _clamp(round(sum([getattr(components, k) * w for (k, w) in weights.items()]), 6));
}

"""Deterministic, template-built justification. No model drafts this text."""
def rationale(
    rank: int, cluster: IncidentCluster, scored: ClusterScore, weights: dict[str, float]
) -> str {
    contributions: list[tuple[float, str]] = sorted(
        [(getattr(scored.components, k) * w, k) for (k, w) in weights.items()], reverse=True
    )[:2];
    drivers = " and ".join(
        [
            f"{LABELS[c[1]]} {getattr(scored.components, c[1]):.2f}x{weights[c[1]]:.2f}"
            for c in contributions
        ]
    );
    head = (
        f"#{rank} {cluster.hazard_type.value.replace('_', ' ')} at {cluster.gn_id}, "
        f"score {scored.score:.2f}, driven by {drivers}."
    );
    return f"{head} {'; '.join(scored.facts)}." if scored.facts else head;
}
