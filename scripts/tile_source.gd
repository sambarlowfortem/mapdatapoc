## Shared math for XYZ map tiles: converting z/x/y tile coordinates to
## world-space meters (Web Mercator) and building URLs/grids of neighbors.
## Pure functions only - HTTP fetching stays local to each loader script.
extends RefCounted
class_name TileSource

const EARTH_CIRCUMFERENCE_M := 40075016.6855784

## Web Mercator's scale distortion factor at `lat` (degrees): a tile's
## EARTH_CIRCUMFERENCE_M/2^z width is in Mercator-*projected* meters, which
## only equals true ground meters at the equator - away from it, ground
## distance = projected distance * cos(lat). Without this, every world-space
## distance this file computes is inflated by 1/cos(lat) (e.g. ~31% at 40°),
## since the projection stretches distances increasingly toward the poles.
## https://en.wikipedia.org/wiki/Web_Mercator_projection#Scale_factor
static func ground_scale(lat: float) -> float:
	return cos(deg_to_rad(lat))


## Real-world ground size (meters, not Mercator-projected) of one tile at
## zoom `z`, at latitude `lat` (degrees) - see ground_scale().
static func size_meters(z: int, lat: float) -> float:
	return EARTH_CIRCUMFERENCE_M / pow(2.0, z) * ground_scale(lat)


## World-space (x, z) offset of tile (z,x,y)'s center relative to the exact
## real-world point (ref_lat, ref_lon) - this is the scene's real-world
## origin (see TerrainRGBLoader's class doc comment), so this is what places
## every tile (terrain, vector, satellite) correctly regardless of zoom.
## Works across different zoom levels because tile position is first
## expressed as a fraction of the whole world (dimensionless, zoom-
## independent) before the reference point is subtracted. `ref_lat` doubles
## as the scene's reference latitude for ground_scale()'s Web Mercator scale
## correction - the area covered by a loaded tile grid is small enough that
## using one fixed reference latitude throughout, rather than each tile's
## own, is an acceptable approximation.
static func world_offset(z: int, x: int, y: int, ref_lat: float, ref_lon: float) -> Vector2:
	var n := pow(2.0, z)
	var ref_lat_rad := deg_to_rad(ref_lat)
	var ref_fx := (ref_lon + 180.0) / 360.0
	var ref_fy := (1.0 - log(tan(ref_lat_rad) + 1.0 / cos(ref_lat_rad)) / PI) / 2.0
	var fx := (float(x) + 0.5) / n - ref_fx
	var fz := (float(y) + 0.5) / n - ref_fy
	return Vector2(fx, fz) * (EARTH_CIRCUMFERENCE_M * ground_scale(ref_lat))


## Substitutes {z}/{x}/{y} placeholders in a URL template.
static func url_for(template: String, z: int, x: int, y: int) -> String:
	return template.replace("{z}", str(z)).replace("{x}", str(x)).replace("{y}", str(y))


## (x,y) tile coordinates for a square grid of the given radius around
## (center_x, center_y) - radius 0 is just the center tile, 1 is 3x3, etc.
static func grid_coords(center_x: int, center_y: int, radius: int) -> Array:
	var coords := []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			coords.append(Vector2i(center_x + dx, center_y + dy))
	return coords


## Start (in tile-index units at whatever zoom `center` is expressed in) of
## the 4-wide window centered on `center`, expanded so its edges land
## exactly on (that zoom - 1) tile boundaries (2 tiles at this zoom = 1 tile
## one zoom level coarser) - i.e. the smallest even integer <= center - 1.
## Used to build a same-zoom ring around a higher-detail center that hands
## off cleanly to a one-zoom-coarser ring around THAT, with no gap and no
## double-covered area - see MVTTileRenderer's class doc comment (and
## SatelliteTileLoader, which reuses the identical scheme one zoom level up).
static func aligned_window_start(center: int) -> int:
	return ((center - 1) / 2) * 2


## Standard Web Mercator "slippy map" tile (x,y) at zoom `z` containing
## (lat, lon), both in degrees. See
## https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames.
static func lat_lon_to_tile(lat: float, lon: float, z: int) -> Vector2i:
	var n := pow(2.0, z)
	var x := int(floor((lon + 180.0) / 360.0 * n))
	var lat_rad := deg_to_rad(lat)
	var y := int(floor((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n))
	return Vector2i(x, y)
