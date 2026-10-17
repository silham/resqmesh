"""Responsive operations workspace; the wide view keeps the queue visible beside the
map and decision panel. Changing urgency never steals the operator's current tab."""

import from "@mantine/core" { ScrollArea }
import from .ApprovalPanel { ApprovalPanel }
import from .Fleet { Fleet }
import from .HeldReports { HeldReports }
import from .MapPanel { MapPanel }
import from .TriageQueue { TriageQueue }

def:pub ConsoleWorkspace(
    view: any, canAct: bool, mobile: bool, wide: bool, tab: str,
    onTab: Callable[[str], None], refresh: Callable[[], None]
) -> JsxElement {
    attention: bool = bool(view["awaiting_decision"] or view["escalated"]);
    held: int = len(view["unresolved"]);
    selected: str = "queue" if not mobile and tab == "map" else tab;
    if wide and selected == "queue" {
        selected = "approval";
    }
    tabs: list[dict[str, str]] = [];
    if mobile {
        tabs = tabs + [{"value": "map", "label": "Map"}];
    }
    if not wide {
        tabs = tabs + [{"value": "queue", "label": "Incidents"}];
    }
    tabs = tabs + [
        {"value": "approval", "label": "Decisions !" if attention else "Decisions"},
        {"value": "fleet", "label": "Fleet"},
        {"value": "held", "label": "Held " + str(held) if held > 0 else "Held"}
    ];

    def selectFor(value: str) -> Callable[[], None] {
        return lambda { onTab(value); };
    }

    <div className={"crisis-workspace is-wide" if wide else "crisis-workspace"}>
        {if wide {
            <aside className="crisis-queue-rail" aria-label="Prioritized incidents">
                <div className="crisis-panel-heading">
                    <h2>Incident queue</h2>
                    <span>Highest priority first</span>
                </div>
                <ScrollArea className="crisis-panel-scroll"><TriageQueue view={view} /></ScrollArea>
            </aside>
        }}
        {if not mobile or selected == "map" {
            <section className="crisis-map-region" aria-label="Incident map">
                <div className="crisis-panel-heading">
                    <h2>Situation map</h2>
                    <span>Hazards · incidents · dispatch routes</span>
                </div>
                <div className="crisis-map-body"><MapPanel view={view} /></div>
            </section>
        }}
        <aside className={"crisis-side-panel map-active" if mobile and selected == "map" else "crisis-side-panel"} aria-label="Response controls">
            <nav className="crisis-tabs" aria-label="Console views">
                {for t in tabs {
                    <button
                        key={t["value"]}
                        type="button"
                        className={"crisis-tab is-active" if selected == t["value"] else "crisis-tab"}
                        aria-pressed={selected == t["value"]}
                        onClick={selectFor(t["value"])}
                    >{t["label"]}</button>
                }}
            </nav>
            {if not mobile or selected != "map" {
                <ScrollArea className="crisis-panel-scroll">
                    {if selected == "approval" {
                        <ApprovalPanel view={view} canAct={canAct} refresh={refresh} />
                    } elif selected == "fleet" {
                        <Fleet view={view} />
                    } elif selected == "held" {
                        <HeldReports view={view} canAct={canAct} refresh={refresh} />
                    } else {
                        <TriageQueue view={view} />
                    }}
                </ScrollArea>
            }}
        </aside>
    </div>
}
