"""What the public should be reading right now, folded out of the alert log.

`state.alerts` is append-only, like every other observation: a bulletin that went out
went out, and no later decision unsends it. So a status change is a new record
carrying the same `alert_id`, and the current position is a fold, the same shape as
`resqmesh.graph.commitments`.

Three things retire a bulletin, and the distinction is worth keeping in the log:

* **superseded**: a later bulletin covers the same area, so the old one is not wrong,
  it is just not the latest;
* **expired**: its own validity window ran out with nobody saying anything;
* **cancelled**: somebody decided it is over and issued a stand-down.

Only the last is a decision, and only the last gets its own bulletin. The other two
are bookkeeping, and reading them as "we told people it was over" would be a lie the
audit trail should not let anyone tell.
"""

import from datetime { datetime }
import from resqmesh.contracts.enums { AlertStatus, alert_is_current }
import from resqmesh.contracts.models { CommunityAlert, evolve }

"""How long a bulletin is taken to be true if nothing says otherwise. Long enough to
cover a shift change, short enough that a forgotten warning stops shouting."""
glob DEFAULT_VALIDITY_HOURS: int = 6;

"""Alert id -> its most recent record. Later records win by list order."""
def latest(alerts: list[CommunityAlert]) -> dict[str, CommunityAlert] {
    out: dict[str, CommunityAlert] = {};
    for record in alerts {
        out[record.alert_id] = record;
    }
    return out;
}

def _issued_at(a: CommunityAlert) -> datetime {
    return a.issued_at;
}

"""Bulletins a member of the public should be reading, newest first.

An expiry that has passed counts as retired whether or not anybody recorded it, so the
public page cannot show a stale warning just because no tick has run."""
def current(alerts: list[CommunityAlert], now: datetime) -> list[CommunityAlert] {
    live = [
        a for a in latest(alerts).values()
        if alert_is_current(a.status) and not (a.expires_at is not None and a.expires_at <= now)
    ];
    return sorted(live, key=_issued_at, reverse=True);
}

"""A new record retiring one bulletin. The old record stays in the log."""
def retire(
    alert: CommunityAlert,
    status: AlertStatus,
    superseded_by: str | None = None,
    stood_down_by: str | None = None
) -> CommunityAlert {
    return evolve(alert, status=status, superseded_by=superseded_by, stood_down_by=stood_down_by);
}

"""Retire live bulletins that a fresh one covers the same ground as.

Matched on area and template: a second flood warning for Kolonnawa replaces the first,
while a flood warning does not silently retire an evacuation order for the same place.
Those say different things and the stronger one has to be stood down deliberately."""
def superseded_by(
    existing: list[CommunityAlert], fresh: list[CommunityAlert], now: datetime
) -> list[CommunityAlert] {
    replacing: dict[tuple[str, str], str] = {};
    for a in fresh {
        for gn in a.target_gn_ids {
            replacing[(a.template_id, gn)] = a.alert_id;
        }
    }
    out: list[CommunityAlert] = [];
    for live in current(existing, now) {
        newer: str | None = None;
        for gn in live.target_gn_ids {
            aid = replacing.get((live.template_id, gn));
            if aid {
                newer = aid;
                break;
            }
        }
        if newer is not None and newer != live.alert_id {
            out.append(retire(live, AlertStatus.SUPERSEDED, superseded_by=newer));
        }
    }
    return out;
}
