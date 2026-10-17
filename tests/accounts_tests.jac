"""Accounts, roles, sign-in modes, first-run setup and responder enrolment.

Two shared tokens were once the whole model, so who approved a plan was whatever the
caller said. These tests pin the properties that make attribution a fact (the author
comes from the signed-in member, never the request), the ones that stop an enrolment
link being a permanent key, and the behaviour of each deployment mode.

Identity is Jac's own and the roster is a graph of `Member` nodes; a test acts as a
member by binding that member to its own root (that is how `caller()` finds the
signed-in member), and every username here is unique so nothing collides with an
earlier run or a developer's database."""

import inspect;
import os;
import time;
import uuid;
import from datetime { datetime, UTC }
import from jaclang.server.identity.app_tokens { token_create }
import from jaclang.server.identity.user_manager { UserManager }
import from resqmesh.service.app { Runtime, _RUNTIME, build_service }
import from resqmesh.service.auth {
    ENROLMENT_TTL_S, SPENT_CODES, SPENT_TTL_S, AuthSettings, AuthState, Member, bootstrap as bootstrap_state,
    caller, create_member, disable_member, ensure_shared, find_member, forget_old_codes, make_identity,
    member_json, members, provision, require, settings_from_env, spent_key
}
import from resqmesh.service.core { IncidentService, ServiceError }
import from resqmesh.service.endpoints {
    bootstrap, create_account, decide, enrol, get_incident, halt, health, issue_enrolment, list_accounts,
    list_devices, me, open_incident, open_session, responder_update, revoke_device, submit_report
}

glob GOAL: str = "coordinate the response to flooding in the Kelani basin";
glob SALT: str = "test-salt";
glob PASSWORD: str = "correct horse";

# Two sources per place, so a plan reaches the gate.
glob REPORTS: list[tuple[str, str]] = [
    ("Flooding in Kolonnawa, 12 people trapped, elderly couple on the roof. Urgent!", "0771111111"),
    ("Water rising fast at Kolonnawa, children stranded", "0772222222"),
    ("Patient needs dialysis at Hanwella, 3 people cannot leave. Critical", "0774444444"),
    ("Hanwella dialysis patient confirmed, urgent medical help", "0775555555")
];

glob ENV_NAMES: list[str] = [
    "RESQMESH_COMMANDER_TOKEN", "RESQMESH_VIEWER_TOKEN", "RESQMESH_AUTH_MODE", "RESQMESH_SETUP_CODE",
    "RESQMESH_SALT", "TELEGRAM_WEBHOOK_SECRET"
];

# ------------------------------------------------------------------ helpers

def uname(prefix: str = "acct") -> str {
    return f"{prefix}-{uuid.uuid4().hex[:8]}";
}

"""A service installed as the runtime the endpoints serve, in the given auth mode."""
def install(mode: str = "accounts", setup_code: str | None = None) -> IncidentService {
    svc = build_service(llm_mode="offline", persisted=False);
    auth = AuthState(settings=AuthSettings(mode=mode, salt=SALT, setup_code=setup_code), setup_code=setup_code);
    _RUNTIME["runtime"] = Runtime(service=svc, auth=auth);
    return svc;
}

"""A real account: identity in Jac's store plus a roster record, not yet signed in."""
def new_member(role: str, vehicle_id: str | None = None, password: str = PASSWORD) -> Member {
    return create_member(uname(role), password, role, f"{role} on duty", vehicle_id);
}

"""Sign the test in as this member: it, and only it, is bound to the test's root."""
def bind(who: Member) -> Member {
    rid = jid(root);
    for m in members() {
        if m.root_id == rid {
            m.root_id = f"unbound-{uuid.uuid4().hex[:8]}";
        }
    }
    who.root_id = rid;
    return who;
}

def act_as(role: str, vehicle_id: str | None = None) -> Member {
    return bind(new_member(role, vehicle_id));
}

def sign_out() -> None {
    rid = jid(root);
    for m in members() {
        if m.root_id == rid {
            m.root_id = f"unbound-{uuid.uuid4().hex[:8]}";
        }
    }
}

def can_sign_in(username: str, password: str) -> bool {
    um = UserManager();
    result: any = um.authenticate(username, password);
    return result is not None;
}

def status_of(caught: any) -> int {
    err: any = caught.value;
    return err.status;
}

def roster_has_commander() -> bool {
    return any([m.role == "commander" for m in members()]);
}

"""Open the incident as `commander`, report as the public, and return the view at the gate."""
def gate_as(svc: IncidentService, commander: Member) -> dict[str, any] {
    bind(commander);
    open_incident(GOAL);
    svc.process_pending();
    sign_out();
    for (text, phone) in REPORTS {
        submit_report(text, source=phone);
    }
    svc.process_pending();
    bind(commander);
    return get_incident();
}

