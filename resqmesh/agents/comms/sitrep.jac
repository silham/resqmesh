"""SITREP assembly, hash-chaining and rendering.

The situation report is the artefact a commander distributes, so two properties are
load-bearing:

* **Every factual sentence binds to a source.** Claims are assembled here only from
  evidence the state actually holds, and A5's source-binding audit strips anything
  unsourced before the PDF is built. "Unsourced SITREP claims: exactly 0" is a hard
  constraint, not a target.
* **The report is tamper-evident.** Each SITREP carries the hash of its predecessor,
  so a silent after-the-fact edit breaks the chain and is detectable.

Rendering sits behind `SitrepRenderer` so the deterministic core (assembly, hashing,
source binding) is testable with no PDF toolkit in the path. The ReportLab renderer
imports its dependency only when it renders, so loading this module costs nothing on
a machine without it.
"""

import hashlib;
import from datetime { datetime }
import from pathlib { Path }
import from resqmesh.contracts.enums { HazardMethod }
import from resqmesh.contracts.models {
    DispatchPlan, HazardSurface, IncidentCluster, SourcedClaim
}

"""Every identifier a claim is allowed to bind to.

Cluster ids, their member report ids, the hazard surface id, the plan id, plus any
external dataset identifiers (an NBRO advisory, a DMC situation report) the caller
vouches for."""
def known_source_refs(
    clusters: list[IncidentCluster],
    hazard: HazardSurface | None,
    plan: DispatchPlan | None,
    extra: list[str] = []
) -> set[str] {
    refs: set[str] = set(extra);
    for c in clusters {
        refs.add(c.cluster_id);
        refs.update(c.member_report_ids);
    }
    if hazard is not None {
        refs.add(hazard.surface_id);
    }
    if plan is not None {
        refs.add(plan.plan_id);
    }
    return refs;
}

"""Surface the documented HAND degradation (proposal section 4.3).

When the hazard surface was produced by the buffer-proxy fallback the SITREP must say
so, in plain terms, rather than presenting a reduced-confidence estimate as if it were
the real model."""
def degraded_notice_for(hazard: HazardSurface | None) -> str | None {
    if hazard is not None and hazard.method == HazardMethod.BUFFER_PROXY {
        return (
            "Hazard estimated by buffer-proxy fallback (HAND unavailable); "
            "treat inundation extent as reduced-confidence."
        );
    }
    return None;
}

def _confidence(c: IncidentCluster) -> float {
    return c.confidence_0_1;
}

"""Build the factual claim set from state, each sentence bound to its source.

Numbers here are *formatted*, never computed: the values come straight from the typed
state that deterministic tools produced. The language model has no part in this path,
which is what lets A5 recompute and A6 hash it reproducibly.

`division_names` maps a GN id to its human name, so a claim reads "Hanwella" rather
than "LK1115205"; a missing id falls back to the id itself."""
def assemble_claims(
    clusters: list[IncidentCluster],
    hazard: HazardSurface | None,
    plan: DispatchPlan | None,
    top_n: int = 5,
    division_names: dict[str, str] | None = None
) -> list[SourcedClaim] {
    names: dict[str, str] = division_names or {};
    claims: list[SourcedClaim] = [];

    if hazard is not None {
        rain = (
            f"{hazard.driving_rainfall_mm_24h:.0f} mm/24h"
            if hazard.driving_rainfall_mm_24h is not None
            else "n/a rainfall"
        );
        claims.append(
            SourcedClaim(
                sentence=(
                    f"Hazard surface v{hazard.version}: inundation modelled via "
                    f"{hazard.method.value.upper()} at {rain}; "
                    f"{len(hazard.impassable_edge_ids)} road segment(s) impassable."
                ),
                source_ref=hazard.surface_id
            )
        );
    }

    for c in sorted(clusters, key=_confidence, reverse=True)[:top_n] {
        claims.append(
            SourcedClaim(
                sentence=(
                    f"{names.get(c.gn_id, c.gn_id)}: {c.hazard_type.value} reported, confidence "
                    f"{c.confidence_0_1:.2f} ({c.state.value}), "
                    f"{c.corroborating_source_count} corroborating source(s)."
                ),
                source_ref=c.cluster_id
            )
        );
    }

    if plan is not None {
        gap = f"{plan.optimality_gap * 100:.1f}%" if plan.optimality_gap is not None else "unknown";
        claims.append(
            SourcedClaim(
                sentence=(
                    f"Dispatch plan v{plan.version}: {len(plan.assignments)} assignment(s), "
                    f"solver {plan.solver_status.value}, optimality gap {gap}."
                ),
                source_ref=plan.plan_id
            )
        );
        for a in plan.assignments {
            claims.append(
                SourcedClaim(
                    sentence=(
                        f"{a.vehicle_id} assigned to {a.cluster_id}, "
                        f"ETA {a.eta_minutes:.0f} min over {a.distance_km:.1f} km."
                    ),
                    source_ref=plan.plan_id
                )
            );
        }
    }

    return claims;
}

