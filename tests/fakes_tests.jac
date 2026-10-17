"""The fakes behave the way the real adapters do, including at the failure boundaries."""

import from datetime { datetime, timedelta, UTC }
import from resqmesh.adapters.fakes { FakeAdvisoryFeed, FakeGazetteer, FakeWeather, MockBroadcast, StubLLM }
import from resqmesh.contracts.enums { HazardType, LLMProvider }
import from resqmesh.contracts.ports { AdvisoryPort, BroadcastPort, GeocodePort, LLMPort, WeatherPort }

test "every fake honours its port" {
    assert isinstance(StubLLM(), LLMPort);
    assert isinstance(FakeWeather(), WeatherPort);
    assert isinstance(FakeGazetteer(), GeocodePort);
    assert isinstance(MockBroadcast(), BroadcastPort);
    assert isinstance(FakeAdvisoryFeed(), AdvisoryPort);
}

test "gazetteer resolves an exact division name" {
    r = FakeGazetteer().resolve("Biyagama");
    assert r.matched and r.gn_id == "KLN-001" and r.match_confidence == 1.0;
}

test "gazetteer resolves a name embedded in free text" {
    r = FakeGazetteer().resolve("water rising near Kolonnawa town");
    assert r.matched and r.gn_id == "KLN-003" and r.match_confidence < 1.0;
}

test "gazetteer refuses to guess an unknown place" {
    r = FakeGazetteer().resolve("Wakanda Ward 9");
    assert not r.matched and r.gn_id is None;
}

test "gazetteer refuses empty place text" {
    for blank in ["", "   ", "!!!"] {
        assert not FakeGazetteer().resolve(blank).matched;
    }
}

test "gazetteer membership check" {
    g = FakeGazetteer();
    assert g.contains("KLN-001") and not g.contains("KLN-999");
}

test "gazetteer locates a nearby point and holds a distant one" {
    g = FakeGazetteer();
    near = g.locate(6.9295, 79.8880);
    assert near.matched and near.gn_id == "KLN-003" and near.via == "coordinates";
    assert not g.locate(7.5, 81.0).matched;
}

test "stub llm classifies hazard type" {
    cases = [
        ("Water is rising fast in the village", HazardType.FLOOD),
        ("Earth slip on the slope above the school", HazardType.LANDSLIDE),
        ("The culvert has collapsed, road impassable", HazardType.ROAD_BLOCKED),
        ("Patient needs dialysis urgently", HazardType.MEDICAL),
        ("qwertyuiop", HazardType.UNKNOWN)
    ];
    for (text, expected) in cases {
        assert StubLLM().extract(text, dict).payload["hazard_type"] == expected, text;
    }
}

test "stub llm is deterministic" {
    assert StubLLM().extract("Flooding in Biyagama", dict).payload == StubLLM().extract("Flooding in Biyagama", dict).payload;
}

test "stub llm extracts a headcount and reports none when absent" {
    assert StubLLM().extract("12 people trapped in Kaduwela", dict).payload["reported_people_affected"] == 12;
    assert StubLLM().extract("Water rising", dict).payload["reported_people_affected"] is None;
}

test "stub llm vision severity is bounded" {
    for path in ["a.jpg", "b.jpg", "some/long/path.png"] {
        assert 0 <= StubLLM().vision(path, dict).payload["severity_0_4"] <= 4;
    }
}

test "stub llm declares its provider" {
    assert StubLLM().extract("x", dict).provider == LLMProvider.STUB;
}

test "fake weather returns a rising profile" {
    s = FakeWeather(peak_mm=40.0).rainfall(6.95, 79.98, hours_back=24);
    assert len(s.observed_mm) == 24 and s.observed_mm[-1] > s.observed_mm[0];
}

test "fake weather totals the last 24 hours" {
    s = FakeWeather().rainfall(6.95, 79.98, hours_back=48);
    assert abs(s.total_24h() - sum(s.observed_mm[-24:])) < 1e-9;
}

test "fake weather historical spans the window" {
    start = datetime(2016, 5, 15, tzinfo=UTC);
    s = FakeWeather().historical(6.95, 79.98, start, start + timedelta(hours=12));
    assert len(s.observed_mm) == 12 and s.start_time == start;
}

test "mock broadcast records without any external dependency" {
    m = MockBroadcast();
    assert m.send("chat-1", "hello");
    assert m.broadcast(["KLN-001", "KLN-003"], "evacuate") == 2;
    assert m.sent == [("chat-1", "hello")];
    assert m.broadcasts[0][0] == ["KLN-001", "KLN-003"];
}

test "advisory feed filters by timestamp" {
    f = FakeAdvisoryFeed();
    assert f.poll() != [];
    assert f.poll(since=datetime.now(UTC)) == [];
}
