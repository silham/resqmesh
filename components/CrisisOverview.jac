"""Persistent, snapshot-derived overview. Counts describe reported demand, not live GPS
or independently verified headcounts. Contact time and incident change time are distinct."""

import from "react" { useMemo }
import from ..lib.crisis { crisisCounts }
import from .ConsoleHelpers { clockTime }

def:pub CrisisOverview(view: any, lastContact: float, now: float, stale: bool) -> JsxElement {
    counts: any = useMemo(lambda { return crisisCounts(view); }, [view]);
    age: int = int(Math.max(0, Math.floor((now - lastContact) / 1000)));
    contact: str = "Waiting for server";
    if lastContact > 0 {
        contact = str(age) + "s ago";
    }
    <section className="crisis-overview" aria-label="Incident overview">
        <h1 className="crisis-sr">Response overview</h1>
        <div className="crisis-overview-id">
            <span className="crisis-eyebrow">COMMAND CENTRE / {view["incident_id"]}</span>
            <span className="crisis-goal" title={view["goal"]}>{view["goal"]}</span>
        </div>
        <div className="crisis-metrics">
            <div className={"crisis-metric metric-critical" if counts["critical"] > 0 else "crisis-metric"} title="P1 priority, open demand">
                <strong>{counts["critical"]}</strong>
                <span className="crisis-metric-label">Critical</span>
            </div>
            <div className="crisis-metric" title="Ranked, not reported complete">
                <strong>{counts["active"]}</strong>
                <span className="crisis-metric-label">Open</span>
            </div>
            <div className="crisis-metric" title={str(counts["unknown"]) + " incident(s) with unknown counts" if counts["unknown"] > 0 else "Reported in open incidents"}>
                <strong>{str(counts["people"]) + ("+" if counts["unknown"] > 0 else "")}</strong>
                <span className="crisis-metric-label">People</span>
            </div>
            <div className="crisis-metric" title="Available roster, no open commitment">
                <strong>{counts["available"]}<small>{"/" + str(counts["total"])}</small></strong>
                <span className="crisis-metric-label">Vehicles</span>
            </div>
        </div>
        <div className="crisis-connection" title={contact + " · Incident updated " + clockTime(view["updated_at"])}>
            <span className={"crisis-signal is-stale" if stale else "crisis-signal"}>
                <span className="crisis-signal-dot" aria-hidden="true"></span>
                {"Needs attention" if stale else "Live"}
            </span>
            <span>{contact}</span>
        </div>
    </section>
}
