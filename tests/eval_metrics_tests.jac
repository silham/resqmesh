"""Unit tests for the Table 7 metric functions, driven with known answers."""

import math;
import from resqmesh.eval.metrics {
    autonomy_chain_lengths, dcg, f1_score, human_intervention_rate, iou, mean_chain_length,
    ndcg_at_k, prf1, priority_weighted_response_time, response_time_improvement
}

# --- nDCG ------------------------------------------------------------------ #

test "ndcg perfect ranking is one" {
    rel = {"a": 3.0, "b": 2.0, "c": 1.0};
    assert ndcg_at_k(["a", "b", "c"], rel) == 1.0;
}

test "ndcg reversed ranking is worse" {
    rel = {"a": 3.0, "b": 2.0, "c": 1.0};
    assert ndcg_at_k(["c", "b", "a"], rel) < 1.0;
}

test "ndcg no relevance is one" {
    assert ndcg_at_k(["a", "b"], {}) == 1.0;
}

test "dcg matches formula" {
    # gains [3, 2]: 3/log2(2) + 2/log2(3)
    assert math.isclose(dcg([3.0, 2.0]), 3.0 / 1.0 + 2.0 / math.log2(3));
}

# --- IoU ------------------------------------------------------------------- #

test "iou identical is one" {
    assert iou({"KLN-001", "KLN-002"}, {"KLN-001", "KLN-002"}) == 1.0;
}

test "iou disjoint is zero" {
    assert iou({"a"}, {"b"}) == 0.0;
}

test "iou partial" {
    # intersection 1, union 3
    assert iou({"a", "b"}, {"b", "c"}) == 1 / 3;
}

test "iou both empty is one" {
    assert iou(set(), set()) == 1.0;
}

# --- F1 -------------------------------------------------------------------- #

test "f1 perfect" {
    assert f1_score({"r1", "r2"}, {"r1", "r2"}) == 1.0;
}

test "prf1 known values" {
    # predicted {a,b,c}, actual {b,c,d}: tp=2, fp=1, fn=1
    scores = prf1({"a", "b", "c"}, {"b", "c", "d"});
    assert math.isclose(scores[0], 2 / 3);
    assert math.isclose(scores[1], 2 / 3);
    assert math.isclose(scores[2], 2 / 3);
}

test "f1 empty against empty is one" {
    assert f1_score(set(), set()) == 1.0;
}

# --- dispatch timing ------------------------------------------------------- #

test "priority weighted response time" {
    etas = {"a": 10.0, "b": 20.0};
    pri = {"a": 1.0, "b": 0.0};  # only a matters
    assert priority_weighted_response_time(etas, pri) == 10.0;
}

test "response time improvement" {
    assert response_time_improvement(75.0, 100.0) == 0.25;
    assert response_time_improvement(120.0, 100.0) == -0.2;
    assert response_time_improvement(10.0, 0.0) == 0.0;
}

# --- autonomy from the trace ----------------------------------------------- #

obj FakeEvent {
    has agent: str,
        human_touch: bool = False;
}

def make_trace() -> list[FakeEvent] {
    # 3 agent steps, a human touch, then 2 more agent steps
    return [
        FakeEvent(agent="A1"),
        FakeEvent(agent="A2"),
        FakeEvent(agent="A4"),
        FakeEvent(agent="gate", human_touch=True),
        FakeEvent(agent="A5"),
        FakeEvent(agent="A6")
    ];
}

test "autonomy chain lengths" {
    assert autonomy_chain_lengths(make_trace()) == [3, 2];
}

test "mean chain length" {
    assert mean_chain_length(make_trace()) == 2.5;
}

test "human intervention rate" {
    # 1 human, 5 agent steps -> 1/6
    assert math.isclose(human_intervention_rate(make_trace()), 1 / 6);
}
