"""Route `/console`: the commander console.

What is on screen is decided in a fixed order: the session check, then the sign-in gate,
then "no incident is open", then the console itself.

The session check and the incident poll are deliberately separate things. The session is
asked once, when the page opens and again after a sign-in or a rejected poll; it is never
polled. The incident poll starts only once the session has said yes. Deriving the sign-in
gate from the poll would make signing in impossible: every poll tick while signed out
fails, resets the screen to "loading" and unmounts the form with whatever had been typed
in it. A poll must never be the thing that decides whether you are signed in.
"""

import from "react" { useEffect }
import from "@jac/runtime" { jacIsLoggedIn, jacLogout }
import from "@mantine/core" { Alert, AppShell, Button, Loader, Stack }
import from "@mantine/hooks" { useMediaQuery }
import from resqmesh.service.endpoints { get_incident, me as whoAmI }
import from ..lib.api { parseError }
import from ..components.CrisisOverview { CrisisOverview }
import from ..components.ConsoleWorkspace { ConsoleWorkspace }
import from ..components.Header { Header }
import from ..components.Login { Login }
import from ..components.OpenIncident { OpenIncident }
import from ..components.Records { Records }
import from ..components.ConsoleHelpers { stillStarting }

glob POLL_MS: int = 3000;

def:pub Console() -> JsxPage {
    # "checking" until the first answer, then "in", "out" (show the sign-in gate) or
    # "error" (the server did not answer, which no sign-in form fixes).
    has session: str = "checking";
    has sessionError: str = "";
    has user: any = None;
    has view: any = None;
    has viewError: str = "";
    has noIncident: bool = False;
    has pollOn: bool = False;
    has tab: str = "queue";
    has records: bool = False;
    has lastContact: float = 0;
    has now: float = 0;
    # Bumped whenever the session ends, so an answer still in flight from the old one
    # cannot put a stale incident back on screen.
    has epoch: Ref[any] = Ref(0);
    has inFlight: Ref[bool] = Ref(False);

    mq: any = useMediaQuery("(max-width: 1023px)");
    wideMq: any = useMediaQuery("(min-width: 1600px)");
    isMobile: bool = True if mq else False;
    isWide: bool = True if wideMq else False;
    headerHeight: int = 64;

    def endSession() {
        n: any = epoch.current;
        epoch.current = n + 1;
    }

    def showLoginGate() {
        user = None;
        view = None;
        noIncident = False;
        pollOn = False;
        lastContact = 0;
        session = "out";
    }

    # Is there a session? No token means no, without asking: the runtime reacts to a
    # refused call on a protected endpoint by discarding the token and reloading the
    # page, so asking while signed out would only reload in a loop. With a token the
    # server is asked who it belongs to; if that token is dead the same reload happens
    # once, with the token gone, and lands on the sign-in gate.
    async def checkSession() {
        if not jacIsLoggedIn() {
            showLoginGate();
            return;
        }
        who: any = None;
        try {
            who = await whoAmI();
            if not who or not who["username"] {
                # The refusal path above: a reload is already on its way.
                showLoginGate();
                return;
            }
            user = who;
            sessionError = "";
            session = "in";
            pollOn = True;
        } except Exception as e {
            err = parseError(e);
            if err["status"] == 401 or err["status"] == 403 {
                jacLogout();
                showLoginGate();
            } elif stillStarting(err["message"]) {
                # The server is booting: keep the spinner and ask again shortly.
                session = "checking";
                setTimeout(lambda { checkSession(); }, 2000);
            } else {
                sessionError = err["message"];
                session = "error";
            }
        }
    }

    # A session that died while the console was open: drop the dead token and check
    # again, which puts the sign-in gate up through the normal route instead of leaving
    # the screen stuck on an error nobody can act on. (The runtime caches reads for a
    # minute, so a cached "who am I" would still answer yes if the token were kept.)
    async def sessionEnded() {
        endSession();
        pollOn = False;
        jacLogout();
        await checkSession();
    }

    async def fetchView() {
        if inFlight.current {
            return;
        }
        inFlight.current = True;
        mine: any = epoch.current;
        got: any = None;
        timeout: any = None;
        try {
            deadline: any = new(Promise, lambda (_resolve: any, reject: any) {
                timeout = setTimeout(lambda {
                    reject.call(None, {"message": "The server did not respond within 15 seconds."});
                }, 15000);
            });
            got = await Promise.race([get_incident(int(Date.now())), deadline]);
            if mine != epoch.current {
                return;
            }
            if not got or not got["incident_id"] {
                # A refused poll comes back empty while the runtime drops the dead
                # token and reloads. Treat it as the session having ended.
                await sessionEnded();
                return;
            }
            view = got;
            lastContact = Date.now();
            now = Date.now();
            viewError = "";
            noIncident = False;
        } except Exception as e {
            if mine != epoch.current {
                return;
            }
            err = parseError(e);
            if err["status"] == 401 {
                await sessionEnded();
            } elif err["code"] == "not_found" or err["status"] == 404 {
                # No incident is open: that is a state, not a failure.
                view = None;
                viewError = "";
                noIncident = True;
                pollOn = False;
            } elif stillStarting(err["message"]) {
                viewError = "The server is restarting. The last received picture is shown.";
            } else {
                viewError = err["message"];
                # A rejection is a verdict, not an outage: polling it every three
                # seconds fixes nothing. Outages keep being retried.
                if err["status"] >= 400 and err["status"] < 500 {
                    pollOn = False;
                }
            }
        } finally {
            clearTimeout(timeout);
            inFlight.current = False;
        }
    }

    # What every write calls when it is done: read the incident now, and again once the
    # writer (which works asynchronously) has had a moment to apply the command. It also
    # restarts a poll that had stopped on a rejection.
    def refresh() {
        pollOn = True;
        fetchView();
        setTimeout(lambda { fetchView(); }, 1500);
    }

    def signOut() {
        endSession();
        pollOn = False;
        jacLogout();
        user = None;
        view = None;
        noIncident = False;
        viewError = "";
        records = False;
        lastContact = 0;
        session = "out";
    }

    def afterSignIn() {
        checkSession();
    }

    def retrySession() {
        session = "checking";
        checkSession();
    }

    async can with entry {
        await checkSession();
    }

    # The incident poll, running only while signed in and not stopped by a rejection.
    useEffect(lambda {
        timer: any = None;
        if session == "in" and pollOn {
            fetchView();
            timer = setInterval(lambda { fetchView(); }, POLL_MS);
        }
        return lambda {
            if timer {
                clearInterval(timer);
            }
        };
    }, [session, pollOn]);

    useEffect(lambda {
        timer: any = setInterval(lambda { now = Date.now(); }, 1000);
        return lambda { clearInterval(timer); };
    }, []);

    signedIn: bool = session == "in";
    # Only a commander may authorise a dispatch or freeze the response. Greying the
    # buttons out for everyone else is honesty, not security (the server refuses them
    # regardless), but a dispatcher should not be invited to click Approve and then told no.
    canAct: bool = False;
    if user {
        canAct = user["role"] == "commander";
    }
    attention: bool = False;
    halted: bool = False;
    if view {
        attention = bool(view["awaiting_decision"] or view["escalated"]);
        halted = view["status"] == "halted";
    }
    stale: bool = bool(viewError) or (lastContact > 0 and now - lastContact > 15000);
    actionsEnabled: bool = canAct and not stale and not halted and not view["busy"] if view else False;

    def openDecision() {
        tab = "approval";
    }

    def openRecords() {
        records = True;
    }
    def closeRecords() {
        records = False;
    }
    def pickTab(v: str) {
        tab = v;
    }

    loading: bool = session == "checking" or (signedIn and not view and not viewError and not noIncident);

    <AppShell header={{"height": headerHeight}} padding={0} className="crisis-app">
        <AppShell.Header>
            <Header
                view={view}
                me={user}
                compact={isMobile}
                canAct={canAct}
                refresh={refresh}
                onOpenRecords={openRecords}
                onSignOut={signOut}
            />
        </AppShell.Header>

        <AppShell.Main className={"crisis-main" if signedIn and view else "crisis-main is-gated"}>
            {if loading {
                <Loader m="xl" />
            }}
            {if session == "out" {
                <Login onSignedIn={afterSignIn} />
            }}
            {if signedIn and noIncident {
                <OpenIncident me={user} canAct={canAct} refresh={refresh} />
            }}
            {if session == "error" {
                <Alert color="red" title="Cannot reach the server" m="md">
                    <Stack gap="xs">
                        <span>{sessionError + " — check that the server is running."}</span>
                        <Button variant="default" size="xs" onClick={retrySession}>
                            Try again
                        </Button>
                    </Stack>
                </Alert>
            }}
            {if signedIn and viewError and not view and not noIncident {
                <Alert color="red" title="Cannot load the incident" m="md">
                    <Stack gap="sm">
                        <span>{viewError}</span>
                        <Button variant="default" onClick={refresh}>Retry connection</Button>
                    </Stack>
                </Alert>
            }}
            {if signedIn and view {
                <div className="crisis-console">
                    <CrisisOverview view={view} lastContact={lastContact} now={now} stale={stale} />
                    {if stale {
                        <div className="crisis-notice notice-connection" role="alert">
                            <div>
                                <strong>Live updates interrupted</strong>
                                <p>{viewError or "No response received for over 15 seconds."} Showing the last received picture. Dispatch decisions are paused until fresh data arrives.</p>
                            </div>
                            <Button variant="default" onClick={refresh}>Retry connection</Button>
                        </div>
                    }}
                    {if halted {
                        <div className="crisis-notice notice-halt" role="alert">
                            <div>
                                <strong>Response halted</strong>
                                <p>Autonomous processing is paused. A commander can resume it from the header.</p>
                            </div>
                        </div>
                    } elif attention {
                        <div className="crisis-notice notice-decision" role="status">
                            <div>
                                <strong>{"Commander review required" if view["escalated"] else "Dispatch approval required"}</strong>
                                <p>{"The system needs a decision before it can continue." if view["escalated"] else "Review the proposed crews, destinations and risks before authorising dispatch."}</p>
                            </div>
                            <Button color="dark" onClick={openDecision}>Review decision</Button>
                        </div>
                    }}
                    <ConsoleWorkspace
                        view={view} canAct={actionsEnabled} mobile={isMobile} wide={isWide}
                        tab={tab} onTab={pickTab} refresh={refresh}
                    />
                </div>
            }}
        </AppShell.Main>

        {if signedIn and view {
            <Records view={view} me={user} opened={records} onClose={closeRecords} onChanged={refresh} />
        }}
    </AppShell>
}
