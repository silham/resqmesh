"""Manage accounts on a running server.

    jac run --no-takeover scripts/accounts.jac bootstrap cmdr-01 --code SETUP-CODE
    jac run --no-takeover scripts/accounts.jac add dispatch-01 --role dispatcher
    jac run --no-takeover scripts/accounts.jac list
    jac run --no-takeover scripts/accounts.jac enrol BOAT-01 --base-url https://host

The server owns the roster, so this talks to it over HTTP rather than touching its
storage. `bootstrap` creates the very first commander from the one-time setup code the
server prints at start (or `RESQMESH_SETUP_CODE`); once any account exists that door is
closed and every other command signs in as an existing commander first
(`--username`, or `RESQMESH_ADMIN_USER`; the password is prompted for, or read from
`RESQMESH_ADMIN_PASSWORD`).

Passwords are prompted for rather than passed as arguments, because an argument lands in
the shell history and in `ps`.
"""

import argparse;
import getpass;
import os;
import sys;
import httpx;

glob ROLES: list[str] = ["commander", "dispatcher", "citizen"];

obj Server {
    has base: str,
        token: str = "";

    def call(name: str, body: dict[str, any]) -> any {
        headers = {"content-type": "application/json"};
        if self.token {
            headers["authorization"] = f"Bearer {self.token}";
        }
        res = httpx.post(f"{self.base}/function/{name}", json=body, headers=headers, timeout=30.0);
        payload = res.json();
        if res.status_code >= 400 or not payload.get("ok", False) {
            err = payload.get("error") or {};
            raise RuntimeError(err.get("message") or f"{name} failed with HTTP {res.status_code}");
        }
        return payload["data"]["result"];
    }

    def sign_in(username: str, password: str) -> None {
        res = httpx.post(
            f"{self.base}/user/login", json={"identity": username, "credential": password}, timeout=30.0
        );
        if res.status_code >= 400 {
            raise RuntimeError("sign-in refused: check the username and password");
        }
        self.token = res.json()["data"]["token"];
    }
}

def secret(prompt: str, env: str) -> str {
    return os.environ.get(env) or getpass.getpass(prompt);
}

def signed_in(args: any) -> Server {
    server = Server(base=args.url.rstrip("/"));
    username = args.username or os.environ.get("RESQMESH_ADMIN_USER") or input("commander username: ");
    server.sign_in(username, secret(f"password for {username}: ", "RESQMESH_ADMIN_PASSWORD"));
    return server;
}

def new_password(who: str) -> str {
    first = getpass.getpass(f"password for {who}: ");
    if first != getpass.getpass("repeat: ") {
        raise RuntimeError("passwords do not match");
    }
    return first;
}

def main(argv: list[str]) -> int {
    common = argparse.ArgumentParser(add_help=False);
    common.add_argument("--url", `default=os.environ.get("RESQMESH_URL", "http://localhost:8000"), help="the running server");
    common.add_argument("--username", `default=None, help="the commander to sign in as");

    ap = argparse.ArgumentParser(description=__doc__, parents=[common], formatter_class=argparse.RawDescriptionHelpFormatter);
    sub = ap.add_subparsers(dest="command", required=True);

    boot = sub.add_parser("bootstrap", help="create the first commander from the setup code", parents=[common]);
    boot.add_argument("username");
    boot.add_argument("--code", `default=None, help="the setup code; prompted for if omitted");
    boot.add_argument("--name", `default="", help="display name; defaults to the username");

    add = sub.add_parser("add", help="create an account", parents=[common]);
    add.add_argument("username");
    add.add_argument("--role", choices=ROLES, `default="dispatcher");
    add.add_argument("--name", `default="", help="display name; defaults to the username");

    sub.add_parser("list", help="show accounts and their devices", parents=[common]);

    enrol = sub.add_parser("enrol", help="issue a one-time responder enrolment code", parents=[common]);
    enrol.add_argument("vehicle_id");
    enrol.add_argument("--base-url", `default="", help="prefix the code with a console URL to make a link");

    args = ap.parse_args(argv);
    try {
        if args.command == "bootstrap" {
            server = Server(base=args.url.rstrip("/"));
            code = args.code or getpass.getpass("setup code: ");
            made = server.call(
                "bootstrap",
                {"code": code, "username": args.username, "password": new_password(args.username), "display_name": args.name}
            );
            print(f"created commander {made.get('username', args.username)}");
            return 0;
        }
        server = signed_in(args);
        if args.command == "add" {
            made = server.call(
                "create_account",
                {"username": args.username, "password": new_password(args.username), "role": args.role, "display_name": args.name}
            );
            print(f"created {made['username']} ({made['role']})");
            return 0;
        }
        if args.command == "list" {
            rows = server.call("list_accounts", {});
            print(f"{len(rows)} account(s)");
            for row in rows {
                state = "disabled" if row.get("disabled") else "active";
                vehicle = row.get("vehicle_id") or "";
                print(f"  {row['username']:24s} {row['role']:11s} {vehicle:10s} {state}");
            }
            return 0;
        }
        issued = server.call("issue_enrolment", {"vehicle_id": args.vehicle_id});
        code = issued["code"];
        where = f"{args.base_url.rstrip('/')}/responder?c={code}" if args.base_url else code;
        print(f"{args.vehicle_id}: {where}");
        return 0;
    } except RuntimeError as exc {
        print(str(exc), file=sys.stderr);
        return 1;
    } except httpx.HTTPError as exc {
        print(f"cannot reach {args.url}: {exc}", file=sys.stderr);
        return 1;
    }
}

with entry {
    argv = [a for a in sys.argv[1:] if not a.endswith(".jac")];
    exit_code = main(argv);
}
