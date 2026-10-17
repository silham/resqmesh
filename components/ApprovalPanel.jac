"""The Tier C approval gate: the one place a human is asked. Shows the proposed dispatch
and the guardrail checks it passed, and lets the commander approve, reject or modify. A
rejection carries a constraint back to the optimiser; it is a re-solve instruction, not a
stop."""

import from "@mantine/core" {
    Alert, Anchor, Badge, Button, Card, Checkbox, Chip, Divider, Group, List, Modal, Stack, Text, ThemeIcon
}
import from resqmesh.service.endpoints { decide }
import from ..lib.format { clusterPlace, navigationUrl, prettyHazard }
import from .ConsoleEscalated { ConsoleEscalated }
import from .ConsoleHelpers { percent, toastErr, toastOk, toastWarn, words }

def:pub ApprovalPanel(view: any, canAct: bool, refresh: Callable[[], None]) -> JsxElement {
    has tokens: list[str] = [];
    has publishAlerts: bool = False;
    has confirming: bool = False;
    has sending: bool = False;

    pending: any = view["awaiting_decision"];
    plan: any = view["plan"];
    verdict: any = view["verdict"];
    constraint: str = "; ".join(tokens);

    def findCluster(clusterId: any) -> any {
        for c in view["clusters"] {
            if c["cluster_id"] == clusterId {
                return c;
            }
        }
        return None;
    }

    async def submit(decision: str) {
        if decision == "modified" and not constraint {
            toastWarn("Pick a constraint to modify — an empty one is a pointless re-solve.");
            return;
        }
        confirming = False;
        sending = True;
        planVersion = pending["plan_version"];
        try {
            # Only an approval can carry a broadcast; a rejection publishes nothing.
            await decide(decision, planVersion, constraint if constraint else None, decision == "approved" and publishAlerts);
            toastOk("Plan v" + str(planVersion) + " " + decision);
            # The constraint was spent on that plan. Left selected it would ride along on
            # the next one, as a chip that may no longer even be on screen.
            tokens = [];
        } except Exception as e {
            toastErr(e);
        }
        sending = False;
        # A refusal means the plan moved on under us (a stale version), so pull the
        # fresh one at once rather than waiting for the next poll. The writer is
        # asynchronous, so ask again once it has had a moment.
        refresh();
        setTimeout(lambda { refresh(); }, 1500);
    }

    def approve() {
        confirming = True;
    }
    def cancelConfirm() {
        confirming = False;
    }
    async def modify() {
        await submit("modified");
    }
    async def reject() {
        await submit("rejected");
    }
    async def authorise() {
        await submit("approved");
    }

    if not pending or not plan {
        if view["escalated"] {
            return <ConsoleEscalated view={view} canAct={canAct} refresh={refresh} />;
        }
        return <Text size="sm" c="dimmed" p="md">
            No decision pending. The system is running autonomously.
        </Text>;
    }

    # Who a broadcast would reach: every division with demand, not only the ones a
    # vehicle is going to. The divisions nobody can reach are the ones that most need
    # telling, and deriving this from the assignments used to leave them silent.
    clusterIds: list[str] = [];
    for a in plan["assignments"] {
        clusterIds = clusterIds + [a["cluster_id"]];
    }
    for q in view["queue"] {
        clusterIds = clusterIds + [q["cluster_id"]];
    }
    warned: list[str] = [];
    for cid in clusterIds {
        cl = findCluster(cid);
        if cl and cl["gn_id"] {
            div = view["divisions"][cl["gn_id"]];
            name: str = div["name"] if (div and div["name"]) else cl["gn_id"];
            if name not in warned {
                warned = warned + [name];
            }
        }
    }

    gap: any = plan["optimality_gap"];
    gapText: str = "unknown";
    if gap or gap == 0 {
        gapText = (gap * 100).toFixed(1) + "%";
    }

    skipIds: list[str] = [];
    for a in plan["assignments"] {
        if a["cluster_id"] not in skipIds {
            skipIds = skipIds + [a["cluster_id"]];
        }
    }

    <Stack gap="sm" p="md">
        <Group justify="space-between">
            <Text fw={700}>Tier C — approval required</Text>
            <Badge color="yellow" variant="filled">
                {"plan " + plan["plan_id"] + " v" + str(pending["plan_version"])}
            </Badge>
        </Group>

        <Card withBorder padding="sm" radius="md">
            <Text size="xs" c="dimmed" mb={4}>
                {"solver " + plan["solver_status"] + " · gap " + gapText}
            </Text>
            <Stack gap={4}>
                {for a in plan["assignments"] {
                    cluster = findCluster(a["cluster_id"]);
                    # This is the sentence a commander authorises people into danger on,
                    # so it names the crew, the place and the hazard, never a cluster id.
                    <Group key={a["vehicle_id"]} justify="space-between" wrap="nowrap" align="flex-start">
                        <div>
                            <Text size="sm">
                                <Text span={True} ff="monospace" fw={600}>
                                    {a["vehicle_id"]}
                                </Text>{" "}
                                → <strong>{clusterPlace(view, a["cluster_id"])}</strong>
                            </Text>
                            {if cluster {
                                <Text size="xs" c="dimmed">
                                    {prettyHazard(cluster["hazard_type"]) + " · confidence " + percent(cluster["confidence_0_1"]) + "% · "}
                                    {#* The same destination and link the crew is handed on the responder
                                        page, so the commander can check where they are about to send
                                        people before authorising it. *#}
                                    <Anchor
                                        href={navigationUrl(cluster["centroid_lat"], cluster["centroid_lon"])}
                                        target="_blank"
                                        rel="noreferrer"
                                        inherit={True}
                                    >
                                        map
                                    </Anchor>
                                </Text>
                            }}
                        </div>
                        <Text size="sm" c="dimmed" style={{"whiteSpace": "nowrap"}}>
                            {"ETA " + a["eta_minutes"].toFixed(0) + " min · " + str(a["load"]) + " people"}
                        </Text>
                    </Group>
                }}
            </Stack>
        </Card>

        {if verdict {
            <Alert
                color={"teal" if verdict["passed"] else "red"}
                variant="light"
                title={"Guardrails passed" if verdict["passed"] else "Guardrail failed: " + str(verdict["violated_constraint"])}
            >
                <List size="xs" spacing={2}>
                    {for c in verdict["checks"] {
                        <List.Item
                            key={c["name"]}
                            icon={
                                <ThemeIcon color={"teal" if c["passed"] else "red"} size={16} radius="xl">
                                    {"✓" if c["passed"] else "✗"}
                                </ThemeIcon>
                            }
                        >
                            {words(c["name"])}
                        </List.Item>
                    }}
                </List>
            </Alert>
        }}

        <Divider />

        {#* The public broadcast is its own decision. Sending a crew is not the same act
            as putting a message on every phone in these divisions, and the second must
            never ride silently on the first. *#}
        <Card withBorder padding="sm" radius="md" bg={"orange.0" if publishAlerts else "var(--mantine-color-body)"}>
            <Checkbox
                checked={publishAlerts}
                onChange={lambda (e: ChangeEvent) { publishAlerts = e.target.checked; }}
                label={<Text size="sm" fw={600}>Also broadcast a public warning</Text>}
                description={
                    ("Trilingual bulletin to " + str(len(warned)) + " division(s): " + ", ".join(warned) + ". Published to /news and the alert channel.")
                    if len(warned) > 0 else "No divisions to warn."
                }
            />
        </Card>

        {#* A constraint typed as free text can name something that matches no live id,
            and the commander then gets an identical plan back with no hint why. These
            chips are the whole grammar, so the console cannot emit one that does nothing. *#}
        <Stack gap={6}>
            <Text size="xs" fw={600}>
                Constraint (on reject or modify)
            </Text>
            <Chip.Group multiple={True} value={tokens} onChange={lambda (v: list[str]) { tokens = v; }}>
                <Group gap={6}>
                    {for a in plan["assignments"] {
                        <Chip
                            key={"p-" + a["vehicle_id"]}
                            size="xs"
                            value={"forbid_pair:" + a["vehicle_id"] + ">" + a["cluster_id"]}
                        >
                            {"not " + a["vehicle_id"] + " → " + clusterPlace(view, a["cluster_id"])}
                        </Chip>
                    }}
                    {for cid in skipIds {
                        <Chip key={"c-" + cid} size="xs" color="orange" value={"exclude_cluster:" + cid}>
                            {"skip " + clusterPlace(view, cid)}
                        </Chip>
                    }}
                    {for v in view["vehicles"] {
                        <Chip key={"v-" + v["vehicle_id"]} size="xs" color="grape" value={"exclude_vehicle:" + v["vehicle_id"]}>
                            {"hold " + v["vehicle_id"]}
                        </Chip>
                    }}
                </Group>
            </Chip.Group>
        </Stack>

        {if plan["commander_constraints"] and plan["commander_constraints"].length > 0 {
            <Text size="xs" c="dimmed">
                {"Already applied to this plan: " + plan["commander_constraints"].join("; ")}
            </Text>
        }}

        {if not canAct {
            <Text size="xs" c="dimmed">
                You are signed in without commander authority, so you can read this plan but not authorise it.
            </Text>
        }}

        {#* The one irreversible act in the system must not be one unguarded click. This
            does not ask "are you sure"; it restates who is being sent where, which is
            what a commander is actually authorising. *#}
        <Modal opened={confirming} onClose={cancelConfirm} title="Commit these crews?" centered={True}>
            <Stack gap="sm">
                <Text size="sm">{"You are authorising " + str(len(plan["assignments"])) + " crew(s) into a flood zone:"}</Text>
                <Stack gap={4}>
                    {for a in plan["assignments"] {
                        <Text key={a["vehicle_id"]} size="sm">
                            <Text span={True} ff="monospace" fw={600}>{a["vehicle_id"]}</Text>
                            {" → " + clusterPlace(view, a["cluster_id"]) + " "}
                            <Text span={True} c="dimmed">
                                {"(" + str(a["load"]) + " people, ETA " + a["eta_minutes"].toFixed(0) + " min)"}
                            </Text>
                        </Text>
                    }}
                </Stack>
                {if publishAlerts {
                    <Text size="sm" c="orange.8">
                        {"A public warning will also be broadcast to " + str(len(warned)) + " division(s)."}
                    </Text>
                }}
                <Group grow={True}>
                    <Button variant="default" onClick={cancelConfirm}>
                        Cancel
                    </Button>
                    <Button color="teal" loading={sending} onClick={authorise}>
                        Authorise dispatch
                    </Button>
                </Group>
            </Stack>
        </Modal>

        <Group grow={True}>
            <Button color="teal" disabled={not canAct} loading={sending} onClick={approve}>
                Approve
            </Button>
            <Button color="blue" variant="light" disabled={not canAct} onClick={modify}>
                Modify
            </Button>
            <Button color="red" variant="light" disabled={not canAct} onClick={reject}>
                Reject
            </Button>
        </Group>
    </Stack>
}
