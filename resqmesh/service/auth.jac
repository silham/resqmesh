"""Who may do what.

Identity is Jac's own: users, passwords (scrypt) and signed session tokens. On top of
it this module keeps the roster, the app-level facts about each account: its role,
the call sign it is bound to, and whether it has been switched off.

Roles (a commander token is the only way to authorise a Tier C action):

    commander   everything, including every irreversible act
    dispatcher  read the incident picture and relay reports
    responder   read, and update dispatches for its own call sign only
    citizen     no access to the incident picture

Three deployment modes, picked by RESQMESH_AUTH_MODE (or implied by which credentials
are configured, so a configured token can never silently leave the API open):

    accounts    named users sign in; the first commander is created from the console
                with a one-time setup code printed at startup
    static      two shared credentials (commander, viewer) from the environment
    open        local development: the console signs in as a local commander

Every attributed act takes its author from the signed-in member, never from the
request: an approval that records a name the caller chose is not attribution.
"""

import hashlib;
import logging;
import os;
import hmac;
import secrets;
import time;
import from datetime { datetime, timedelta, UTC }
import from jaclang.server.identity.user_manager { UserManager }
import from jaclang.server.identity.app_tokens { token_create, token_consume, token_revoke }
import from resqmesh.service.core { ServiceError, utc_now }

glob log: any = logging.getLogger("resqmesh.service.auth");

glob SHARED_COMMANDER: str = "shared-commander";
glob SHARED_VIEWER: str = "shared-viewer";
glob LOCAL_COMMANDER: str = "local";
glob ENROLMENT_TTL_S: int = 2 * 3600;
glob READ_ROLES: list[str] = ["commander", "dispatcher", "responder"];
glob ALL_ROLES: list[str] = ["commander", "dispatcher", "responder", "citizen"];

"""Deployment settings, resolved once from the environment."""
obj AuthSettings {
    has mode: str = "open",
        commander_token: str | None = None,
        viewer_token: str | None = None,
        setup_code: str | None = None,
        salt: str = "",
        telegram_secret: str | None = None;

    def auth_enabled -> bool {
        return self.mode != "open";
    }
}

def env_value(name: str) -> str | None {
    value = os.environ.get(name, "").strip();
    return value or None;
}

"""Read the settings from RESQMESH_* variables. Tokens without an explicit mode still
mean token auth: leaving the mode at "open" for a caller who had just configured a
credential would be the worst possible direction for a default to fail in."""
def settings_from_env() -> AuthSettings {
    commander = env_value("RESQMESH_COMMANDER_TOKEN");
    viewer = env_value("RESQMESH_VIEWER_TOKEN");
    mode = (env_value("RESQMESH_AUTH_MODE") or "").lower();
    if mode not in ["accounts", "static", "open"] {
        mode = "static" if (commander or viewer) else "open";
    }
    if mode == "open" and (commander or viewer) {
        mode = "static";
    }
    return AuthSettings(
        mode=mode, commander_token=commander, viewer_token=viewer,
        setup_code=env_value("RESQMESH_SETUP_CODE"),
        salt=env_value("RESQMESH_SALT") or "",
        telegram_secret=env_value("TELEGRAM_WEBHOOK_SECRET")
    );
}

# ------------------------------------------------------------------ the roster

