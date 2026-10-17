"""The words the reporters used.

Interrogating a ranking means seeing the evidence under it, not only the arithmetic over
it. The reports are in every incident view already; this lists the ones that make up a
cluster."""

import from "@mantine/core" { Box, Stack, Text }
import from .ConsoleHelpers { clockTime }

def:pub ConsoleEvidence(view: any, cluster: any) -> JsxElement {
    members: list[any] = [r for r in view["reports"] if r["report_id"] in cluster["member_report_ids"]];
    if len(members) == 0 {
        return <></>;
    }
    <Box mt="xs">
        <Text size="xs" fw={600} mb={4}>
            Evidence · {len(members)} report(s)
        </Text>
        <Stack gap={4}>
            {for r in members {
                <Box key={r["report_id"]} pl="xs" style={{"borderLeft": "2px solid var(--mantine-color-gray-3)"}}>
                    <Text size="xs">{r["description"]}</Text>
                    <Text size="xs" c="dimmed" ff="monospace">
                        {r["source_id"] + " · " + clockTime(r["observed_at"]) + (" · severity " + str(r["severity_claim"]) + "/4" if (r["severity_claim"] or r["severity_claim"] == 0) else "")}
                    </Text>
                </Box>
            }}
        </Stack>
    </Box>
}
