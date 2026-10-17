"""ResQ-Mesh: report, bulletins, responder dispatch and the commander console.

This is the application entry. The server side is the endpoints in
resqmesh/service/endpoints.jac and the scheduled tasks in resqmesh/service/tasks.jac; the
client side is the app shell here plus `pages/`, `components/` and `lib/`.
"""

import resqmesh.service.tasks as tasks;
import resqmesh.service.endpoints;
import "@mantine/core/styles.css";
import "@mantine/notifications/styles.css";
import "leaflet/dist/leaflet.css";
import ".styles/global.css";
import ".styles/map.css";
import from "@mantine/core" { MantineProvider }
import from "@mantine/notifications" { Notifications }
import from .lib.theme { theme }

@schedule(trigger=ScheduleTrigger.STATIC, interval=1)
def drain_commands -> None {
    tasks.drain();
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=60)
def heartbeat -> None {
    tasks.beat();
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=5)
def poll_telegram -> None {
    tasks.poll();
}

def:pub app(children: any) -> JsxElement {
    <MantineProvider theme={theme} defaultColorScheme="light">
        <Notifications position="top-right" />
        {children}
    </MantineProvider>
}
