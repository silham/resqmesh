"""Regenerate the example incident views: `jac run --no-takeover scripts/export_examples.jac`.

Writes `docs/examples/*.json`: real `get_incident` responses captured from the synthetic
incident at each stage of its lifecycle, so every console screen can be built and reviewed
against real data before the server is running.

Offline and deterministic in content (ids and timestamps differ run to run).
"""

import json;
import sys;
import from datetime { datetime, timedelta, UTC }
import from pathlib { Path }
import from resqmesh.contracts.enums { ApprovalDecision }
import from resqmesh.graph.world { follow_up_signals, opening_signals }
import from resqmesh.service.app { DEMO_GOAL, build_service }
import from resqmesh.service.core { IncidentService }

glob OUT: Path = Path(__file__).resolve().parents[1] / "docs" / "examples";

def write(name: str, data: dict[str, any]) -> None {
    OUT.mkdir(parents=True, exist_ok=True);
    path = OUT / f"{name}.json";
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + chr(10), encoding="utf-8");
    print(f"wrote docs/examples/{name}.json");
}

def snapshot(service: IncidentService, name: str) -> dict[str, any] {
    service.process_pending();
    view = service.view();
    if view is None {
        raise RuntimeError("no incident is open");
    }
    write(name, view);
    return view;
}

def main -> int {
    service = build_service(llm_mode="offline", persisted=False);
    service.open(DEMO_GOAL);
    snapshot(service, "01-opened");

    t0 = datetime.now(UTC) - timedelta(minutes=30);
    # Directly, so the scripted source ids and timestamps are kept.
    for signal in opening_signals(t0) {
        service.submit_report(signal);
    }
    view = snapshot(service, "02-awaiting-decision");

    service.decide(ApprovalDecision.APPROVED, view["plan"]["version"], None, True, "cmdr-01");
    snapshot(service, "03-executing");

    for signal in follow_up_signals(t0 + timedelta(minutes=20)) {
        service.submit_report(signal);
    }
    view = snapshot(service, "04-replanned-awaiting-decision");

    service.decide(ApprovalDecision.REJECTED, view["plan"]["version"], "exclude_vehicle: BOAT-01", False, "cmdr-01");
    snapshot(service, "05-resolved-under-constraint");

    service.halt();
    snapshot(service, "06-halted");
    return 0;
}

with entry {
    exit_code = main();
    sys.exit(exit_code);
}
