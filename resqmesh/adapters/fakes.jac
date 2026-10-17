"""Deterministic fakes for every port.

They let the whole pipeline run with no API key, no network and no cost, and they are
what the unit tests run against: deterministic components must be testable with no
model anywhere in the path. Every fake honours the same interface as its real
counterpart, so swapping in the real adapter is a wiring change and nothing else.
"""

import hashlib;
import math;
import re;
import from datetime { datetime, timedelta, UTC }
import from resqmesh.adapters.llm.rules { RuleBasedExtractor }
import from resqmesh.contracts.enums { LLMProvider }
import from resqmesh.contracts.ports {
    Advisory, AdvisoryPort, BroadcastPort, ExtractionResult, GeocodePort, GeocodeResult,
    RainfallSeries, WeatherPort
}

"""A small slice of Kelani basin GN divisions: id -> (name, lat, lon)."""
glob KELANI_GN_DIVISIONS: dict[str, tuple[str, float, float]] = {
    "KLN-001": ("Biyagama", 6.9497, 79.9853),
    "KLN-002": ("Kaduwela", 6.9339, 79.9836),
    "KLN-003": ("Kolonnawa", 6.9294, 79.8878),
    "KLN-004": ("Hanwella", 6.8983, 80.0819),
    "KLN-005": ("Avissawella", 6.9544, 80.2097),
    "KLN-006": ("Kelaniya", 6.9553, 79.9219),
    "KLN-007": ("Malabe", 6.9061, 79.9697),
    "KLN-008": ("Pahathgama", 6.8756, 80.0669),
    "KLN-009": ("Sedawatta", 6.9403, 79.8961),
    "KLN-010": ("Wellampitiya", 6.9375, 79.9022)
};

"""How far a coordinate may sit from a known centroid before the fake gives up."""
glob FAKE_LOCATE_RADIUS_KM: float = 5.0;

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    r = 6371.0088;
    p1 = math.radians(lat1);
    p2 = math.radians(lat2);
    dp = p2 - p1;
    dl = math.radians(lon2 - lon1);
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2;
    return 2 * r * math.asin(math.sqrt(a));
}

"""A GeocodePort over a handful of centroids.

Matching is deliberately conservative: an unrecognised place returns unmatched rather
than a nearest guess. A confidently invented location is the most dangerous
hallucination in this domain, so the fake models the real failure mode.
"""
obj FakeGazetteer(GeocodePort) {
    has divisions: dict[str, tuple[str, float, float]] = {};

    def postinit {
        if not self.divisions {
            self.divisions = dict(KELANI_GN_DIVISIONS);
        }
    }

    def by_name -> dict[str, tuple[str, float, float]] {
        return {name.lower(): (gid, lat, lon) for (gid, (name, lat, lon)) in self.divisions.items()};
    }

    override def resolve(place_text: str) -> GeocodeResult {
        needle = re.sub(r"[^a-z\s]", "", place_text.lower()).strip();
        if not needle {
            return GeocodeResult(matched=False, match_confidence=0.0);
        }
        names = self.by_name();
        if needle in names {
            (gid, lat, lon) = names[needle];
            return GeocodeResult(matched=True, gn_id=gid, gn_name=self.divisions[gid][0], lat=lat, lon=lon, match_confidence=1.0);
        }
        for (name, (gid, lat, lon)) in names.items() {
            if name in needle {
                return GeocodeResult(matched=True, gn_id=gid, gn_name=self.divisions[gid][0], lat=lat, lon=lon, match_confidence=0.75);
            }
        }
        return GeocodeResult(matched=False, match_confidence=0.0);
    }

    """Nearest centroid within FAKE_LOCATE_RADIUS_KM. The fake holds centroids and no
    boundaries, so it cannot do point-in-polygon; what it keeps is that a point nowhere
    near any division is held rather than snapped to whatever is closest."""
    override def locate(lat: float, lon: float) -> GeocodeResult {
        if not self.divisions {
            return GeocodeResult(matched=False, match_confidence=0.0, via="coordinates");
        }
        best_id = "";
        best_km = math.inf;
        for (gid, (name, dlat, dlon)) in self.divisions.items() {
            km = haversine_km(lat, lon, dlat, dlon);
            if km < best_km {
                best_km = km;
                best_id = gid;
            }
        }
        if best_km > FAKE_LOCATE_RADIUS_KM {
            return GeocodeResult(matched=False, match_confidence=0.0, via="coordinates");
        }
        return GeocodeResult(
            matched=True, gn_id=best_id, gn_name=self.divisions[best_id][0], lat=lat, lon=lon,
            match_confidence=round(max(0.5, 1.0 - best_km / FAKE_LOCATE_RADIUS_KM), 2),
            via="coordinates"
        );
    }

    override def contains(gn_id: str) -> bool {
        return gn_id in self.divisions;
    }
}

