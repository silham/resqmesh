import inspect;
import from jaclang.server.identity.user_manager { UserManager }
import from jaclang.server.identity.app_tokens { token_create, token_consume, token_revoke }
def dump(*a: any) -> None {
    with open('/private/tmp/claude-501/-Users-shakil-Dev-TealTitans-resqmesh-jac/41ccd3da-8650-41b9-b0bd-c447bbcba91a/scratchpad/out.txt', 'a') as f { f.write(' '.join([str(x) for x in a]) + '\n'); }
}
test "intro" {
    dump([n for n in dir(UserManager) if not n.startswith("__")]);
    for n in ["create_internal_user", "authenticate", "login", "verify_password", "find_user_by_identity", "reset_password_by_user_id", "get_root_id", "validate_token", "login_internal_user", "authenticate_internal_user"] {
        if hasattr(UserManager, n) {
            try { dump(inspect.getsource(getattr(UserManager, n))); } except Exception as e { dump(n, "nosource", e); }
        }
    }
    dump(inspect.getsource(token_create));
    dump(inspect.getsource(token_consume));
}
