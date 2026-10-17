"""Shown when no incident is open yet. This is the commander's starting point on a live
run: state the objective once, and everything after it is the system's own decision. With
the demo switched on the incident is opened for you; without it, this is where a real
operation begins."""

import from "@mantine/core" { Button, Card, Center, Stack, Text, Textarea }
import from resqmesh.service.endpoints { open_incident }
import from .ConsoleHelpers { toastErr, toastOk, toastWarn }

glob DEFAULT_GOAL: str = "coordinate the response to flooding in the Kelani basin";

def:pub OpenIncident(me: any, canAct: bool, refresh: Callable[[], None]) -> JsxElement {
    has goal: str = DEFAULT_GOAL;
    has opening: bool = False;

    async def submit() {
        text: str = goal.strip();
        if len(text) < 8 {
            toastWarn("State a goal for the incident.");
            return;
        }
        opening = True;
        try {
            await open_incident(text);
            toastOk("Incident opened. Reports will flow into the loop.");
            refresh();
            # The writer takes a moment to open it; ask again in case the first read was early.
            setTimeout(lambda { refresh(); }, 3000);
        } except Exception as e {
            toastErr(e);
        }
        opening = False;
    }

    <Center h="100%" p="md">
        <Card withBorder radius="md" padding="xl" style={{"maxWidth": 520}}>
            <Stack gap="md">
                <div>
                    <Text fw={700} size="lg">
                        No incident open
                    </Text>
                    <Text size="sm" c="dimmed">
                        State one objective. The system then perceives, reasons and plans on its own, stopping
                        only to ask you before it commits a crew. Reports arrive from <Text span={True} ff="monospace">/report</Text>,
                        the Telegram bot, or an operator.
                    </Text>
                </div>
                <Textarea
                    label="Incident goal"
                    value={goal}
                    onChange={lambda (e: ChangeEvent) { goal = e.target.value; }}
                    minRows={2}
                    autosize={True}
                />
                {if not canAct {
                    <Text size="xs" c="dimmed">
                        {"You are signed in as " + (me["role"] if me else "a reader") + ", and only a commander can open an incident."}
                    </Text>
                }}
                <Button color="teal" size="md" loading={opening} disabled={not canAct} onClick={submit}>
                    Open incident
                </Button>
            </Stack>
        </Card>
    </Center>
}
