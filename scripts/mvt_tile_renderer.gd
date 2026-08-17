## Fetches .pbf (Mapbox Vector Tile) tiles over HTTP in three concentric,
## NON-overlapping rings of increasing zoom (= detail) toward the center: a
## 2x2 block of tiles at tile_z+1 in the middle, a ring of tiles at tile_z
## around that, and a ring of tiles at tile_z-1 around that. Ground
## (landcover/landuse/water) and lines (roads/waterways) are rasterized
## directly from the parsed vector data into a texture applied to the
## terrain surface (see _build_and_apply_ground_texture /
## TerrainRGBLoader.apply_ground_texture) rather than built as 3D geometry -
## only buildings are extruded 3D meshes, draped onto the terrain surface.
##
## The center 2x2 block (tile_z+1, from high_detail_url_template) covers
## exactly the footprint of the single tile_z tile containing (tile_x,
## tile_y). If that source can't be reached, the center tile is instead
## fetched as part of the tile_z ring below (from url_template).
##
## The tile_z ring (url_template) is a 4x4 window of tile_z tiles - not
## just the 8 immediate neighbors - expanded (see TileSource.aligned_window_start())
## so its edges land exactly on tile_z-1 tile boundaries (2 tile_z tiles =
## 1 tile_z-1 tile). That's what lets the tile_z-1 ring below start exactly
## where this one ends, with no gap and no double-covered area - unlike a
## plain 3x3 window, which straddles tile_z-1 boundaries unevenly (3 tiles
## covers 1.5 tiles' worth one zoom level coarser) and would otherwise force
## a choice between a gap or fetching/rendering the same ground twice at two
## different zoom levels (which used to happen here - duplicate buildings
## in the overlap band, among other things).
##
## The tile_z-1 ring (outer_url_template) is the 12 tiles forming a
## one-tile-wide ring around the 2x2 tile_z-1 block the tile_z window above
## exactly covers.
##
## Each ring gets its own buildings mesh (Buildings / OuterBuildings), so
## material/priority could differ per ring if ever needed. No true
## streaming yet - it all loads once, up front.
##
## This node does NOT fetch/render on its own - rendering needs a terrain to
## drape onto, so it waits for render_draped() to be called (normally by a
## sibling TerrainRGBLoader, once its own tile grid has loaded).
extends Node3D
class_name MVTTileRenderer

## Preferred high-detail source, tried first - {z}/{x}/{y} substituted (plus
## any query string, e.g. an API key, already baked into the template).
## Fetches the 4 tiles at tile_z+1 that make up (tile_z, tile_x, tile_y),
## e.g. "https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=...".
@export var high_detail_url_template: String = ""

## Fallback source, used only if high_detail_url_template can't be reached
## (any of the 4 high-detail requests fails) - fetches a single tile at
## tile_z/tile_x/tile_y instead, e.g.
## "http://172.16.0.250:8089/data/vector/{z}/{x}/{y}.pbf". Lower detail but
## more reliable than the external source. Also fetches the 8 same-zoom
## neighbors around the center (always, regardless of which center source
## was used).
@export var url_template: String = ""

## Outer ring source - a one-tile-wide ring of tiles at tile_z-1 (one zoom
## level coarser), around the tile_z-1 footprint the tile_z ring exactly
## covers. Left empty, no outer ring is loaded. See the class doc comment
## for the exact (non-overlapping) tiling scheme.
@export var outer_url_template: String = ""

## Zoom/x/y of the tile this node covers. high_detail_url_template (if set)
## fetches this tile's 4 children at tile_z+1; url_template (fallback, or
## if high_detail_url_template is empty) fetches this exact tile.
@export var tile_z: int = 13
@export var tile_x: int = 0
@export var tile_y: int = 0

## Real-world latitude/longitude (degrees) this tile grid is centered on -
## set by main.gd alongside tile_x/tile_y, and should match the sibling
## TerrainRGBLoader's lat/lon. `lat` corrects Web Mercator's latitude-
## dependent scale distortion, see TileSource.ground_scale(); both together
## are the exact point TileSource.world_offset() places everything relative
## to (see TerrainRGBLoader's class doc comment).
@export var lat: float = 0.0
@export var lon: float = 0.0

