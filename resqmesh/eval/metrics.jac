"""The Table 7 metric functions.

Deliberately pure: every function here takes plain data and returns a number, with
no pipeline, no network and no language model in the path. That is what lets the
evaluation be recomputed and trusted: the same failure-mode discipline the
guardrail rests on, applied to the scorecard itself.

The harness (`resqmesh.eval.harness`) drives a scenario through the real agent graph
and feeds the results into these functions; the unit tests drive the functions
directly against fixtures with known answers.
"""

import math;

"""Agent steps that count toward an autonomous decision chain (everything but the gate)."""
glob AGENT_STEPS: list[str] = ["A0", "A1", "A2", "A3", "A4", "A5", "A6"];

# --------------------------------------------------------------------------- #
# Ranking quality: nDCG@k against expert-labelled priority
# --------------------------------------------------------------------------- #

"""Discounted cumulative gain: earlier positions are worth more."""
def dcg(gains: list[float]) -> float {
    total = 0.0;
    for (i, g) in enumerate(gains) {
        total += g / math.log2(i + 2);
    }
    return total;
}

"""Normalised DCG of a ranking against expert relevance (higher = better order).

1.0 is the ideal ordering; 0.0 means none of the top-k had any relevance. When
the reference itself assigns no relevance we return 1.0: there is nothing to
get wrong."""
def ndcg_at_k(ranked_ids: list[str], relevance: dict[str, float], k: int = 10) -> float {
    ideal = sorted(list(relevance.values()), reverse=True)[:k];
    idcg = dcg(ideal);
    if idcg == 0.0 {
        return 1.0;
    }
    gains = [relevance.get(cid, 0.0) for cid in ranked_ids[:k]];
    return dcg(gains) / idcg;
}

# --------------------------------------------------------------------------- #
# Hazard footprint: IoU of predicted against observed
# --------------------------------------------------------------------------- #

"""Intersection-over-union of two sets (e.g. affected divisions or grid cells).

Set-based, which matches the division-granularity fallback of proposal section
7.3 when pixel-level observed inundation is unavailable. Two empty sets agree
perfectly (1.0): there was nothing to predict and nothing was predicted."""
def iou(predicted: any, observed: any) -> float {
    p: set[any] = set(predicted);
    o: set[any] = set(observed);
    union = p | o;
    if not union {
        return 1.0;
    }
    return len(p & o) / len(union);
}

# --------------------------------------------------------------------------- #
# Contradiction resolution: precision / recall / F1
# --------------------------------------------------------------------------- #

"""Precision, recall and F1 for a set-membership prediction, as a (p, r, f1) tuple.

Used for contradiction resolution: `actual` is the set of reports that were in
truth false/contradicted, `predicted` is the set the system flagged. Empty
against empty is a perfect call."""
def prf1(predicted: any, actual: any) -> tuple[float, float, float] {
    p: set[any] = set(predicted);
    a: set[any] = set(actual);
    tp = len(p & a);
    fp = len(p - a);
    fn = len(a - p);
    precision = tp / (tp + fp) if (tp + fp) else 1.0;
    recall = tp / (tp + fn) if (tp + fn) else 1.0;
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0;
    return (precision, recall, f1);
}

def f1_score(predicted: any, actual: any) -> float {
    return prf1(predicted, actual)[2];
}

# --------------------------------------------------------------------------- #
# Dispatch quality: priority-weighted response time and improvement
# --------------------------------------------------------------------------- #

"""Mean arrival time weighted by priority, so a late high-priority arrival hurts
more than a late low-priority one. Unranked targets contribute nothing."""
def priority_weighted_response_time(etas: dict[str, float], priorities: dict[str, float]) -> float {
    num = 0.0;
    den = 0.0;
    for (cid, eta) in etas.items() {
        weight = priorities.get(cid, 0.0);
        num += weight * eta;
        den += weight;
    }
    return num / den if den else 0.0;
}

"""Fractional reduction of the system against a baseline (0.25 = 25% faster).

Negative when the system is worse. A non-positive baseline yields 0.0."""
def response_time_improvement(system: float, baseline: float) -> float {
    if baseline <= 0.0 {
        return 0.0;
    }
    return (baseline - system) / baseline;
}

# --------------------------------------------------------------------------- #
# Autonomy: measured from the trace, not asserted
# --------------------------------------------------------------------------- #

"""Consecutive autonomous agent steps between human touches.

`trace` is any sequence of events with `agent` and `human_touch` attributes (a
TraceEvent qualifies). Every human touch closes a chain; agent steps extend the
current one. The list always has at least one entry (the run may end with no
trailing human touch)."""
def autonomy_chain_lengths(trace: list[any]) -> list[int] {
    chains: list[int] = [];
    current = 0;
    for e in trace {
        if e.human_touch {
            chains.append(current);
            current = 0;
        } elif e.agent in AGENT_STEPS {
            current += 1;
        }
    }
    chains.append(current);
    return chains;
}

def mean_chain_length(trace: list[any]) -> float {
    chains = autonomy_chain_lengths(trace);
    return sum(chains) / len(chains) if chains else 0.0;
}

"""Fraction of decision points that required a human.

Decision points are agent steps plus human touches; the target is < 10%, and by
design every human touch is a Tier C approval."""
def human_intervention_rate(trace: list[any]) -> float {
    humans = len([e for e in trace if e.human_touch]);
    steps = len([e for e in trace if e.agent in AGENT_STEPS]);
    total = humans + steps;
    return humans / total if total else 0.0;
}

# --------------------------------------------------------------------------- #
# Report structure
# --------------------------------------------------------------------------- #

"""One scored line of the Table 7 scorecard.

`value` is None for a metric that is defined but not yet measured (a reference or
baseline it needs is not in place). We report that honestly rather than inventing
a number: the roadmap is explicit that no metric is fabricated."""
obj Metric {
    has name: str,
        value: float | None,
        target: str,
        meets: bool | None,
        hard_constraint: bool = False;

    def as_dict -> dict[str, any] {
        value = self.value;
        return {
            "name": self.name,
            "value": None if value is None else round(value, 4),
            "target": self.target,
            "meets": self.meets,
            "hard_constraint": self.hard_constraint
        };
    }
}
