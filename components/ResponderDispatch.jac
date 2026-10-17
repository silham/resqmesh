"""The vehicle operator's dispatch screen: the last mile on the dispatch side.

A crew (an army boat, a truck driver) opens this on a phone and sees their live dispatch the
moment the commander approves it. Access follows how a government fleet actually works: the
vehicle is an anonymous asset identified by its call sign only.

* The command post issues one enrolment link per vehicle, `/responder?c=<one-time code>`.
  Opening it exchanges the code for credentials the page signs in with, bound to that call
  sign, and the code is then dead. No personal login: the link is the onboarding, which
  suits a shared asset that changes crew each shift. A link that was itself the credential
  would keep working wherever it ended up (a Referer header, browser history, a screenshot).
* Reopening the page later reuses the session the browser already holds, so a crew does not
  need a new link, and losing a phone is a revoke, not a password change.
* Delivery is pull, not push: the page polls, so a dropped signal costs nothing; on
  reconnect the current order is simply there. When an order first arrives the page also
  raises a browser notification so an idle phone buzzes.
"""

import from "react" { useEffect }
import from "@mantine/core" { Alert, Anchor, Badge, Button, Card, Group, Loader, Select, Stack, Text }
import from "@mantine/notifications" { notifications }
import from "@jac/runtime" { jacLogin, jacIsLoggedIn }
import from resqmesh.service.endpoints { enrol, me, get_incident, responder_update, health, open_session }
import from ..lib.api { isUnauthorized, parseError }
import from ..lib.format { divisionName, isCompleted, navigationUrl }
import from .PublicShell { PublicShell, publicMessage }

glob POLL_MS: int = 3000;

"""Raise a system notification, if the operator allowed them."""
def notifyDispatched(vehicleId: str, area: str) -> None {
    browserWindow: any = window;
    note: any = browserWindow["Notification"];
    if not note or note.permission != "granted" {
        return;
    }
    new(note, vehicleId + " — DISPATCH ORDER", {"body": "Proceed to " + area});
}

