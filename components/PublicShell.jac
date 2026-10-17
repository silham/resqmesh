"""The frame shared by every public page: a slim header, one centred column and the
emergency numbers underneath.

It is deliberately small. A member of the public reaches these pages from a phone, often
on a poor connection, so the commander console's map and polling do not belong here.
"""

import from "@mantine/core" { Anchor, AppShell, Group, Title }
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

def:pub PublicShell(title: str, subtitle: str = "", children: any = None) -> JsxElement {
    <AppShell header={{"height": 60}} padding={0} className="crisis-app public-app">
        <AppShell.Header>
            <Group h="100%" px="md" justify="space-between" wrap="nowrap" gap="sm" className="crisis-header">
                <Anchor component={Link} to="/" underline="never" className="crisis-brand" aria-label="ResQ-Mesh home">
                    <Title order={4}>ResQ-Mesh</Title>
                    <span>EMERGENCY RESPONSE</span>
                </Anchor>
                <nav className="public-nav" aria-label="Public pages">
                    <Link to="/report">Report</Link>
                    <Link to="/news">Bulletins</Link>
                </nav>
            </Group>
        </AppShell.Header>
        <AppShell.Main className="public-main">
            {#* On every public page, not only the landing page: somebody who opened the
                report form and realised it is worse than they thought should not have to
                navigate back to find the number. Above the page itself, because no page
                here may be the reason somebody delayed calling. *#}
            <div className="public-emergency" role="note">
                <span>Life-threatening emergency? Call first.</span>
                <span className="public-emergency-calls">
                    {for e in EMERGENCY_NUMBERS {
                        <a key={e["number"]} href={"tel:" + e["number"]} aria-label={"Call " + e["who"] + " on " + e["number"]}>
                            <strong>{e["number"]}</strong>{" " + e["who"]}
                        </a>
                    }}
                </span>
            </div>
            <div className="public-column">
                <div className="public-heading">
                    <h1>{title}</h1>
                    {subtitle and <p>{subtitle}</p>}
                </div>
                {children}
                <footer className="public-footer">
                    <Link to="/responder">Responder dispatch</Link>
                    <Link to="/console">Commander console</Link>
                </footer>
            </div>
        </AppShell.Main>
    </AppShell>
}
