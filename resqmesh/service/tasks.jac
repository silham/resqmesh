"""The work the scheduled tasks do (declared in main.jac, which is where the scheduler
looks for them).

* drain      the single writer: boots the application on its first tick, then runs
             queued commands in order, one batch at a time
* heartbeat  queues a tick when idle, so time-based triggers (hazard TTL) still fire
* telegram   polls the bot for field reports (off unless a bot token is configured)
"""

import from resqmesh.service.app { boot, booted }

def drain -> None {
    boot().service.process_pending();
}

def beat -> None {
    rt = booted();
    if rt is not None {
        rt.service.heartbeat();
    }
}

def poll -> None {
    rt = booted();
    if rt is not None and rt.poller is not None {
        rt.poller.poll_once();
    }
}
