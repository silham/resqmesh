"""The real Grama Niladhari gazetteer: place text -> a real administrative division.

Every dispatch destination must resolve here first. A location that does not
resolve cannot enter a plan, which is what makes the most dangerous hallucination
— a confidently invented place — structurally impossible (proposal section 10.2).

Built from the 757 GN divisions of the Kelani basin downloaded by
`scripts/fetch_data.jac` (HDX admin-4 boundaries), indexed by English **and**
Sinhala name. The real data is messier than a toy lookup, in two ways this module
has to take seriously:

* **Names repeat.** Thirteen English names occur in more than one division. An
  exact hit on a repeated name is *ambiguous*, not a match: returning either one
  would be a coin flip that sends a crew to the wrong place.
* **Reports name areas, not divisions.** A caller says "Biyagama"; the register
  holds Biyagama North, West, South and Colony. Refusing those would discard most
  real reports. So a bare area name resolves to the sibling closest to the group's
  centre, at reduced confidence, and A3 sees that lower confidence.

Both behaviours are visible to the caller through `match_confidence` rather than
hidden, and an ambiguous or unknown place still returns `matched=False` so the
report goes to the unresolved queue instead of being guessed at.
"""

import json;
import math;
import re;
import unicodedata;
import from pathlib { Path }
import from shapely.geometry { Point, shape }
import from shapely.strtree { STRtree }
import from resqmesh.adapters.geo.paths { gn_boundaries_path }
import from resqmesh.contracts.ports { GeocodePort, GeocodeResult }

"""Words that decorate a place name in a report without identifying it."""
glob NOISE: set[str] = {
    "town", "city", "area", "village", "junction", "road", "rd", "street", "lane",
    "bridge", "culvert", "near", "at", "in", "the", "gn", "division", "ward"
};

"""Lowercase, strip accents and punctuation, drop decorative words.

Sinhala is left alone by the accent pass (NFKD on Sinhala does not decompose
into ASCII), so Sinhala names index and match as themselves. Word characters,
Sinhala (U+0D80-U+0DFF) and Tamil (U+0B80-U+0BFF) survive; everything else is a
separator.
"""
def normalise(text: str) -> str {
    decomposed = unicodedata.normalize("NFKD", text);
    stripped = "".join([c for c in decomposed if not unicodedata.combining(c)]);
    cleaned = re.sub(r"[^\w\s඀-෿஀-௿]", " ", stripped.lower());
    words = [w for w in cleaned.split() if w and w not in NOISE];
    return " ".join(words);
}

"""One GN division of the register."""
obj Division {
    has gn_id: str,
        name_en: str,
        name_si: str | None,
        lat: float,
        lon: float,
        ds_division: str,
        district: str,
        # The division's own boundary, kept so a coordinate can be resolved to the
        # division that *contains* it rather than the one whose centre happens to be
        # nearest. None when the source file carried no geometry.
        shape: any = None;
}

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    r = 6371.0088;
    p1 = math.radians(lat1);
    p2 = math.radians(lat2);
    dp = p2 - p1;
    dl = math.radians(lon2 - lon1);
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2;
    return 2 * r * math.asin(math.sqrt(a));
}

