"""Shared display helpers so the map, queue and panels agree on colour and wording.

The incident view arrives as plain JSON, so these helpers take it as `any`.
"""

"""Priority band from a 0-1 score: P1 critical (red) -> P3 monitored (green)."""
def:pub priorityBand(score: float) -> dict[str, str] {
    if score >= 0.75 {
        return {"label": "P1", "color": "red"};
    }
    if score >= 0.45 {
        return {"label": "P2", "color": "orange"};
    }
    return {"label": "P3", "color": "green"};
}

def:pub hazardColor(hazardType: str) -> str {
    if hazardType == "flood" {
        return "#2f6fed";
    }
    if hazardType == "landslide" {
        return "#e8730c";
    }
    if hazardType == "medical" {
        return "#e03131";
    }
    if hazardType == "road_blocked" {
        return "#7048e8";
    }
    return "#868e96";
}

def:pub statusColor(status: str) -> str {
    if status == "awaiting_approval" {
        return "yellow";
    }
    if status == "executing" {
        return "teal";
    }
    if status == "halted" {
        return "red";
    }
    if status == "escalated" {
        return "orange";
    }
    if status == "resolved" {
        return "gray";
    }
    return "blue";
}

def:pub prettyStatus(status: str) -> str {
    return status.replace("_", " ");
}

"""The priority score the triage queue gave a cluster, or None."""
def:pub clusterScore(view: any, cluster: any) -> float | None {
    for item in view["queue"] {
        if item["cluster_id"] == cluster["cluster_id"] {
            return item["score_0_1"];
        }
    }
    return None;
}

# A commander reads place names, not database keys. The view carries the GN id -> name
# table, so nothing on screen has an excuse to say "KLN-003" when it could say
# "Kolonnawa". Ids stay available in tooltips and the trace, where they are useful
# for audit.

"""Human place name for a GN division id. Falls back to the id: never blank."""
def:pub divisionName(view: any, gnId: any) -> str {
    if not gnId {
        return "unknown location";
    }
    found = view["divisions"][gnId];
    if found and found["name"] {
        return found["name"];
    }
    return f"{gnId}";
}

"""Where a cluster is, for panels that hold an id and nothing else."""
def:pub clusterPlace(view: any, clusterId: str) -> str {
    for c in view["clusters"] {
        if c["cluster_id"] == clusterId {
            return divisionName(view, c["gn_id"]);
        }
    }
    return clusterId;
}

"""'road blocked' rather than 'road_blocked'."""
def:pub prettyHazard(hazardType: str) -> str {
    return hazardType.replace("_", " ");
}

"""Turn-by-turn navigation to a point, as a Google Maps deep link: the same mechanism
the responder page hands a vehicle operator. A link costs nothing and needs no key."""
def:pub navigationUrl(lat: float, lon: float) -> str {
    return f"https://www.google.com/maps/dir/?api=1&destination={lat},{lon}";
}

"""Has a responder reported this cluster served?"""
def:pub isCompleted(view: any, clusterId: str) -> bool {
    done = view["completed_cluster_ids"];
    if not done {
        return False;
    }
    return done.includes(clusterId);
}

"""The moment the current plan version was authorised to move, or None.

Anchored to the commander's own approval rather than to when the plan was solved: a
plan can sit at the gate for twenty minutes, and a crew does not start driving until
someone says so."""
def:pub dispatchedAt(view: any) -> any {
    plan = view["plan"];
    if not plan {
        return None;
    }
    latest: any = None;
    for a in view["approvals"] {
        if a["plan_id"] == plan["plan_id"] and a["plan_version"] == plan["version"] and a["decision"] == "approved" {
            stamp = new(Date, a["decided_at"]);
            if latest is None or stamp.getTime() > latest.getTime() {
                latest = stamp;
            }
        }
    }
    return latest;
}
