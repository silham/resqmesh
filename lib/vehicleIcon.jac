"""Map markers for the fleet, one glyph per vehicle kind.

Inline SVG in a Leaflet divIcon, deliberately: no icon library, no CDN request, no font to
load. The console has to work on a laptop at a command post with no internet.

Two things read at a glance: the kind (boat, ambulance, truck) from the glyph shape, so it
survives printing or colour blindness, and the state (idle at the depot: white; committed to
a dispatch: teal, matching its route line).
"""

import from "leaflet" { divIcon }

glob DISPATCHED: str = "#0bbbb1";   # the route colour, so a crew and its route read as one thing
glob IDLE: str = "#ffffff";
glob INK: str = "#212529";
glob BADGE: int = 24;

# 16x16 glyphs, drawn to sit inside the badge circle.
glob GLYPHS: dict[str, str] = {
    # Hull plus sail: reads as a boat even at 16 px.
    "boat": '<path d="M1.6 9.4h12.8l-2.1 3.9H3.7z"/><path d="M7.4 1.3h1.2v7.1H7.4z"/><path d="M9.2 2.4l3.1 4.9H9.2z"/>',
    # A cross: the least ambiguous medical glyph there is.
    "ambulance": '<path d="M6.4 2.2h3.2v4.2H14v3.2H9.6V14H6.4V9.6H2V6.4h4.4z"/>',
    # Box body, cab and two wheels.
    "truck": (
        '<path d="M1.2 3.8h7.4v6.4H1.2z"/><path d="M8.6 5.9h2.9l2.3 2.4v1.9H8.6z"/>'
        + '<circle cx="4.1" cy="11.6" r="1.5"/><circle cx="11.3" cy="11.6" r="1.5"/>'
    )
};

# A kind the fleet grows into with no glyph: a plain dot, still showing its state.
glob FALLBACK: str = '<circle cx="8" cy="8" r="3.4"/>';

def glyphFor(kind: str) -> str {
    lowered = kind.lower();
    for key in ["boat", "ambulance", "truck"] {
        if key in lowered {
            return GLYPHS[key];
        }
    }
    return FALLBACK;
}

"""The badge as raw SVG markup, shared by the map marker and the legend so the key on
screen is drawn by the same code as the thing it explains."""
def vehicleBadgeSvg(kind: str, dispatched: bool, size: int = 24) -> str {
    fill = DISPATCHED if dispatched else IDLE;
    ink = "#ffffff" if dispatched else INK;
    return (
        f'<svg viewBox="0 0 24 24" width="{size}" height="{size}" aria-hidden="true">'
        + f'<circle cx="12" cy="12" r="10.5" fill="{fill}" stroke="{INK}" stroke-width="1.6"/>'
        + f'<g transform="translate(4 4)" fill="{ink}">{glyphFor(kind)}</g></svg>'
    );
}

"""A badge marker for one vehicle; `dispatched` fills it teal, so a commander can count
committed crews without reading a single label."""
def vehicleIcon(kind: str, dispatched: bool) -> any {
    return divIcon({
        "html": vehicleBadgeSvg(kind, dispatched, BADGE),
        "className": "resqmesh-vehicle-marker",
        "iconSize": [BADGE, BADGE],
        "iconAnchor": [BADGE / 2, BADGE / 2],
        "tooltipAnchor": [0, 0 - BADGE / 2]
    });
}
