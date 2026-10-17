"""Operational counts must not inflate demand or advertise committed vehicles as free."""

import from lib.crisis { clusterPeople, crisisCounts }

def snapshot() -> dict[str, any] {
    return {
        "queue": [
            {"cluster_id": "critical", "score_0_1": 0.8},
            {"cluster_id": "unknown", "score_0_1": 0.5},
            {"cluster_id": "zero", "score_0_1": 0.1}
        ],
        "clusters": [
            {"cluster_id": "critical", "member_report_ids": ["r1", "r2"]},
            {"cluster_id": "unknown", "member_report_ids": ["r3"]},
            {"cluster_id": "zero", "member_report_ids": ["r4"]}
        ],
        "reports": [
            {"report_id": "r1", "reported_people_affected": 12},
            {"report_id": "r2", "reported_people_affected": 15},
            {"report_id": "r3", "reported_people_affected": None},
            {"report_id": "r4", "reported_people_affected": 0}
        ],
        "completed_cluster_ids": [],
        "commitments": [],
        "vehicles": [
            {"vehicle_id": "BOAT-01", "available": True},
            {"vehicle_id": "TRK-01", "available": True},
            {"vehicle_id": "AMB-01", "available": False}
        ]
    };
}

test "merged reports use the largest headcount and unknown differs from zero" {
    view = snapshot();
    assert clusterPeople(view, "critical") == 15;
    assert clusterPeople(view, "unknown") == -1;
    assert clusterPeople(view, "zero") == 0;
    counts = crisisCounts(view);
    assert counts["people"] == 15;
    assert counts["unknown"] == 1;
    assert counts["active"] == 3 and counts["critical"] == 1;
}

test "completed incidents stop contributing to outstanding demand" {
    view = snapshot();
    view["completed_cluster_ids"] = ["critical"];
    counts = crisisCounts(view);
    assert counts["active"] == 2 and counts["critical"] == 0;
    assert counts["people"] == 0 and counts["unknown"] == 1;
}

test "only available vehicles without open commitments count as free" {
    view = snapshot();
    view["commitments"] = [
        {"status": "en_route", "assignment": {"vehicle_id": "BOAT-01"}},
        {"status": "complete", "assignment": {"vehicle_id": "TRK-01"}}
    ];
    counts = crisisCounts(view);
    assert counts["available"] == 1 and counts["total"] == 3;
    for status in ["released", "on_scene"] {
        view["commitments"] = [{"status": status, "assignment": {"vehicle_id": "TRK-01"}}];
        assert crisisCounts(view)["available"] == 1;
    }
}

test "repeated queue entries do not inflate the operational overview" {
    view = snapshot();
    view["queue"] = view["queue"] + [{"cluster_id": "critical", "score_0_1": 0.8}];
    counts = crisisCounts(view);
    assert counts["active"] == 3 and counts["critical"] == 1;
    assert counts["people"] == 15;
}

test "an empty incident has zero demand without claiming known headcounts" {
    view = snapshot();
    view["queue"] = [];
    view["vehicles"] = [];
    counts = crisisCounts(view);
    assert counts["active"] == 0 and counts["critical"] == 0;
    assert counts["people"] == 0 and counts["unknown"] == 0;
    assert counts["available"] == 0 and counts["total"] == 0;
}
