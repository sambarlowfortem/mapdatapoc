## Shared math for XYZ map tiles: converting z/x/y tile coordinates to
## world-space meters (Web Mercator) and building URLs/grids of neighbors.
## Pure functions only - HTTP fetching stays local to each loader script.
extends RefCounted
class_name TileSource

const EARTH_CIRCUMFERENCE_M := 40075016.6855784

## Real-world size (meters) of one tile at zoom `z`.
static func size_meters(z: int) -> float:
	return EARTH_CIRCUMFERENCE_M / pow(2.0, z)


## World-space (x, z) offset of tile (z,x,y)'s center relative to the center
## of tile (origin_z,origin_x,origin_y) - works across different zoom levels,
## e.g. placing a vector tile relative to the terrain tile's origin.
static func world_offset(z: int, x: int, y: int, origin_z: int, origin_x: int, origin_y: int) -> Vector2:
	var fx := (float(x) + 0.5) / pow(2.0, z) - (float(origin_x) + 0.5) / pow(2.0, origin_z)
	var fz := (float(y) + 0.5) / pow(2.0, z) - (float(origin_y) + 0.5) / pow(2.0, origin_z)
	return Vector2(fx, fz) * EARTH_CIRCUMFERENCE_M


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
