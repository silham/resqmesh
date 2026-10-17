"""Open-Meteo rainfall — the real `WeatherPort`.

Two endpoints, both free and keyless:

* `/v1/forecast` — the last `hours_back` observed hours plus a short forecast,
  for live operation;
* `/v1/archive` — reanalysis history, which is how the evaluation harness replays
  the May 2016 and May 2017 Kelani events.

Failure path (roadmap section 5.3, item 5): every successful response is written to
a disk cache. On a network error, a timeout, an open circuit breaker or
`RESQMESH_OFFLINE=1`, the adapter serves the last cached reading with
`from_cache=True` — a stated, older answer instead of silence. Only when there is
no cache at all does it raise `WeatherUnavailableError`, and A2 turns that into
a conservative, low-confidence surface rather than halting.
"""

import hashlib;
import json;
import time;
import from datetime { datetime, UTC }
import from pathlib { Path }
import httpx;
import from resqmesh.adapters.geo.paths { cache_dir, ensure_dir, is_offline }
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }

glob FORECAST_URL: str = "https://api.open-meteo.com/v1/forecast";
glob ARCHIVE_URL: str = "https://archive-api.open-meteo.com/v1/archive";
glob FORECAST_HOURS: int = 12;

"""No live response and nothing cached to fall back on."""
class WeatherUnavailableError(RuntimeError) {}

"""Stop hammering a dead endpoint: after `threshold` consecutive failures the
network is skipped for `cooldown_s` and the cache answers directly."""
obj CircuitBreaker {
    has threshold: int = 3,
        cooldown_s: float = 60.0,
        failures: int = 0,
        opened_at: float | None = None;

    def allow -> bool {
        if self.opened_at is None {
            return True;
        }
        if time.monotonic() - self.opened_at >= self.cooldown_s {
            # half-open: try once more
            self.opened_at = None;
            self.failures = 0;
            return True;
        }
        return False;
    }

    def record(ok: bool) -> None {
        if ok {
            self.failures = 0;
            self.opened_at = None;
            return;
        }
        self.failures += 1;
        if self.failures >= self.threshold {
            self.opened_at = time.monotonic();
        }
    }
}

def _parse_hour(stamp: str) -> datetime {
    return datetime.fromisoformat(stamp).replace(tzinfo=UTC);
}

def _floor_hour(t: datetime) -> datetime {
    return t.astimezone(UTC).replace(minute=0, second=0, microsecond=0);
}

"""Hourly timestamps and precipitation values from a response body."""
def _hourly(payload: dict[str, any]) -> tuple[list[datetime], list[float]] {
    hourly: dict[str, any] = payload.get("hourly") or {};
    times = [_parse_hour(t) for t in hourly.get("time", [])];
    # Open-Meteo returns null for hours it has no value for; no rain is the safe
    # reading for a gap, and the gap itself is visible in the cached raw payload.
    values = [float(v) if v is not None else 0.0 for v in hourly.get("precipitation", [])];
    if len(times) != len(values) {
        raise ValueError("malformed Open-Meteo payload: time/precipitation length mismatch");
    }
    return (times, values);
}