def set_env(values: dict[str, str]) -> dict[str, str | None] {
    saved: dict[str, str | None] = {};
    for name in ENV_NAMES {
        saved[name] = os.environ.get(name);
        os.environ.pop(name, None);
    }
    for (key, value) in values.items() {
        os.environ[key] = value;
    }
    return saved;
}

def restore_env(saved: dict[str, str | None]) -> None {
    for (name, value) in saved.items() {
        if value is None {
            os.environ.pop(name, None);
        } else {
            os.environ[name] = value;
        }
    }
}

def settings_with(values: dict[str, str]) -> AuthSettings {
    saved = set_env(values);
    try {
        return settings_from_env();
    } finally {
        restore_env(saved);
    }
}

def skip_unless_empty_roster() -> None {
    if roster_has_commander() {
        testskip("this scenario needs a roster with no commander");
    }
}

# ------------------------------------------------------------------ the roster

test "an account is created with a role and can sign in" {
    name = uname("cmdr");
    m = create_member(f"  {name.upper()}  ", PASSWORD, "commander", "Cmdr Perera");
    # usernames are normalised, so one person cannot hold two spellings
    assert m.username == name and m.role == "commander" and m.display_name == "Cmdr Perera";
    assert m.disabled is False and m.vehicle_id is None and m.created_at;
    found = find_member(name.upper());
    assert found is not None and found.user_id == m.user_id;
    assert can_sign_in(name, PASSWORD);
}

test "a display name defaults to the username" {
    m = create_member(uname("desk"), PASSWORD, "dispatcher");
    assert m.display_name == m.username;
}

test "a password is never stored on the roster and a wrong one never signs in" {
    m = new_member("commander");
    # the roster record has no credential at all; the identity store holds the (hashed) password
    assert "password" not in " ".join(vars(m).keys());
    assert PASSWORD not in str(member_json(m));
    assert can_sign_in(m.username, PASSWORD);
    assert not can_sign_in(m.username, "Correct horse");
    assert not can_sign_in(m.username, "");
    # an unknown user and a wrong password are indistinguishable to the caller
    assert not can_sign_in(uname("nobody"), PASSWORD);
    um = UserManager();
    known: any = um.authenticate(m.username, "wrong");
    unknown: any = um.authenticate(uname("nobody"), "wrong");
    assert known is None and unknown is None;
}

test "an account refusal leaves the roster unchanged" {
    name = uname("dup");
    first = create_member(name, "first password", "dispatcher");
    with testraises(ServiceError) as same {
        create_member(name.upper(), "second password", "commander");
    }
    assert status_of(same) == 409 and "already exists" in str(same.value);
    with testraises(ServiceError) as role {
        create_member(uname("x"), PASSWORD, "admiral");
    }
    assert status_of(role) == 422;
    with testraises(ServiceError) as blank {
        create_member("   ", PASSWORD, "commander");
    }
    assert status_of(blank) == 422;
    # the existing account was not taken over by the refused duplicate
    assert [m.username for m in members()].count(name) == 1;
    assert find_member(name) is first and first.role == "dispatcher";
    assert can_sign_in(name, "first password") and not can_sign_in(name, "second password");
}

test "an identity left without a roster record is adopted and its password reset" {
    # an earlier attempt created the user and stopped; the next one must not fail
    name = uname("adopt");
    um = UserManager();
    made: any = um.create_internal_user(name, "old password", "user");
    assert made.get("user_id");
    assert find_member(name) is None;
    m = create_member(name, "new password", "dispatcher");
    assert str(m.user_id) == str(made["user_id"]) and str(m.root_id) == str(made["root_id"]);
    assert can_sign_in(name, "new password") and not can_sign_in(name, "old password");
    # asking again for the same identity returns it rather than a second user
    (user_id, root_id) = make_identity(name, "newer password");
    assert user_id == m.user_id and root_id == m.root_id;
    assert can_sign_in(name, "newer password");
}

test "the signed-in caller is the member bound to the caller's own root" {
    m = new_member("dispatcher");
    other = new_member("commander");
    # neither is bound to this session, so nobody is signed in
    assert caller() is None;
    bind(m);
    who = caller();
    assert who is not None and who.username == m.username;
    # a record for someone else's root never answers for this caller
    bind(other);
    who = caller();
    assert who is not None and who.username == other.username and m.root_id != other.root_id;
}

