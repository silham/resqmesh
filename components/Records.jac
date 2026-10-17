"""The incident record drawer: the audit trail, situation reports, public bulletins, the
command log, device access and the provider chain.

None of this is what a commander watches between decisions. It is what they open when they
want to know why something happened, so it lives in a drawer rather than in the side panel.
Every write goes through the same path as the rest of the console: the server accepts it,
this drawer toasts the outcome and calls `onChanged` so the shell refreshes.
"""

import from "@mantine/core" { Alert, Badge, Button, Card, Drawer, Group, ScrollArea, Stack, Table, Tabs, Text }
import from resqmesh.service.endpoints { stand_down, issue_enrolment, list_devices, revoke_device }
import from ..lib.api { errorText, notifyError, notifyOk }
import from ..lib.format { divisionName }

glob TIER_COLOR: dict[str, str] = {"A": "gray", "B": "blue", "C": "yellow"};
glob COMMAND_COLOR: dict[str, str] = {"queued": "blue", "done": "teal", "failed": "red"};

"""A time of day for the audit trail; text that is not a timestamp is shown as it came."""
def when(iso: any) -> str {
    d: any = new(Date, iso);
    if Number.isNaN(d.getTime()) {
        return str(iso);
    }
    return d.toLocaleTimeString();
}

def stamp(iso: any) -> str {
    return new(Date, iso).toLocaleString();
}

"""Newest first, without touching the list the view owns."""
def newestFirst(items: any) -> list[any] {
    if not items {
        return [];
    }
    out: list[any] = [];
    for i in range(len(items) - 1, -1, -1) {
        out = out + [items[i]];
    }
    return out;
}

def TraceCells(e: any) -> JsxElement {
    <>
        <Table.Td ff="monospace">{when(e["occurred_at"])}</Table.Td>
        <Table.Td>
            <Text size="xs" fw={600}>
                {"HUMAN" if e["human_touch"] else e["agent"]}
            </Text>
        </Table.Td>
        <Table.Td>
            <Badge size="xs" color={TIER_COLOR[e["tier"]] or "gray"} variant="light">
                {e["tier"]}
            </Badge>
        </Table.Td>
        <Table.Td>
            <Text size="xs" fw={500}>
                {e["action"].replace("_", " ")}
            </Text>
            <Text size="xs" c="dimmed">
                {e["detail"]}
            </Text>
        </Table.Td>
    </>
}

def TraceRow(e: any) -> JsxElement {
    if e["human_touch"] {
        return <Table.Tr bg="yellow.0"><TraceCells e={e} /></Table.Tr>;
    }
    return <Table.Tr><TraceCells e={e} /></Table.Tr>;
}

"""The decision history, newest first. Human touches are marked, because the autonomy
claim is exactly "how much ran between them"."""
def AuditTrail(view: any) -> JsxElement {
    events: list[any] = newestFirst(view["trace"]);

    <Table striped={True} highlightOnHover={True} stickyHeader={True} fz="xs">
        <Table.Thead>
            <Table.Tr>
                <Table.Th w={70}>Time</Table.Th>
                <Table.Th w={54}>Agent</Table.Th>
                <Table.Th w={40}>Tier</Table.Th>
                <Table.Th>What happened</Table.Th>
            </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
            {for e in events {
                <TraceRow key={e["event_id"]} e={e} />
            }}
        </Table.Tbody>
    </Table>
}

