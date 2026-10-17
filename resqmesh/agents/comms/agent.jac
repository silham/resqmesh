"""A6: Communications and Reporting Agent.

Produces the system's outward artefacts: the commander SITREP, and the trilingual
public alerts.

Two invariants it never breaks:

* A claim reaches the SITREP only after passing A5's source-binding audit, so an
  unsourced sentence is impossible in a released report.
* A public alert is broadcast only when it carries a commander approval id (Tier C:
  no approval, no broadcast), and only to areas the rate limiter permits.

State fields written: `sitreps` and `alerts` (both append-only). It reads the verified
plan, clusters, hazard and approval decisions; it never writes them.
"""

import uuid;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.agents.guardrail.agent { GuardrailAgent }
import from resqmesh.agents.comms.alerts { AlertRateLimiter, fill_template }
import from resqmesh.agents.comms.lifecycle { DEFAULT_VALIDITY_HOURS, superseded_by }
import from resqmesh.agents.comms.sitrep {
    PlainTextRenderer, SitrepRenderer, assemble_claims, compute_hash,
    degraded_notice_for, known_source_refs
}
import from resqmesh.contracts.enums { ActionTier, HazardMethod }
import from resqmesh.contracts.models {
    ApprovalRecord, CommunityAlert, DispatchPlan, GuardrailCheck, Shelter, Sitrep,
    SourcedClaim, TraceEvent
}
import from resqmesh.contracts.ports { BroadcastPort }
import from resqmesh.contracts.state { IncidentState }

"""Raised on an attempt to broadcast an alert with no approval id.

Tier C is human-authority by design; the code makes the omission an error, not a
silent send."""
class UnapprovedBroadcast(RuntimeError) {}

def _decided_at(a: ApprovalRecord) -> datetime {
    return a.decided_at;
}

"""The approval bound to exactly this plan version: matching plan id and version,
the latest decision winning. Kept local so A6 stays a leaf module with no dependency
on the orchestration layer."""
def approval_for_plan(approvals: list[ApprovalRecord], plan: DispatchPlan | None) -> ApprovalRecord | None {
    if plan is None {
        return None;
    }
    matches = [
        a for a in approvals or []
        if a.plan_id == plan.plan_id and a.plan_version == plan.version
    ];
    return max(matches, key=_decided_at) if matches else None;
}