test "roles decide who may read and who may command" {
    expected: dict[str, tuple[bool, bool]] = {
        "commander": (True, True), "dispatcher": (True, False), "responder": (True, False),
        "citizen": (False, False)
    };
    for (role, (reads, commands)) in expected.items() {
        who = act_as(role, "BOAT-01" if role == "responder" else None);
        if reads {
            assert require("viewer").username == who.username;
        } else {
            with testraises(ServiceError) as read {
                require("viewer");
            }
            assert status_of(read) == 403;
        }
        if commands {
            assert require("commander").role == "commander";
        } else {
            with testraises(ServiceError) as command {
                require("commander");
            }
            assert status_of(command) == 403 and "commander authority required" in str(command.value);
        }
    }
}

test "nobody signed in is unauthorized" {
    new_member("commander");
    sign_out();
    for minimum in ["viewer", "commander"] {
        with testraises(ServiceError) as ei {
            require(minimum);
        }
        assert status_of(ei) == 401 and "unauthorized" in str(ei.value);
    }
}

test "me describes the signed-in member" {
    install("accounts");
    who = act_as("responder", "BOAT-02");
    out = me();
    assert out["role"] == "responder" and out["username"] == who.username;
    assert out["vehicle_id"] == "BOAT-02" and out["display_name"] == who.display_name;
    assert out["auth_mode"] == "accounts";
    sign_out();
    with testraises(ServiceError) as ei {
        me();
    }
    assert status_of(ei) == 401;
}

test "a commander creates named accounts" {
    install("accounts");
    act_as("commander");
    name = uname("desk");
    out = create_account(name, "desk pass 123", "dispatcher", "Ops Desk");
    assert out["username"] == name and out["role"] == "dispatcher" and out["display_name"] == "Ops Desk";
    assert out["disabled"] is False and "password" not in out;
    assert can_sign_in(name, "desk pass 123");
    # the display name falls back to the username
    plain = create_account(uname("citizen"), "citizen pass 123", "citizen");
    assert plain["display_name"] == plain["username"];
}

test "account creation is validated and commander only" {
    install("accounts");
    commander = act_as("commander");
    with testraises(ServiceError) as responder {
        create_account(uname("crew"), "crew pass 123", "responder");
    }
    assert status_of(responder) == 422 and "enrol" in str(responder.value);
    with testraises(ServiceError) as short {
        create_account(uname("short"), "short", "dispatcher");
    }
    assert status_of(short) == 422 and "8 characters" in str(short.value);
    with testraises(ServiceError) as duplicate {
        create_account(commander.username, "another pass 123", "dispatcher");
    }
    assert status_of(duplicate) == 409;
    act_as("dispatcher");
    with testraises(ServiceError) as desk {
        create_account(uname("late"), "late pass 123", "dispatcher");
    }
    assert status_of(desk) == 403;
    sign_out();
    with testraises(ServiceError) as nobody {
        create_account(uname("late"), "late pass 123", "dispatcher");
    }
    assert status_of(nobody) == 401;
}

test "the roster lists every account but the device list hides the system ones" {
    install("accounts");
    act_as("commander");
    for system in ["shared-commander", "shared-viewer", "local"] {
        if find_member(system) is None {
            create_member(system, "system password", "commander" if system != "shared-viewer" else "dispatcher");
        }
    }
    crew = new_member("responder", "BOAT-01");
    everyone = [a["username"] for a in list_accounts()];
    assert crew.username in everyone and "local" in everyone and "shared-commander" in everyone;
    devices = [d["username"] for d in list_devices()];
    assert crew.username in devices;
    for system in ["shared-commander", "shared-viewer", "local"] {
        assert system not in devices;
    }
    for row in list_accounts() {
        assert set(row.keys()) == {"username", "display_name", "role", "vehicle_id", "label", "created_at", "disabled"};
    }
    act_as("dispatcher");
    for lister in [list_accounts, list_devices] {
        with testraises(ServiceError) as ei {
            lister();
        }
        assert status_of(ei) == 403;
    }
}

# ------------------------------------------------------------------ revocation

test "a revoked account cannot sign in or act" {
    install("accounts");
    target = new_member("dispatcher");
    # signed in: it can act
    bind(target);
    assert require("viewer").username == target.username;
    commander = act_as("commander");
    out = revoke_device(target.username);
    assert out == {"ok": True};
    assert target.disabled is True;
    # the old password no longer works, and neither does a session already bound to it
    assert not can_sign_in(target.username, PASSWORD);
    bind(target);
    with testraises(ServiceError) as ei {
        require("viewer");
    }
    assert status_of(ei) == 401;
    # the roster still lists it, switched off, so the commander can see what was revoked
    bind(commander);
    row = [a for a in list_accounts() if a["username"] == target.username][0];
    assert row["disabled"] is True;
}