"""SHA-256 over the canonical content of a SITREP, chained to its predecessor.

Including `prev_hash` in the digest is what makes the chain tamper-evident: altering
any earlier report changes every hash that followed it."""
def compute_hash(
    sitrep_id: str,
    generated_at: datetime,
    claims: list[SourcedClaim],
    hazard_method: HazardMethod,
    degraded_notice: str | None,
    prev_hash: str | None
) -> str {
    h = hashlib.sha256();
    parts: list[str] = [
        sitrep_id,
        generated_at.isoformat(),
        hazard_method.value,
        degraded_notice or "",
        prev_hash or ""
    ];
    parts.extend([f"{c.source_ref}|{c.sentence}" for c in claims]);
    h.update("\n".join(parts).encode("utf-8"));
    return h.hexdigest();
}

# --------------------------------------------------------------------------- #
# Renderers
# --------------------------------------------------------------------------- #

def _header_lines(
    sitrep_id: str,
    generated_at: datetime,
    hazard_method: HazardMethod,
    degraded_notice: str | None
) -> list[str] {
    lines: list[str] = [
        "ResQ-Mesh — Situation Report",
        f"SITREP {sitrep_id}",
        f"Generated {generated_at.isoformat()}",
        f"Hazard method: {hazard_method.value.upper()}"
    ];
    if degraded_notice {
        lines.append(f"NOTICE: {degraded_notice}");
    }
    return lines;
}

"""Turns the verified claim set into a distributable file, returns its path."""
obj SitrepRenderer {
    has extension: str = "";

    def render(
        sitrep_id: str,
        generated_at: datetime,
        claims: list[SourcedClaim],
        hazard_method: HazardMethod,
        degraded_notice: str | None,
        out_dir: Path
    ) -> str {
        raise NotImplementedError("render");
    }
}

"""The documented degradation for the PDF path: a plain-text report.

Used in tests and whenever ReportLab is unavailable, so a SITREP is still produced:
a lower-fidelity artefact rather than silence."""
obj PlainTextRenderer(SitrepRenderer) {
    has extension: str = "txt";

    override def render(
        sitrep_id: str,
        generated_at: datetime,
        claims: list[SourcedClaim],
        hazard_method: HazardMethod,
        degraded_notice: str | None,
        out_dir: Path
    ) -> str {
        folder = Path(out_dir);
        folder.mkdir(parents=True, exist_ok=True);
        path = folder / f"{sitrep_id}.{self.extension}";
        body = _header_lines(sitrep_id, generated_at, hazard_method, degraded_notice);
        body.append("");
        body.extend([f"- {c.sentence}  [source: {c.source_ref}]" for c in claims]);
        path.write_text("\n".join(body), encoding="utf-8");
        return str(path);
    }
}

"""The real SITREP PDF. ReportLab is imported only when a report is rendered, so this
module stays loadable without it."""
obj ReportLabRenderer(SitrepRenderer) {
    has extension: str = "pdf";

    override def render(
        sitrep_id: str,
        generated_at: datetime,
        claims: list[SourcedClaim],
        hazard_method: HazardMethod,
        degraded_notice: str | None,
        out_dir: Path
    ) -> str {
        import from reportlab.lib.pagesizes { A4 }
        import from reportlab.lib.styles { getSampleStyleSheet }
        import from reportlab.platypus { Paragraph, SimpleDocTemplate, Spacer }

        folder = Path(out_dir);
        folder.mkdir(parents=True, exist_ok=True);
        path = folder / f"{sitrep_id}.{self.extension}";
        styles = getSampleStyleSheet();
        doc = SimpleDocTemplate(str(path), pagesize=A4, title=f"SITREP {sitrep_id}");

        story: list[any] = [];
        header = _header_lines(sitrep_id, generated_at, hazard_method, degraded_notice);
        story.append(Paragraph(header[0], styles["Title"]));
        for line in header[1:] {
            story.append(Paragraph(line, styles["Normal"]));
        }
        story.append(Spacer(1, 12));
        for c in claims {
            # The source ref is rendered on every claim: a sentence a commander
            # cannot trace to evidence never appears in this document.
            story.append(Paragraph(f"{c.sentence} <i>[source: {c.source_ref}]</i>", styles["Normal"]));
            story.append(Spacer(1, 6));
        }

        doc.build(story);
        return str(path);
    }
}
