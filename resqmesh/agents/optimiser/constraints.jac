"""Targeted re-solve: turn a rejection into a constraint, not a blind retry.

Two sources feed back into the next solve:

1. **A5's verdict.** `GuardrailVerdict.violated_constraint` names the failed check (the
   constants in `resqmesh.agents.guardrail.checks`). A4 recomputes *which* assignments
   broke it from the same state — never by parsing A5's prose — and excludes exactly
   those.
2. **The commander.** `ApprovalRecord.constraint_note` on a REJECTED or MODIFIED
   decision. Grammar (one or more tokens, separated by `;` `,` or newlines — the
   console should offer these as buttons):

       exclude_cluster:<cluster_id>     do not dispatch to this cluster
       exclude_vehicle:<vehicle_id>     do not use this vehicle
       forbid_pair:<vehicle_id>><cluster_id>   not this vehicle to this cluster

   Also accepted, case-insensitive: `exclude|hold|skip <id>` and
   `no <vehicle_id> to <cluster_id>`. Ids are matched only against the current
   clusters and vehicles, so free text can never invent a constraint.

Every applied constraint is written into `DispatchPlan.commander_constraints` as a
canonical token, so the audit trail shows why the new plan differs from the last.
"""

import re;
import from resqmesh.agents.guardrail.checks {
    GAZETTEER_MEMBERSHIP, NO_GO_INTERSECTION, TARGETS_EXIST, TIER_C_CONFIDENCE_FLOOR,
    VEHICLE_CAPACITY
}
import from resqmesh.contracts.enums { ApprovalDecision, ClusterState }
import from resqmesh.contracts.models {
    ApprovalRecord, DispatchPlan, GuardrailVerdict, HazardSurface, IncidentCluster, Vehicle
}
import from resqmesh.contracts.ports { GeocodePort }

obj SolveConstraints {
    has excluded_clusters: set[str] = set(),
        excluded_vehicles: set[str] = set(),
        forbidden_pairs: set[tuple[str, str]] = set(),
        avoid_edges: set[str] = set(),
        tokens: list[str] = [];

    def _token(t: str) -> None {
        if t not in self.tokens {
            self.tokens.append(t);
        }
    }

    def exclude_cluster(cid: str, why: str = "") -> None {
        self.excluded_clusters.add(cid);
        self._token(f"exclude_cluster:{cid}" + (f" ({why})" if why else ""));
    }

    def exclude_vehicle(vid: str) -> None {
        self.excluded_vehicles.add(vid);
        self._token(f"exclude_vehicle:{vid}");
    }

    def forbid_pair(vid: str, cid: str, why: str = "") -> None {
        self.forbidden_pairs.add((vid, cid));
        self._token(f"forbid_pair:{vid}>{cid}" + (f" ({why})" if why else ""));
    }

    def avoid(edges: any, surface_version: int) -> None {
        self.avoid_edges.update(edges);
        self._token(f"avoid_impassable:surface_v{surface_version}");
    }
}

# --------------------------------------------------------------------------- From A5

"""Add the constraint that fixes the violation A5 reported on `plan`."""
def apply_verdict(
    constraints: SolveConstraints,
    verdict: GuardrailVerdict | None,
    plan: DispatchPlan | None,
    clusters: list[IncidentCluster],
    vehicles: list[Vehicle],
    hazard: HazardSurface | None,
    confidence_floor: float,
    gazetteer: GeocodePort | None = None
) -> None {
    if verdict is None or verdict.passed or plan is None or verdict.plan_id != plan.plan_id {
        return;
    }
    failed = {c.name for c in verdict.checks if not c.passed};
    by_cluster = {c.cluster_id: c for c in clusters};
    by_vehicle = {v.vehicle_id: v for v in vehicles};

    if NO_GO_INTERSECTION in failed and hazard is not None {
        # The plan was built on a graph older than the current surface (or with pruning
        # disabled): route around every edge the current surface closes.
        constraints.avoid(hazard.impassable_edge_ids, hazard.version);
    }
    if VEHICLE_CAPACITY in failed {
        for a in plan.assignments {
            v = by_vehicle.get(a.vehicle_id);
            if v is not None and a.load > v.capacity {
                constraints.forbid_pair(a.vehicle_id, a.cluster_id, "capacity");
            }
        }
    }
    if TIER_C_CONFIDENCE_FLOOR in failed {
        for a in plan.assignments {
            c = by_cluster.get(a.cluster_id);
            if c is not None and (c.state == ClusterState.UNRESOLVED or c.confidence_0_1 < confidence_floor) {
                constraints.exclude_cluster(a.cluster_id, "below confidence floor");
            }
        }
    }
    if GAZETTEER_MEMBERSHIP in failed {
        for a in plan.assignments {
            c = by_cluster.get(a.cluster_id);
            if c is None {
                continue;
            }
            if gazetteer is not None {
                if not gazetteer.contains(c.gn_id) {
                    constraints.exclude_cluster(a.cluster_id, "not in gazetteer");
                }
            } elif c.gn_id in _gazetteer_offenders(verdict) {
                constraints.exclude_cluster(a.cluster_id, "not in gazetteer");
            }
        }
    }
    if TARGETS_EXIST in failed {
        for a in plan.assignments {
            if a.cluster_id not in by_cluster {
                constraints.exclude_cluster(a.cluster_id, "unknown cluster");
            }
            if a.vehicle_id not in by_vehicle {
                constraints.exclude_vehicle(a.vehicle_id);
            }
        }
    }
}

