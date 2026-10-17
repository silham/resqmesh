# Third-party notices

ResQ-Mesh is released under the [MIT Licence](LICENSE). It uses the open-source software and open
data listed below. No third-party code has been copied into this repository; everything here is
consumed as a dependency or downloaded at runtime by `scripts/fetch_data.jac`.

## Data

| Source | Licence | Use and obligations |
|---|---|---|
| **OpenStreetMap** contributors | **ODbL 1.0** | The road network the optimiser routes on and the waterways the hazard model buffers, via Geofabrik extracts and OSMnx. © OpenStreetMap contributors. Any published map or derived database must carry this attribution and stay under ODbL. |
| **SRTM 30 m elevation** (NASA/USGS) | Public domain | Terrain for the HAND inundation model and slope-based landslide susceptibility. |
| **Open-Meteo** | Free non-commercial; data CC-BY 4.0 | Observed and forecast rainfall, and the historical archive used to replay past events. |
| **GDACS** (EC Joint Research Centre / UN) | Public feed | Official corroboration of event scale and affected areas. |
| **Nominatim** (OpenStreetMap Foundation) | ODbL; usage policy applies | Residual geocoding only, rate-limited to one request per second. A local gazetteer resolves the overwhelming majority of places. |
| **Grama Niladhari division boundaries** | Public administrative data | The gazetteer every dispatch destination must resolve against. |
| **Department of Census and Statistics** population figures | Public | Division-level exposure, used at aggregate level only. |
| **WFP ADAM** rapid impact analysis `FL-20251201-LKA-00`, incorporating the **NOAA VIIRS** flood composite | **CC BY-SA 4.0** (HDX) | The published flood extent our hazard footprint is *scored against* (`scripts/validate_hazard.jac`). Evaluation only: nothing in the incident path reads it, and a reference the system could see would stop being a reference. Attribution: WFP ADAM; NOAA VIIRS Floodmap; processed in Google Earth Engine. The Floodscan layer the ADAM map also carries is **not** open data and is not used here. |

## Language and runtime

| Package | Licence |
|---|---|
| Jac / Jaseci (`jaclang`, the `jac` toolchain, its client framework and embedded graph store) | MIT |

## Libraries used by the server

| Package | Licence |
|---|---|
| Google OR-Tools | Apache-2.0 |
| OSMnx | MIT |
| NetworkX, Shapely, rasterio, SciPy | BSD-3-Clause |
| pyproj | MIT |
| NumPy | BSD-3-Clause (with 0BSD / MIT / Zlib components) |
| httpx | BSD-3-Clause |
| python-dotenv | BSD-3-Clause |
| ReportLab | BSD |
| **pysheds** (imported lazily) | **GPL-3.0-or-later** — see the note below |

### Note on pysheds (GPL-3.0)

`pysheds` computes the HAND terrain surface. It is a **copyleft** dependency in a project that is
otherwise MIT, so three things are deliberately true:

1. It is **never imported at module level**. The import happens inside the HAND
   computation, so nothing in the system touches GPL code unless that path runs.
2. The system **runs without it**: if HAND is unavailable the hazard agent falls back to its
   documented buffer-proxy estimate and annotates the situation report with reduced confidence.
3. It is **not redistributed here**. It is installed from PyPI by `jac install`, under its own
   licence.

Anyone who redistributes a combined work including `pysheds` must comply with GPL-3.0.

## Console dependencies

| Package | Licence |
|---|---|
| React, React DOM | MIT |
| Vite | MIT |
| Mantine (`@mantine/core`, `hooks`, `notifications`) | MIT |
| Leaflet | BSD-2-Clause |
| react-leaflet | Hippocratic-2.1 |
| MapLibre GL JS | BSD-3-Clause |

### Note on react-leaflet (Hippocratic 2.1)

`react-leaflet` is licensed under the Hippocratic Licence 2.1, which is not an OSI-approved
open-source licence: it permits use except by parties committing human rights violations as
defined in the licence. Use in a disaster-response system operated by a civil disaster management
authority is within those terms. Leaflet itself is BSD-2-Clause.

Map tiles are served by the OpenStreetMap tile servers, subject to their
[tile usage policy](https://operations.osmfoundation.org/policies/tiles/); a production deployment
should use its own tile source.

The 3D console uses **MapLibre GL JS** (BSD-3-Clause). Building tiles come from
[OpenFreeMap](https://openfreemap.org/) using OpenStreetMap data; terrain tiles
come from [Mapterhorn](https://mapterhorn.com/). TileJSON source attributions are
displayed by the map alongside the OpenStreetMap attribution. Building heights
are the provider's mapped values, not surveyed measurements by ResQ-Mesh.

## Services

Gemini (Google), Groq and DeepSeek are used through their public APIs under their respective terms.
Telegram is used through the Bot API. Each sits behind an adapter with a documented fallback, so no
single provider is required for the system to function.
