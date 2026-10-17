"""Why a cluster ranks where it does: the rationale, then each scoring component with
the weight it carried."""

import from "@mantine/core" { Box, Group, Progress, Stack, Text }
import from .ConsoleHelpers { fixed, words }

def:pub ConsoleScoreBreakdown(item: any) -> JsxElement {
    comps: any = item["components"];
    weights: any = item["weights"];
    rows: list[str] = [k for k in Object.keys(comps) if k != "schema_version"];
    <Box pl="md" pt="xs" pb="sm">
        <Text size="xs" c="dimmed" mb={6}>
            {item["rationale_text"]}
        </Text>
        <Stack gap={6}>
            {for k in rows {
                <Group key={k} gap="xs" wrap="nowrap">
                    <Text size="xs" w={130} tt="capitalize">
                        {words(k)}
                    </Text>
                    <Progress value={comps[k] * 100} w={120} size="sm" />
                    <Text size="xs" ff="monospace">
                        {fixed(comps[k], 2)}
                    </Text>
                    <Text size="xs" c="dimmed">
                        {"× w" + fixed(weights[k], 2)}
                    </Text>
                </Group>
            }}
        </Stack>
    </Box>
}
