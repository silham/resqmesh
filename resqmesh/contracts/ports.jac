"""Interfaces for every external dependency.

Each external service sits behind one of these with a documented fallback, so the
failure of any single provider degrades output quality without halting the system.
No single failure produces silence; it produces a stated, lower-confidence answer.

Every port has a fake in `resqmesh.adapters.fakes`, so the whole pipeline runs with
no network and no keys.
"""

import from datetime { datetime }
import from resqmesh.contracts.enums { LLMProvider }
import from resqmesh.contracts.models { Contract, check_score, check_aware }

"""What an extraction returned, plus which provider actually served it."""
obj ExtractionResult(Contract) {
    has payload: dict[str, any],
        provider: LLMProvider,
        repaired: bool = False,
        latency_ms: float = 0.0;

    def postinit {
        self.provider = LLMProvider(self.provider);
    }
}

"""Observed and forecast precipitation for one basin point."""
obj RainfallSeries(Contract) {
    has lat: float,
        lon: float,
        observed_mm: list[float],
        forecast_mm: list[float],
        start_time: datetime,
        step_hours: int = 1,
        from_cache: bool = False;

    def postinit {
        check_aware("start_time", self.start_time);
    }

    def total_24h -> float {
        return sum(self.observed_mm[-24:]);
    }
}

"""Gazetteer resolution of a free-text place reference or a coordinate.

`matched` False is a legitimate outcome and sends the report to the unresolved
queue: a place that is not a real division can never enter a dispatch plan.
"""
obj GeocodeResult(Contract) {
    has matched: bool,
        gn_id: str | None = None,
        gn_name: str | None = None,
        lat: float | None = None,
        lon: float | None = None,
        match_confidence: float = 0.0,
        via: str = "gazetteer";

    def postinit {
        check_score("match_confidence", self.match_confidence);
    }
}

"""Official corroboration from GDACS or the DMC."""
obj Advisory(Contract) {
    has advisory_id: str,
        source: str,
        affected_gn_ids: list[str],
        severity: str,
        published_at: datetime,
        summary: str = "";

    def postinit {
        check_aware("published_at", self.published_at);
    }
}

"""Language and vision. The model never computes a number that matters: it extracts
structure, reads photographs and drafts prose."""
obj LLMPort {
    """Free text -> a payload validated against `schema`. One repair attempt on parse
    failure, then escalate. Malformed output is never coerced into looking valid."""
    def extract(text: str, schema: type, lang_hint: str = "unknown") -> ExtractionResult {
        raise NotImplementedError("extract");
    }

    """Damage photograph -> bounded severity assessment."""
    def vision(image_path: str, schema: type) -> ExtractionResult {
        raise NotImplementedError("vision");
    }

    """Narrative prose. Never public-facing: those come from reviewed templates."""
    def draft(prompt: str, max_tokens: int = 512) -> ExtractionResult {
        raise NotImplementedError("draft");
    }
}

"""Rainfall. Fallback: last cached reading."""
obj WeatherPort {
    def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        raise NotImplementedError("rainfall");
    }

    """Archive window; the evaluation harness replays historic series through this."""
    def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        raise NotImplementedError("historical");
    }
}

"""The GN-division gazetteer: names, coordinates and the dispatch whitelist."""
obj GeocodePort {
    def resolve(place_text: str) -> GeocodeResult {
        raise NotImplementedError("resolve");
    }

    """Which division contains this point? A point outside every division is held,
    exactly as an unrecognised name is."""
    def locate(lat: float, lon: float) -> GeocodeResult {
        raise NotImplementedError("locate");
    }

    """Whitelist membership. A5 calls this on every dispatch destination."""
    def contains(gn_id: str) -> bool {
        raise NotImplementedError("contains");
    }
}

"""Public broadcast channel (Telegram, or the mock)."""
obj BroadcastPort {
    def send(chat_id: str, text: str) -> bool {
        raise NotImplementedError("send");
    }

    """Returns the number of recipients reached."""
    def broadcast(gn_ids: list[str], text: str) -> int {
        raise NotImplementedError("broadcast");
    }
}

"""GDACS / DMC feeds."""
obj AdvisoryPort {
    def poll(since: datetime | None = None) -> list[Advisory] {
        raise NotImplementedError("poll");
    }
}
