"""The public bulletin feed.

Anyone with the URL can read the emergency bulletins the commander has approved, newest
first, each stamped with the time it was issued: the web channel for how an alert reaches
people, alongside the Telegram push. Read-only, and it only ever shows alerts that are
already public, never drafts or internal state.
"""

import from "react" { useEffect }
import from "@mantine/core" { Alert, Badge, Button, Card, Group, Loader, SegmentedControl, Stack, Text }
import from "@jac/runtime" { Link }
import from resqmesh.service.endpoints { public_alerts }
import from ..lib.api { parseError }
import from .PublicShell { PublicShell, publicMessage }

glob POLL_MS: int = 5000;

# Three languages stacked on every card is worse for all three audiences than a selector.
# The choice is remembered in the address, so a Tamil reader can send the page to another
# Tamil reader and have it arrive in Tamil.
glob LANGS: list[dict[str, str]] = [
    {"value": "en", "label": "English"},
    {"value": "si", "label": "සිංහල"},
    {"value": "ta", "label": "தமிழ்"}
];

# A stand-down is good news and must not read like another warning.
glob STAND_DOWN_HEADING: dict[str, str] = {
    "en": "All clear",
    "si": "අනතුරු ඇඟවීම ඉවත් කර ඇත",
    "ta": "எச்சரிக்கை நீக்கப்பட்டது"
};

"""The language to open in: the address first, then the browser's own preference."""
def initialLang() -> str {
    query: any = new(URLSearchParams, window.location.search);  # jac:ignore[E1053]
    fromUrl: any = query.get("lang");
    if fromUrl == "si" or fromUrl == "ta" or fromUrl == "en" {
        return fromUrl;
    }
    # Following the browser is usually right and costs the reader nothing.
    prefs: any = navigator.languages if navigator.languages else [navigator.language];
    for p in prefs {
        if p and p.startsWith("si") {
            return "si";
        }
        if p and p.startsWith("ta") {
            return "ta";
        }
    }
    return "en";
}

def textFor(alert: any, lang: str) -> str {
    if lang == "si" {
        return alert["text_si"];
    }
    if lang == "ta" {
        return alert["text_ta"];
    }
    return alert["text_en"];
}

def headingFor(alert: any, lang: str) -> str {
    if alert["template_id"] == "stand_down" {
        return STAND_DOWN_HEADING[lang];
    }
    return str(alert["template_id"]).replace("_", " ");
}

def issuedMs(alert: any) -> float {
    return new(Date, alert["issued_at"]).getTime();
}

"""Local time, so a resident reads it in their own timezone."""
def whenIssued(iso: str) -> str {
    d: any = new(Date, iso);
    if Number.isNaN(d.getTime()) {
        return iso;
    }
    return d.toLocaleString([], {"dateStyle": "medium", "timeStyle": "short"});
}

def:pub NewsFeed() -> JsxElement {
    has lang: str = initialLang();
    has alerts: list[any] = [];
    has loading: bool = True;
    has failure: any = None;

    # Approved bulletins only, no sign-in, none of the tactical picture. An incident with
    # nothing to announce returns an empty list, not an error. The nonce keeps the
    # client's response cache from answering a poll with a stale list.
    async def load() -> None {
        got: any = None;
        try {
            got = await public_alerts(int(Date.now()));
            alerts = sorted(got, key=issuedMs, reverse=True);
            failure = None;
        } except Exception as e {
            failure = e;
        }
        loading = False;
    }

    useEffect(lambda {
        load();
        timer = setInterval(lambda { load(); }, POLL_MS);
        return lambda { clearInterval(timer); };
    }, []);

    def pickLang(v: str) {
        lang = v;
        url: any = new(URL, window.location.href);  # jac:ignore[E1053]
        url.searchParams.set("lang", v);
        window.history.replaceState({}, "", url);
    }

    <PublicShell title="Emergency bulletins">
        <Stack gap="md">
            <SegmentedControl value={lang} onChange={pickLang} data={LANGS} fullWidth={True} />
            {loading and <Loader />}
            {failure and (
                <Alert color="red" variant="light">
                    {publicMessage(
                        parseError(failure)["code"],
                        "Cannot reach the bulletin server. Warnings may exist that this page cannot show — if this is life-threatening, call 119."
                    )}
                </Alert>
            )}
            {not loading and not failure and len(alerts) == 0 and (
                <Card withBorder={True} radius="md" padding="lg">
                    <Stack gap="sm">
                        <div>
                            <Text fw={600}>No active bulletins</Text>
                            <Text size="sm" c="dimmed">
                                There are no emergency warnings in force right now. This page updates itself — no bulletin here does not mean an area is safe, only that none has been issued.
                            </Text>
                        </div>
                        <Button variant="light" color="red" size="md" fullWidth={True} component={Link} to="/report">
                            Report an emergency
                        </Button>
                    </Stack>
                </Card>
            )}

            {for a in alerts {
                <Card key={a["alert_id"]} withBorder={True} radius="md" padding="lg">
                    <Stack gap="xs">
                        <Group justify="space-between">
                            <Badge color={"teal" if a["template_id"] == "stand_down" else "red"} variant="light">
                                {headingFor(a, lang)}
                            </Badge>
                            <Text size="xs" c="dimmed">
                                {whenIssued(a["issued_at"])}
                            </Text>
                        </Group>
                        {a["slots"] and a["slots"]["area"] and (
                            <Text fw={700} size="lg">
                                {a["slots"]["area"]}
                            </Text>
                        )}
                        <Text size="sm">{textFor(a, lang)}</Text>
                    </Stack>
                </Card>
            }}
            {len(alerts) > 0 and (
                <Button variant="light" color="red" size="md" fullWidth={True} component={Link} to="/report">
                    Report an emergency
                </Button>
            )}
        </Stack>
    </PublicShell>
}
