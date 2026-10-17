"""Where the emergency is, from the phone that is standing in it.

A place *name* alone has to survive both the reporter knowing their Grama Niladhari
division and the gazetteer matching what they typed, and a matched name yields only the
division's centroid: every incident in a division lands on one pin, the clustering radius
ends up measuring the distance between administrative centres, and the responder's
"navigate" link points at the middle of a division rather than at the people.

So there are two ways in, because neither works alone: the device's own fix, which is exact
and often refused, and a pin on a map, which always works and needs the reporter to
recognise where they are.

`value` is None or {lat, lon, accuracy_m, location_source}; `onChange` receives the same
shape, or None when the reporter clears it. `location_source` is "gps" for the device's own
fix and "map_pin" for a dropped pin, the two values the report endpoint accepts.
"""

import from "@mantine/core" { Alert, Box, Button, Group, Text }
import from "react-leaflet" { MapContainer, Marker, TileLayer, useMapEvents }
import from ..lib.pinIcon { pinIcon }

glob KELANI: list[float] = [6.95, 79.98];

"""Accepts a click anywhere on the map as the reported position."""
def PinOnClick(onPick: Callable[[float, float], None]) -> JsxElement {
    useMapEvents({
        "click": lambda (e: any) {
            onPick(e.latlng.lat, e.latlng.lng);
        }
    });
    <></>
}

def:pub LocationPicker(value: any, onChange: Callable[[any], None]) -> JsxElement {
    has asking: bool = False;
    has denied: bool = False;
    has showMap: bool = False;

    def useDevice(e: MouseEvent) {
        nav: any = navigator;
        if not nav.geolocation {
            denied = True;
            showMap = True;
            return;
        }
        asking = True;
        nav.geolocation.getCurrentPosition(
            lambda (pos: any) {
                asking = False;
                denied = False;
                reading = pos.coords.accuracy;
                onChange({
                    "lat": pos.coords.latitude,
                    "lon": pos.coords.longitude,
                    "accuracy_m": reading if Number.isFinite(reading) else None,
                    "location_source": "gps"
                });
            },
            lambda (err: any) {
                # Refusing is normal and must not be a dead end: fall through to the map.
                asking = False;
                denied = True;
                showMap = True;
            },
            {"enableHighAccuracy": True, "timeout": 10000, "maximumAge": 60000}
        );
    }

    def pin(lat: float, lon: float) {
        onChange({"lat": lat, "lon": lon, "accuracy_m": None, "location_source": "map_pin"});
    }

    def toggleMap(e: MouseEvent) {
        showMap = not showMap;
    }

    def clearFix(e: MouseEvent) {
        onChange(None);
    }

    accuracy: any = None;
    hasAccuracy: bool = False;
    summary: str = "";
    if value {
        accuracy = value["accuracy_m"];
        hasAccuracy = bool(accuracy) or accuracy == 0;
        summary = "Location set: " + value["lat"].toFixed(5) + ", " + value["lon"].toFixed(5);
        if hasAccuracy {
            summary = summary + " (±" + str(Math.round(accuracy)) + " m)";
            if accuracy > 200 {
                summary = summary + " — too rough to use on its own, so please name the place too.";
            }
        } else {
            summary = summary + " (from the map)";
        }
    }

    <Box>
        <Text size="sm" fw={500} mb={4}>
            Where are you?
        </Text>
        <Group gap="xs" mb="xs">
            <Button size="xs" variant="light" loading={asking} onClick={useDevice}>
                Use my location
            </Button>
            <Button size="xs" variant="subtle" onClick={toggleMap}>
                {"Hide map" if showMap else "Point on a map"}
            </Button>
            {value and (
                <Button size="xs" variant="subtle" color="gray" onClick={clearFix}>
                    Clear
                </Button>
            )}
        </Group>

        {denied and not value and (
            <Alert color="gray" variant="light" p="xs" mb="xs">
                <Text size="xs">
                    Your device did not share a location. Point on the map instead, or just name the place in your message — both work.
                </Text>
            </Alert>
        )}

        {value and (
            <Text size="xs" c="teal.8" mb="xs">
                {summary}
            </Text>
        )}

        {showMap and (
            <Box style={{"height": 240, "borderRadius": 8, "overflow": "hidden"}}>
                <MapContainer
                    center={[value["lat"], value["lon"]] if value else KELANI}
                    zoom={15 if value else 12}
                    style={{"height": "100%", "width": "100%"}}
                >
                    <TileLayer
                        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                    />
                    <PinOnClick onPick={pin} />
                    {value and <Marker position={[value["lat"], value["lon"]]} icon={pinIcon()} />}
                </MapContainer>
            </Box>
        )}
        {showMap and (
            <Text size="xs" c="dimmed" mt={4}>
                Tap the map where the emergency is.
            </Text>
        )}
    </Box>
}