## Fallback building height (meters) when a feature has no render_height.
@export var default_building_height: float = 8.0

## Flat vertical offset (meters) added on top of the sampled terrain
## elevation for all draped geometry - compensates for terrain/vector data
## not agreeing exactly on where "ground level" is. 0 = exact calculated
## position, no artificial lift.
@export var drape_height_offset: float = 0.0

## How far (meters) building walls extend below their sampled base
## elevation - a foundation "skirt" so there's never a visible gap under a
## building on sloped terrain, since base_y is the minimum of samples taken
## at the footprint's own corners (see _add_building) and terrain can still
## dip lower somewhere between those corners.
@export var building_foundation_depth: float = 20.0

## Experiment toggle: when false, landcover/landuse/water/road/waterway
## features are still parsed (buildings need the same .pbf tiles) but never
## turned into the baked ground texture - only buildings render. Used to A/B
## the vector-drawn ground against a satellite-imagery ground (see
## SatelliteTileLoader) without the two competing for the same terrain
## material at once.
var render_ground_and_lines: bool = false

const GEOM_POINT := MVTParser.GEOM_POINT
const GEOM_LINESTRING := MVTParser.GEOM_LINESTRING
const GEOM_POLYGON := MVTParser.GEOM_POLYGON

## Palette tuned to match a muted, low-saturation basemap style (dark navy
## water, uniform sage-olive ground, pale cream road hierarchy, flat matte
## gray buildings) - all classes stay in the same desaturated earth-tone
## family instead of the more saturated per-class OSM colors this used to
## use, so different land-use classes still read as distinct without
## breaking the overall cohesive look.
const LAYER_COLORS := {
	"water": Color(0.09, 0.17, 0.28),
	"landcover": Color(0.62, 0.64, 0.52),
	"landuse": Color(0.62, 0.64, 0.52),
	"building": Color(0.068, 0.07, 0.065, 1.0),
}

const LANDUSE_CLASS_COLORS := {
	"residential": Color(0.65, 0.65, 0.55),
	"commercial": Color(0.6, 0.59, 0.51),
	"retail": Color(0.62, 0.61, 0.52),
	"industrial": Color(0.56, 0.57, 0.53),
	"park": Color(0.5, 0.58, 0.42),
	"cemetery": Color(0.55, 0.6, 0.48),
	"hospital": Color(0.66, 0.6, 0.55),
	"theme_park": Color(0.6, 0.55, 0.58),
	"pitch": Color(0.48, 0.62, 0.4),
}

const ROAD_STYLE := {
	"motorway": {"width": 18.0, "color": Color(0.9, 0.88, 0.8)},
	"trunk": {"width": 16.0, "color": Color(0.88, 0.86, 0.78)},
	"primary": {"width": 14.0, "color": Color(0.87, 0.85, 0.76)},
	"secondary": {"width": 11.0, "color": Color(0.85, 0.83, 0.74)},
	"tertiary": {"width": 9.0, "color": Color(0.83, 0.81, 0.72)},
	"minor": {"width": 6.0, "color": Color(0.8, 0.79, 0.7)},
	"service": {"width": 4.0, "color": Color(0.75, 0.74, 0.66)},
	"rail": {"width": 3.0, "color": Color(0.35, 0.33, 0.3)},
}
const ROAD_STYLE_DEFAULT := {"width": 5.0, "color": Color(0.78, 0.77, 0.68)}

var tile_size_meters: float = 0.0