"""Situation reports, with the hash chain that makes silent revision detectable."""
def Sitreps(view: any) -> JsxElement {
    has busy: str = "";

    # The PDF is a plain download endpoint, not a call, so a bare link would not carry the
    # session. It is fetched with the session token (kept by the runtime in local storage)
    # and handed to the browser as a file.
    async def download(sitrepId: str) {
        busy = sitrepId;
        token: any = None;
        try {
            token = localStorage.getItem("jac_token");
        } except Exception {
            token = None;
        }
        headers: dict[str, str] = {};
        if token {
            headers["Authorization"] = "Bearer " + token;
        }
        res: any = None;
        blob: any = None;
        try {
            res = await fetch("/sitreps/" + encodeURIComponent(sitrepId) + "/pdf", {"headers": headers});
            if res.ok {
                blob = await res.blob();
                globals: any = window;
                url: any = globals.URL.createObjectURL(blob);
                link: any = document.createElement("a");
                link.href = url;
                link.setAttribute("download", sitrepId + ".pdf");
                link.click();
                globals.URL.revokeObjectURL(url);
            } else {
                notifyError({"message": "HTTP " + str(res.status)}, "Could not open " + sitrepId);
            }
        } except Exception as e {
            notifyError(e, "Could not open " + sitrepId);
        }
        busy = "";
    }

    reports: list[any] = newestFirst(view["sitreps"]);

    <>
        {if len(reports) == 0 {
            <Text size="sm" c="dimmed">
                No situation report published yet. The first is written when a plan is approved.
            </Text>
        }}
        <Stack gap="sm">
            {for s in reports {
                <Card key={s["sitrep_id"]} withBorder={True} radius="md" padding="sm">
                    <Group justify="space-between" wrap="nowrap" mb={6}>
                        <div>
                            <Text size="sm" fw={600}>
                                {s["sitrep_id"]}
                            </Text>
                            <Text size="xs" c="dimmed">
                                {stamp(s["generated_at"]) + " · " + str(s["claims"].length) + " sourced claim(s) · " + s["hazard_method"]}
                            </Text>
                        </div>
                        <Button size="xs" variant="light" loading={busy == s["sitrep_id"]} onClick={lambda { download(s["sitrep_id"]); }}>
                            Open PDF
                        </Button>
                    </Group>
                    {if s["degraded_notice"] {
                        <Alert color="orange" variant="light" p="xs" mb={6}>
                            <Text size="xs">{s["degraded_notice"]}</Text>
                        </Alert>
                    }}
                    <Stack gap={2}>
                        {for (i, c) in enumerate(s["claims"]) {
                            <Text key={i} size="xs">
                                {c["sentence"] + " "}
                                <Text span={True} c="dimmed" ff="monospace">
                                    {"[" + c["source_ref"] + "]"}
                                </Text>
                            </Text>
                        }}
                    </Stack>
                    <Text size="xs" c="dimmed" ff="monospace" mt={6}>
                        {"hash " + s["hash"].slice(0, 12) + (" ← " + s["prev_hash"].slice(0, 12) if s["prev_hash"] else " (first in chain)")}
                    </Text>
                </Card>
            }}
        </Stack>
    </>
}

"""The division names a bulletin went to, as one comma-separated phrase."""
def placeNames(view: any, ids: any) -> str {
    names: list[str] = [];
    for gn in ids {
        names = names + [divisionName(view, gn)];
    }
    return ", ".join(names);
}

