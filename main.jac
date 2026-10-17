"""ResQ-Mesh: report, bulletins, responder dispatch and the commander console.

The server side registers the endpoints (resqmesh/service/endpoints.jac), boots the
shared runtime, and declares the three scheduled tasks that keep the incident moving:

* drain      the single writer: boots the application on its first tick, then runs
             queued commands in order, one batch at a time
* heartbeat  queues a tick when idle, so time-based triggers (hazard TTL) still fire
* telegram   polls the bot for field reports (off unless a bot token is configured)
"""

import from resqmesh.service.app { boot, booted }
import from resqmesh.service.endpoints {
    bootstrap, create_account, decide, enrol, get_incident, halt, health, issue_enrolment,
    list_accounts, list_devices, me, open_incident, open_session, place_report, public_alerts,
    responder_update, resume, revoke_device, sitrep_pdf, stand_down, submit_report, telegram_webhook
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=1)
def drain_commands -> None {
    boot().service.process_pending();
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=60)
def heartbeat -> None {
    rt = booted();
    if rt is not None {
        rt.service.heartbeat();
    }
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=5)
def poll_telegram -> None {
    rt = booted();
    if rt is not None and rt.poller is not None {
        rt.poller.poll_once();
    }
}