## Builds this node's buildings meshes (sampling `terrain`'s elevation at
## each building's centroid so they rest on the terrain surface instead of
## floating at a flat y) and the baked ground/line texture applied to
## `terrain` itself. See the class doc comment for the
## center/surroundings/fallback strategy.
func render_draped(terrain: TerrainRGBLoader) -> void:
	if high_detail_url_template == "" and url_template == "":
		push_warning("MVTTileRenderer: no high_detail_url_template or url_template set")
		return

	var st_buildings := SurfaceTool.new()
	st_buildings.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Flat-shade buildings: see the note on _finalize_mesh's caller below.
	st_buildings.set_smooth_group(-1)

	var st_outer_buildings := SurfaceTool.new()
	st_outer_buildings.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_outer_buildings.set_smooth_group(-1)

	var counts := 0  # buildings vertex count
	var outer_counts := 0
	var loaded := 0
	var total := 0
	var used_high_detail := false

	# Flat (no elevation) ground/line geometry for the baked ground texture
	# - collected from both the inner and outer rings (same coverage as the
	# Buildings/OuterBuildings meshes below), entirely independent of
	# terrain. See _build_and_apply_ground_texture.
	var ground_tris := []
	var line_quads := []

	# Center: 4 higher-detail children at tile_z+1, from high_detail_url_template.
	if high_detail_url_template != "":
		var child_z := tile_z + 1
		var children := [
			Vector2i(tile_x * 2, tile_y * 2),
			Vector2i(tile_x * 2 + 1, tile_y * 2),
			Vector2i(tile_x * 2, tile_y * 2 + 1),
			Vector2i(tile_x * 2 + 1, tile_y * 2 + 1),
		]
		var fetched := []
		var all_ok := true
		for c in children:
			var data: PackedByteArray = await _cached_get(high_detail_url_template, child_z, c.x, c.y)
			if data.is_empty():
				push_warning("MVTTileRenderer: high-detail source unreachable, falling back to url_template for the center tile")
				all_ok = false
				break
			fetched.append([c, data])
		if all_ok:
			used_high_detail = true
			tile_size_meters = TileSource.size_meters(child_z, lat)
			total += fetched.size()
			for entry in fetched:
				var c: Vector2i = entry[0]
				var data: PackedByteArray = entry[1]
				var layers := MVTParser.parse_tile(data)
				if layers.is_empty():
					continue
				var world_offset := TileSource.world_offset(child_z, c.x, c.y, lat, lon)
				counts += _render_buildings(layers, terrain, world_offset, st_buildings)
				if render_ground_and_lines:
					_collect_flat_layers(layers, world_offset, ground_tris, line_quads)
				loaded += 1

	# 4x4 window of tile_z tiles, aligned to tile_z-1 tile boundaries (2
	# tile_z tiles = 1 tile_z-1 tile) so the tile_z ring and tile_z-1 ring
	# below hand off with no gap and no overlap - see the class doc comment
	# and TileSource.aligned_window_start().
	var z14_x0 := TileSource.aligned_window_start(tile_x)
	var z14_y0 := TileSource.aligned_window_start(tile_y)

	# tile_z ring: every tile in the aligned 4x4 window - this is what
	# actually surrounds the high-detail center edge-to-edge. Center tile
	# is skipped when the 4 high-detail children already cover it.
	if url_template != "":
		tile_size_meters = TileSource.size_meters(tile_z, lat)
		for dy in range(4):
			for dx in range(4):
				var cx := z14_x0 + dx
				var cy := z14_y0 + dy
				if cx == tile_x and cy == tile_y and used_high_detail:
					continue  # already covered by the 4 high-detail tiles above
				total += 1
				var data: PackedByteArray = await _cached_get(url_template, tile_z, cx, cy)
				if data.is_empty():
					continue
				var layers := MVTParser.parse_tile(data)
				if layers.is_empty():
					continue
				var world_offset := TileSource.world_offset(tile_z, cx, cy, lat, lon)
				counts += _render_buildings(layers, terrain, world_offset, st_buildings)
				if render_ground_and_lines:
					_collect_flat_layers(layers, world_offset, ground_tris, line_quads)
				loaded += 1
	elif not used_high_detail:
		push_warning("MVTTileRenderer: high-detail source failed and no fallback url_template set")

	# Outer ring: the 12 tiles forming a one-tile-wide ring around the 2x2
	# tile_z-1 block the tile_z window above exactly covers - picking up
	# precisely where that window stops, with no overlap and no gap.
	if outer_url_template != "":
		var outer_z := tile_z - 1
		var z13_x0 := z14_x0 / 2
		var z13_y0 := z14_y0 / 2
		tile_size_meters = TileSource.size_meters(outer_z, lat)
		for dy in range(-1, 3):
			for dx in range(-1, 3):
				if dx >= 0 and dx <= 1 and dy >= 0 and dy <= 1:
					continue  # inner 2x2 - already covered by the tile_z window above
				var cx := z13_x0 + dx
				var cy := z13_y0 + dy
				total += 1
				var data: PackedByteArray = await _cached_get(outer_url_template, outer_z, cx, cy)
				if data.is_empty():
					continue
				var layers := MVTParser.parse_tile(data)
				if layers.is_empty():
					continue
				var world_offset := TileSource.world_offset(outer_z, cx, cy, lat, lon)
				outer_counts += _render_buildings(layers, terrain, world_offset, st_outer_buildings)
				if render_ground_and_lines:
					_collect_flat_layers(layers, world_offset, ground_tris, line_quads)
				loaded += 1

	print("MVTTileRenderer: loaded %d/%d tiles (center %s)" % [loaded, total, "high-detail" if used_high_detail else "fallback"])

	_finalize_mesh(st_buildings, "Buildings", counts, 0, false, BaseMaterial3D.CULL_BACK)
	_finalize_mesh(st_outer_buildings, "OuterBuildings", outer_counts, 0, false, BaseMaterial3D.CULL_BACK)

	# Baked ground texture - built directly from ground_tris/line_quads
	# (parsed vector data, flat, no elevation), not from any 3D geometry.
	# See _build_and_apply_ground_texture. Covers the same inner+outer
	# footprint as the buildings meshes above; buildings themselves are
	# excluded from the texture (they stay 3D-only). Skipped entirely when
	# render_ground_and_lines is off - ground_tris/line_quads are empty in
	# that case anyway, but this also avoids overwriting whatever ground
	# texture (e.g. SatelliteTileLoader's) is already applied to `terrain`.
	if render_ground_and_lines:
		await _build_and_apply_ground_texture(ground_tris, line_quads, terrain)


