"""Signing in, whichever way this deployment authenticates.

What to show comes from the server's own description of itself, read once when this
screen opens:

  open      nothing to type: the console signs in as the local commander by itself
  static    a shared token, with no username
  accounts  username and password, or the one-time first-commander setup while no
            commander exists yet

The sign-in itself is the framework's (`jacLogin`); the session token stays inside it and
this screen never sees one."""

import from "@jac/runtime" { jacLogin }
import from "@mantine/core" { Alert, Button, Card, Center, Loader, PasswordInput, Stack, Text, TextInput, Title }
import from resqmesh.service.endpoints { health as fetchHealth, open_session }
import from ..lib.api { errorText }
import from .ConsoleFirstCommander { ConsoleFirstCommander }
import from .ConsoleHelpers { tryLogin }
import from .ConsoleSharedToken { ConsoleSharedToken }

def:pub Login(onSignedIn: Callable[[], None]) -> JsxElement {
    has info: any = None;
    has loadError: str = "";
    has attempt: int = 0;
    has username: str = "";
    has password: str = "";
    has error: str = "";
    has busy: bool = False;

    async def signInLocally() {
        creds: any = None;
        ok: bool = False;
        try {
            creds = await open_session();
            if creds {
                ok = await tryLogin(creds["username"], creds["password"]);
            }
        } except Exception as e {
            loadError = errorText(e);
            return;
        }
        if ok {
            onSignedIn();
        } else {
            loadError = "The console could not sign itself in.";
        }
    }

    # Read how this deployment signs people in. Re-runs when "Try again" is pressed.
    async can with [attempt] entry {
        loadError = "";
        found: any = None;
        try {
            found = await fetchHealth();
        } except Exception as e {
            loadError = errorText(e);
            return;
        }
        if found["status"] == "starting" {
            # Not up yet, and what it says about itself is a placeholder. Look again.
            setTimeout(lambda { attempt = attempt + 1; }, 2000);
            return;
        }
        info = found;
        if found["auth_mode"] == "open" {
            await signInLocally();
        }
    }

    async def submit() {
        if not username or not password or busy {
            return;
        }
        busy = True;
        error = "";
        # Usernames are kept in lower case, so sign in under the same spelling.
        ok: bool = await tryLogin(username.strip().lower(), password);
        busy = False;
        if ok {
            onSignedIn();
        } else {
            # One message for every failure: a wrong username, a wrong password and a
            # disabled account are not worth distinguishing for whoever is probing.
            error = "Username or password is incorrect.";
        }
    }

    def retry() {
        attempt = attempt + 1;
    }

    if loadError {
        return <Center h="100%" p="md">
            <Card withBorder radius="md" padding="xl" style={{"maxWidth": 420, "width": "100%"}}>
                <Stack gap="md">
                    <Alert color="red" variant="light" title="Cannot sign in yet">
                        {loadError}
                    </Alert>
                    <Button variant="default" onClick={retry}>
                        Try again
                    </Button>
                </Stack>
            </Card>
        </Center>;
    }

    if not info or info["auth_mode"] == "open" {
        return <Center h="100%" p="md">
            <Loader />
        </Center>;
    }

    if info["needs_setup"] {
        return <ConsoleFirstCommander onSignedIn={onSignedIn} />;
    }

    <Center h="100%" p="md">
        <Card withBorder radius="md" padding="xl" style={{"maxWidth": 420, "width": "100%"}}>
            <Stack gap="md">
                <div>
                    <Title order={4} c="teal.7">
                        ResQ-Mesh
                    </Title>
                    <Text size="sm" c="dimmed">
                        Sign in to the commander console. Reporting an emergency needs no account —
                        use <Text span={True} ff="monospace">/report</Text>.
                    </Text>
                </div>
                {#* A password form is the wrong thing to show someone whose deployment
                    authenticates with a shared token: there is no account to type. *#}
                {if info["auth_mode"] == "static" {
                    <ConsoleSharedToken onSignedIn={onSignedIn} />
                } else {
                    <>
                        <TextInput
                            label="Username"
                            value={username}
                            onChange={lambda (e: ChangeEvent) { username = e.target.value; }}
                            onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { submit(); } }}
                            autoFocus={True}
                        />
                        <PasswordInput
                            label="Password"
                            value={password}
                            onChange={lambda (e: ChangeEvent) { password = e.target.value; }}
                            onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { submit(); } }}
                        />
                        {if error {
                            <Alert color="red" variant="light">
                                {error}
                            </Alert>
                        }}
                        <Button color="teal" loading={busy} disabled={not username or not password} onClick={submit}>
                            Sign in
                        </Button>
                    </>
                }}
            </Stack>
        </Card>
    </Center>
}
