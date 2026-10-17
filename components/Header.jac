"""Top bar: incident identity and status, who is signed in, the Record drawer, and the
emergency halt, which is always reachable."""

import from "@mantine/core" { Badge, Button, Group, Modal, Stack, Text, Title }
import from resqmesh.service.endpoints { halt, resume }
import from ..lib.format { prettyStatus, statusColor }
import from .ConsoleHelpers { toastErr, toastOk }

def:pub Header(
    view: any,
    me: any,
    compact: bool,
    canAct: bool,
    refresh: Callable[[], None],
    onOpenRecords: Callable[[], None],
    onSignOut: Callable[[], None]
) -> JsxElement {
    has confirmHalt: bool = False;

    halted: bool = False;
    if view {
        halted = view["status"] == "halted";
    }
    size: str = "xs" if compact else "sm";

    async def doHalt() {
        confirmHalt = False;
        try {
            if halted {
                await resume();
                toastOk("Resumed");
            } else {
                await halt();
                toastOk("Halted — autonomy frozen");
            }
        } except Exception as e {
            toastErr(e);
        }
        refresh();
        setTimeout(lambda { refresh(); }, 1500);
    }

    def askHalt() {
        confirmHalt = True;
    }
    def keepRunning() {
        confirmHalt = False;
    }
    def haltOrResume() {
        if halted {
            doHalt();
        } else {
            confirmHalt = True;
        }
    }

    <Group justify="space-between" h="100%" px={"xs" if compact else "md"} wrap="nowrap">
        <Group gap={6 if compact else "sm"} wrap="nowrap" style={{"minWidth": 0}}>
            <Title order={5 if compact else 4} c="teal.7" style={{"whiteSpace": "nowrap"}}>
                ResQ-Mesh
            </Title>
            {if view {
                <Badge
                    color={statusColor(view["status"])}
                    variant="filled"
                    size={"sm" if compact else "lg"}
                    style={{"flexShrink": 0}}
                >
                    {prettyStatus(view["status"])}
                </Badge>
            }}
            {if view and not compact {
                # The goal is the one thing the commander actually states, and it is
                # the first thing this bar should show them.
                <Text size="sm" c="dimmed" truncate="end" title={view["goal"]} style={{"minWidth": 0}}>
                    {view["incident_id"] + " · " + view["goal"] + (" · working…" if view["busy"] else "")}
                </Text>
            }}
        </Group>

        <Group gap="xs" wrap="nowrap">
            {if me and not compact {
                <Text size="xs" c="dimmed" style={{"whiteSpace": "nowrap"}}>
                    {me["display_name"] + " · " + me["role"]}
                </Text>
            }}
            {#* In open mode the console signs itself in, so there is nothing to sign out of. *#}
            {if me and me["auth_mode"] != "open" {
                <Button variant="subtle" size={size} onClick={onSignOut}>
                    Sign out
                </Button>
            }}
            {if view {
                <Button variant="default" size={size} onClick={onOpenRecords}>
                    {"Log" if compact else "Record"}
                </Button>
            }}
            <Button
                color="red"
                size={size}
                variant={"light" if halted else "filled"}
                disabled={not canAct}
                onClick={haltOrResume}
            >
                {"Resume" if halted else ("Halt" if compact else "Emergency halt")}
            </Button>

            {#* Freezing the response mid-flood must not be a casual click, so it asks first. *#}
            <Modal opened={confirmHalt} onClose={keepRunning} title="Freeze the response?" centered={True}>
                <Stack gap="sm">
                    <Text size="sm">
                        All autonomous work stops: no ingest, no re-ranking, no re-planning. The incident
                        picture is kept and nothing is lost, but nothing moves until you resume.
                    </Text>
                    <Group grow={True}>
                        <Button variant="default" onClick={keepRunning}>
                            Keep running
                        </Button>
                        <Button color="red" onClick={doHalt}>
                            Halt now
                        </Button>
                    </Group>
                </Stack>
            </Modal>
        </Group>
    </Group>
}
