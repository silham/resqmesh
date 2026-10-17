"""The way in for a deployment that runs the two shared tokens.

There is no account to type, so a password form would be a dead end. The token goes in
here and is used as the password of the shared commander account; a viewer token is the
same thing for the shared viewer account, so the commander is tried first."""

import from "@mantine/core" { Alert, Button, PasswordInput, Stack }
import from .ConsoleHelpers { tryLogin }

def:pub ConsoleSharedToken(onSignedIn: Callable[[], None]) -> JsxElement {
    has token: str = "";
    has error: str = "";
    has busy: bool = False;

    async def submit() {
        value: str = token.strip();
        if not value or busy {
            return;
        }
        busy = True;
        error = "";
        ok: bool = await tryLogin("shared-commander", value);
        if not ok {
            ok = await tryLogin("shared-viewer", value);
        }
        busy = False;
        if ok {
            onSignedIn();
        } else {
            error = "That token was not accepted.";
        }
    }

    <Stack gap="sm">
        <Alert color="gray" variant="light">
            This deployment authenticates with a shared bearer token rather than accounts, so there is
            no username. Paste the token to continue.
        </Alert>
        <PasswordInput
            label="Bearer token"
            value={token}
            onChange={lambda (e: ChangeEvent) { token = e.target.value; }}
            onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { submit(); } }}
            autoFocus={True}
        />
        {if error {
            <Alert color="red" variant="light">
                {error}
            </Alert>
        }}
        <Button color="teal" loading={busy} disabled={not token.strip()} onClick={submit}>
            Continue
        </Button>
    </Stack>
}
