"""A WeatherPort that answers "live" rainfall from the archive at a simulated clock.

The replay harness drives scenarios A and B through the same agents that run live.
A2 asks for `rainfall(lat, lon, hours_back=72)` — "the last 72 hours" — and this
adapter answers it from Open-Meteo's archive as of the replay clock, so May 2016
plays back through exactly the code path a real flood would take.

No forecast is returned during replay: a forecast issued in 2016 is not in the
archive, and substituting what actually fell would leak the future into the run.

`from_cache` is always `False` here. For a live feed it means "stale reading" and
A2 lowers confidence on it; archived history cannot go stale, so a disk-cached
archive answer is as good as a fresh one.
"""

import from datetime { datetime, timedelta }
import from resqmesh.contracts.models { evolve }
import from resqmesh.contracts.ports { RainfallSeries, WeatherPort }

"""Implements `WeatherPort` over an archive port. `clock` is a zero-arg callable
returning the replay's current (aware) time."""
obj ReplayWeather(WeatherPort) {
    has archive: WeatherPort,
        clock: any;

    override def rainfall(lat: float, lon: float, hours_back: int = 48) -> RainfallSeries {
        now: datetime = self.clock();
        series = self.archive.historical(lat, lon, now - timedelta(hours=hours_back), now);
        return evolve(series, from_cache=False);
    }

    override def historical(lat: float, lon: float, start: datetime, end: datetime) -> RainfallSeries {
        series = self.archive.historical(lat, lon, start, min(end, self.clock()));
        return evolve(series, from_cache=False);
    }
}