test "revocation is refused for yourself, the unknown and the already revoked" {
    install("accounts");
    commander = act_as("commander");
    with testraises(ServiceError) as mine {
        revoke_device(commander.username);
    }
    assert status_of(mine) == 409 and "signed in with" in str(mine.value);
    assert commander.disabled is False and can_sign_in(commander.username, PASSWORD);
    with testraises(ServiceError) as unknown {
        revoke_device(uname("ghost"));
    }
    assert status_of(unknown) == 404;
    victim = new_member("dispatcher");
    revoke_device(victim.username);
    with testraises(ServiceError) as again {
        revoke_device(victim.username);
    }
    assert status_of(again) == 404 and "no such live account" in str(again.value);
    act_as("dispatcher");
    with testraises(ServiceError) as desk {
        revoke_device(victim.username);
    }
    assert status_of(desk) == 403;
}

test "a revoked password cannot be guessed back and the account stays off" {
    m = new_member("commander", password="battery staple");
    disable_member(m);
    assert m.disabled is True;
    assert not can_sign_in(m.username, "battery staple");
    # an account switched off by revocation is not re-opened by creating it again
    with testraises(ServiceError) as ei {
        create_member(m.username, "battery staple", "commander");
    }
    assert status_of(ei) == 409;
    assert not can_sign_in(m.username, "battery staple");
}

# ------------------------------------------------------------------ attribution

test "the approval records who was signed in not who they said they were" {
    svc = install("accounts");
    cmdr = new_member("commander");
    view = gate_as(svc, cmdr);
    # the request cannot carry an author at all, so it cannot lie about one
    params = set(inspect.signature(decide).parameters.keys());
    assert params == {"decision", "plan_version", "constraint", "publish_alerts"};
    assert svc.queued() == [];
    out = decide("approved", view["plan"]["version"]);
    assert out["status"] == "queued";
    assert svc.queued()[0].payload["author"] == cmdr.username;
    svc.process_pending();
    approvals = get_incident()["approvals"];
    assert len(approvals) == 1;
    assert approvals[0]["commander_id"] == cmdr.username;
}

test "two commanders are distinguishable in the audit log" {
    svc = install("accounts");
    one = new_member("commander");
    two = new_member("commander");
    view = gate_as(svc, one);
    decide("rejected", view["plan"]["version"], "exclude_vehicle: BOAT-01");
    svc.process_pending();
    bind(two);
    view = get_incident();
    decide("approved", view["plan"]["version"]);
    svc.process_pending();
    approvals = get_incident()["approvals"];
    assert [a["commander_id"] for a in approvals] == [one.username, two.username];
}

test "a dispatcher may read everything and approve nothing" {
    svc = install("accounts");
    view = gate_as(svc, new_member("commander"));
    desk = act_as("dispatcher");
    assert get_incident()["goal"] == GOAL;
    with testraises(ServiceError) as decided {
        decide("approved", view["plan"]["version"]);
    }
    assert status_of(decided) == 403;
    with testraises(ServiceError) as halted {
        halt();
    }
    assert status_of(halted) == 403;
    assert svc.queued() == [];
    assert desk.role == "dispatcher";
}

# ------------------------------------------------------------------ responders

def released(svc: IncidentService) -> dict[str, any] {
    cmdr = new_member("commander");
    view = gate_as(svc, cmdr);
    decide("approved", view["plan"]["version"]);
    svc.process_pending();
    return get_incident();
}

test "a responder can only report on their own call sign" {
    svc = install("accounts");
    view = released(svc);
    assignment = view["plan"]["assignments"][0];
    other = [v["vehicle_id"] for v in view["vehicles"] if v["vehicle_id"] != assignment["vehicle_id"]][0];
    act_as("responder", other);
    # signed in, can read, and still cannot close someone else's job
    assert get_incident()["goal"] == GOAL;
    with testraises(ServiceError) as ei {
        responder_update(assignment["vehicle_id"], assignment["cluster_id"], "complete");
    }
    assert status_of(ei) == 403 and f"you are {other}" in str(ei.value);
    assert svc.queued() == [];
    assert get_incident()["completed_cluster_ids"] == [];
}

test "a responder reports on their own dispatch" {
    svc = install("accounts");
    view = released(svc);
    assignment = view["plan"]["assignments"][0];
    act_as("responder", assignment["vehicle_id"]);
    out = responder_update(assignment["vehicle_id"], assignment["cluster_id"], "on_scene");
    assert out["status"] == "queued";
    svc.process_pending();
    assert [e["action"] for e in get_incident()["trace"]].count("responder_on_scene") == 1;
}