## Returns tile (z,x,y) from `template`'s on-disk cache (see TileCache) if
## present, otherwise fetches it live and writes it to the cache on success.
func _cached_get(template: String, z: int, x: int, y: int) -> PackedByteArray:
	var cache_path := TileCache.path_for(template, z, x, y)
	var cached := TileCache.read(cache_path)
	if not cached.is_empty():
		return cached
	var url := TileSource.url_for(template, z, x, y)
	print("SENDING REQUEST TO ", url)
	var data := await _http_get(url)
	if not data.is_empty():
		TileCache.write(cache_path, data)
	return data


## Fetches `url` and returns the raw response body, or an empty array on any
## failure (logged via push_error). Tiles are fetched one at a time (this is
## awaited fully before the next one starts) rather than firing the whole
## grid concurrently - the tile server appears not to handle many
## simultaneous connections, which was causing requests to hang forever
## instead of failing.
func _http_get(url: String) -> PackedByteArray:
	var req := HTTPRequest.new()
	add_child(req)
	req.timeout = 10.0  # a stalled request should fail loudly, not hang forever
	var err := req.request(url)
	if err != OK:
		push_error("MVTTileRenderer: could not start request for %s (error %d)" % [url, err])
		req.queue_free()
		return PackedByteArray()
	var response: Array = await req.request_completed
	req.queue_free()
	var http_result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]
	if http_result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("MVTTileRenderer: request to %s failed (result %d, code %d)" % [url, http_result, response_code])
		return PackedByteArray()
	return body


func _to_world(p: Vector2, extent: int) -> Vector2:
	# Map tile-local [0, extent] -> meters, relative to THIS tile's own
	# center - grid placement (world_offset) is added separately by callers.
	# Tile Y grows downward (south); Godot -Z is "forward/north" by
	# convention, so we flip Y into Z directly (world Z grows south).
	var s := tile_size_meters / float(extent)
	var wx := p.x * s - tile_size_meters * 0.5
	var wz := p.y * s - tile_size_meters * 0.5
	return Vector2(wx, wz)


## Terrain elevation at world position (x, z), plus drape_height_offset.
func _terrain_y(terrain: TerrainRGBLoader, x: float, z: float) -> float:
	return terrain.get_elevation_at_global(to_global(Vector3(x, 0.0, z))) + drape_height_offset


static func _signed_area(ring: PackedVector2Array) -> float:
	var area := 0.0
	for i in range(ring.size()):
		var a: Vector2 = ring[i]
		var b: Vector2 = ring[(i + 1) % ring.size()]
		area += (a.x * b.y - b.x * a.y)
	return area


