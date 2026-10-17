"""The public front door, shown at `/` and for any path that matches no page.

Most visitors arrive to report an emergency or to read a warning, so those two actions are
prominent and the two operational views (responder, commander) are quiet links underneath.
It is built for a phone held by someone frightened: one column, full-width targets, and the
two numbers that outrank this whole system at the top as links that dial on a tap.
"""

import from "@mantine/core" { Anchor, Button, Card, Group, Stack, Text, Title }
import from "@jac/runtime" { Link }
import from .PublicShell { EMERGENCY_NUMBERS, PublicShell }

def PublicAction(href: str, title: str, detail: str, cta: str, color: str, variant: str = "filled") -> JsxElement {
    # The whole card is the target, not just the button: a small button is a poor thing
    # to ask a wet hand to hit.
    <Card withBorder={True} radius="md" padding="lg" component={Link} to={href} style={{"textDecoration": "none"}}>
        <Stack gap="sm">
            <div>
                <Text fw={700} size="lg">
                    {title}
                </Text>
                <Text size="sm" c="dimmed">
                    {detail}
                </Text>
            </div>
            {#* Full width and below the text rather than beside it: beside it, the
                description squeezed the button and clipped its label on a narrow phone. *#}
            <Button color={color} variant={variant} component="span" size="md" fullWidth={True}>
                {cta}
            </Button>
        </Stack>
    </Card>
}

def:pub PublicLanding() -> JsxElement {
    <PublicShell title="Kelani basin flood response">
        <Stack gap="lg">
            <div>
                <Title order={2} fz={{"base": 24, "sm": 28}}>
                    Emergency response
                </Title>
                <Text size="sm" c="dimmed" mt={4}>
                    Report what is happening, or read the latest warnings.
                </Text>
            </div>

            {#* Above the two actions, because this page must never be the reason
                somebody delayed calling. *#}
            <Card withBorder={True} radius="md" padding="md" bg="red.0" style={{"borderColor": "var(--mantine-color-red-3)"}}>
                <Text size="sm" fw={600} c="red.9" mb={6}>
                    Life-threatening emergency? Call first.
                </Text>
                <Group gap="xs" wrap="wrap">
                    {for e in EMERGENCY_NUMBERS {
                        <Button key={e["number"]} component="a" href={"tel:" + e["number"]} color="red" variant="filled" size="sm">
                            {e["number"] + " · " + e["who"]}
                        </Button>
                    }}
                </Group>
            </Card>

            <PublicAction
                href="/report"
                title="Report an emergency"
                detail="Flood, someone trapped, a blocked road — in Sinhala, Tamil or English. No account needed."
                cta="Report an emergency"
                color="red"
            />

            <PublicAction
                href="/news"
                title="Emergency bulletins"
                detail="The latest approved warnings, newest first, in Sinhala, Tamil and English."
                cta="Read the bulletins"
                color="teal"
                variant="light"
            />

            <Group justify="center" gap="lg" mt="sm" wrap="wrap">
                <Anchor component={Link} to="/responder" c="dimmed" size="sm">
                    Responder dispatch →
                </Anchor>
                <Anchor component={Link} to="/console" c="dimmed" size="sm">
                    Commander console →
                </Anchor>
            </Group>
        </Stack>
    </PublicShell>
}