test "a commander or dispatcher can relay an update for any crew" {
    # most updates arrive over the radio and are typed in by the ops room
    svc = install("accounts");
    view = released(svc);
    a = view["plan"]["assignments"][0];
    for role in ["commander", "dispatcher"] {
        act_as(role);
        out = responder_update(a["vehicle_id"], a["cluster_id"], "en_route");
        assert out["status"] == "queued", role;
    }
    svc.process_pending();
    assert [e["action"] for e in get_incident()["trace"]].count("responder_en_route") >= 1;
}

test "a revoked device stops working" {
    svc = install("accounts");
    commander = new_member("commander");
    view = gate_as(svc, commander);
    code = issue_enrolment(view["vehicles"][0]["vehicle_id"])["code"];
    creds = enrol(code, "lost phone");
    crew = find_member(creds["username"]);
    assert crew is not None;
    bind(crew);
    assert get_incident()["goal"] == GOAL;
    bind(commander);
    devices = [d for d in list_devices() if d["label"] == "lost phone"];
    assert len(devices) == 1 and devices[0]["username"] == creds["username"];
    revoke_device(devices[0]["username"]);
    bind(crew);
    with testraises(ServiceError) as ei {
        get_incident();
    }
    assert status_of(ei) == 401;
    assert not can_sign_in(creds["username"], creds["password"]);
}

# ------------------------------------------------------------------ enrolment

test "an enrolment code is issued for a known call sign by a commander" {
    svc = install("accounts");
    act_as("commander");
    out = issue_enrolment("BOAT-01");
    assert out["vehicle_id"] == "BOAT-01" and out["code"];
    expires = datetime.fromisoformat(out["expires_at"]);
    assert out["expires_at"].endswith("Z");
    ahead = (expires - datetime.now(UTC)).total_seconds();
    assert ENROLMENT_TTL_S - 60 < ahead <= ENROLMENT_TTL_S;
    with testraises(ServiceError) as unknown {
        issue_enrolment("HOVERCRAFT-99");
    }
    assert status_of(unknown) == 404 and "unknown vehicle" in str(unknown.value);
    act_as("dispatcher");
    with testraises(ServiceError) as desk {
        issue_enrolment("BOAT-01");
    }
    assert status_of(desk) == 403;
    sign_out();
    with testraises(ServiceError) as nobody {
        issue_enrolment("BOAT-01");
    }
    assert status_of(nobody) == 401;
    assert svc.queued() == [];
}

test "enrolment creates a responder account bound to the call sign" {
    install("accounts");
    act_as("commander");
    code = issue_enrolment("BOAT-01")["code"];
    sign_out();
    # the code is the credential: no sign-in is needed to spend it
    creds = enrol(code, "  crew phone  ");
    assert creds["vehicle_id"] == "BOAT-01" and creds["username"].startswith("boat-01-");
    assert len(creds["password"]) >= 24;
    crew = find_member(creds["username"]);
    assert crew is not None;
    assert crew.role == "responder" and crew.vehicle_id == "BOAT-01" and crew.label == "crew phone";
    assert can_sign_in(creds["username"], creds["password"]);
    # signed in as that account, the call sign is the binding
    bind(crew);
    out = me();
    assert out["role"] == "responder" and out["vehicle_id"] == "BOAT-01";
}

test "an unlabelled enrolment is labelled with the call sign and long labels are cut" {
    install("accounts");
    act_as("commander");
    plain = enrol(issue_enrolment("BOAT-02")["code"], "");
    long = enrol(issue_enrolment("BOAT-02")["code"], "p" * 200);
    plain_member = find_member(plain["username"]);
    long_member = find_member(long["username"]);
    assert plain_member is not None and long_member is not None;
    assert plain_member.label == "BOAT-02";
    assert long_member.label == "p" * 80;
}

test "an enrolment code is single use once the replay window has passed" {
    install("accounts");
    act_as("commander");
    code = issue_enrolment("BOAT-01")["code"];
    first = enrol(code, "crew phone");
    assert first["vehicle_id"] == "BOAT-01";
    # a link found later in a Referer header, a history or a screenshot is worthless
    SPENT_CODES[spent_key(code)]["at"] = time.monotonic() - SPENT_TTL_S - 1.0;
    with testraises(ServiceError) as ei {
        enrol(code, "someone else");
    }
    assert status_of(ei) == 401 and "not valid" in str(ei.value);
    # the second attempt did not mint a second account
    assert len([m for m in members() if m.vehicle_id == "BOAT-01" and m.role == "responder"]) == 1;
    # and the window's own bookkeeping dropped the stale entry
    assert spent_key(code) not in SPENT_CODES;
}