"""An LLMPort for development and tests: the offline rule extractor, labelled STUB so
a test can never mistake it for a real tier, which "reads" photos with a stable hash."""
obj StubLLM(RuleBasedExtractor) {
    has provider: LLMProvider = LLMProvider.STUB,
        confidence: float = 0.7;

    """Severity derived from the path hash: stable, bounded, obviously synthetic."""
    override def vision(image_path: str, schema: type) -> ExtractionResult {
        digest = hashlib.sha256(image_path.encode()).digest()[0];
        return ExtractionResult(
            payload={"severity_0_4": digest % 5, "tags": ["stub"], "model_confidence": 0.5},
            provider=self.provider, latency_ms=1.0
        );
    }

    override def draft(prompt: str, max_tokens: int = 512) -> ExtractionResult {
        return ExtractionResult(payload={"text": f"[stub narrative for: {prompt[:80]}]"}, provider=self.provider, latency_ms=1.0);
    }
}

"""A WeatherPort with a rising-rainfall profile, so hazard thresholds actually trip."""
obj FakeWeather(WeatherPort) {
    has peak_mm: float = 40.0;

    def profile(hours: int, start: datetime) -> RainfallSeries {
        denom = max(hours - 1, 1);
        observed = [round(self.peak_mm * (i / denom) ** 2, 2) for i in range(hours)];
        forecast = [round(self.peak_mm * 0.8, 2) for _ in range(12)];
        return RainfallSeries(lat=6.95, lon=79.98, observed_mm=observed, forecast_mm=forecast, start_time=start, step_hours=1, from_cache=False);
    }

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        return self.profile(hours_back, datetime.now(UTC) - timedelta(hours=hours_back));
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        hours = max(int((end - start).total_seconds() // 3600), 1);
        return self.profile(hours, start);
    }
}

"""A BroadcastPort writing to an in-memory log instead of Telegram."""
obj MockBroadcast(BroadcastPort) {
    has sent: list[tuple[str, str]] = [],
        broadcasts: list[tuple[list[str], str]] = [];

    override def send(chat_id: str, text: str) -> bool {
        self.sent.append((chat_id, text));
        return True;
    }

    override def broadcast(gn_ids: list[str], text: str) -> int {
        self.broadcasts.append((list(gn_ids), text));
        return len(gn_ids);
    }
}

"""An AdvisoryPort with one stub GDACS advisory."""
obj FakeAdvisoryFeed(AdvisoryPort) {
    has advisories: list[Advisory] = [];

    def postinit {
        if not self.advisories {
            self.advisories = [
                Advisory(
                    advisory_id="GDACS-STUB-1", source="GDACS", affected_gn_ids=["KLN-001", "KLN-003"],
                    severity="orange", published_at=datetime.now(UTC) - timedelta(hours=2),
                    summary="Stub advisory: elevated flood risk, Kelani basin."
                )
            ];
        }
    }

    override def poll(since: datetime | None = None) -> list[Advisory] {
        if since is None {
            return list(self.advisories);
        }
        return [a for a in self.advisories if a.published_at > since];
    }
}
