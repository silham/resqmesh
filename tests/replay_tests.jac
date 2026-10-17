"""End-to-end replay: drive the synthetic scenario through the real graph and score it.

Emits the metrics artefact and asserts the robust invariants (task completion and both
hard constraints) rather than the compressed synthetic world's exact metric values."""

import sys;
import from resqmesh.adapters.geo.paths { outputs_dir }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.contracts.models {
    DispatchPlan, HazardSurface, IncidentCluster, SourcedClaim
}
import from resqmesh.eval.harness { evaluate }
import from resqmesh.eval.scenarios { synthetic_scenario }
# Loaded so the comms module is in sys.modules, where the injection test patches it.
import from resqmesh.agents.comms.agent { CommsAgent }

test "synthetic replay meets hard constraints" {
    scorecard = evaluate(synthetic_scenario());

    # Emit the graded artefact for the CI upload.
    scorecard.write(outputs_dir() / "metrics.json");

    assert scorecard.get("autonomous_task_completion").meets is True;
    assert scorecard.get("gazetteer_violations").value == 0.0;
    # A6 is wired: SITREPs exist, so this is a real measurement, never a vacuous None.
    assert scorecard.get("unsourced_sitrep_claims").value == 0.0;
    # No hard constraint is violated (not-measured is not a violation).
    assert scorecard.hard_constraints_pass() is True;
}

test "a published unsourced claim fails the gate" {
    # The check must catch a real violation, not just stay quiet on honest runs.
    #
    # Inject a claim citing a source that never existed and bypass A5's filter so A6
    # publishes it. SITREPs are judged against publication-time sources (not the final
    # state), and the ghost must still be caught.
    comms_module: any = sys.modules["resqmesh.agents.comms.agent"];
    real_assemble: any = getattr(comms_module, "assemble_claims");
    real_audit: any = getattr(GuardrailAgent, "audit_sitrep_claims");
    ghost = SourcedClaim(sentence="Bridge collapsed at Kaduwela.", source_ref="GHOST-999");

    def with_ghost(
        clusters: list[IncidentCluster], hazard: HazardSurface | None, plan: DispatchPlan | None,
        top_n: int = 5, division_names: dict[str, str] | None = None
    ) -> list[SourcedClaim] {
        honest: list[SourcedClaim] = real_assemble(clusters, hazard, plan, top_n=top_n, division_names=division_names);
        return honest + [ghost];
    }

    def without_filter(agent: GuardrailAgent, claims: list[SourcedClaim], known_refs: set[str]) -> tuple[any, list[SourcedClaim]] {
        audited: any = real_audit(agent, claims, known_refs);
        return (audited[0], claims);
    }

    setattr(comms_module, "assemble_claims", with_ghost);
    setattr(GuardrailAgent, "audit_sitrep_claims", without_filter);
    value: float | None = None;
    passed = True;
    try {
        scorecard = evaluate(synthetic_scenario());
        value = scorecard.get("unsourced_sitrep_claims").value;
        passed = scorecard.hard_constraints_pass();
    } finally {
        setattr(comms_module, "assemble_claims", real_assemble);
        setattr(GuardrailAgent, "audit_sitrep_claims", real_audit);
    }
    assert value == 1.0;
    assert passed is False;
}
