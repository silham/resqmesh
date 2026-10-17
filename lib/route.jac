"""Walking a route line, for the estimated-progress marker.

Read the docstring on `estimatedProgress` before using any of this: the position it
produces is inferred from the clock, not reported by the vehicle. The system has no
live vehicle tracking, so the map must never present this as a fact.

A point is a [lat, lon] pair, in Leaflet's order (the API sends GeoJSON [lon, lat]).
"""

"""Route coordinates converted to Leaflet order."""
def:pub toLatLon(route: any) -> list[any] {
    return [[c[1], c[0]] for c in route["coordinates"]];
}

def:pub squaredGap(a: any, b: any) -> float {
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2;
}

"""The line oriented depot-first.

The API builds routes from the depot outwards, but the geometry comes from road edges
whose direction we do not control, so orientation is checked against the depot rather
than assumed. Getting this backwards would animate every crew driving away from the
emergency."""
def:pub orientedFromDepot(line: list[any], depot: any) -> list[any] {
    if len(line) < 2 {
        return line;
    }
    head = squaredGap(line[0], depot);
    tail = squaredGap(line[len(line) - 1], depot);
    if tail < head {
        return [p for p in reversed(line)];
    }
    return line;
}

"""The point a given fraction (0-1) of the way along a polyline.

Interpolates on raw lat/lon. At basin scale the distortion is metres, far below the
honesty of the estimate itself, so projecting properly would be false rigour."""
def:pub pointAlong(line: list[any], fraction: float) -> any {
    if len(line) == 0 {
        return None;
    }
    if len(line) == 1 {
        return line[0];
    }
    spans: list[float] = [];
    total: float = 0.0;
    for i in range(1, len(line)) {
        d = squaredGap(line[i], line[i - 1]) ** 0.5;
        spans = spans + [d];
        total = total + d;
    }
    if total == 0 {
        return line[0];
    }
    target = max(0.0, min(1.0, fraction)) * total;
    walked: float = 0.0;
    for i in range(len(spans)) {
        if walked + spans[i] >= target {
            t = 0.0 if spans[i] == 0 else (target - walked) / spans[i];
            a = line[i];
            b = line[i + 1];
            return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
        }
        walked = walked + spans[i];
    }
    return line[len(line) - 1];
}

"""How far along its route a crew should be, given the clock, as
{fraction, elapsedMin, etaMin, arrived}, or None.

This is an estimate and nothing more. It is derived from the moment the commander
approved the plan, the solver's ETA, and the current time; the vehicle itself has
reported nothing, because there is no channel for it to report on. Every caller must
render the result as visibly provisional (a dashed, hollow marker) and say "est." in
words. Returns None before approval: an unapproved plan is a proposal, and a proposal
has no crew on the road to estimate."""
def:pub estimatedProgress(view: any, route: any, dispatchedAt: any, now: any) -> any {
    if dispatchedAt is None or not view["plan"] {
        return None;
    }
    found: any = None;
    for a in view["plan"]["assignments"] {
        if a["vehicle_id"] == route["vehicle_id"] and a["cluster_id"] == route["cluster_id"] {
            found = a;
        }
    }
    if not found {
        return None;
    }
    etaMin = found["eta_minutes"];
    elapsedMin = (now.getTime() - dispatchedAt.getTime()) / 60000;
    if elapsedMin < 0 {
        return None;   # clock skew between server and browser
    }
    # A zero-ETA assignment is a crew already on site, not a divide-by-zero.
    fraction = 1.0 if etaMin <= 0 else min(1.0, elapsedMin / etaMin);
    return {"fraction": fraction, "elapsedMin": elapsedMin, "etaMin": etaMin, "arrived": fraction >= 1};
}
