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
        contact = "Last contact " + str(age) + "s ago";
    }
    <section className="crisis-overview" aria-label="Incident overview">
        <div className="crisis-overview-heading">
            <div>
                <div className="crisis-eyebrow">COMMAND CENTRE / {view["incident_id"]}</div>
                <h1>Response overview</h1>
                <p className="crisis-goal">{view["goal"]}</p>
            </div>
            <div className="crisis-connection">
                <span className={"crisis-signal is-stale" if stale else "crisis-signal"}>
                    <span className="crisis-signal-dot" aria-hidden="true"></span>
                    {"Connection needs attention" if stale else "Connected to server"}
                </span>
                <span>{contact}</span>
                <span>{"Incident updated " + clockTime(view["updated_at"])}</span>
            </div>
        </div>
        <div className="crisis-metrics">
            <div className={"crisis-metric metric-critical" if counts["critical"] > 0 else "crisis-metric"}>
                <span className="crisis-metric-label">Critical incidents</span>
                <strong>{counts["critical"]}</strong>
                <span>P1 priority · open demand</span>
            </div>
            <div className="crisis-metric">
                <span className="crisis-metric-label">Open incidents</span>
                <strong>{counts["active"]}</strong>
                <span>Ranked · not reported complete</span>
            </div>
            <div className="crisis-metric">
                <span className="crisis-metric-label">Reported people</span>
                <strong>{str(counts["people"]) + ("+" if counts["unknown"] > 0 else "")}</strong>
                <span>{str(counts["unknown"]) + " incident(s) with unknown counts" if counts["unknown"] > 0 else "Reported in open incidents"}</span>
            </div>
            <div className="crisis-metric">
                <span className="crisis-metric-label">Vehicles available</span>
                <strong>{counts["available"]}<small>{" / " + str(counts["total"])}</small></strong>
                <span>Available roster · no open commitment</span>
            </div>
        </div>
    </section>
}