test "a re-run inside the replay window returns the same credentials and no second account" {
    # the runtime may re-run an endpoint after a write conflict, when the code is already spent
    assert SPENT_TTL_S == 10.0;
    install("accounts");
    act_as("commander");
    code = issue_enrolment("BOAT-01")["code"];
    first = enrol(code, "crew phone");
    again = enrol(code, "crew phone");
    assert again == first;
    # whitespace around a pasted code does not matter
    assert enrol(f"  {code}  ", "crew phone") == first;
    crews = [m for m in members() if m.vehicle_id == "BOAT-01" and m.role == "responder"];
    assert len(crews) == 1 and crews[0].username == first["username"];
    assert can_sign_in(first["username"], first["password"]);
}

test "old replay entries are forgotten and recent ones kept" {
    old = spent_key(uname("old-code"));
    recent = spent_key(uname("recent-code"));
    SPENT_CODES[old] = {"at": time.monotonic() - SPENT_TTL_S - 5.0};
    SPENT_CODES[recent] = {"at": time.monotonic()};
    forget_old_codes();
    assert old not in SPENT_CODES and recent in SPENT_CODES;
    SPENT_CODES.pop(recent, None);
}

test "an invalid or expired enrolment code is refused" {
    install("accounts");
    for code in ["", "   ", "not-a-code", "A" * 64] {
        with testraises(ServiceError) as ei {
            enrol(code, "x");
        }
        assert status_of(ei) == 401, f"code [{code}]";
    }
    # a code past its lifetime is as dead as one that never existed
    stale = token_create("enrol", "BOAT-01", -5, {"vehicle_id": "BOAT-01"});
    with testraises(ServiceError) as expired {
        enrol(stale, "late");
    }
    assert status_of(expired) == 401;
    # and a code for another purpose cannot be spent as an enrolment
    other = token_create("password-reset", "BOAT-01", 60, {"vehicle_id": "BOAT-01"});
    with testraises(ServiceError) as wrong {
        enrol(other, "x");
    }
    assert status_of(wrong) == 401;
    assert len([m for m in members() if m.role == "responder"]) == 0;
}

test "each enrolment code makes its own account so one lost phone ends one device" {
    install("accounts");
    commander = act_as("commander");
    one = enrol(issue_enrolment("BOAT-01")["code"], "phone one");
    two = enrol(issue_enrolment("BOAT-01")["code"], "phone two");
    assert one["username"] != two["username"] and one["password"] != two["password"];
    revoke_device(one["username"]);
    assert not can_sign_in(one["username"], one["password"]);
    assert can_sign_in(two["username"], two["password"]);
    still = find_member(two["username"]);
    assert still is not None and still.disabled is False;
    assert commander.disabled is False;
}

# ------------------------------------------------------------------ the sign-in modes

test "the mode follows the configuration and a configured token never leaves the API open" {
    assert settings_with({}).mode == "open";
    assert settings_with({"RESQMESH_COMMANDER_TOKEN": "cmd"}).mode == "static";
    assert settings_with({"RESQMESH_VIEWER_TOKEN": "view"}).mode == "static";
    # an explicit mode is honoured
    assert settings_with({"RESQMESH_AUTH_MODE": "accounts"}).mode == "accounts";
    assert settings_with({"RESQMESH_AUTH_MODE": "Static"}).mode == "static";
    # but "open" with a credential configured is the worst direction to fail in
    assert settings_with({"RESQMESH_AUTH_MODE": "open", "RESQMESH_COMMANDER_TOKEN": "cmd"}).mode == "static";
    # an unrecognised mode is inferred from what is configured
    assert settings_with({"RESQMESH_AUTH_MODE": "magic"}).mode == "open";
    assert settings_with({"RESQMESH_AUTH_MODE": "magic", "RESQMESH_VIEWER_TOKEN": "v"}).mode == "static";
    # accounts mode stays accounts even with tokens present
    assert settings_with({"RESQMESH_AUTH_MODE": "accounts", "RESQMESH_COMMANDER_TOKEN": "c"}).mode == "accounts";
}

test "the settings carry the tokens, salt, setup code and webhook secret" {
    s = settings_with({
        "RESQMESH_AUTH_MODE": "accounts", "RESQMESH_COMMANDER_TOKEN": " cmd ", "RESQMESH_VIEWER_TOKEN": "view",
        "RESQMESH_SETUP_CODE": "setup-1", "RESQMESH_SALT": "salty", "TELEGRAM_WEBHOOK_SECRET": "hook"
    });
    assert s.commander_token == "cmd" and s.viewer_token == "view";
    assert s.setup_code == "setup-1" and s.salt == "salty" and s.telegram_secret == "hook";
    assert s.auth_enabled() is True;
    blank = settings_with({"RESQMESH_COMMANDER_TOKEN": "   "});
    assert blank.commander_token is None and blank.mode == "open" and blank.auth_enabled() is False;
    empty = settings_with({});
    assert empty.salt == "" and empty.setup_code is None and empty.telegram_secret is None;
}