static func _ensure_ccw(ring: PackedVector2Array) -> PackedVector2Array:
	if _signed_area(ring) < 0.0:
		ring.reverse()
	return ring


## An MVT polygon feature's `rings` isn't necessarily one polygon - it can
## be a MultiPolygon, encoding several disconnected footprints (e.g. a whole
## row of townhomes, or an apartment complex's separate wings) as one
## feature. The spec's own convention is what makes them distinguishable at
## all: every exterior ring shares one winding direction, and every hole
## shares the opposite one, however many separate exterior rings there are.
## This walks the RAW (pre-_ensure_ccw - winding still means something)
## rings in order and starts a new sub-polygon each time a ring's winding
## matches the first ring's, treating any opposite-wound ring as a hole of
## whichever sub-polygon it immediately follows. Returns Array[Array] - one
## inner Array per sub-polygon, each already in the [outer, hole, hole...]
## shape _add_building/_add_polygon_flat expect.
##
## Getting this right matters: before this split existed, a building
## function was handed the whole multi-hundred-ring feature at once and
## sampled ONE elevation from just the first ring, then reused that single
## value for every other ring's walls - so a feature bundling hundreds of
## real buildings scattered across a tile rendered them all at whichever
## one building's elevation happened to be first, regardless of how far the
## rest actually were from it.
static func _split_into_polygons(rings: Array) -> Array:
	var polygons: Array = []
	if rings.is_empty():
		return polygons
	var exterior_positive := _signed_area(rings[0]) >= 0.0
	for ring in rings:
		var is_exterior := (_signed_area(ring) >= 0.0) == exterior_positive
		if polygons.is_empty() or is_exterior:
			polygons.append([ring])
		else:
			polygons[polygons.size() - 1].append(ring)
	return polygons


