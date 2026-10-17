"""SRTM terrain: load the basin DEM and derive slope and aspect.

Cell spacing is in degrees, so slope uses the metre-per-degree scale at the raster's
mid-latitude: accurate to well under 1 % at 7 N, far inside the uncertainty of a
30 m DEM.
"""

import math;
import from pathlib { Path }
import numpy as np;
import from resqmesh.adapters.geo.paths { dem_path }

glob M_PER_DEG_LAT: float = 110574.0;
glob M_PER_DEG_LON_EQUATOR: float = 111320.0;

"""An elevation grid in EPSG:4326 with its affine transform."""
obj Dem {
    has elevation: any,
        transform: any,
        nodata: float | None = None;

    def shape -> tuple[int, int] {
        return (int(self.elevation.shape[0]), int(self.elevation.shape[1]));
    }

    """(dx, dy) in metres at the grid's mid-latitude."""
    def cell_size_m -> tuple[float, float] {
        (rows, _) = self.shape();
        mid_lat = self.transform.f + self.transform.e * rows / 2;
        dx = abs(self.transform.a) * M_PER_DEG_LON_EQUATOR * math.cos(math.radians(mid_lat));
        dy = abs(self.transform.e) * M_PER_DEG_LAT;
        return (dx, dy);
    }
}

def load_dem(path: Path | None = None) -> Dem {
    import rasterio;
    p = path or dem_path();
    if not p.exists() {
        raise FileNotFoundError(f"DEM not found at {p}; run `jac run scripts/fetch_data.jac`");
    }
    with rasterio.open(p) as src {
        band = src.read(1).astype("float64");
        nodata = src.nodata;
        if nodata is not None {
            band[band == nodata] = np.nan;
        }
        return Dem(elevation=band, transform=src.transform, nodata=nodata);
    }
}

"""Slope in degrees by central differences. NaN cells propagate as NaN."""
def slope_degrees(dem: Dem) -> any {
    (dx, dy) = dem.cell_size_m();
    grads: any = np.gradient(dem.elevation, dy, dx);
    dz_dy: any = grads[0];
    dz_dx: any = grads[1];
    return np.degrees(np.arctan(np.hypot(dz_dx, dz_dy)));
}

"""Downslope direction in degrees clockwise from north (0-360)."""
def aspect_degrees(dem: Dem) -> any {
    (dx, dy) = dem.cell_size_m();
    grads: any = np.gradient(dem.elevation, dy, dx);
    dz_dy: any = grads[0];
    dz_dx: any = grads[1];
    return (np.degrees(np.arctan2(-dz_dx, dz_dy)) + 360.0) % 360.0;
}