test "open mode signs the console in as a local commander" {
    state = provision(AuthSettings(mode="open", salt=SALT));
    creds = state.local_credentials();
    assert creds is not None;
    assert creds["username"] == "local" and len(creds["password"]) >= 24;
    local = find_member("local");
    assert local is not None and local.role == "commander" and local.disabled is False;
    assert can_sign_in("local", creds["password"]);
    # the same credentials are served by the public sign-in helper, and nothing else
    _RUNTIME["runtime"] = Runtime(service=build_service(llm_mode="offline", persisted=False), auth=state);
    assert open_session() == creds;
    # a new boot rotates the password, so an old console session credential is dead
    again = provision(AuthSettings(mode="open", salt=SALT));
    fresh = again.local_credentials();
    assert fresh is not None and fresh["password"] != creds["password"];
    assert can_sign_in("local", fresh["password"]) and not can_sign_in("local", creds["password"]);
}

test "only open mode offers credentials without a form" {
    for mode in ["static", "accounts"] {
        state = AuthState(settings=AuthSettings(mode=mode));
        assert state.local_credentials() is None;
    }
    _RUNTIME["runtime"] = Runtime(
        service=build_service(llm_mode="offline", persisted=False),
        auth=AuthState(settings=AuthSettings(mode="static", salt=SALT))
    );
    assert open_session() is None;
}

test "static mode makes the shared commander and viewer accounts with the configured tokens" {
    state = provision(AuthSettings(
        mode="static", commander_token="commander-token-1", viewer_token="viewer-token-1", salt=SALT
    ));
    commander = find_member("shared-commander");
    viewer = find_member("shared-viewer");
    assert commander is not None and commander.role == "commander";
    assert viewer is not None and viewer.role == "dispatcher";
    assert can_sign_in("shared-commander", "commander-token-1");
    assert can_sign_in("shared-viewer", "viewer-token-1");
    assert not can_sign_in("shared-viewer", "commander-token-1");
    assert state.local_credentials() is None and state.needs_setup() is False;
    # the token can change between boots: only the current one works, and an account
    # that was switched off comes back on
    commander.disabled = True;
    provision(AuthSettings(mode="static", commander_token="commander-token-2", salt=SALT));
    assert not can_sign_in("shared-commander", "commander-token-1");
    assert can_sign_in("shared-commander", "commander-token-2");
    assert commander.disabled is False;
    # with a viewer token missing the viewer's old password is left alone, not rotated
    assert can_sign_in("shared-viewer", "viewer-token-1");
}

test "static mode with only a viewer token makes no commander" {
    skip_unless_empty_roster();
    provision(AuthSettings(mode="static", viewer_token="viewer-token-3", salt=SALT));
    assert find_member("shared-viewer") is not None;
    assert not roster_has_commander();
}

test "shared accounts are ensured idempotently with exactly the given password" {
    name = uname("shared");
    first = ensure_shared(name, "first shared password", "dispatcher", "Shared");
    second = ensure_shared(name, "second shared password", "dispatcher", "Shared");
    assert first is second;
    assert can_sign_in(name, "second shared password") and not can_sign_in(name, "first shared password");
    assert [m.username for m in members()].count(name) == 1;
}

# ------------------------------------------------------------------ first-run setup

test "setup is only offered by an accounts deployment with no commander" {
    skip_unless_empty_roster();
    accounts = AuthState(settings=AuthSettings(mode="accounts"));
    assert accounts.needs_setup() is True;
    # neither of the other modes has an account store, so neither offers setup
    for mode in ["open", "static"] {
        assert AuthState(settings=AuthSettings(mode=mode)).needs_setup() is False;
    }
    # a roster of only non-commanders is still empty of authority
    create_member(uname("desk"), PASSWORD, "dispatcher");
    assert accounts.needs_setup() is True;
    create_member(uname("cmdr"), PASSWORD, "commander");
    assert accounts.needs_setup() is False;
}

test "health offers first run setup on an empty accounts deployment" {
    skip_unless_empty_roster();
    install("accounts");
    out = health();
    assert out["auth_mode"] == "accounts" and out["auth"] == "token" and out["needs_setup"] is True;
    create_member(uname("cmdr"), PASSWORD, "commander");
    assert health()["needs_setup"] is False;
}

