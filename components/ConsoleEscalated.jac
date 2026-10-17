"""The approval tab when the loop has stopped rather than asked.

"Nothing pending" and "the loop gave up" are different states. Telling a commander the
system is running autonomously while it has actually stopped is the most dangerous thing
this tab could say, so the escalation gets its own panel and its own way forward: a
constraint that makes the problem solvable."""

import from "@mantine/core" { Alert, Button, Stack, Text, TextInput }
import from resqmesh.service.endpoints { decide }
import from .ConsoleHelpers { clockTime, toastErr, toastOk, toastWarn, words }

def:pub ConsoleEscalated(view: any, canAct: bool, refresh: Callable[[], None]) -> JsxElement {
    has constraint: str = "";
    has sending: bool = False;
    esc: any = view["escalated"];

    async def resolve() {
        if not constraint.strip() {
            toastWarn("Add a constraint — an unchanged re-solve will fail the same way.");
            return;
        }
        sending = True;
        try {
            # A re-solve request is not a broadcast, so nothing is published.
            await decide("modified", esc["plan_version"], constraint, False);
            toastOk("Re-solving under your constraint");
        } except Exception as e {
            toastErr(e);
        }
        sending = False;
        refresh();
        setTimeout(lambda { refresh(); }, 1500);
    }

    <Stack gap="sm" p="md">
        <Alert color="red" variant="filled" title="Stopped — plan withheld">
            <Stack gap="xs">
                <Text size="sm">
                    The optimiser could not produce a plan that passes its safety checks. After{" "}
                    <b>{esc["rejections"]}</b> rejections the plan was withheld from you rather than shown.
                    <b> Nothing is being dispatched.</b>
                </Text>
                {if esc["violated_constraint"] {
                    <Text size="sm">
                        Failing check: <Text span={True} ff="monospace">{words(esc["violated_constraint"])}</Text>
                    </Text>
                }}
                {if esc["remediation_hint"] {
                    <Text size="sm">Suggested: {esc["remediation_hint"]}</Text>
                }}
                <Text size="xs">
                    {"Plan " + esc["plan_id"] + " v" + str(esc["plan_version"]) + " · since " + clockTime(esc["since"])}
                </Text>
            </Stack>
        </Alert>

        <Text size="sm" c="dimmed">
            Two ways forward: give the optimiser a constraint that makes the problem solvable, or halt
            while you work the incident by other means. New reports also unblock it — the budget resets
            when the queue is re-ranked.
        </Text>
        <TextInput
            label="Constraint for the re-solve"
            placeholder="exclude_cluster: CL-R-0007"
            value={constraint}
            onChange={lambda (e: ChangeEvent) { constraint = e.target.value; }}
            size="xs"
        />
        <Button color="blue" variant="light" disabled={not canAct} loading={sending} onClick={resolve}>
            Re-solve under this constraint
        </Button>
    </Stack>
}