"""What went out to the public, under whose authority, and how to take it back."""
def Alerts(view: any, canStandDown: bool, onChanged: Callable[[], None]) -> JsxElement {
    has standing: str = "";

    async def standDown(alertId: str) {
        standing = alertId;
        try {
            await stand_down(alertId);
            notifyOk("Stood down — the all-clear goes out to the same areas.");
            onChanged();
        } except Exception as e {
            notifyError(e);
        }
        standing = "";
    }

    alerts: list[any] = newestFirst(view["alerts"]);

    <>
        {if len(alerts) == 0 {
            <Text size="sm" c="dimmed">
                Nothing has been broadcast. A public warning goes out only when you tick it at the approval gate — approving a dispatch does not publish one.
            </Text>
        }}
        <Stack gap="sm">
            {for a in alerts {
                <Card key={a["alert_id"]} withBorder={True} radius="md" padding="sm">
                    <Group justify="space-between" mb={4}>
                        <Badge size="sm" color="red" variant="light">
                            {a["template_id"].replace("_", " ")}
                        </Badge>
                        <Text size="xs" c="dimmed">
                            {stamp(a["issued_at"])}
                        </Text>
                    </Group>
                    <Text size="xs" c="dimmed" mb={4}>
                        {"To " + placeNames(view, a["target_gn_ids"]) + " · under approval "}
                        <Text span={True} ff="monospace">{a["approval_id"]}</Text>
                    </Text>
                    <Text size="sm">{a["text_en"]}</Text>
                    <Text size="sm">{a["text_si"]}</Text>
                    <Text size="sm">{a["text_ta"]}</Text>
                    <Group justify="space-between" mt="xs" wrap="nowrap">
                        <Text size="xs" c="dimmed">
                            {("Expires " + stamp(a["expires_at"])) if a["expires_at"] else "No expiry"}
                        </Text>
                        {#* Telling people it is over is not a lesser act than telling them to
                            leave, so it is a deliberate button, and a commander's alone. *#}
                        {if canStandDown and a["template_id"] != "stand_down" {
                            <Button
                                size="compact-xs"
                                variant="light"
                                color="orange"
                                loading={standing == a["alert_id"]}
                                onClick={lambda { standDown(a["alert_id"]); }}
                            >
                                Stand down
                            </Button>
                        }}
                    </Group>
                </Card>
            }}
        </Stack>
    </>
}

"""Every write is accepted first, so this is where a command's real outcome shows up."""
def Commands(view: any) -> JsxElement {
    commands: any = view["commands"] or [];

    <Stack gap={4}>
        <Text size="xs" c="dimmed" mb={4}>
            Every action is accepted first and executed by the incident worker. A command that failed after being accepted shows here — and nowhere else.
        </Text>
        {if commands.length == 0 {
            <Text size="sm" c="dimmed">Nothing submitted yet.</Text>
        }}
        {for c in commands {
            <Group key={c["command_id"]} gap="xs" wrap="nowrap" align="flex-start">
                <Badge size="xs" color={COMMAND_COLOR[c["status"]] or "gray"} variant="light" w={58}>
                    {c["status"]}
                </Badge>
                <div style={{"minWidth": 0}}>
                    <Text size="xs" fw={500}>
                        {c["kind"] + " · "}
                        <Text span={True} ff="monospace" c="dimmed">{c["command_id"]}</Text>
                    </Text>
                    {if c["detail"] {
                        <Text size="xs" c="red">
                            {c["detail"]}
                        </Text>
                    }}
                </div>
            </Group>
        }}
    </Stack>
}

"""Which language-model providers are answering, and which have tripped out."""
def System(view: any) -> JsxElement {
    llm: any = view["llm"];

    <Stack gap="sm">
        <div>
            <Text size="sm" fw={600}>
                Extraction providers
            </Text>
            <Text size="xs" c="dimmed">
                {"Chain order: " + (llm["chain"].join(" → ") or "none") + ". Every number that reaches a decision is computed, never generated, so a provider outage degrades extraction quality and nothing else."}
            </Text>
        </div>
        {for p in llm["providers"] {
            <Group key={p["provider"]} justify="space-between">
                <Text size="sm">{p["provider"]}</Text>
                <Group gap="xs">
                    {if p["vision"] {
                        <Badge size="xs" variant="light">vision</Badge>
                    }}
                    <Badge size="xs" color={"red" if p["circuit_open"] else "teal"} variant="light">
                        {("circuit open (" + str(p["consecutive_failures"]) + " failures)") if p["circuit_open"] else "ready"}
                    </Badge>
                </Group>
            </Group>
        }}
        {if llm["skipped"].length > 0 {
            <Alert color="gray" variant="light" p="xs">
                <Text size="xs">{"Skipped: " + llm["skipped"].join("; ")}</Text>
            </Alert>
        }}
    </Stack>
}

"""Issue a dispatch link for a crew, and revoke a device that is gone.

Losing a phone is the normal case in this domain, not an edge one, which is why the
revoke list is here rather than in a config file. Devices are keyed by account name."""
def Access(view: any, me: any, onChanged: Callable[[], None]) -> JsxElement {
    has devices: any = None;
    has loadError: str = "";
    has issued: any = None;
    has revoking: str = "";

    async def load() {
        got: any = None;
        try {
            got = await list_devices();
            devices = got;
            loadError = "";
        } except Exception as e {
            loadError = errorText(e);
        }
    }

    async can with entry {
        await load();
    }

    async def issue(vehicleId: str) {
        code: any = None;
        try {
            code = await issue_enrolment(vehicleId);
            issued = {
                "vehicle_id": vehicleId,
                "link": window.location.origin + "/responder?c=" + encodeURIComponent(code["code"])
            };
            await load();
            onChanged();
        } except Exception as e {
            notifyError(e);
        }
    }

    async def revoke(username: str) {
        revoking = username;
        try {
            await revoke_device(username);
            notifyOk("Access revoked for " + username + ".");
            await load();
            onChanged();
        } except Exception as e {
            notifyError(e);
        }
        revoking = "";
    }

    live: list[any] = [];
    if devices {
        for d in devices {
            if not d["disabled"] {
                live = live + [d];
            }
        }
    }

    <Stack gap="md">
        <div>
            <Text size="sm" fw={600}>
                Dispatch links
            </Text>
            <Text size="xs" c="dimmed">
                One link per call sign. It works once: opening it binds that device to the vehicle, and the link is dead afterwards, so a copy left in a browser history or a screenshot is not a key.
            </Text>
        </div>
        <Group gap="xs">
            {for v in view["vehicles"] {
                <Button key={v["vehicle_id"]} size="compact-xs" variant="light" onClick={lambda { issue(v["vehicle_id"]); }}>
                    {v["vehicle_id"]}
                </Button>
            }}
        </Group>
        {if issued {
            <Alert color="teal" variant="light" p="xs">
                <Text size="xs" fw={600}>
                    {"Link for " + issued["vehicle_id"] + " — send it to the crew now, it expires in 2 hours"}
                </Text>
                <Text size="xs" ff="monospace" style={{"wordBreak": "break-all"}}>
                    {issued["link"]}
                </Text>
            </Alert>
        }}

        <div>
            <Text size="sm" fw={600}>
                Signed-in devices
            </Text>
            <Text size="xs" c="dimmed">
                Revoking switches that account off and rotates its password, so nothing issued before still works. Other accounts are untouched.
            </Text>
        </div>
        {if loadError {
            <Text size="sm" c="red">{loadError}</Text>
        }}
        {if devices and len(live) == 0 {
            <Text size="sm" c="dimmed">Nothing signed in.</Text>
        }}
        {for d in live {
            <Group key={d["username"]} justify="space-between" wrap="nowrap">
                <div style={{"minWidth": 0}}>
                    <Text size="sm">{d["display_name"] or d["username"]}</Text>
                    <Text size="xs" c="dimmed">
                        {d["username"] + " · " + d["role"] + " · " + (d["label"] or "unlabelled") + " · since " + stamp(d["created_at"])}
                    </Text>
                </div>
                {#* A commander cannot revoke the account they are using; the server refuses,
                    so the button is not offered. *#}
                {if d["username"] != me["username"] {
                    <Button
                        size="compact-xs"
                        color="red"
                        variant="light"
                        loading={revoking == d["username"]}
                        onClick={lambda { revoke(d["username"]); }}
                    >
                        Revoke
                    </Button>
                }}
            </Group>
        }}
    </Stack>
}

def:pub Records(
    view: any,
    me: any,
    opened: bool,
    onClose: Callable[[], None],
    onChanged: Callable[[], None]
) -> JsxElement {
    isCommander: bool = False;
    if me {
        isCommander = me["role"] == "commander";
    }

    <Drawer opened={opened} onClose={onClose} position="right" size="xl" title="Incident record">
        <Tabs defaultValue="audit" keepMounted={False}>
            <Tabs.List>
                <Tabs.Tab value="audit">Audit trail</Tabs.Tab>
                <Tabs.Tab value="sitreps">SITREPs</Tabs.Tab>
                <Tabs.Tab value="alerts">Bulletins</Tabs.Tab>
                <Tabs.Tab value="commands">Commands</Tabs.Tab>
                {if isCommander {
                    <Tabs.Tab value="access">Access</Tabs.Tab>
                }}
                <Tabs.Tab value="system">System</Tabs.Tab>
            </Tabs.List>
            <ScrollArea h="calc(100dvh - 140px)" pt="sm">
                <Tabs.Panel value="audit"><AuditTrail view={view} /></Tabs.Panel>
                <Tabs.Panel value="sitreps"><Sitreps view={view} /></Tabs.Panel>
                <Tabs.Panel value="alerts"><Alerts view={view} canStandDown={isCommander} onChanged={onChanged} /></Tabs.Panel>
                <Tabs.Panel value="commands"><Commands view={view} /></Tabs.Panel>
                {if isCommander {
                    <Tabs.Panel value="access"><Access view={view} me={me} onChanged={onChanged} /></Tabs.Panel>
                }}
                <Tabs.Panel value="system"><System view={view} /></Tabs.Panel>
            </ScrollArea>
        </Tabs>
    </Drawer>
}