test "provision prints a setup code only when setup is needed" {
    skip_unless_empty_roster();
    fixed = provision(AuthSettings(mode="accounts", setup_code="setup-code-123"));
    assert fixed.setup_code == "setup-code-123";
    # no configured code: a fresh one-time code each boot
    one = provision(AuthSettings(mode="accounts"));
    two = provision(AuthSettings(mode="accounts"));
    assert one.setup_code is not None and two.setup_code is not None;
    assert len(one.setup_code) >= 12 and one.setup_code != two.setup_code;
    # once a commander exists there is nothing to set up, so no code is made
    create_member(uname("cmdr"), PASSWORD, "commander");
    done = provision(AuthSettings(mode="accounts", setup_code="setup-code-123"));
    assert done.setup_code is None;
}

test "the first commander is created with the setup code" {
    skip_unless_empty_roster();
    state = AuthState(settings=AuthSettings(mode="accounts"), setup_code="setup-code-123");
    name = uname("cmdr");
    out = bootstrap_state(state, " setup-code-123 ", name.upper(), "correct horse", "Cmdr Perera");
    assert out == {"username": name};
    first = find_member(name);
    assert first is not None and first.role == "commander" and first.display_name == "Cmdr Perera";
    assert can_sign_in(name, "correct horse");
    assert state.needs_setup() is False;
}

test "setup needs the code the server printed" {
    skip_unless_empty_roster();
    state = AuthState(settings=AuthSettings(mode="accounts"), setup_code="setup-code-123");
    for code in ["guess", "", "setup-code-12", "SETUP-CODE-123"] {
        with testraises(ServiceError) as ei {
            bootstrap_state(state, code, uname("mallory"), "hunter2 hunter2", "");
        }
        assert status_of(ei) == 401, f"code [{code}]";
    }
    assert not roster_has_commander();
    # a deployment that never printed a code cannot be set up at all
    silent = AuthState(settings=AuthSettings(mode="accounts"));
    with testraises(ServiceError) as none {
        bootstrap_state(silent, "", uname("mallory"), "hunter2 hunter2", "");
    }
    assert status_of(none) == 401;
}

test "setup refuses a short password and leaves the door open" {
    skip_unless_empty_roster();
    state = AuthState(settings=AuthSettings(mode="accounts"), setup_code="setup-code-123");
    with testraises(ServiceError) as ei {
        bootstrap_state(state, "setup-code-123", uname("cmdr"), "short", "");
    }
    assert status_of(ei) == 422;
    assert state.needs_setup() is True;
}

test "setup closes once a commander exists" {
    skip_unless_empty_roster();
    state = AuthState(settings=AuthSettings(mode="accounts"), setup_code="setup-code-123");
    bootstrap_state(state, "setup-code-123", uname("cmdr"), "correct horse", "");
    # same code, same call, and now refused: the door is one-way
    with testraises(ServiceError) as ei {
        bootstrap_state(state, "setup-code-123", uname("cmdr"), "correct horse", "");
    }
    assert status_of(ei) == 409;
    assert len([m for m in members() if m.role == "commander"]) == 1;
}

test "setup is not offered where accounts already exist" {
    # the endpoint exists on every accounts deployment; only an empty roster opens it
    install("accounts", "setup-code-123");
    create_member(uname("cmdr"), PASSWORD, "commander");
    with testraises(ServiceError) as ei {
        bootstrap("anything", uname("mallory"), "hunter2 hunter2");
    }
    assert status_of(ei) == 409;
    assert health()["needs_setup"] is False;
    # even with the right code
    with testraises(ServiceError) as right {
        bootstrap("setup-code-123", uname("mallory"), "hunter2 hunter2");
    }
    assert status_of(right) == 409;
}

test "setup is not available outside accounts mode" {
    for mode in ["open", "static"] {
        install(mode, "setup-code-123");
        with testraises(ServiceError) as ei {
            bootstrap("setup-code-123", uname("mallory"), "hunter2 hunter2");
        }
        assert status_of(ei) == 503 and "unavailable" in str(ei.value);
    }
}

test "the setup endpoint creates the first commander" {
    skip_unless_empty_roster();
    install("accounts", "setup-code-123");
    name = uname("cmdr");
    out = bootstrap("setup-code-123", name, "correct horse", "Cmdr Perera");
    assert out == {"username": name};
    # the new commander is a commander: bound to a session, they pass the highest gate
    first = find_member(name);
    assert first is not None;
    bind(first);
    assert require("commander").username == name;
    assert me()["display_name"] == "Cmdr Perera";
    assert health()["needs_setup"] is False;
}

# ------------------------------------------------------------------ the public routes stay public

test "reporting needs no account but the incident picture does" {
    svc = install("accounts");
    commander = new_member("commander");
    bind(commander);
    open_incident(GOAL);
    svc.process_pending();
    # in a flood you cannot ask a caller to sign up
    sign_out();
    assert submit_report("water rising in Kaduwela")["status"] == "queued";
    with testraises(ServiceError) as ei {
        get_incident();
    }
    assert status_of(ei) == 401;
}
