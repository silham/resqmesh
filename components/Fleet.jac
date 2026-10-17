"""The fleet, and what each vehicle is actually doing.

A commander can see the dispatch plan, and this shows the rest: who is committed, who is
free and how far along a crew is. That matters because a vehicle with an open commitment
is one the optimiser may not re-task, so "why did the plan not use BOAT-01" has an answer
the console can give."""

import from "@mantine/core" { Badge, Card, Group, Stack, Text }
import from ..lib.format { clusterPlace }
import from .ConsoleHelpers { words }

glob STATUS_COLOR: dict[str, str] = {
    "released": "yellow",
    "en_route": "blue",
    "on_scene": "teal",
    "complete": "gray",
    "declined": "orange",
    "recalled": "orange"
};

glob OPEN_STATUSES: list[str] = ["released", "en_route", "on_scene"];

def:pub Fleet(view: any) -> JsxElement {
    # Latest record per vehicle; an open one always wins over a closed history.
    byVehicle: dict[str, any] = {};
    for c in (view["commitments"] or []) {
        vid = c["assignment"]["vehicle_id"];
        held = byVehicle[vid];
        if not held or c["status"] in OPEN_STATUSES {
            byVehicle[vid] = c;
        }
    }
    proposed: dict[str, any] = {};
    if view["plan"] {
        for a in view["plan"]["assignments"] {
            proposed[a["vehicle_id"]] = a;
        }
    }

    if len(view["vehicles"]) == 0 {
        return <Text size="sm" c="dimmed" p="md">
            No vehicles in the roster.
        </Text>;
    }

    <Stack gap="xs" p="xs">
        {for v in view["vehicles"] {
            commitment = byVehicle[v["vehicle_id"]];
            isOpen = bool(commitment) and commitment["status"] in OPEN_STATUSES;
            pending = None if isOpen else proposed[v["vehicle_id"]];
            badgeColor = "gray";
            if commitment {
                badgeColor = STATUS_COLOR[commitment["status"]] or "gray";
            } elif pending {
                badgeColor = "yellow";
            }
            badgeText = "available";
            if isOpen {
                badgeText = words(commitment["status"]);
            } elif pending {
                badgeText = "proposed";
            }
            <Card key={v["vehicle_id"]} withBorder radius="md" padding="sm">
                <Group justify="space-between" wrap="nowrap" align="flex-start">
                    <div style={{"minWidth": 0}}>
                        <Text size="sm" fw={600} ff="monospace">
                            {v["vehicle_id"]}
                        </Text>
                        <Text size="xs" c="dimmed">
                            {v["kind"] + " · capacity " + str(v["capacity"])}
                        </Text>
                    </div>
                    <Badge size="sm" variant={"filled" if isOpen else "light"} color={badgeColor}>
                        {badgeText}
                    </Badge>
                </Group>
                {if isOpen {
                    <Text size="xs" mt={4}>
                        Committed to <b>{clusterPlace(view, commitment["assignment"]["cluster_id"])}</b>
                        {" · " + str(commitment["assignment"]["load"]) + " people · ETA " + commitment["assignment"]["eta_minutes"].toFixed(0) + " min"}
                    </Text>
                }}
                {if isOpen {
                    <Text size="xs" c="dimmed" mt={2}>
                        The optimiser cannot re-task this crew. Diverting them needs a constraint at the gate.
                    </Text>
                }}
                {if not isOpen and pending {
                    <Text size="xs" mt={4} c="dimmed">
                        Proposed for <b>{clusterPlace(view, pending["cluster_id"])}</b> — not yet approved.
                    </Text>
                }}
                {if commitment and not isOpen {
                    <Text size="xs" c="dimmed" mt={4}>
                        {"Last job " + clusterPlace(view, commitment["assignment"]["cluster_id"]) + ": " + words(commitment["status"]) + (" (" + commitment["note"] + ")" if commitment["note"] else "")}
                    </Text>
                }}
            </Card>
        }}
    </Stack>
}
