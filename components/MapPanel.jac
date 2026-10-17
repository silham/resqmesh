"""The map the console shows: lightweight 2D by default, with optional 3D.

The panel owns the 2D/3D choice and the reason for any fallback. The 3D map reports
trouble through `onFlat` (the commander chose 2D) and `onUnavailable` (the renderer could
not start or was lost); either way the flat map takes over and says which it is.
"""

import from "@mantine/core" { Button, Group, Paper, Text }
import from .Map2D { Map2D }
import from .Map3D { Map3D }

def:pub MapPanel(view: any) -> JsxElement {
    has flat: bool = True;
    has failure: str = "";

    def goFlat() {
        flat = True;
    }

    def failed(message: str) {
        failure = message;
    }

    def tryThreeD() {
        failure = "";
        flat = False;
    }

    <div className="incident-map">
        {if flat or failure {
            <>
                <Map2D view={view} />
                <Paper className="map-mode-switch" shadow="sm" p="xs" radius="md">
                    <Group gap="xs">
                        <Button size="sm" onClick={tryThreeD}>{"Retry 3D" if failure else "Switch to 3D"}</Button>
                        <Text size="xs" role="status">{failure or "2D map"}</Text>
                    </Group>
                </Paper>
            </>
        } else {
            <Map3D view={view} onFlat={goFlat} onUnavailable={failed} />
        }}
    </div>
}