"""One account's app-level record, kept on the shared graph."""
node Member {
    has user_id: str,
        root_id: str,
        username: str,
        display_name: str,
        role: str,
        vehicle_id: str | None = None,
        label: str = "",
        created_at: str = "",
        disabled: bool = False;

    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

"""Where the members hang. Looking up the caller happens on every protected request, and a
walk over everything attached to the shared graph would load the incident along with the
roster and write it straight back: its whole state, every time. The members therefore sit
under their own node, which is found by id."""
node Roster {
    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

glob ROSTER_ID: dict[str, str] = {};

"""The roster node, created on first use. Members an earlier version attached directly to
the shared graph are moved under it."""
def roster() -> Roster {
    cached = ROSTER_ID.get("id", "");
    if cached {
        try {
            found: any = jobj(cached);
            if found is not None and isinstance(found, Roster) {
                return found;
            }
        } except Exception {
            log.debug("cached roster id no longer resolves; looking again");
        }
    }
    holders: list[Roster] = [];
    loose: list[Member] = [];
    for n in [root.shared -->] {
        if isinstance(n, Roster) {
            holders.append(n);
        } elif isinstance(n, Member) {
            loose.append(n);
        }
    }
    home = holders[0] if holders else Roster();
    if not holders {
        root.shared ++> home;
    }
    for m in loose {
        root.shared del--> m;
        home ++> m;
    }
    ROSTER_ID["id"] = jid(home);
    return home;
}

def members() -> list[Member] {
    return [m for m in [roster() -->] if isinstance(m, Member)];
}

def find_member(username: str) -> Member | None {
    wanted = username.strip().lower();
    for m in members() {
        if m.username == wanted {
            return m;
        }
    }
    return None;
}

"""The signed-in caller's member record, or None. Matched on the caller's own root,
which Jac binds to the session token: there is nothing for a client to forge."""
def caller() -> Member | None {
    rid = jid(root);
    for m in members() {
        if m.root_id == rid and not m.disabled {
            return m;
        }
    }
    return None;
}

def can_read(m: Member) -> bool {
    return m.role in READ_ROLES;
}

"""The caller, or a refusal. `minimum` is "commander" or "viewer" (anyone who may read)."""
def require(minimum: str) -> Member {
    who = caller();
    if who is None {
        raise ServiceError(401, "missing, invalid or revoked session");
    }
    if minimum == "commander" and who.role != "commander" {
        raise ServiceError(403, "commander authority required");
    }
    if minimum == "viewer" and not can_read(who) {
        raise ServiceError(403, "this account may not read the incident picture");
    }
    return who;
}

def random_password() -> str {
    return secrets.token_urlsafe(24);
}

"""Create (or adopt) the identity in Jac's store. Returns (user_id, root_id).

If the identity exists but the roster has no record of it, an earlier attempt got as far
as creating the user and no further (a boot interrupted, or an endpoint re-run after a
write conflict). Adopt it and set the password we were asked for, rather than failing."""
def make_identity(name: str, password: str) -> tuple[str, str] {
    um = UserManager();
    made: any = um.create_internal_user(name, password, "user");
    user_id = str(made.get("user_id", ""));
    root_id = str(made.get("root_id", ""));
    if made.get("error") or not user_id {
        found: any = um.find_user_by_identity(name);
        if not found {
            raise ServiceError(409, str(made.get("error") or f"could not create {name}"));
        }
        user_id = str(found["user_id"]);
        um.reset_password_by_user_id(user_id, password);
        root_id = str(um.get_root_id(user_id) or "");
    }
    return (user_id, root_id);
}

"""Record an account's role on the roster. Idempotent: an existing record is returned."""
def attach_member(
    name: str, user_id: str, root_id: str, role: str, display_name: str,
    vehicle_id: str | None, label: str
) -> Member {
    existing = find_member(name);
    if existing is not None {
        return existing;
    }
    m = Member(
        user_id=user_id, root_id=root_id, username=name, display_name=display_name or name,
        role=role, vehicle_id=vehicle_id, label=label, created_at=utc_now().isoformat()
    );
    roster() ++> m;
    return m;
}

"""Create an account in Jac's identity store and record its role. Returns the member."""
def create_member(
    username: str, password: str, role: str, display_name: str = "",
    vehicle_id: str | None = None, label: str = ""
) -> Member {
    if role not in ALL_ROLES {
        raise ServiceError(422, f"unknown role {role}");
    }
    name = username.strip().lower();
    if not name {
        raise ServiceError(422, "a username is required");
    }
    if find_member(name) is not None {
        raise ServiceError(409, f"{name} already exists");
    }
    (user_id, root_id) = make_identity(name, password);
    return attach_member(name, user_id, root_id, role, display_name, vehicle_id, label);
}

"""Ensure a shared credential account exists with exactly this password."""
def ensure_shared(username: str, password: str, role: str, display_name: str) -> Member {
    existing = find_member(username);
    if existing is None {
        return create_member(username, password, role, display_name);
    }
    UserManager().reset_password_by_user_id(existing.user_id, password);
    existing.disabled = False;
    return existing;
}

"""Switch an account off and rotate its password, so nothing issued before still works
and the account cannot sign in again until it is re-enrolled."""
def disable_member(m: Member) -> None {
    m.disabled = True;
    UserManager().reset_password_by_user_id(m.user_id, random_password());
}

# ------------------------------------------------------------------ boot

obj AuthState {
    has settings: AuthSettings,
        local_password: str = "",
        setup_code: str | None = None;

    """Signed-in credentials for open mode, so the console can sign in without a form."""
    def local_credentials -> dict[str, str] | None {
        if self.settings.mode != "open" {
            return None;
        }
        return {"username": LOCAL_COMMANDER, "password": self.local_password};
    }

    def needs_setup -> bool {
        if self.settings.mode != "accounts" {
            return False;
        }
        return not any([m.role == "commander" for m in members()]);
    }
}

"""Touch the one-time token store once at boot, so its lazy initialisation never lands
inside a responder's first enrolment."""
def warm_token_store() -> None {
    try {
        token_create("warmup", "boot", 5, {});
        token_revoke("warmup", "boot");
    } except Exception {
        log.exception("could not warm the token store");
    }
}

"""Provision what the chosen mode needs, and announce the setup code if one is due."""
def provision(settings: AuthSettings, host_hint: str = "localhost:8000") -> AuthState {
    warm_token_store();
    state = AuthState(settings=settings);
    if settings.mode == "open" {
        log.warning("no API tokens configured: the API is OPEN. Set RESQMESH_COMMANDER_TOKEN before deploying");
        state.local_password = random_password();
        ensure_shared(LOCAL_COMMANDER, state.local_password, "commander", "local development (auth open)");
    } elif settings.mode == "static" {
        log.warning(
            "auth mode is 'static': one shared token, so an approval is attributed to 'shared commander token' "
            + "rather than to a person. Set RESQMESH_AUTH_MODE=accounts for named commanders"
        );
        if settings.commander_token {
            ensure_shared(SHARED_COMMANDER, settings.commander_token, "commander", "shared commander token");
        }
        if settings.viewer_token {
            ensure_shared(SHARED_VIEWER, settings.viewer_token, "dispatcher", "shared viewer token");
        }
    } else {
        if state.needs_setup() {
            # Nobody can sign in yet, so print a one-time setup code and let the console
            # create the first commander. The code goes to the server's own output, which
            # only whoever started the process can see; it is spent the moment the first
            # commander exists.
            state.setup_code = settings.setup_code or secrets.token_urlsafe(9);
            log.warning(
                "no accounts exist yet. Open http://%s/console and create the first commander with this setup code: %s",
                host_hint, state.setup_code
            );
        }
    }
    return state;
}

# ------------------------------------------------------------------ operations behind the endpoints

"""Create the first commander. Available exactly once: the roster has no commander, and
the caller presents the setup code printed at startup."""
def bootstrap(
    auth: AuthState, code: str, username: str, password: str, display_name: str
) -> dict[str, str] {
    if auth.settings.mode != "accounts" {
        raise ServiceError(503, "this deployment is not running account authentication");
    }
    if not auth.needs_setup() {
        raise ServiceError(409, "this deployment already has accounts; ask a commander for one");
    }
    expected = auth.setup_code or "";
    if not expected or not hmac.compare_digest(code.strip().encode(), expected.encode()) {
        raise ServiceError(401, "that setup code is not valid; it is printed in the server log at startup");
    }
    if len(password) < 8 {
        raise ServiceError(422, "password must be at least 8 characters");
    }
    m = create_member(username, password, "commander", display_name or username);
    # The code is spent by the roster, not by a flag: once a commander exists the door is
    # shut, and an endpoint re-run after a write conflict still finds the code valid.
    log.warning("first commander created: %s (%s) via console setup", m.username, m.user_id);
    return {"username": m.username};
}

"""A one-time link code binding a device to a call sign. Replaces a link that was itself
the credential and so stayed valid wherever it ended up: a leaked URL is worthless
after first use."""
def issue_enrolment(vehicle_id: str) -> dict[str, any] {
    code = token_create("enrol", vehicle_id, ENROLMENT_TTL_S, {"vehicle_id": vehicle_id});
    expires = utc_now() + timedelta(seconds=ENROLMENT_TTL_S);
    return {"code": code, "vehicle_id": vehicle_id, "expires_at": expires.isoformat().replace("+00:00", "Z")};
}

"""What a just-spent code produced, kept for a few seconds. The runtime may re-run an
endpoint after a write conflict; the one-time code is already consumed by then, so the
re-run must return the same credentials rather than report the code as invalid."""
glob SPENT_CODES: dict[str, dict[str, any]] = {};
glob SPENT_TTL_S: float = 10.0;

def spent_key(code: str) -> str {
    return hashlib.sha256(code.strip().encode()).hexdigest();
}

def forget_old_codes() -> None {
    cutoff = time.monotonic() - SPENT_TTL_S;
    for key in [k for (k, v) in SPENT_CODES.items() if v["at"] < cutoff] {
        SPENT_CODES.pop(key, None);
    }
}

"""Spend an enrolment code. The code is the credential: no sign-in needed. Each device
gets its own account bound to the call sign, so revoking one phone ends exactly that
phone's access. Returns one-time credentials the device signs in with and never keeps."""
def enrol(code: str, label: str) -> dict[str, str] {
    forget_old_codes();
    key = spent_key(code);
    done = SPENT_CODES.get(key);
    if done is None {
        got: any = token_consume("enrol", code.strip());
        if got is None {
            raise ServiceError(401, "that enrolment code is not valid; ask the command post for a new link");
        }
        vehicle_id = str(got["subject"]);
        username = f"{vehicle_id.lower()}-{secrets.token_hex(3)}";
        password = random_password();
        (user_id, root_id) = make_identity(username, password);
        done = {
            "username": username, "password": password, "vehicle_id": vehicle_id,
            "user_id": user_id, "root_id": root_id, "at": time.monotonic()
        };
        SPENT_CODES[key] = done;
    }
    attach_member(done["username"], done["user_id"], done["root_id"], "responder", done["vehicle_id"], done["vehicle_id"], label or done["vehicle_id"]);
    return {"username": done["username"], "password": done["password"], "vehicle_id": done["vehicle_id"]};
}

def member_json(m: Member) -> dict[str, any] {
    return {
        "username": m.username, "display_name": m.display_name, "role": m.role,
        "vehicle_id": m.vehicle_id, "label": m.label, "created_at": m.created_at, "disabled": m.disabled
    };
}
