"""The frame shared by every public page: a slim header, one centred column and the
emergency numbers underneath.

It is deliberately small. A member of the public reaches these pages from a phone, often
on a poor connection, so the commander console's map and polling do not belong here.
"""

import from "@mantine/core" { Anchor, AppShell, Group, Text }
import from "@jac/runtime" { Link }

"""The two numbers that outrank this whole system. Tappable, because this is a phone."""
glob:pub EMERGENCY_NUMBERS: list[dict[str, str]] = [
    {"number": "119", "who": "Police"},
    {"number": "1990", "who": "Suwa Seriya ambulance"}
];

"""What to tell a member of the public when a call fails. `code` is the refusal word
`parseError(e)["code"]` gives (empty when the server was not reached).

A raw server message in front of someone standing in a flood tells them nothing they can
act on and reads as if the system is broken. What they need is whether their emergency got
through and what to do instead, which is the same answer whatever went wrong. The one
exception is "no incident is open", which has its own wording."""
def:pub publicMessage(code: str, fallback: str) -> str {
    if code == "not_found" {
        return "The response team has not opened an incident for this area yet. If this is life-threatening, call 119 now.";
    }
    return fallback;
}

def:pub PublicShell(title: str, children: any = None) -> JsxElement {
    <AppShell header={{"height": 56}} padding="md">
        <AppShell.Header>
            <Group h="100%" px="md" justify="space-between" wrap="nowrap" gap="sm">
                <Anchor component={Link} to="/" fw={700} c="teal" underline="never" style={{"flexShrink": 0}}>
                    ResQ-Mesh
                </Anchor>
                <Text size="sm" c="dimmed" truncate={True}>
                    {title}
                </Text>
            </Group>
        </AppShell.Header>
        <AppShell.Main>
            <div style={{"maxWidth": 560, "margin": "0 auto"}}>
                {children}
                {#* On every public page, not only the landing page: somebody who opened the
                    report form and realised it is worse than they thought should not have
                    to navigate back to find the number. *#}
                <Group justify="center" gap="xs" mt="xl" mb="md" wrap="wrap">
                    <Text size="xs" c="dimmed">
                        Life-threatening emergency?
                    </Text>
                    {for e in EMERGENCY_NUMBERS {
                        <Anchor key={e["number"]} href={"tel:" + e["number"]} size="xs" fw={700} c="red.7">
                            Call {e["number"]}
                        </Anchor>
                    }}
                </Group>
            </div>
        </AppShell.Main>
    </AppShell>
}
