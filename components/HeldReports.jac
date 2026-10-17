"""Reports the gazetteer could not place.

The ingest step holds these rather than guessing, which is the right call: a confidently
invented location is the one hallucination that could kill someone. But a queue nobody can
see means "held, never dropped" reads as "dropped" from the commander's chair. These are
people who reported an emergency and whose report has reached nobody.

An operator who recognises the place can put a pin on it. That is recorded as an
attributed judgement beside the report, never written into it: the report keeps the words
it arrived with, and re-submitting it with coordinates attached would manufacture a second
source, letting one person's report corroborate itself past the dispatch floor."""

import from "@mantine/core" { Alert, Badge, Button, Card, Group, Modal, Stack, Text }
import from resqmesh.service.endpoints { place_report }
import from ..lib.format { prettyHazard }
import from .ConsoleHelpers { clockTime, toastErr, toastOk }
import from .LocationPicker { LocationPicker }

def:pub HeldReports(view: any, canAct: bool, refresh: Callable[[], None]) -> JsxElement {
    has placing: any = None;
    has fix: any = None;
    has saving: bool = False;

    def closeModal() {
        placing = None;
        fix = None;
    }

    # One handler per card; see the note in TriageQueue on handlers built inside a loop.
    def placeFor(id: any) -> any {
        return lambda { placing = id; };
    }

    async def place() {
        if not placing or not fix {
            return;
        }
        saving = True;
        reportId = placing;
        try {
            await place_report(reportId, fix["lat"], fix["lon"]);
            toastOk(reportId + " placed — it will enter the queue on the next pass.");
            closeModal();
            refresh();
        } except Exception as e {
            toastErr(e);
        }
        saving = False;
    }

    if len(view["unresolved"]) == 0 {
        return <Text size="sm" c="dimmed" p="md">
            Nothing held. Every report so far resolved to a real division.
        </Text>;
    }

    <Stack gap="xs" p="xs">
        <Alert color="orange" variant="light" p="xs">
            <Text size="xs">
                {len(view["unresolved"])} report(s) name a place the gazetteer could not match, so they are
                not on the map and not in the queue. They are held rather than guessed at: a dispatch to an
                invented location is the failure this system refuses to risk. If you recognise the place,
                put a pin on it and the report enters the queue like any other.
            </Text>
        </Alert>
        {for r in view["unresolved"] {
            reportId = r["report_id"];
            <Card key={reportId} withBorder radius="md" padding="sm">
                <Group justify="space-between" wrap="nowrap" mb={2}>
                    <Badge size="xs" variant="light">
                        {prettyHazard(r["hazard_type"])}
                    </Badge>
                    <Text size="xs" c="dimmed">
                        {clockTime(r["observed_at"])}
                    </Text>
                </Group>
                <Text size="sm">{r["description"]}</Text>
                {if r["raw_place_text"] {
                    <Text size="xs" c="dimmed" mt={2}>
                        Said the place was: <b>{r["raw_place_text"]}</b> — no match
                    </Text>
                }}
                <Group justify="space-between" mt={4} wrap="nowrap">
                    <Text size="xs" c="dimmed" ff="monospace">
                        {reportId + " · " + r["source_id"]}
                    </Text>
                    <Button
                        size="compact-xs"
                        variant="light"
                        disabled={not canAct}
                        onClick={placeFor(reportId)}
                    >
                        Place on map
                    </Button>
                </Group>
            </Card>
        }}
        <Modal
            opened={bool(placing)}
            onClose={closeModal}
            title={"Place " + (placing or "")}
            centered={True}
            size="lg"
        >
            <Stack gap="sm">
                <Text size="sm">
                    Put the pin where you believe this report is. It is recorded as your judgement, with your
                    account and the time, beside the report rather than inside it.
                </Text>
                <LocationPicker value={fix} onChange={lambda (f: any) { fix = f; }} />
                <Group grow={True}>
                    <Button variant="default" onClick={closeModal}>
                        Cancel
                    </Button>
                    <Button color="teal" disabled={not fix} loading={saving} onClick={place}>
                        Place report
                    </Button>
                </Group>
            </Stack>
        </Modal>
    </Stack>
}
