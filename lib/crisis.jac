"""Counts for the operations overview, derived from the same snapshot as the panels.

Reports in a merged cluster describe the same incident: use the largest reported
headcount, matching triage, rather than adding duplicate reports together. A reported
zero is known; a missing headcount is unknown. Completed clusters are excluded.
"""

def:pub clusterPeople(view: any, clusterId: str) -> int {
    count: int = -1;
    for cluster in view["clusters"] {
        if cluster["cluster_id"] == clusterId {
            for r in view["reports"] {
                if r["report_id"] in cluster["member_report_ids"] {
                    n: any = r["reported_people_affected"];
                    if (n or n == 0) and n > count {
                        count = n;
                    }
                }
            }
        }
    }
    return count;
}

def:pub crisisCounts(view: any) -> dict[str, int] {
    active: int = 0;
    critical: int = 0;
    people: int = 0;
    unknown: int = 0;
    free: int = 0;
    completed: any = view["completed_cluster_ids"] or [];
    seen: list[str] = [];
    for item in view["queue"] {
        cid: str = item["cluster_id"];
        if cid in completed or cid in seen {
            continue;
        }
        seen = seen + [cid];
        active += 1;
        if item["score_0_1"] >= 0.75 {
            critical += 1;
        }
        count: int = clusterPeople(view, cid);
        if count >= 0 {
            people += count;
        } else {
            unknown += 1;
        }
    }
    committed: list[str] = [];
    for c in (view["commitments"] or []) {
        if c["status"] in ["released", "en_route", "on_scene"] {
            committed = committed + [c["assignment"]["vehicle_id"]];
        }
    }
    for v in view["vehicles"] {
        if v["available"] and v["vehicle_id"] not in committed {
            free += 1;
        }
    }
    return {"active": active, "critical": critical, "people": people,
        "unknown": unknown, "available": free, "total": len(view["vehicles"])};
}
