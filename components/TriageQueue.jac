"""The ranked demand queue. Every score expands into the evidence and weights that
produced it: a commander interrogates a ranking rather than accepting it blind."""

import from "@mantine/core" { Badge, Box, Group, Select, Stack, Text, TextInput, UnstyledButton }
import from ..lib.format { clusterPlace, isCompleted, prettyHazard, priorityBand }
import from .ConsoleEvidence { ConsoleEvidence }
import from .ConsoleHelpers { percent }
import from .ConsoleScoreBreakdown { ConsoleScoreBreakdown }

def:pub TriageQueue(view: any) -> JsxElement {
    has openId: any = None;
    has search: str = "";
    has hazard: any = None;

    def byRank(item: any) -> float {
        return item["rank"] as float;
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

    <Stack gap={4} p="xs">
        <Group gap="xs" wrap="nowrap">
            <TextInput
                placeholder="Search place or reason"
                value={search}
                onChange={lambda (e: ChangeEvent) { search = e.target.value; }}
                size="xs"
                style={{"flex": 1}}
            />
            <Select
                placeholder="Any hazard"
                value={hazard}
                onChange={lambda (v: any) { hazard = v; }}
                data={hazardOptions}
                clearable={True}
                size="xs"
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
            subtitle = "served — reported complete by the crew" if done else (
                (prettyHazard(cluster["hazard_type"]) if cluster else "unknown hazard")
                + " · conf " + percent(cluster["confidence_0_1"] if cluster else 0) + "%"
            );
            <Box key={clusterId} style={{"border": "1px solid var(--mantine-color-gray-2)", "borderRadius": 8}}>
                <UnstyledButton
                    onClick={toggleFor(clusterId)}
                    style={{"width": "100%", "padding": "8px 12px"}}
                >
                    <Group justify="space-between" wrap="nowrap">
                        <Group gap="sm" wrap="nowrap">
                            <Badge
                                color={"gray" if done else band["color"]}
                                variant={"light" if done else "filled"}
                                radius="sm"
                            >
                                {"✓" if done else band["label"]}
                            </Badge>
                            <div>
                                <Text
                                    size="sm"
                                    fw={600}
                                    td={"line-through" if done else "none"}
                                    c={"dimmed" if done else "inherit"}
                                >
                                    {clusterPlace(view, clusterId)}
                                </Text>
                                <Text size="xs" c="dimmed">
                                    {subtitle}
                                </Text>
                            </div>
                        </Group>
                        <Text size="lg" fw={700} ff="monospace">
                            {item["score_0_1"].toFixed(2)}
                        </Text>
                    </Group>
                </UnstyledButton>
                {if isOpen {
                    <Box>
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
