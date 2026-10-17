"""The ranked demand queue. Every score expands into the evidence and weights that
produced it: a commander interrogates a ranking rather than accepting it blind."""

import from "@mantine/core" { Badge, Box, Group, Select, Stack, Text, TextInput, UnstyledButton }
import from ..lib.format { clusterPlace, isCompleted, prettyHazard, priorityBand }
import from ..lib.crisis { clusterPeople }
import from .ConsoleEvidence { ConsoleEvidence }
import from .ConsoleHelpers { percent }
import from .ConsoleScoreBreakdown { ConsoleScoreBreakdown }

def:pub TriageQueue(view: any) -> JsxElement {
    has openId: any = None;
    has search: str = "";
    has hazard: any = None;

    def byRank(item: any) -> float {
        return (item["rank"] + (100000 if isCompleted(view, item["cluster_id"]) else 0)) as float;
    }

    # One handler per row. Variables assigned inside a JSX loop are shared by every
    # iteration, so a click handler built there would all see the last row's id; a
    # function call gives each row its own binding.
    def toggleFor(clusterId: any) -> any {
        return lambda { openId = None if openId == clusterId else clusterId; };
    }

    def findCluster(clusterId: any) -> any {
        for c in view["clusters"] {
            if c["cluster_id"] == clusterId {
                return c;
            }
        }
        return None;
    }

    ranked: list[any] = sorted(view["queue"], key=byRank);

    # The proposal targets forty simultaneous calls; an unfiltered scroll stops being
    # usable well before that.
    hazards: list[str] = [];
    for c in view["clusters"] {
        if c["hazard_type"] not in hazards {
            hazards = hazards + [c["hazard_type"]];
        }
    }
    hazardOptions: list[any] = [{"value": h, "label": prettyHazard(h)} for h in hazards];

    needle: str = search.strip().lower();
    items: list[any] = [];
    for item in ranked {
        cluster = findCluster(item["cluster_id"]);
        if hazard and (not cluster or cluster["hazard_type"] != hazard) {
            continue;
        }
        if needle {
            hay: str = (clusterPlace(view, item["cluster_id"]) + " " + item["cluster_id"] + " " + item["rationale_text"]).lower();
            if needle not in hay {
                continue;
            }
        }
        items = items + [item];
    }

    if len(ranked) == 0 {
        return <Text size="sm" c="dimmed" p="md">
            No demand ranked yet.
        </Text>;
    }

    <Stack gap="sm" p="md" className="crisis-triage">
        <Group gap="xs" wrap="nowrap">
            <TextInput
                label="Find an incident"
                placeholder="Search place or reason"
                value={search}
                onChange={lambda (e: ChangeEvent) { search = e.target.value; }}
                size="sm"
                style={{"flex": 1}}
            />
            <Select
                label="Hazard"
                placeholder="Any hazard"
                value={hazard}
                onChange={lambda (v: any) { hazard = v; }}
                data={hazardOptions}
                clearable={True}
                size="sm"
                w={130}
            />
        </Group>
        {if len(items) == 0 {
            <Text size="sm" c="dimmed" p="xs">
                Nothing matches. {len(ranked)} incident(s) are ranked.
            </Text>
        }}
        {for item in items {
            band = priorityBand(item["score_0_1"]);
            cluster = findCluster(item["cluster_id"]);
            isOpen = openId == item["cluster_id"];
            # A cluster a crew has reported served stays in the queue for the audit
            # trail, but must stop reading as outstanding demand.
            done = isCompleted(view, item["cluster_id"]);
            clusterId = item["cluster_id"];
            priorityText = "Critical" if band["label"] == "P1" else ("Urgent" if band["label"] == "P2" else "Monitor");
            people = clusterPeople(view, clusterId);
            subtitle = "Reported complete by the crew" if done else (
                (prettyHazard(cluster["hazard_type"]) if cluster else "unknown hazard")
                + " · " + (str(people) + " people reported" if people >= 0 else "People count unknown")
            );
            <Box key={clusterId} className={"crisis-incident is-complete" if done else "crisis-incident priority-" + band["label"]}>
                <UnstyledButton
                    onClick={toggleFor(clusterId)}
                    className="crisis-incident-button"
                    aria-expanded={isOpen}
                    aria-controls={"incident-evidence-" + clusterId}
                >
                    <Stack gap="xs">
                        <Group justify="space-between" wrap="nowrap">
                            <Badge
                                color={"gray" if done else band["color"]}
                                variant={"light" if done else "filled"}
                                radius="sm"
                            >
                                {"Complete" if done else band["label"] + " · " + priorityText}
                            </Badge>
                            <Text size="xs" c="dimmed">{"Rank " + str(item["rank"])}</Text>
                        </Group>
                        <div>
                                <Text
                                    size="lg"
                                    fw={700}
                                    td={"line-through" if done else "none"}
                                    c={"dimmed" if done else "inherit"}
                                >
                                    {clusterPlace(view, clusterId)}
                                </Text>
                                <Text size="sm" c="dimmed">
                                    {subtitle}
                                </Text>
                        </div>
                        <Group justify="space-between" gap="xs">
                            <Text size="xs" c="dimmed">
                                {"Evidence confidence " + percent(cluster["confidence_0_1"] if cluster else 0) + "%"}
                            </Text>
                            <span className="crisis-evidence-toggle">{ "Close evidence −" if isOpen else "Review evidence +" }</span>
                        </Group>
                    </Stack>
                </UnstyledButton>
                {if isOpen {
                    <Box id={"incident-evidence-" + clusterId}>
                        <ConsoleScoreBreakdown item={item} />
                        {if cluster and cluster["merged_from"] and cluster["merged_from"].length > 0 {
                            <Text size="xs" c="dimmed" px="md" pb={4}>
                                Absorbed {cluster["merged_from"].join(", ")} — reports that arrived since showed
                                these were one incident.
                            </Text>
                        }}
                        {if cluster {
                            <Box px="md" pb="sm">
                                <ConsoleEvidence view={view} cluster={cluster} />
                            </Box>
                        }}
                    </Box>
                }}
            </Box>
        }}
    </Stack>
}
