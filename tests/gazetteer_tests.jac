"""The real GN gazetteer, against a fixture cut from the real basin data.

Eleven real divisions, including the awkward cases the full register contains:
sibling divisions of one area (Biyagama North/West/South), a more specific name
that contains a shorter one (Megoda Kolonnawa vs Kolonnawa), a near-homograph in
Sinhala (මෙගොඩ vs මීගොඩ), and two different divisions sharing one English name
(Suduwella).
"""

import json;
import tempfile;
import from pathlib { Path }
import from resqmesh.adapters.gazetteer.gn { GNGazetteer, load_divisions, load_gazetteer, normalise }
import from resqmesh.adapters.geo.paths { gn_boundaries_path, project_root }
import from resqmesh.contracts.ports { GeocodePort }

glob FIXTURE: Path = project_root() / "data" / "fixtures" / "gn_sample.geojson";

glob _GAZ: list[GNGazetteer] = [];

"""One gazetteer over the fixture, shared by the tests that only read it."""
def gaz -> GNGazetteer {
    if not _GAZ {
        _GAZ.append(GNGazetteer(divisions=load_divisions(FIXTURE)));
    }
    return _GAZ[0];
}

test "the gazetteer honours the geocode port" {
    assert isinstance(gaz(), GeocodePort);
}

test "exact name is certain" {
    hit = gaz().resolve("Kolonnawa");
    assert hit.matched and hit.gn_name == "Kolonnawa" and hit.match_confidence == 1.0;
}

test "a place inside a sentence is found" {
    hit = gaz().resolve("Flooding in Kolonnawa, 12 people trapped, elderly couple on the roof");
    assert hit.matched and hit.gn_name == "Kolonnawa";
}

test "the more specific name wins" {
    # 'Megoda Kolonnawa' must not fall through to 'Kolonnawa' — a different
    # division two kilometres away. Longest run of words first.
    g = GNGazetteer(divisions=load_divisions(FIXTURE));
    hit = g.resolve("Flooding in Megoda Kolonnawa");
    assert hit.matched and hit.gn_name == "Megoda Kolonnawa";
}

test "an area name resolves to a real sibling with lower confidence" {
    # A caller says 'Biyagama'; the register holds North, West and South. Refusing
    # would discard most real reports, so resolve to a real sibling and say it is
    # less certain.
    hit = gaz().resolve("Biyagama");
    assert hit.matched;
    assert hit.gn_name is not None and hit.gn_name.startswith("Biyagama");
    assert 0.35 <= hit.match_confidence < 0.8;
    # never a synthetic centroid: always a real division
    assert hit.gn_id is not None and gaz().contains(hit.gn_id);
}

test "a name shared by two divisions is held not guessed" {
    # Suduwella is two different places. Picking one would be a coin flip.
    assert gaz().resolve("Suduwella").matched is False;
}

test "sinhala names resolve" {
    for text in ["කොළොන්නාව", "කොළොන්නාව ගංවතුර"] {
        hit = gaz().resolve(text);
        assert hit.matched and hit.gn_name == "Kolonnawa", text;
    }
}

test "sinhala vowel length distinguishes two real places" {
    # මෙගොඩ (Megoda) and මීගොඩ (Meegoda) differ by one vowel and are different
    # divisions. Fuzzy matching here would send a crew to the wrong town, so exact
    # matching is the safe behaviour.
    assert gaz().resolve("මෙගොඩ කොළොන්නාව").gn_name == "Megoda Kolonnawa";
    assert gaz().resolve("මීගොඩ උතුර").gn_name == "Meegoda North";
}

test "unknown places are held" {
    # The whitelist is what makes a confidently invented place impossible.
    for text in ["near the old temple", "Wakanda Ward 9", "", "   ", "12 people trapped"] {
        assert gaz().resolve(text).matched is False, text;
    }
}

test "contains is the dispatch whitelist" {
    assert gaz().contains("LK1106110") is True;
    assert gaz().contains("GHOST-1") is False;
}

test "decorative words are ignored" {
    assert gaz().resolve("Kaduwela town").gn_name == "Kaduwela";
    assert gaz().resolve("near the Kaduwela road junction").gn_name == "Kaduwela";
}

test "normalise" {
    cases = [("  KOLONNAWA  ", "kolonnawa"), ("Kaduwela Town", "kaduwela"), ("Biyagama, North!", "biyagama north")];
    for (raw, expected) in cases {
        assert normalise(raw) == expected, raw;
    }
}

test "every resolved division is in the register" {
    # Whatever path a match takes, the returned id must be dispatchable.
    for text in ["Kolonnawa", "Biyagama", "Megoda Kolonnawa", "Kaduwela town", "කොළොන්නාව"] {
        hit = gaz().resolve(text);
        assert hit.matched and hit.gn_id is not None and gaz().contains(hit.gn_id), text;
        assert hit.lat is not None and hit.lon is not None, text;
    }
}

test "locate answers with the containing division and the reporter's point" {
    # Two adjacent unit squares; a point on neither is held, never snapped.
    def square(gid: str, name: str, x0: float) -> dict[str, any] {
        return {
            "type": "Feature",
            "properties": {"gn_id": gid, "name_en": name, "center_lat": 6.905, "center_lon": x0 + 0.005},
            "geometry": {
                "type": "Polygon",
                "coordinates": [[[x0, 6.90], [x0 + 0.01, 6.90], [x0 + 0.01, 6.91], [x0, 6.91], [x0, 6.90]]]
            }
        };
    }
    path = Path(tempfile.mkdtemp()) / "gn.geojson";
    path.write_text(json.dumps({
        "type": "FeatureCollection",
        "features": [square("A", "Alpha", 79.90), square("B", "Beta", 79.91)]
    }), encoding="utf-8");
    g = load_gazetteer(path);
    hit = g.locate(6.903, 79.915);
    assert hit.matched and hit.gn_id == "B" and hit.via == "coordinates";
    assert hit.lat == 6.903 and hit.lon == 79.915 and hit.match_confidence == 1.0;
    miss = g.locate(7.5, 81.0);
    assert not miss.matched and miss.via == "coordinates";
    # The fixture carries no geometry, so every coordinate is held.
    assert not gaz().locate(6.9333, 79.8897).matched;
}

test "a missing boundary file points at the fetch script" {
    with testraises(FileNotFoundError, `match="fetch_data") {
        load_gazetteer(Path(tempfile.mkdtemp()) / "absent.geojson");
    }
}

# --------------------------------------------------------------------------- #
# Against the full downloaded register, when it is present
# --------------------------------------------------------------------------- #

test "the full register resolves the demo places" {
    path = gn_boundaries_path();
    if not path.exists() {
        # run scripts/fetch_data.jac --only gn for the full register
        return;
    }
    g = GNGazetteer(divisions=load_divisions(path));
    assert len(g.divisions) > 500;
    for text in ["Kolonnawa", "Kaduwela", "Pahathgama", "Avissawella", "Kelaniya", "Sedawatta", "Wellampitiya"] {
        assert g.resolve(text).matched, text;
    }
}