"""GN ids named in A5's gazetteer detail — used only when no gazetteer is injected."""
def _gazetteer_offenders(verdict: GuardrailVerdict) -> set[str] {
    detail = "";
    for c in verdict.checks {
        if c.name == GAZETTEER_MEMBERSHIP {
            detail = c.detail;
            break;
        }
    }
    return set(re.findall(r"->\s*([^,\s]+)", detail));
}

# --------------------------------------------------------------------------- From the commander

glob _REJECTING: list[ApprovalDecision] = [ApprovalDecision.REJECTED, ApprovalDecision.MODIFIED];

"""Every rejection/modification note in the audit log, parsed against known ids.

Approvals are append-only, so re-reading them all each cycle is stateless and makes a
commander's constraint persist across every later re-plan."""
def apply_commander_notes(
    constraints: SolveConstraints,
    approvals: list[ApprovalRecord],
    cluster_ids: any,
    vehicle_ids: any
) -> None {
    clusters = set(cluster_ids);
    vehicles = set(vehicle_ids);
    for record in approvals {
        if record.decision in _REJECTING and record.constraint_note {
            for (vid, cid) in _parse_note(record.constraint_note, clusters, vehicles) {
                if vid and cid {
                    constraints.forbid_pair(vid, cid, "commander");
                } elif cid {
                    constraints.exclude_cluster(cid, "commander");
                } elif vid {
                    constraints.exclude_vehicle(vid);
                }
            }
        }
    }
}

"""`forbid_pair:V>C` or `no V to C`."""
glob _PAIR: any = re.compile(
    r"forbid_pair:\s*(?P<v1>\S+?)\s*>\s*(?P<c1>\S+)|(?i:no)\s+(?P<v2>\S+)\s+(?i:to)\s+(?P<c2>\S+)"
);

def _parse_note(note: str, clusters: set[str], vehicles: set[str]) -> list[tuple[str | None, str | None]] {
    out: list[tuple[str | None, str | None]] = [];
    for raw in re.split(r"[;,\n]+", note) {
        token = raw.strip();
        if not token {
            continue;
        }
        m: any = re.fullmatch(r"exclude_cluster:\s*(\S+)", token);
        if m {
            out.append((None, m.group(1)) if m.group(1) in clusters else (None, None));
            continue;
        }
        m = re.fullmatch(r"exclude_vehicle:\s*(\S+)", token);
        if m {
            out.append((m.group(1), None) if m.group(1) in vehicles else (None, None));
            continue;
        }
        m = _PAIR.fullmatch(token);
        if m {
            vid = m.group("v1") or m.group("v2");
            cid = m.group("c1") or m.group("c2");
            if vid in vehicles and cid in clusters {
                out.append((vid, cid));
            }
            continue;
        }
        m = re.fullmatch(r"(?i)(?:exclude|hold|skip)\s+(\S+)", token);
        if m {
            ident = m.group(1);
            if ident in clusters {
                out.append((None, ident));
            } elif ident in vehicles {
                out.append((ident, None));
            }
        }
    }
    return [p for p in out if p != (None, None)];
}
