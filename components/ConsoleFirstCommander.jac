"""Create the first commander, once, against the setup code in the server log.

Somebody has to be first, and it cannot be an ordinary call: an endpoint that mints
commanders is the largest hole there is. The authority stays with whoever can see the
process's output. The server prints a setup code at startup while the account store has
no commander, and both the code and the emptiness are required. The first account through
closes the door."""

import from "@mantine/core" { Alert, Button, Card, Center, PasswordInput, Stack, Text, TextInput, Title }
import from resqmesh.service.endpoints { bootstrap }
import from ..lib.api { parseError }
import from .ConsoleHelpers { tryLogin }

def:pub ConsoleFirstCommander(onSignedIn: Callable[[], None]) -> JsxElement {
    has code: str = "";
    has username: str = "";
    has displayName: str = "";
    has password: str = "";
    has repeat: str = "";
    has error: str = "";
    has busy: bool = False;

    mismatch: bool = len(repeat) > 0 and password != repeat;
    tooShort: bool = len(password) > 0 and len(password) < 8;
    ready: bool = bool(code) and bool(username.strip()) and len(password) >= 8 and password == repeat;

    async def submit() {
        if not ready or busy {
            return;
        }
        busy = True;
        error = "";
        # The server keeps usernames in lower case, so sign in under the same spelling.
        name: str = username.strip().lower();
        created: bool = False;
        try {
            await bootstrap(code, name, password, displayName.strip() or name);
            created = True;
        } except Exception as e {
            err = parseError(e);
            if err["code"] == "conflict" {
                error = "An account already exists on this deployment. Ask a commander to create yours.";
            } elif err["code"] == "invalid" {
                error = err["message"];
            } elif err["status"] == 401 {
                error = "That setup code is not valid. It is printed in the server's log when it starts.";
            } else {
                error = err["message"];
            }
        }
        if created {
            ok: bool = await tryLogin(name, password);
            if ok {
                busy = False;
                onSignedIn();
                return;
            }
            error = "The commander was created but signing in failed. Reload and sign in.";
        }
        busy = False;
    }

    <div style={{"height": "100%", "overflowY": "auto"}}>
    <Center mih="100%" p="md">
        <Card withBorder radius="md" padding="xl" style={{"maxWidth": 460, "width": "100%"}}>
            <Stack gap="md">
                <div>
                    <Title order={4} c="teal.7">
                        Set up ResQ-Mesh
                    </Title>
                    <Text size="sm" c="dimmed">
                        This deployment has no accounts yet. Create the first commander — the account that can
                        authorise a dispatch. The setup code is printed in the server's log when it starts.
                    </Text>
                </div>
                <TextInput
                    label="Setup code"
                    description="From the server log: “create the first commander with this setup code: …”"
                    value={code}
                    onChange={lambda (e: ChangeEvent) { code = e.target.value.strip(); }}
                    autoFocus={True}
                />
                <TextInput
                    label="Username"
                    value={username}
                    onChange={lambda (e: ChangeEvent) { username = e.target.value; }}
                />
                <TextInput
                    label="Display name"
                    description="Shown beside your approvals. Defaults to the username."
                    value={displayName}
                    onChange={lambda (e: ChangeEvent) { displayName = e.target.value; }}
                />
                <PasswordInput
                    label="Password"
                    description="At least 8 characters."
                    error={"Too short" if tooShort else None}
                    value={password}
                    onChange={lambda (e: ChangeEvent) { password = e.target.value; }}
                />
                <PasswordInput
                    label="Repeat password"
                    error={"Passwords do not match" if mismatch else None}
                    value={repeat}
                    onChange={lambda (e: ChangeEvent) { repeat = e.target.value; }}
                    onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { submit(); } }}
                />
                {if error {
                    <Alert color="red" variant="light">
                        {error}
                    </Alert>
                }}
                <Button color="teal" loading={busy} disabled={not ready} onClick={submit}>
                    Create commander and sign in
                </Button>
            </Stack>
        </Card>
    </Center>
    </div>
}