func _world_ring(ring: PackedVector2Array, extent: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in ring:
		out.append(_to_world(p, extent))
	# Drop a duplicate closing point (MVT rings from ClosePath repeat the first point).
	if out.size() > 2 and out[0].is_equal_approx(out[out.size() - 1]):
		out.remove_at(out.size() - 1)
	return _ensure_ccw(out)


## Flat polygon at a fixed y (used for building roofs, which stay level
## regardless of the terrain under the building's footprint).
func _add_polygon_flat(st: SurfaceTool, rings: Array, extent: int, color: Color, y: float, world_offset: Vector2) -> int:
	var count := 0
	for ring in rings:
		if ring.size() < 3:
			continue
		var world_ring := _world_ring(ring, extent)
		if world_ring.size() < 3:
			continue
		var indices := Geometry2D.triangulate_polygon(world_ring)
		if indices.size() == 0:
			continue
		for i in range(0, indices.size(), 3):
			var a: Vector2 = world_ring[indices[i]]
			var b: Vector2 = world_ring[indices[i + 1]]
			var c: Vector2 = world_ring[indices[i + 2]]
			st.set_color(color)
			st.add_vertex(Vector3(a.x + world_offset.x, y, a.y + world_offset.y))
			st.set_color(color)
			st.add_vertex(Vector3(b.x + world_offset.x, y, b.y + world_offset.y))
			st.set_color(color)
			st.add_vertex(Vector3(c.x + world_offset.x, y, c.y + world_offset.y))
			count += 3
	return count


## Buildings sit on a single base elevation - the MINIMUM terrain elevation
## sampled across the footprint's own corners (not a centroid average) -
## so walls stay vertical and roofs stay flat. Using the minimum guarantees
## the roof is always at least `height` above the lowest point terrain
## actually touches under the building: a centroid average can land well
## below the footprint's real corners on steep terrain (Seattle-hilly, not
## just gently sloped), which let base_y + height end up below the
## surrounding ground everywhere - the whole building buried, not just its
## foundation skirt showing a gap. The tradeoff is the reverse of that on
## sloped lots - the foundation now visibly buries deeper on the uphill
## side of a footprint - which is a far less objectionable artifact than a
## building floating or vanishing outright.
#var one_building: bool = false
func _add_building(st: SurfaceTool, rings: Array, extent: int, height: float, color: Color, terrain: TerrainRGBLoader, world_offset: Vector2) -> int:
	#print("Adding Building: st: ", st, " rings: ", rings, " extent: ", extent, " height ", height, " color: ", color, " terrain ", terrain, " world offset ", world_offset)
	#print("Adding Building: st: ", st, " extent: ", extent, " height ", height, " color: ", color, " terrain ", terrain, " world offset ", world_offset)

	var base_y := 0.0
	if rings.size() > 0:
		var outer := _world_ring(rings[0], extent)
		if outer.size() > 0:
			base_y = _terrain_y(terrain, outer[0].x + world_offset.x, outer[0].y + world_offset.y)
			for p in outer:
				base_y = min(base_y, _terrain_y(terrain, p.x + world_offset.x, p.y + world_offset.y))
	var count := _add_polygon_flat(st, rings, extent, color, base_y + height, world_offset)  # roof
	var wall_color := color.darkened(0.2)
	for ring in rings:
		if ring.size() < 2:
			continue
		var world_ring := _world_ring(ring, extent)
		var n := world_ring.size()
		if n < 2:
			continue
		for i in range(n):
			#print("Looping another ring with base_y ", base_y)
			var a: Vector2 = world_ring[i] + world_offset
			var b: Vector2 = world_ring[(i + 1) % n] + world_offset
			var a0 := Vector3(a.x, base_y - building_foundation_depth, a.y)
			var b0 := Vector3(b.x, base_y - building_foundation_depth, b.y)
			var a1 := Vector3(a.x, base_y + height, a.y)
			var b1 := Vector3(b.x, base_y + height, b.y)
			st.set_color(wall_color); st.add_vertex(a0)
			st.set_color(wall_color); st.add_vertex(b0)
			st.set_color(wall_color); st.add_vertex(b1)
			st.set_color(wall_color); st.add_vertex(a0)
			st.set_color(wall_color); st.add_vertex(b1)
			st.set_color(wall_color); st.add_vertex(a1)
			count += 6
	return count


## Buildings use normal depth testing against the terrain (and each other),
## plus CULL_BACK instead of the default CULL_DISABLED so their own
## back/interior faces don't compete with front faces for the same pixels -
## ordinary convex building footprints render correctly with backface
## culling alone.
func _finalize_mesh(st: SurfaceTool, node_name: String, vertex_count: int, render_priority: int = 0, no_depth_test: bool = true, cull_mode: BaseMaterial3D.CullMode = BaseMaterial3D.CULL_DISABLED) -> void:
	if vertex_count == 0:
		return
	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = node_name
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = cull_mode
	mat.no_depth_test = no_depth_test
	mat.render_priority = render_priority
	mi.material_override = mat
	add_child(mi)


## Collects `layers`' ground (landcover/landuse/water) and line
## (transportation/waterway) features as flat, pre-triangulated world-space
## shapes with no elevation involved at all - used to build the baked
## ground texture (_build_and_apply_ground_texture) directly from the
## parsed vector data. Buildings are excluded on purpose - they stay
## 3D-only, see _render_buildings.
func _collect_flat_layers(layers: Dictionary, world_offset: Vector2, ground_tris: Array, line_quads: Array) -> void:
	for lname in ["landcover", "landuse"]:
		if not layers.has(lname):
			continue
		var extent: int = layers[lname]["extent"]
		var base_color: Color = LAYER_COLORS.get(lname, Color(0.5, 0.5, 0.5))
		for feat in layers[lname]["features"]:
			if feat["type"] != GEOM_POLYGON:
				continue
			var col := base_color
			if lname == "landuse" and feat["props"].has("class"):
				col = LANDUSE_CLASS_COLORS.get(feat["props"]["class"], base_color)
			_collect_flat_polygon(ground_tris, feat["rings"], extent, col, world_offset)
	if layers.has("water"):
		var extent: int = layers["water"]["extent"]
		for feat in layers["water"]["features"]:
			if feat["type"] == GEOM_POLYGON:
				_collect_flat_polygon(ground_tris, feat["rings"], extent, LAYER_COLORS["water"], world_offset)

	if layers.has("transportation"):
		var extent: int = layers["transportation"]["extent"]
		for feat in layers["transportation"]["features"]:
			if feat["type"] != GEOM_LINESTRING:
				continue
			var cls: String = feat["props"].get("class", "minor")
			var style = ROAD_STYLE.get(cls, ROAD_STYLE_DEFAULT)
			_collect_flat_line(line_quads, feat["rings"], extent, style["width"], style["color"], world_offset)
	if layers.has("waterway"):
		var extent: int = layers["waterway"]["extent"]
		for feat in layers["waterway"]["features"]:
			if feat["type"] == GEOM_LINESTRING:
				_collect_flat_line(line_quads, feat["rings"], extent, 2.0, Color(0.14, 0.26, 0.4), world_offset)


## Triangulates `rings` the same way _add_polygon_flat does, but keeps the
## triangles as flat world-space (x, z) points with no y at all - appended
## to `tris` as {points, color} entries.
func _collect_flat_polygon(tris: Array, rings: Array, extent: int, color: Color, world_offset: Vector2) -> void:
	for ring in rings:
		if ring.size() < 3:
			continue
		var world_ring := _world_ring(ring, extent)
		if world_ring.size() < 3:
			continue
		var indices := Geometry2D.triangulate_polygon(world_ring)
		if indices.size() == 0:
			continue
		for i in range(0, indices.size(), 3):
			var a: Vector2 = world_ring[indices[i]] + world_offset
			var b: Vector2 = world_ring[indices[i + 1]] + world_offset
			var c: Vector2 = world_ring[indices[i + 2]] + world_offset
			tris.append({"points": PackedVector2Array([a, b, c]), "color": color})


## Builds per-segment width ribbon quads (same shape math a 3D draped line
## mesh would use), but as flat world-space (x, z) points with no y -
## appended to `quads` as {points, color} entries.
func _collect_flat_line(quads: Array, rings: Array, extent: int, width: float, color: Color, world_offset: Vector2) -> void:
	for ring in rings:
		if ring.size() < 2:
			continue
		var world_ring := PackedVector2Array()
		for p in ring:
			world_ring.append(_to_world(p, extent))
		for i in range(world_ring.size() - 1):
			var a: Vector2 = world_ring[i]
			var b: Vector2 = world_ring[i + 1]
			var dir := b - a
			if dir.length() < 0.0001:
				continue
			dir = dir.normalized()
			var perp := Vector2(-dir.y, dir.x) * (width * 0.5)
			var a0 := a + perp + world_offset
			var a1 := a - perp + world_offset
			var b0 := b + perp + world_offset
			var b1 := b - perp + world_offset
			quads.append({"points": PackedVector2Array([a0, a1, b1, b0]), "color": color})


## Target texel density for the baked ground texture (see
## _build_and_apply_ground_texture) - a middle ground between crispness
## (the narrowest roads are ~4m wide, so anything much coarser than this
## erases them) and texture memory (the covered area is typically several
## thousand meters across, so texel count grows fast). The pixel-size
## clamps keep both ends sane regardless of how large or small the actual
## covered area turns out to be.
const GROUND_TEXTURE_METERS_PER_PIXEL := 1.25
const GROUND_TEXTURE_MIN_SIZE := 1024
const GROUND_TEXTURE_MAX_SIZE := 6144


## Rasterizes `ground_tris`/`line_quads` (flat world-space shapes collected
## by _collect_flat_layers straight from the parsed vector tiles - no
## elevation, no 3D scene, no camera photographing anything) into a texture
## via a plain 2D SubViewport, then hands it to `terrain` to apply on its
## heightmap surface. Ground is drawn first, lines second, so lines always
## paint fully over ground with no depth test or occlusion involved at all
## - the source of the road-gap artifact the old top-down-photo approach
## had. Does nothing if there's no geometry to draw.
func _build_and_apply_ground_texture(ground_tris: Array, line_quads: Array, terrain: TerrainRGBLoader) -> void:
	var bounds := Rect2()
	var has_bounds := false
	for entry in ground_tris + line_quads:
		for p in entry["points"]:
			if not has_bounds:
				bounds = Rect2(p, Vector2.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(p)
	if not has_bounds or bounds.size.x < 1.0 or bounds.size.y < 1.0:
		return

	var bbox_min := bounds.position
	var bbox_size := bounds.size

	var mpp := GROUND_TEXTURE_METERS_PER_PIXEL
	var largest_px = max(bbox_size.x, bbox_size.y) / mpp
	if largest_px > GROUND_TEXTURE_MAX_SIZE:
		mpp *= largest_px / GROUND_TEXTURE_MAX_SIZE
	elif largest_px < GROUND_TEXTURE_MIN_SIZE:
		mpp *= largest_px / GROUND_TEXTURE_MIN_SIZE
	var tex_w = max(1, int(round(bbox_size.x / mpp)))
	var tex_h = max(1, int(round(bbox_size.y / mpp)))

	# World (x, z) -> pixel space: Godot's 2D canvas is already +X right /
	# +Y down, which matches +X world -> +U, +Z world -> +V exactly (same
	# north-up convention as _to_world()'s Y/Z doc comment, and the same
	# formula terrain_ground_texture.gdshader uses) - no flip needed.
	var canvas := preload("res://scripts/ground_texture_canvas.gd").new()
	var px_polys := []
	for entry in ground_tris + line_quads:
		var px_points := _to_px(entry["points"], bbox_min, mpp)
		if _fails_to_triangulate(px_points):
			continue
		px_polys.append({"points": px_points, "color": entry["color"]})
	canvas.polygons = px_polys

	var viewport := SubViewport.new()
	viewport.size = Vector2i(tex_w, tex_h)
	viewport.transparent_bg = true
	add_child(viewport)
	viewport.add_child(canvas)
	canvas.queue_redraw()

	# UPDATE_ONCE needs a couple of frames to actually land before the
	# texture is readable.
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img := viewport.get_texture().get_image()
	viewport.queue_free()
	if img == null:
		push_warning("MVTTileRenderer: ground texture capture failed")
		return

	var tex := ImageTexture.create_from_image(img)
	terrain.apply_ground_texture(tex, bbox_min, bbox_size)


func _to_px(points: PackedVector2Array, bbox_min: Vector2, mpp: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append((p - bbox_min) / mpp)
	return out


## Both the pre-triangulated ground triangles (_collect_flat_polygon) and the
## line ribbon quads (_collect_flat_line) come from real-world GIS data full
## of near-duplicate/near-collinear vertices, and draw_colored_polygon()'s
## internal triangulator rejects anything it can't find a valid ear for,
## printing "Invalid polygon data, triangulation failed." Rather than
## reinvent that validity check with a guessed area/epsilon threshold,
## Geometry2D.triangulate_polygon() runs the same triangulation
## draw_colored_polygon() does internally - if it can't triangulate a shape
## either, draw_colored_polygon() won't - so an empty result here is a
## direct, exact predictor of that failure, not a heuristic for it.
func _fails_to_triangulate(points: PackedVector2Array) -> bool:
	if points.size() < 3:
		return true
	return Geometry2D.triangulate_polygon(points).is_empty()


## Adds one tile's building features into `st_buildings` - shared across
## the whole grid, so all tiles end up merged into one mesh rather than one
## per tile - offsetting every vertex by world_offset. Ground/lines are
## handled separately, see _collect_flat_layers. Returns the added vertex
## count so the caller can accumulate a running total across tiles.
func _render_buildings(layers: Dictionary, terrain: TerrainRGBLoader, world_offset: Vector2, st_buildings: SurfaceTool) -> int:
	var buildings_count := 0
	if layers.has("building"):
		#one_building = true
		var extent: int = layers["building"]["extent"]
		for feat in layers["building"]["features"]:
			if feat["type"] != GEOM_POLYGON:
				continue
			var props: Dictionary = feat["props"]
			var height := default_building_height
			if props.has("render_height"):
				height = float(props["render_height"])
			var color: Color = LAYER_COLORS["building"]
			if props.has("colour") and (props["colour"] as String).begins_with("#"):
				color = Color(props["colour"])
			# A feature's rings can be a MultiPolygon (many disconnected
			# footprints bundled together) - split it into its true
			# sub-polygons first so each one gets its OWN elevation sample
			# instead of every sub-polygon after the first silently
			# borrowing the first one's, however far away it actually is.
			# See _split_into_polygons.
			for sub_rings in _split_into_polygons(feat["rings"]):
				buildings_count += _add_building(st_buildings, sub_rings, extent, height, color, terrain, world_offset)

	return buildings_count
