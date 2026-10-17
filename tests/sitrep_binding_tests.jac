"""Adversarial: an unsourced claim must never reach a released SITREP.

The second hard constraint (unsourced SITREP claims: exactly 0), enforced at the point
of assembly. A fabricated source identifier slipped into the claim set must be
stripped by A5's audit before the report is built, and the surviving report's hash
must reflect only the verified claims."""

import tempfile;
import from pathlib { Path }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.comms.agent { CommsAgent }
import from resqmesh.agents.comms.sitrep { assemble_claims, known_source_refs }
import from resqmesh.contracts.models { SourcedClaim }
import from tests.support.baseline { NOW, clusters, gazetteer, hazard, valid_plan }

test "fabricated claim never reaches the sitrep" {
    tmp = Path(tempfile.mkdtemp());
    comms = CommsAgent(guardrail=GuardrailAgent(gazetteer=gazetteer()));
    h = hazard();

    honest = assemble_claims(clusters(), h, valid_plan());
    poisoned = honest + [SourcedClaim(sentence="The main dam has failed.", source_ref="FABRICATED-999")];
    refs = known_source_refs(clusters(), h, valid_plan());  # does NOT include the fabricated ref

    (sitrep, check) = comms.build_sitrep(
        sitrep_id="SR-1", claims=poisoned, known_refs=refs,
        hazard_method=h.method, out_dir=tmp, now=NOW
    );

    assert check.passed is False;  # the audit noticed the fabrication
    sentences = [c.sentence for c in sitrep.claims];
    assert "The main dam has failed." not in sentences;
    assert all([c.source_ref in refs for c in sitrep.claims]);

    # and the rendered file contains no trace of the stripped claim
    rendered = tmp.joinpath("SR-1.txt").read_text(encoding="utf-8");
    assert "dam has failed" not in rendered;
}
