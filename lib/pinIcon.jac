"""The marker a reporter drops to say "the emergency is here".

Inline SVG in a divIcon: no asset pipeline to get wrong, nothing to fetch, and it still
draws when the command post has no internet, which is the condition this system is for.
"""

import from "leaflet" { divIcon }

glob PIN_W: int = 26;
glob PIN_H: int = 34;

glob PIN_SVG: str = (
    '<svg viewBox="0 0 26 34" width="26" height="34" aria-hidden="true">'
    + '<path d="M13 33.2C13 33.2 24.5 20.4 24.5 12.5A11.5 11.5 0 1 0 1.5 12.5C1.5 20.4 13 33.2 13 33.2Z" '
    + 'fill="#0bbbb1" stroke="#212529" stroke-width="1.6" stroke-linejoin="round"/>'
    + '<circle cx="13" cy="12.5" r="4.2" fill="#ffffff"/></svg>'
);

"""A teardrop pin whose point is the reported position, not its centre."""
def:pub pinIcon() -> any {
    return divIcon({
        "html": PIN_SVG,
        # Leaflet's default divIcon styling would draw a white box behind the SVG.
        "className": "resqmesh-pin-marker",
        "iconSize": [PIN_W, PIN_H],
        # The tip, so the pin marks the place rather than hovering above it.
        "iconAnchor": [PIN_W / 2, PIN_H]
    });
}
