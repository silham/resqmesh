"""The public emergency report form.

Anyone with the URL can report in Sinhala, Tamil or English. The report goes through the
same endpoint the console operator uses, so it enters the loop, is geocoded and
de-duplicated exactly like a Telegram or radio report. No sign-in: in a flood you cannot
ask a caller to create an account.
"""

import from "@mantine/core" { Alert, Button, Card, Select, Stack, Text, Textarea, TextInput }
import from "@jac/runtime" { Link }
import from resqmesh.service.endpoints { submit_report }
import from .LocationPicker { LocationPicker }
import from ..lib.api { parseError }
import from .PublicShell { PublicShell, publicMessage }

glob PROMPTS: dict[str, dict[str, str]] = {
    "en": {
        "label": "What is happening, and where?",
        "placeholder": "e.g. Water is rising fast in Kolonnawa, an elderly couple is trapped on a roof.",
        "button": "Send report"
    },
    "si": {
        "label": "කුමක් සිදුවෙයිද, කොහේද?",
        "placeholder": "උදා: කොළොන්නාවේ ජලය වේගයෙන් ඉහළ යයි, වයෝවෘද්ධ යුවළක් වහලයක සිරවී ඇත.",
        "button": "වාර්තාව යවන්න"
    },
    "ta": {
        "label": "என்ன நடக்கிறது, எங்கே?",
        "placeholder": "எ.கா: கொலன்னாவையில் நீர் வேகமாக உயர்கிறது, முதியவர்கள் கூரையில் சிக்கியுள்ளனர்.",
        "button": "அறிக்கையை அனுப்பு"
    }
};

glob LANGUAGE_CHOICES: list[dict[str, str]] = [
    {"value": "en", "label": "English"},
    {"value": "si", "label": "සිංහල"},
    {"value": "ta", "label": "தமிழ்"}
];

def:pub ReportForm() -> JsxElement {
    has lang: str = "en";
    has body: str = "";
    has source: str = "";
    has reference: str = "";
    has error: str = "";
    has busy: bool = False;
    has fix: any = None;

    prompt = PROMPTS[lang];

    def pickLang(v: any) {
        lang = v if v else "en";
    }

    def editBody(e: ChangeEvent) {
        body = e.target.value;
    }

    def editSource(e: ChangeEvent) {
        source = e.target.value;
    }

    def moveFix(next: any) {
        fix = next;
    }

    def another(e: MouseEvent) {
        reference = "";
    }

    async def submit() -> None {
        if len(body.strip()) < 5 {
            error = "Please describe what is happening — a few words at least.";
            return;
        }
        busy = True;
        error = "";
        res: any = None;
        # Coordinates, when the reporter shared them, are what the crew actually drives
        # to. Without them the best the system can do is the centre of a division, which
        # may be kilometres away.
        lat: any = None;
        lon: any = None;
        accuracy: any = None;
        where: str = "none";
        if fix {
            lat = fix["lat"];
            lon = fix["lon"];
            accuracy = fix["accuracy_m"] if fix["accuracy_m"] or fix["accuracy_m"] == 0 else None;
            where = fix["location_source"];
        }
        who: any = source.strip() if source.strip() else None;
        try {
            res = await submit_report(body.strip(), lang, lat, lon, accuracy, where, who, "web_form");
            reference = res["command_id"];
            body = "";
            source = "";
            fix = None;
        } except Exception as e {
            # Never the raw server message: this reader is standing in the emergency, not
            # debugging it. Tell them whether it got through and what to do instead.
            error = publicMessage(
                parseError(e)["code"],
                "Could not send your report — the connection failed. Try again, and if this is life-threatening call 119 now."
            );
        }
        busy = False;
    }

    <PublicShell title="Report an emergency">
        {reference and (
            <Card withBorder={True} radius="md" padding="lg">
                <Stack gap="md">
                    <div>
                        <Text fw={700} size="lg" c="teal.8">
                            Report received
                        </Text>
                        <Text size="sm" c="dimmed">
                            It has reached the response team and is being located and prioritised now. Nobody will call you back on this page — if your situation worsens, call 119.
                        </Text>
                    </div>
                    <Card withBorder={True} radius="sm" padding="xs" bg="gray.0">
                        <Text size="xs" c="dimmed">
                            Keep this reference
                        </Text>
                        <Text size="sm" ff="monospace" fw={600}>
                            {reference}
                        </Text>
                    </Card>
                    <Button variant="light" color="teal" size="md" fullWidth={True} onClick={another}>
                        Report something else
                    </Button>
                    <Button variant="subtle" color="gray" size="md" fullWidth={True} component={Link} to="/news">
                        Read the latest bulletins
                    </Button>
                </Stack>
            </Card>
        )}
        {not reference and (
            <Card withBorder={True} radius="md" padding="lg">
                <Stack gap="md">
                    <Text size="sm" c="dimmed">
                        Tell the response team what you are seeing. If you can, name the place. You do not need an account.
                    </Text>
                    <Select label="Language" value={lang} onChange={pickLang} data={LANGUAGE_CHOICES} allowDeselect={False} />
                    <Textarea
                        label={prompt["label"]}
                        placeholder={prompt["placeholder"]}
                        value={body}
                        onChange={editBody}
                        minRows={4}
                        autosize={True}
                    />
                    <LocationPicker value={fix} onChange={moveFix} />
                    <TextInput
                        label="Your name or phone (optional)"
                        description="Stored only as a pseudonym; never shown to the public."
                        value={source}
                        onChange={editSource}
                    />
                    {error and (
                        <Alert color="red" variant="light">
                            {error}
                        </Alert>
                    )}
                    <Button color="red" size="lg" fullWidth={True} loading={busy} onClick={submit}>
                        {prompt["button"]}
                    </Button>
                </Stack>
            </Card>
        )}
    </PublicShell>
}