"""Implements `WeatherPort`.

`client` is any object with an `httpx.Client`-style `get`; tests inject a
`MockTransport` client (or just the `transport`) so no test touches the network.
`now` is a zero-arg callable returning an aware datetime and `sleep` replaces
`time.sleep` between retries; both are injectable for tests.
"""
obj OpenMeteoWeather(WeatherPort) {
    has client: any = None,
        transport: any = None,
        cache_root: Path | None = None,
        offline: bool | None = None,
        timeout_s: float = 10.0,
        retries: int = 2,
        backoff_s: float = 0.5,
        now: any = None,
        sleep: any = None,
        breaker: CircuitBreaker = CircuitBreaker();

    # -- port ------------------------------------------------------------------

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        params: dict[str, any] = {
            "latitude": round(lat, 4),
            "longitude": round(lon, 4),
            "hourly": "precipitation",
            "past_hours": hours_back,
            "forecast_hours": FORECAST_HOURS,
            "timezone": "UTC"
        };
        key = f"forecast_{lat:.3f}_{lon:.3f}_{hours_back}";
        fetched = self._fetch(FORECAST_URL, params, key, prefer_cache=False);
        payload: dict[str, any] = fetched[0];
        from_cache: bool = fetched[1];
        parsed = _hourly(payload);
        times = parsed[0];
        values = parsed[1];
        cutoff = _floor_hour(self._now());
        obs_times: list[datetime] = [];
        obs_values: list[float] = [];
        forecast: list[float] = [];
        for i in range(len(times)) {
            if times[i] <= cutoff {
                obs_times.append(times[i]);
                obs_values.append(values[i]);
            } else {
                forecast.append(values[i]);
            }
        }
        obs_times = obs_times[-hours_back:];
        obs_values = obs_values[-hours_back:];
        return RainfallSeries(
            lat=lat, lon=lon,
            observed_mm=obs_values, forecast_mm=forecast[:FORECAST_HOURS],
            start_time=(obs_times[0] if obs_times else cutoff), step_hours=1,
            from_cache=from_cache
        );
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        start_u = start.astimezone(UTC);
        end_u = end.astimezone(UTC);
        start_date = start_u.date().isoformat();
        end_date = end_u.date().isoformat();
        params: dict[str, any] = {
            "latitude": round(lat, 4),
            "longitude": round(lon, 4),
            "hourly": "precipitation",
            "start_date": start_date,
            "end_date": end_date,
            "timezone": "UTC"
        };
        key = f"archive_{lat:.3f}_{lon:.3f}_{start_date}_{end_date}";
        # The archive is immutable history: a cached copy is authoritative, not stale.
        fetched = self._fetch(ARCHIVE_URL, params, key, prefer_cache=True);
        payload: dict[str, any] = fetched[0];
        from_cache: bool = fetched[1];
        parsed = _hourly(payload);
        times = parsed[0];
        values = parsed[1];
        floor_start = _floor_hour(start_u);
        win_times: list[datetime] = [];
        win_values: list[float] = [];
        for i in range(len(times)) {
            if floor_start <= times[i] and times[i] < end_u {
                win_times.append(times[i]);
                win_values.append(values[i]);
            }
        }
        return RainfallSeries(
            lat=lat, lon=lon,
            observed_mm=win_values, forecast_mm=[],
            start_time=(win_times[0] if win_times else floor_start),
            step_hours=1, from_cache=from_cache
        );
    }

    # -- plumbing --------------------------------------------------------------

    def _now -> datetime {
        return self.now() if self.now is not None else datetime.now(UTC);
    }

    def _cache_file(key: str) -> Path {
        base = self.cache_root if self.cache_root is not None else cache_dir() / "open_meteo";
        safe = key if len(key) < 120 else hashlib.sha256(key.encode()).hexdigest();
        return Path(base) / f"{safe}.json";
    }

    def _read_cache(key: str) -> dict[str, any] | None {
        p = self._cache_file(key);
        if not p.exists() {
            return None;
        }
        try {
            return json.loads(p.read_text(encoding="utf-8"));
        } except (OSError, json.JSONDecodeError) {
            return None;
        }
    }

    def _write_cache(key: str, payload: dict[str, any]) -> None {
        p = self._cache_file(key);
        ensure_dir(p.parent);
        tmp = p.with_suffix(".part");
        tmp.write_text(json.dumps(payload), encoding="utf-8");
        tmp.replace(p);
    }

    def _offline -> bool {
        return self.offline if self.offline is not None else is_offline();
    }

    def _pause(seconds: float) -> None {
        if self.sleep is not None {
            self.sleep(seconds);
        } else {
            time.sleep(seconds);
        }
    }

    def _get(url: str, params: dict[str, any]) -> dict[str, any] {
        if self.client is None {
            if self.transport is not None {
                self.client = httpx.Client(transport=self.transport, timeout=self.timeout_s);
            } else {
                self.client = httpx.Client(timeout=self.timeout_s);
            }
        }
        resp: any = self.client.get(url, params=params);
        resp.raise_for_status();
        data: any = resp.json();
        if not isinstance(data, dict) or "hourly" not in data {
            raise ValueError(f"unexpected Open-Meteo response: {str(data)[:200]}");
        }
        return data;
    }

    def _fetch(url: str, params: dict[str, any], key: str, prefer_cache: bool) -> tuple[dict[str, any], bool] {
        if prefer_cache {
            hit = self._read_cache(key);
            if hit is not None {
                return (hit, True);
            }
        }
        if not self._offline() and self.breaker.allow() {
            last_exc: Exception | None = None;
            for attempt in range(self.retries + 1) {
                try {
                    payload = self._get(url, params);
                } except Exception as exc {
                    # network, HTTP status, malformed body
                    last_exc = exc;
                    if attempt < self.retries {
                        self._pause(self.backoff_s * (2 ** attempt));
                    }
                    continue;
                }
                self.breaker.record(True);
                self._write_cache(key, payload);
                return (payload, False);
            }
            self.breaker.record(False);
            cached = self._read_cache(key);
            if cached is None {
                raise WeatherUnavailableError(f"Open-Meteo unreachable and no cache for {key}") from last_exc;
            }
            return (cached, True);
        }
        cached = self._read_cache(key);
        if cached is None {
            raise WeatherUnavailableError(f"offline and no cached rainfall for {key}");
        }
        return (cached, True);
    }
}