def:pub ResponderDispatch() -> JsxElement {
    has booting: bool = True;
    has signedIn: bool = False;
    has role: str = "";
    has vehicleId: str = "";
    has enrolError: str = "";
    has view: any = None;
    has loaded: bool = False;
    has refused: bool = False;
    has failure: any = None;
    has wasDispatched: Ref[bool] = Ref(False);

    # Sign in with whatever this browser can use: the one-time link first, then a session it
    # already holds, then (open mode only) the local operator account.
    async def boot() -> None {
        code: any = new(URLSearchParams, window.location.search).get("c");  # jac:ignore[E1053]
        creds: any = None;
        ok: bool = False;
        if code {
            try {
                creds = await enrol(code, "crew device");
                ok = await jacLogin(creds["username"], creds["password"]);
                if not ok {
                    enrolError = "That link could not be used to sign in.";
                }
            } except Exception as e {
                enrolError = "That link has already been used or has expired.";
            }
            # Spent either way: scrub it from the address bar so it is not left in the
            # history for the next person holding the phone.
            window.history.replaceState({}, "", window.location.pathname);
        }
        if not ok and not jacIsLoggedIn() and not code {
            ok = await openModeSignIn();
        }
        if jacIsLoggedIn() {
            await adoptSession();
        }
        booting = False;
    }

    async def openModeSignIn() -> bool {
        status: any = None;
        local: any = None;
        done: bool = False;
        try {
            status = await health();
            if status["auth_mode"] == "open" {
                local = await open_session();
                if local {
                    done = await jacLogin(local["username"], local["password"]);
                }
            }
        } except Exception as e {
            done = False;
        }
        return done;
    }

    # Ask the server who this session is: the call sign comes from the enrolment, not from
    # a dropdown, and the server refuses updates for any other vehicle.
    async def adoptSession() -> None {
        who: any = None;
        try {
            who = await me();
            role = who["role"];
            if who["vehicle_id"] {
                vehicleId = who["vehicle_id"];
            }
            signedIn = True;
            enrolError = "";
        } except Exception as e {
            signedIn = False;
        }
    }

    async def poll() -> None {
        if not signedIn {
            return;
        }
        got: any = None;
        try {
            got = await get_incident(int(Date.now()));
            view = got;
            failure = None;
            refused = False;
        } except Exception as e {
            if parseError(e)["code"] == "not_found" {
                # No incident open is a normal state for a crew on standby.
                view = None;
                failure = None;
            } elif isUnauthorized(e) {
                refused = True;
            } else {
                failure = e;
            }
        }
        loaded = True;
    }

    async can with entry {
        await boot();
    }

    useEffect(lambda {
        timer: any = None;
        if signedIn {
            poll();
            timer = setInterval(lambda { poll(); }, POLL_MS);
        }
        return lambda {
            if timer {
                clearInterval(timer);
            }
        };
    }, [signedIn]);

    # Ask for notification permission once, when the operator identifies their vehicle.
    useEffect(lambda {
        browserWindow: any = window;
        note: any = browserWindow["Notification"];
        if vehicleId and note and note.permission == "default" {
            note.requestPermission();
        }
    }, [vehicleId]);

    assignment: any = None;
    cluster: any = None;
    if view and view["plan"] and vehicleId {
        for a in view["plan"]["assignments"] {
            if not assignment and a["vehicle_id"] == vehicleId {
                assignment = a;
            }
        }
    }
    if assignment {
        for c in view["clusters"] {
            if not cluster and c["cluster_id"] == assignment["cluster_id"] {
                cluster = c;
            }
        }
    }
    areaName: str = divisionName(view, cluster["gn_id"]) if cluster else "";

    # A plan that still awaits the commander is a proposal, not an order to move.
    dispatched: bool = bool(assignment) and not view["awaiting_decision"];
    done: bool = bool(cluster) and isCompleted(view, cluster["cluster_id"]);

    # Buzz the phone once, on the transition into a live dispatch.
    useEffect(lambda {
        if dispatched and not wasDispatched.current and vehicleId and areaName {
            notifyDispatched(vehicleId, areaName);
        }
        wasDispatched.current = dispatched;
    }, [dispatched, vehicleId, areaName]);

    async def sendUpdate(status: str, reason: str) -> None {
        if not vehicleId or not cluster {
            return;
        }
        try {
            await responder_update(vehicleId, cluster["cluster_id"], status, reason if reason else None);
            notifications.show({"color": "teal", "message": "Reported: " + status.replace("_", " ")});
        } except Exception as e {
            # A crew reading this is in a vehicle, not a terminal.
            notifications.show({
                "color": "red",
                "message": publicMessage(
                    parseError(e)["code"],
                    "That update did not reach the command post. Try again, or call it in."
                )
            });
        }
        # The writer applies it within about a second; look now and again just after.
        await poll();
        setTimeout(lambda { poll(); }, 1500);
    }

    # A crew is the only source of truth about why a job cannot be done: a road gone since
    # the hazard model last looked, a bridge out. Without a way to say so the optimiser
    # proposes the same pairing on the next tick and the crew declines it again.
    def decline(e: MouseEvent) {
        why: any = window.prompt("Why can you not take this? (e.g. bridge out at Kaduwela)");
        if why and why.trim() {
            sendUpdate("declined", why.trim());
        }
    }

    def pickVehicle(v: any) {
        vehicleId = v if v else "";
    }

    vehicles: any = view["vehicles"] if view and view["vehicles"] else [];
    choices: list[dict[str, str]] = [{"value": v["vehicle_id"], "label": v["vehicle_id"] + " · " + v["kind"]} for v in vehicles];
    needsLink: bool = bool(enrolError) or refused or (not booting and not signedIn);
    waiting: bool = booting or (signedIn and not loaded);
    navUrl: str = navigationUrl(cluster["centroid_lat"], cluster["centroid_lon"]) if cluster else "";

    <PublicShell title="Responder dispatch">
        <Stack gap="md">
            {#* A responder device is bound to its call sign by the enrolment. The picker is
                only for an operator signed in as a commander or dispatcher (open mode
                included), who is not bound to one vehicle. *#}
            {signedIn and role == "responder" and (
                <Card withBorder={True} radius="md" padding="sm">
                    <Text size="xs" c="dimmed" tt="uppercase">
                        This device
                    </Text>
                    <Text fw={700} size="lg" ff="monospace">
                        {vehicleId if vehicleId else "—"}
                    </Text>
                </Card>
            )}
            {signedIn and role != "responder" and (
                <Select
                    label="Your vehicle"
                    placeholder="Select your call sign"
                    value={vehicleId if vehicleId else None}
                    onChange={pickVehicle}
                    data={choices}
                    disabled={waiting or len(choices) == 0}
                    size="md"
                />
            )}

            {waiting and <Loader />}
            {needsLink and (
                <Alert color="red" variant="light" title="Access link required">
                    {enrolError if enrolError else "This device is not authorised."}
                    {" Ask the command post for a new dispatch link ("}
                    <Text span={True} ff="monospace">/responder?c=…</Text>
                    {"). Each link works once."}
                </Alert>
            )}
            {failure and not refused and (
                <Alert color="red" variant="light">
                    {publicMessage(
                        parseError(failure)["code"],
                        "Cannot reach the dispatch server. Your last update may not have been recorded — tell the command post by radio."
                    )}
                </Alert>
            )}

            {signedIn and vehicleId and not assignment and loaded and not failure and (
                <Card withBorder={True} radius="md" padding="lg">
                    <Text fw={600}>Standby</Text>
                    <Text size="sm" c="dimmed">
                        {"No active dispatch for " + vehicleId + ". This screen updates automatically the moment you are assigned."}
                    </Text>
                </Card>
            )}

            {assignment and cluster and done and (
                <Card withBorder={True} radius="md" padding="lg">
                    <Text fw={600}>Job complete — standby</Text>
                    <Text size="sm" c="dimmed">
                        {"You reported " + areaName + " served. You are free for the next dispatch; this screen updates when you are re-tasked."}
                    </Text>
                </Card>
            )}

            {assignment and cluster and not done and (
                <Card withBorder={True} radius="md" padding="lg" bg={"teal.0" if dispatched else "yellow.0"}>
                    <Stack gap="sm">
                        <Badge color={"teal" if dispatched else "yellow"} variant="filled" size="lg">
                            {"● DISPATCHED" if dispatched else "AWAITING COMMANDER APPROVAL"}
                        </Badge>
                        <div>
                            <Text size="xs" c="dimmed" tt="uppercase">
                                Proceed to
                            </Text>
                            <Text fw={700} size="xl">
                                {areaName}
                            </Text>
                            <Text size="xs" c="dimmed" ff="monospace">
                                {cluster["centroid_lat"].toFixed(5) + ", " + cluster["centroid_lon"].toFixed(5)}
                            </Text>
                        </div>
                        <Anchor href={navUrl} target="_blank" rel="noreferrer">
                            <Button variant="light" fullWidth={True}>
                                Navigate to location →
                            </Button>
                        </Anchor>
                        <Stack gap={2}>
                            <Text size="sm">
                                Emergency: <b>{cluster["hazard_type"]}</b>
                            </Text>
                            <Text size="sm">
                                People to reach: <b>{assignment["load"]}</b>
                            </Text>
                            <Text size="sm">
                                ETA <b>{assignment["eta_minutes"].toFixed(0) + " min"}</b>{" · " + assignment["distance_km"].toFixed(1) + " km"}
                            </Text>
                        </Stack>
                        <Text size="xs" c="dimmed" ff="monospace">
                            {view["plan"]["plan_id"] + " · confidence " + (cluster["confidence_0_1"] * 100).toFixed(0) + "%"}
                        </Text>
                        {not dispatched and (
                            <Text size="xs" c="dimmed">
                                Do not move yet — this assignment is proposed and not approved.
                            </Text>
                        )}
                        {dispatched and (
                            <Stack gap={6}>
                                <Group grow={True}>
                                    <Button size="xs" variant="default" onClick={lambda { sendUpdate("en_route", ""); }}>
                                        En route
                                    </Button>
                                    <Button size="xs" variant="default" onClick={lambda { sendUpdate("on_scene", ""); }}>
                                        On scene
                                    </Button>
                                    <Button size="xs" color="teal" onClick={lambda { sendUpdate("complete", ""); }}>
                                        Complete
                                    </Button>
                                </Group>
                                <Button size="xs" variant="subtle" color="orange" onClick={decline}>
                                    Cannot take this
                                </Button>
                            </Stack>
                        )}
                    </Stack>
                </Card>
            )}
        </Stack>
    </PublicShell>
}
