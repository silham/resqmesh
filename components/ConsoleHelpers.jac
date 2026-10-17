"""Small helpers the console panels share: how a time of day is written, how a rate is
shown as a percentage, and the three toasts every write answers with. Plain helpers, so
every panel says the same thing in the same way."""

import from "@mantine/notifications" { notifications }
import from "@jac/runtime" { jacLogin }
import from ..lib.api { errorText }

"""The local time of day of an ISO timestamp, as the reports and the log show it."""
def:pub clockTime(iso: any) -> str {
    return new(Date, iso).toLocaleTimeString();
}

"""A 0-1 value as whole percent: 0.734 -> '73'."""
def:pub percent(value: any) -> str {
    return (value * 100).toFixed(0);
}

"""A number to a fixed count of decimals; an absent value reads as zero."""
def:pub fixed(value: any, digits: int) -> str {
    n: any = value;
    if not n {
        n = 0;
    }
    return n.toFixed(digits);
}

"""'schema_version' style keys with the underscores read as spaces."""
def:pub words(text: str) -> str {
    return text.replace("_", " ");
}

"""A write was accepted."""
def:pub toastOk(message: str) -> None {
    notifications.show({"color": "teal", "message": message});
}

"""A write was not attempted: the commander has to fix something first."""
def:pub toastWarn(message: str) -> None {
    notifications.show({"color": "orange", "message": message});
}

"""A call was refused or failed; say what the server said."""
def:pub toastErr(e: any) -> None {
    notifications.show({"color": "red", "message": errorText(e)});
}

"""Sign in, answering True or False. A refusal and a thrown error both mean no session, and
the caller shows one message for every cause: a wrong username, a wrong password and a
disabled account are not worth telling apart to whoever is probing."""
async def:pub tryLogin(username: str, password: str) -> bool {
    ok: bool = False;
    try {
        ok = await jacLogin(username, password);
    } except Exception {
        ok = False;
    }
    return ok;
}

"""True when a refusal only means the server has not finished booting. Calls that need the
running service are answered with 'the server is still starting' until it is up; that is a
reason to wait and ask again, not an error to put in front of a commander."""
def:pub stillStarting(message: str) -> bool {
    return message.lower().find("starting") >= 0;
}
