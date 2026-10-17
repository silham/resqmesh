"""Run the replay scenarios and emit the Table 7 metrics.

    jac run -b python --no-takeover scripts/run_replay.jac

Writes `outputs/metrics.json` (the graded artefact) and prints the scorecard. Exits
non-zero if either hard constraint fails, so CI blocks on a guardrail regression, not
just a code regression.
"""

import sys;
import from resqmesh.adapters.geo.paths { outputs_dir }
import from resqmesh.eval.harness { evaluate }
import from resqmesh.eval.scenarios { synthetic_scenario }

def main -> int {
    scorecard = evaluate(synthetic_scenario());
    out = outputs_dir() / "metrics.json";
    scorecard.write(out);

    print(f"\nReplay: {scorecard.scenario}");
    for m in scorecard.metrics {
        value = "-" if m.value is None else f"{m.value:.3f}";
        mark = ".";
        if m.meets is not None {
            mark = "PASS" if m.meets else "FAIL";
        }
        hard = " [hard]" if m.hard_constraint else "";
        print(f"  {mark:<4} {m.name:<34} {value:>8}   target {m.target}{hard}");
    }
    print(f"\nWrote {out}");

    if not scorecard.hard_constraints_pass() {
        print("HARD CONSTRAINT FAILED", file=sys.stderr);
        return 1;
    }
    return 0;
}

with entry {
    sys.exit(main());
}
