"""The key to the map.

A blue polygon, three sizes of coloured dot and two kinds of badge mean nothing to a
commander who did not build the system, so the key translates them. It also states the
one thing the map cannot show honestly: an estimated position is inferred from the
clock, not reported by the vehicle. The place to disclose a limitation is where someone
is looking at its consequence.
"""

import from "@mantine/core" { ActionIcon, Box, Collapse, Group, Paper, Stack, Text }
import from ..lib.vehicleIcon { vehicleBadgeSvg }

glob ROUTE: str = "#0bbbb1";

def Row(swatch: any, label: str) -> JsxElement {
    <Group gap={8} wrap="nowrap" align="center">
        <Box w={26} style={{"display": "flex", "alignItems": "center", "justifyContent": "center", "flexShrink": 0}}>
            {swatch}
        </Box>
        <Text size="xs" c="dimmed" style={{"lineHeight": 1.3}}>
            {label}
        </Text>
    </Group>
}

def Dot(color: str, size: int) -> JsxElement {
    <Box w={size} h={size} bg={color} style={{"borderRadius": "50%", "border": "2px solid #2f6fed"}} />
}

# The badge is the same constant markup the map draws, with no external or user input in it.
def Badge(kind: str, dispatched: bool) -> JsxElement {
    <span>{unsafe_html(vehicleBadgeSvg(kind, dispatched, 22))}</span>
}

def:pub MapLegend(threeDimensional: bool = False) -> JsxElement {
    # Open by default only on a wide 2D map: in 3D the toolbar already takes the corner,
    # and on a phone the key would cover the map.
    phone: any = window.matchMedia("(max-width: 600px)");
    has open: bool = not threeDimensional and not phone.matches;

    def toggle() {
        open = not open;
    }

    <Paper
        shadow="sm"
        radius="md"
        p={"sm" if open else 6}
        style={{
            "position": "absolute",
            "left": 12,
            "bottom": 24,
            # Above Leaflet's panes (400-700); the map container isolates its own
            # stacking context, so this sits on top without fighting it.
            "zIndex": 500,
            "background": "rgba(255,255,255,0.94)",
            "maxWidth": 230,
            "maxHeight": "45%",
            "overflowY": "auto"
        }}
    >
        <Group justify="space-between" wrap="nowrap" gap="xs">
            <Text size="xs" fw={700}>
                Map key
            </Text>
            <ActionIcon
                variant="subtle"
                size="sm"
                onClick={toggle}
                aria-label={"Hide map key" if open else "Show map key"}
            >
                {"−" if open else "+"}
            </ActionIcon>
        </Group>

        <Collapse expanded={open}>
            <Stack gap={10} mt={8}>
                <Stack gap={4}>
                    <Text size="xs" fw={600}>
                        Incidents — size = urgency
                    </Text>
                    <Row swatch={<Dot color="#e03131" size={15} />} label="P1 critical" />
                    <Row swatch={<Dot color="#f08c00" size={12} />} label="P2 urgent" />
                    <Row swatch={<Dot color="#2f9e44" size={10} />} label="P3 monitored" />
                    <Row
                        swatch={
                            <svg width={16} height={16}>
                                <circle cx="8" cy="8" r="6" fill="#ced4da" fillOpacity="0.55" stroke="#868e96" strokeWidth="2" strokeDasharray="3 3" />
                            </svg>
                        }
                        label="Served — crew reported complete"
                    />
                    <Text size="9px" c="dimmed" pl={34} style={{"lineHeight": 1.3}}>
                        Ring colour is the hazard type.
                    </Text>
                </Stack>

                <Stack gap={4}>
                    <Text size="xs" fw={600}>
                        Hazard
                    </Text>
                    <Row
                        swatch={<Box w={18} h={11} style={{"background": "rgba(47,111,237,0.25)", "border": "1px solid #2f6fed"}} />}
                        label="Modelled flood extent"
                    />
                    <Row
                        swatch={<Box w={18} h={11} style={{"background": "rgba(232,115,12,0.2)", "border": "1px solid #e8730c"}} />}
                        label="Landslide-susceptible slope"
                    />
                    <Row swatch={<Box w={22} h={4} bg="#e03131" />} label="Impassable road — modelled or reported" />
                </Stack>

                <Stack gap={4}>
                    <Text size="xs" fw={600}>
                        Fleet
                    </Text>
                    <Row swatch={<Badge kind="boat" dispatched={False} />} label="Boat — available" />
                    <Row swatch={<Badge kind="ambulance" dispatched={False} />} label="Ambulance — available" />
                    <Row swatch={<Badge kind="truck" dispatched={True} />} label="Truck — dispatched (teal)" />
                    <Text size="9px" c="dimmed" pl={34} style={{"lineHeight": 1.3}}>
                        Shown at its depot: the only position the system knows.
                    </Text>
                </Stack>

                <Stack gap={4}>
                    <Text size="xs" fw={600}>
                        Dispatch
                    </Text>
                    <Row
                        swatch={
                            <svg width={22} height={8}>
                                <line x1="0" y1="4" x2="22" y2="4" stroke={ROUTE} strokeWidth="3" strokeDasharray="5 4" />
                            </svg>
                        }
                        label="Plan route · flow after approval; dashed = approximate"
                    />
                    <Row
                        swatch={
                            <svg width={16} height={16}>
                                <circle cx="8" cy="8" r="6" fill="#fff" stroke={ROUTE} strokeWidth="2" strokeDasharray={"" if threeDimensional else "3 3"} />
                            </svg>
                        }
                        label="Estimated position — inferred from ETA, not tracked"
                    />
                </Stack>
            </Stack>
        </Collapse>
    </Paper>
}