obj CommsAgent {
    has guardrail: GuardrailAgent,
        renderer: SitrepRenderer = PlainTextRenderer(),
        rate_limiter: AlertRateLimiter = AlertRateLimiter(),
        out_dir: Path = Path("outputs/sitreps"),
        # GN id -> human name (e.g. "LK1115205" -> "Hanwella"), so SITREP claims and
        # public alerts read as place names. Injected from the world; a missing id
        # falls back to the id itself. Empty is fine: the demo just shows ids.
        division_names: dict[str, str] = {};

    # -------------------------------------------------------------- GRAPH NODE

    """The A6 graph entry point, called by the release node after an approval.

    Produces the SITREP and the community alerts for the released plan, and returns
    **only the new items**: the release node appends them to `sitreps`, `alerts` and
    `trace`. Reads the verified plan, clusters, hazard and the approval bound to this
    plan version; writes nothing itself."""
    def run(state: IncidentState, now: datetime | None = None) -> dict[str, any] {
        moment = now or datetime.now(UTC);
        plan = state.plan;
        clusters = list(state.clusters or []);
        hazard = state.hazard;
        reports = list(state.reports or []);
        existing = list(state.sitreps or []);
        existing_alerts = list(state.alerts or []);
        # Cooldowns survive a restart only if they come back from the state.
        self.rate_limiter.seed(state.alert_cooldowns or {});
        incident_id = state.incident_id or "INC";
        version = plan.version if plan is not None else 0;

        approval = approval_for_plan(state.approvals or [], plan);

        # --- SITREP: source-bound, hash-chained to the previous one -----------
        claims = assemble_claims(clusters, hazard, plan, division_names=self.division_names);
        known = known_source_refs(clusters, hazard, plan, extra=[r.report_id for r in reports]);
        (sitrep, _check) = self.build_sitrep(
            sitrep_id=f"SR-{incident_id}-v{version}",
            claims=claims,
            known_refs=known,
            hazard_method=hazard.method if hazard is not None else HazardMethod.HAND,
            out_dir=self.out_dir,
            plan_version=plan.version if plan is not None else None,
            degraded_notice=degraded_notice_for(hazard),
            prev_hash=existing[-1].hash if existing else None,
            now=moment
        );

        # --- alerts: one flood warning per division in danger, consent-gated ------
        #
        # Two rules, both learned the hard way.
        #
        # *Who is warned is who is in danger, not who got a vehicle.* Deriving the
        # target list from plan.assignments meant the divisions with demand that no
        # vehicle could reach (the people most at risk, because nobody is coming)
        # were the only ones who heard nothing. Danger is a property of the queue;
        # dispatch is a property of fleet capacity. They are not the same set.
        #
        # *A broadcast needs its own yes.* The commander ticks publish_alerts having
        # seen the divisions it will reach; approving a dispatch alone does not put a
        # message on every phone in the basin.
        alerts: list[CommunityAlert] = [];
        if approval is not None and approval.publish_alerts and plan is not None {
            gn_by_cluster: dict[str, str] = {c.cluster_id: c.gn_id for c in clusters};
            queued = [q.cluster_id for q in state.queue or []];
            served = [a.cluster_id for a in plan.assignments];
            affected = list(
                dict.fromkeys([gn_by_cluster[cid] for cid in served + queued if cid in gn_by_cluster])
            );
            no_go: set[str] = set(hazard.no_go_gn_ids) if hazard is not None else set();
            for (i, gn) in enumerate(affected) {
                # A division the hazard model has declared no-go gets an evacuation
                # order naming where to go, not a warning that water is rising. It
                # needs a shelter to name; without one it falls back to the warning.
                shelter = self._shelter_for(gn, state);
                evacuate = gn in no_go and shelter is not None;
                area = self.division_names.get(gn, gn);
                slots: dict[str, str] = (
                    {"area": area, "shelter": shelter.name}
                    if evacuate and shelter is not None
                    else {"area": area}
                );
                alerts.append(
                    self.compose_alert(
                        alert_id=f"AL-{incident_id}-v{version}-{i + 1}",
                        template_id="evacuate_area" if evacuate else "flood_warning",
                        slots=slots,
                        target_gn_ids=[gn],
                        approval_id=approval.approval_id,
                        expires_at=moment + timedelta(hours=DEFAULT_VALIDITY_HOURS),
                        now=moment
                    )
                );
            }
            # A second bulletin for the same area and template replaces the first, so
            # /news shows what is true now rather than a pile of every warning issued.
            alerts.extend(superseded_by(existing_alerts, alerts, moment));
        }

        event = TraceEvent(
            event_id=f"EV-A6-{uuid.uuid4().hex[:12]}",
            agent="A6",
            action="sitrep_published",
            tier=ActionTier.TIER_B,
            detail=f"SITREP {sitrep.sitrep_id}: {len(sitrep.claims)} sourced claim(s), {len(alerts)} alert(s) composed",
            occurred_at=moment
        );

        update: dict[str, any] = {"sitreps": [sitrep], "alerts": alerts, "trace": [event]};
        cooldowns = self.rate_limiter.cooldowns();
        if cooldowns {
            update["alert_cooldowns"] = cooldowns;
        }
        return update;
    }

    # ----------------------------------------------------------------- SITREP

    """Assemble, source-audit, render and hash-chain a SITREP.

    Returns the report *and* the source-binding check, so the audit result is recorded
    in the trail and counted by the metrics harness. The claims that reach the PDF are
    the survivors of the audit: unsourced sentences are gone before the commander sees
    the document."""
    def build_sitrep(
        sitrep_id: str,
        claims: list[SourcedClaim],
        known_refs: set[str],
        hazard_method: HazardMethod,
        out_dir: Path,
        plan_version: int | None = None,
        degraded_notice: str | None = None,
        prev_hash: str | None = None,
        now: datetime | None = None
    ) -> tuple[Sitrep, GuardrailCheck] {
        moment = now or datetime.now(UTC);
        audit = self.guardrail.audit_sitrep_claims(list(claims), known_refs);
        check = audit[0];
        verified = audit[1];

        pdf_path = self.renderer.render(
            sitrep_id=sitrep_id,
            generated_at=moment,
            claims=verified,
            hazard_method=hazard_method,
            degraded_notice=degraded_notice,
            out_dir=out_dir
        );
        digest = compute_hash(sitrep_id, moment, verified, hazard_method, degraded_notice, prev_hash);

        sitrep = Sitrep(
            sitrep_id=sitrep_id,
            plan_version=plan_version,
            generated_at=moment,
            pdf_path=pdf_path,
            claims=verified,
            hazard_method=hazard_method,
            degraded_notice=degraded_notice,
            prev_hash=prev_hash,
            hash=digest
        );
        return (sitrep, check);
    }

    """An open shelter for this division: its own if there is one, else any open one.

    Falling back to another division's is deliberate. An evacuation order that cannot
    name a destination is not an order, and "go to the next division's centre" is a
    better instruction than silence."""
    def _shelter_for(gn_id: str, state: IncidentState) -> Shelter | None {
        shelters = [s for s in state.shelters or [] if s.open and s.capacity > 0];
        for s in shelters {
            if s.gn_id == gn_id {
                return s;
            }
        }
        return shelters[0] if shelters else None;
    }

    # ------------------------------------------------------------------ ALERTS

    """Fill a reviewed template into a trilingual alert.

    `approval_id` is required by the contract; an empty one is rejected here so an
    unapprovable object can never be constructed and then accidentally sent."""
    def compose_alert(
        alert_id: str,
        template_id: str,
        slots: dict[str, str],
        target_gn_ids: list[str],
        approval_id: str,
        expires_at: datetime | None = None,
        now: datetime | None = None
    ) -> CommunityAlert {
        if not approval_id {
            raise UnapprovedBroadcast("a community alert must carry a commander approval id");
        }
        texts = fill_template(template_id, slots);
        return CommunityAlert(
            alert_id=alert_id,
            template_id=template_id,
            slots=slots,
            text_si=texts[0],
            text_ta=texts[1],
            text_en=texts[2],
            target_gn_ids=list(target_gn_ids),
            approval_id=approval_id,
            expires_at=expires_at,
            issued_at=now or datetime.now(UTC)
        );
    }

    """Send an approved alert to the areas the rate limiter permits.

    Returns the number of recipients reached. A fully rate-limited alert returns zero
    and sends nothing: that is a correct outcome, not a failure."""
    def broadcast(
        alert: CommunityAlert, broadcast_port: BroadcastPort, now: datetime | None = None
    ) -> int {
        if not alert.approval_id {
            raise UnapprovedBroadcast("refusing to broadcast an alert with no approval id");
        }
        moment = now or datetime.now(UTC);

        allowed = self.rate_limiter.filter_allowed(alert.target_gn_ids, moment, alert.template_id)[0];
        if not allowed {
            return 0;
        }

        message = "\n".join([alert.text_si, alert.text_ta, alert.text_en]);
        reached = broadcast_port.broadcast(allowed, message);
        self.rate_limiter.record(allowed, moment);
        return reached;
    }
}
