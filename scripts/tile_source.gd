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


## World-space (x, z) offset of tile (z,x,y)'s center relative to the center
## of tile (origin_z,origin_x,origin_y) - works across different zoom levels,
## e.g. placing a vector tile relative to the terrain tile's origin. `lat` is
## the scene's reference latitude (see ground_scale()) - the area covered by
## a loaded tile grid is small enough that using one fixed reference latitude
## throughout, rather than each tile's own, is an acceptable approximation.
static func world_offset(z: int, x: int, y: int, origin_z: int, origin_x: int, origin_y: int, lat: float) -> Vector2:
	var fx := (float(x) + 0.5) / pow(2.0, z) - (float(origin_x) + 0.5) / pow(2.0, origin_z)
	var fz := (float(y) + 0.5) / pow(2.0, z) - (float(origin_y) + 0.5) / pow(2.0, origin_z)
	return Vector2(fx, fz) * (EARTH_CIRCUMFERENCE_M * ground_scale(lat))


## World-space (x, z) position of (lat, lon) relative to the center of tile
## (origin_z,origin_x,origin_y) - like world_offset(), but for an exact
## lat/lon instead of a tile index, using the same continuous Web Mercator
## projection lat_lon_to_tile() floors to get a tile coordinate.
static func lat_lon_to_world(lat: float, lon: float, origin_z: int, origin_x: int, origin_y: int) -> Vector2:
	var n := pow(2.0, origin_z)
	var lat_rad := deg_to_rad(lat)
	var fx := (lon + 180.0) / 360.0 * n
	var fy := (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n
	return Vector2(fx - (float(origin_x) + 0.5), fy - (float(origin_y) + 0.5)) * (EARTH_CIRCUMFERENCE_M * ground_scale(lat) / n)


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


## Standard Web Mercator "slippy map" tile (x,y) at zoom `z` containing
## (lat, lon), both in degrees. See
## https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames.
static func lat_lon_to_tile(lat: float, lon: float, z: int) -> Vector2i:
	var n := pow(2.0, z)
	var x := int(floor((lon + 180.0) / 360.0 * n))
	var lat_rad := deg_to_rad(lat)
	var y := int(floor((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n))
	return Vector2i(x, y)