"""Implements `GeocodePort` over real divisions."""
obj GNGazetteer(GeocodePort) {
    has divisions: dict[str, Division],
        # normalised full name -> divisions carrying it (English and Sinhala)
        _exact: dict[str, list[Division]] = {},
        # single normalised word -> divisions whose name contains it
        _words: dict[str, list[Division]] = {},
        # Lazily built on the first reverse lookup, so a deployment that never sees a
        # coordinate never pays for it: (STRtree, gn ids in tree order).
        _index: any = None;

    def postinit {
        self._exact = {};
        self._words = {};
        self._index = None;
        for d in self.divisions.values() {
            for name in [d.name_en, d.name_si] {
                if not name {
                    continue;
                }
                key = normalise(name);
                if not key {
                    continue;
                }
                self._exact.setdefault(key, []).append(d);
                for word in key.split() {
                    self._words.setdefault(word, []).append(d);
                }
            }
        }
    }

    # -- GeocodePort ------------------------------------------------------------

    override def resolve(place_text: str) -> GeocodeResult {
        probe = normalise(place_text or "");
        if not probe {
            return GeocodeResult(matched=False, match_confidence=0.0);
        }

        # 1. exact name. One division -> certain; several -> genuinely ambiguous.
        exact = self._exact.get(probe, []);
        if len(exact) == 1 {
            return self._hit(exact[0], 1.0);
        }
        if len(exact) > 1 {
            return GNGazetteer._ambiguous(exact);
        }

        # 2. the report names an area: find divisions whose name contains every
        #    word of the probe ("biyagama" -> Biyagama North/West/South/Colony).
        words = probe.split();
        candidates = [d for d in self._words.get(words[0], []) if GNGazetteer._matches_all(d, words)];
        if not candidates {
            # 3. the report is wordier than the register ("flooding in Megoda
            #    Kolonnawa"). Try every run of consecutive words, longest first, so
            #    the most specific name wins: "megoda kolonnawa" must not fall
            #    through to "kolonnawa", a different division two kilometres away.
            candidates = self._longest_phrase(words);
        }
        if not candidates {
            return GeocodeResult(matched=False, match_confidence=0.0);
        }
        unique: dict[str, Division] = {};
        for d in candidates {
            unique[d.gn_id] = d;
        }
        if len(unique) == 1 {
            return self._hit(next(iter(unique.values())), 0.8);
        }
        return self._area(list(unique.values()));
    }

    """Point-in-polygon against the real boundaries.

    Nearest-centroid would be cheaper and wrong: division centroids sit up to a
    couple of kilometres from their own edges, so a point near a boundary
    routinely lands in a neighbour. That error is invisible on a map and arrives
    as a crew in the wrong place.

    A point inside no division is **not** snapped to the closest one. It returns
    unmatched and A1 holds the report, the same answer an unrecognised place name
    gets, because inventing a destination is the failure mode this whole layer
    exists to prevent.
    """
    override def locate(lat: float, lon: float) -> GeocodeResult {
        index = self._spatial_index();
        if index is None {
            return GeocodeResult(matched=False, match_confidence=0.0, via="coordinates");
        }
        tree: any = index[0];
        ids: list[str] = index[1];
        point = Point(lon, lat);
        for i in tree.query(point) {
            division = self.divisions[ids[int(i)]];
            if division.shape is not None and division.shape.covers(point) {
                # The reporter's own point, never the division centroid: this is
                # where the emergency is, and where a crew is told to go.
                return GeocodeResult(
                    matched=True, gn_id=division.gn_id, gn_name=division.name_en,
                    lat=lat, lon=lon, match_confidence=1.0, via="coordinates"
                );
            }
        }
        return GeocodeResult(matched=False, match_confidence=0.0, via="coordinates");
    }

    """Built once, on the first coordinate we are asked about."""
    def _spatial_index -> tuple[any, list[str]] | None {
        if self._index is None {
            shaped = [(gid, d.shape) for (gid, d) in self.divisions.items() if d.shape is not None];
            if not shaped {
                return None;
            }
            self._index = (STRtree([pair[1] for pair in shaped]), [pair[0] for pair in shaped]);
        }
        return self._index;
    }

    """A5 calls this on every dispatch destination."""
    override def contains(gn_id: str) -> bool {
        return gn_id in self.divisions;
    }

    # -- helpers ------------------------------------------------------------------

    """Divisions matching the longest run of consecutive probe words.

    Also tries the run as an area name, so "flooding in Biyagama today" still
    finds the Biyagama siblings.
    """
    def _longest_phrase(words: list[str]) -> list[Division] {
        for size in range(len(words), 0, -1) {
            for start in range(0, len(words) - size + 1) {
                run = words[start:start + size];
                exact = self._exact.get(" ".join(run), []);
                if exact {
                    return exact;
                }
                area = [d for d in self._words.get(run[0], []) if GNGazetteer._matches_all(d, run)];
                if area {
                    return area;
                }
            }
        }
        return [];
    }

    static def _matches_all(division: Division, words: list[str]) -> bool {
        haystack: set[str] = set();
        for name in [division.name_en, division.name_si] {
            if name {
                haystack.update(normalise(name).split());
            }
        }
        return all([w in haystack for w in words]);
    }

    def _hit(d: Division, confidence: float) -> GeocodeResult {
        return GeocodeResult(
            matched=True, gn_id=d.gn_id, gn_name=d.name_en, lat=d.lat, lon=d.lon,
            match_confidence=confidence
        );
    }

    """Two divisions share this exact name. Picking one would be a coin flip."""
    static def _ambiguous(candidates: list[Division]) -> GeocodeResult {
        if len({d.gn_id for d in candidates}) == 1 {
            first = candidates[0];
            return GeocodeResult(
                matched=True, gn_id=first.gn_id, gn_name=first.name_en,
                lat=first.lat, lon=first.lon, match_confidence=1.0
            );
        }
        return GeocodeResult(matched=False, match_confidence=0.0);
    }

    """A bare area name covering sibling divisions.

    Resolve to the sibling nearest the group's centre — a real division, as the
    gazetteer whitelist requires — at a confidence that falls as the group
    spreads out, so a vague name over a wide area is visibly less certain.
    """
    def _area(candidates: list[Division]) -> GeocodeResult {
        lat = sum([d.lat for d in candidates]) / len(candidates);
        lon = sum([d.lon for d in candidates]) / len(candidates);
        nearest = min(candidates, key=lambda (d: Division) -> float { return haversine_km(lat, lon, d.lat, d.lon); });
        spread = max([haversine_km(lat, lon, d.lat, d.lon) for d in candidates]);
        confidence = round(max(0.35, 0.75 - 0.05 * spread), 2);
        return self._hit(nearest, confidence);
    }
}

"""Read a GN boundary GeoJSON into gn_id -> Division. Features without an id or a
centre are skipped."""
def load_divisions(path: Path) -> dict[str, Division] {
    features: list[any] = json.loads(Path(path).read_text(encoding="utf-8")).get("features", []);
    out: dict[str, Division] = {};
    for f in features {
        p: dict[str, any] = f.get("properties") or {};
        gn_id = str(p.get("gn_id") or "");
        if not gn_id or p.get("center_lat") is None {
            continue;
        }
        geometry = f.get("geometry");
        out[gn_id] = Division(
            gn_id=gn_id,
            name_en=str(p.get("name_en") or gn_id),
            name_si=(str(p["name_si"]) if p.get("name_si") else None),
            lat=float(p["center_lat"]),
            lon=float(p["center_lon"]),
            ds_division=str(p.get("ds_division") or ""),
            district=str(p.get("district") or ""),
            shape=(shape(geometry) if geometry else None)
        );
    }
    return out;
}

"""Load the fetched GN boundary file. Raises if it is missing."""
def load_gazetteer(path: Path | None = None) -> GNGazetteer {
    target = Path(path) if path is not None else gn_boundaries_path();
    if not target.exists() {
        raise FileNotFoundError(f"{target} not found. Run: jac run scripts/fetch_data.jac --only gn");
    }
    return GNGazetteer(divisions=load_divisions(target));
}
