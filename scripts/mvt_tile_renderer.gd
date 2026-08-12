## Fetches .pbf (Mapbox Vector Tile) tiles over HTTP covering (tile_z,
## tile_x, tile_y)'s footprint plus its 8 same-zoom neighbors, plus a third
## "outer" ring one zoom level coarser, and builds simple 3D meshes for them:
## colored ground layers, ribbon roads/waterways, and extruded buildings, all
## draped onto a terrain surface rather than sitting flat.
##
## The center tile prefers 4 higher-detail children (tile_z+1) from
## high_detail_url_template; if that source can't be reached, it falls back
## to the single tile_z/tile_x/tile_y tile from url_template instead. The 8
## surrounding tiles always come from url_template at tile_z, positioned
## edge-to-edge around whichever version of the center ended up loading.
##
## The outer ring (outer_url_template, at tile_z-1) is a 3x3 grid of tiles
## one zoom level coarser, centered on the tile_z-1 PARENT of the center
## tile. A coarser 3x3 ring never lines up evenly with the finer 3x3 grid
## inside it (3 tiles at one zoom covers 1.5 tiles' worth at the zoom one
## level coarser, not a whole number), so rather than try to compute and
## exclude the exact overlapping region, the outer ring is simply fetched
## and rendered in full - including the part that's geographically
## redundant with the finer tiles - and rendered at a lower render_priority
## (see _finalize_mesh) so the finer tiles always visually win wherever they
## overlap. The overlap costs some wasted fetch/render work; it avoids
## needing exact tile-boundary geometry clipping.
##
## Each of the three rings is merged into its own three meshes (ground/
## lines/buildings) - six total, not three - so the outer ring can have its
## own (lower) render priority tier independent of the inner rings. No true
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

## Outer ring source - a 3x3 grid of tiles at tile_z-1 (one zoom level
## coarser), centered on the tile_z-1 parent of (tile_x, tile_y). Left
## empty, no outer ring is loaded. See the class doc comment for why this
## overlaps the inner tiles instead of being clipped to exclude them.
@export var outer_url_template: String = ""

## Zoom/x/y of the tile this node covers. high_detail_url_template (if set)
## fetches this tile's 4 children at tile_z+1; url_template (fallback, or
## if high_detail_url_template is empty) fetches this exact tile.
@export var tile_z: int = 13
@export var tile_x: int = 0
@export var tile_y: int = 0

## Fallback building height (meters) when a feature has no render_height.
@export var default_building_height: float = 8.0

## Flat vertical offset (meters) added on top of the sampled terrain
## elevation for all draped geometry - compensates for terrain/vector data
## not agreeing exactly on where "ground level" is. 0 = exact calculated
## position, no artificial lift.
@export var drape_height_offset: float = 0.0

## How far (meters) building walls extend below their sampled base
## elevation - a foundation "skirt" so there's never a visible gap under a
## building on sloped terrain, since base_y is sampled once at the
## footprint's centroid (see _add_building) and terrain can dip below that
## single sample anywhere else under the footprint.
@export var building_foundation_depth: float = 20.0

const GEOM_POINT := MVTParser.GEOM_POINT
const GEOM_LINESTRING := MVTParser.GEOM_LINESTRING
const GEOM_POLYGON := MVTParser.GEOM_POLYGON

const LAYER_COLORS := {
	"water": Color(0.25, 0.45, 0.75),
	"landcover": Color(0.55, 0.68, 0.42),
	"landuse": Color(0.62, 0.58, 0.5),
	"building": Color(0.78, 0.74, 0.68),
}

const LANDUSE_CLASS_COLORS := {
	"residential": Color(0.75, 0.72, 0.66),
	"commercial": Color(0.7, 0.62, 0.6),
	"retail": Color(0.72, 0.65, 0.58),
	"industrial": Color(0.6, 0.58, 0.62),
	"park": Color(0.45, 0.65, 0.4),
	"cemetery": Color(0.5, 0.6, 0.48),
	"hospital": Color(0.85, 0.75, 0.75),
	"theme_park": Color(0.8, 0.6, 0.75),
	"pitch": Color(0.4, 0.68, 0.35),
}

const ROAD_STYLE := {
	"motorway": {"width": 18.0, "color": Color(0.95, 0.55, 0.2)},
	"trunk": {"width": 16.0, "color": Color(0.95, 0.6, 0.3)},
	"primary": {"width": 14.0, "color": Color(0.95, 0.75, 0.3)},
	"secondary": {"width": 11.0, "color": Color(0.9, 0.85, 0.5)},
	"tertiary": {"width": 9.0, "color": Color(0.85, 0.85, 0.7)},
	"minor": {"width": 6.0, "color": Color(0.88, 0.88, 0.88)},
	"service": {"width": 4.0, "color": Color(0.72, 0.72, 0.72)},
	"rail": {"width": 3.0, "color": Color(0.3, 0.3, 0.3)},
}
const ROAD_STYLE_DEFAULT := {"width": 5.0, "color": Color(0.8, 0.8, 0.8)}

var tile_size_meters: float = 0.0




## Builds this node's meshes, sampling `terrain`'s elevation at every vertex
## so ground/roads/buildings all rest on the terrain surface underneath them
## instead of floating at a flat y. See the class doc comment for the
## center/surroundings/fallback strategy.
func render_draped(terrain: TerrainRGBLoader) -> void:
	if high_detail_url_template == "" and url_template == "":
		push_warning("MVTTileRenderer: no high_detail_url_template or url_template set")
		return

	var st_ground := SurfaceTool.new()
	st_ground.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_lines := SurfaceTool.new()
	st_lines.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_buildings := SurfaceTool.new()
	st_buildings.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Flat-shade buildings: see the note on _finalize_mesh's caller below.
	st_buildings.set_smooth_group(-1)

	var st_outer_ground := SurfaceTool.new()
	st_outer_ground.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_outer_lines := SurfaceTool.new()
	st_outer_lines.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_outer_buildings := SurfaceTool.new()
	st_outer_buildings.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_outer_buildings.set_smooth_group(-1)

	var counts := Vector3i.ZERO  # x=ground, y=lines, z=buildings vertex counts
	var outer_counts := Vector3i.ZERO
	var loaded := 0
	var total := 0
	var used_high_detail := false

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
			var url := TileSource.url_for(high_detail_url_template, child_z, c.x, c.y)
			print("SENDING REQUEST TO ", url)
			var data: PackedByteArray = await _http_get(url)
			if data.is_empty():
				push_warning("MVTTileRenderer: high-detail source unreachable, falling back to url_template for the center tile")
				all_ok = false
				break
			fetched.append([c, data])
		if all_ok:
			used_high_detail = true
			tile_size_meters = TileSource.size_meters(child_z)
			total += fetched.size()
			for entry in fetched:
				var c: Vector2i = entry[0]
				var data: PackedByteArray = entry[1]
				var layers := MVTParser.parse_tile(data)
				if layers.is_empty():
					continue
				var world_offset := TileSource.world_offset(child_z, c.x, c.y, terrain.tile_z, terrain.tile_x, terrain.tile_y)
				counts += _render_layers(layers, terrain, world_offset, st_ground, st_lines, st_buildings)
				loaded += 1

	# Center fallback (only if high-detail didn't come through) plus the 8
	# same-zoom neighbors (always) - all at tile_z, from url_template. This
	# is what actually surrounds the high-detail center edge-to-edge, and
	# it's also the full 3x3 grid on its own if high-detail wasn't used.
	if url_template != "":
		tile_size_meters = TileSource.size_meters(tile_z)
		var center := Vector2i(tile_x, tile_y)
		for c in TileSource.grid_coords(tile_x, tile_y, 1):
			if c == center and used_high_detail:
				continue  # already covered by the 4 high-detail tiles above
			total += 1
			var url := TileSource.url_for(url_template, tile_z, c.x, c.y)
			print("SENDING REQUEST TO ", url)
			var data: PackedByteArray = await _http_get(url)
			if data.is_empty():
				continue
			var layers := MVTParser.parse_tile(data)
			if layers.is_empty():
				continue
			var world_offset := TileSource.world_offset(tile_z, c.x, c.y, terrain.tile_z, terrain.tile_x, terrain.tile_y)
			counts += _render_layers(layers, terrain, world_offset, st_ground, st_lines, st_buildings)
			loaded += 1
	elif not used_high_detail:
		push_warning("MVTTileRenderer: high-detail source failed and no fallback url_template set")

	# Outer ring: 3x3 grid one zoom level coarser, centered on the tile_z-1
	# parent of the center tile. Fetched and rendered in full, overlap with
	# the inner tiles and all - see the class doc comment for why - but kept
	# in its own meshes/materials so it can sit at a lower render_priority
	# and always lose to the inner tiles wherever they overlap.
	if outer_url_template != "":
		var outer_z := tile_z - 1
		var outer_center := Vector2i(tile_x / 2, tile_y / 2)
		tile_size_meters = TileSource.size_meters(outer_z)
		for c in TileSource.grid_coords(outer_center.x, outer_center.y, 1):
			total += 1
			var url := TileSource.url_for(outer_url_template, outer_z, c.x, c.y)
			print("SENDING REQUEST TO ", url)
			var data: PackedByteArray = await _http_get(url)
			if data.is_empty():
				continue
			var layers := MVTParser.parse_tile(data)
			if layers.is_empty():
				continue
			var world_offset := TileSource.world_offset(outer_z, c.x, c.y, terrain.tile_z, terrain.tile_x, terrain.tile_y)
			outer_counts += _render_layers(layers, terrain, world_offset, st_outer_ground, st_outer_lines, st_outer_buildings)
			loaded += 1

	print("MVTTileRenderer: loaded %d/%d tiles (center %s)" % [loaded, total, "high-detail" if used_high_detail else "fallback"])

	_finalize_mesh(st_ground, "GroundLayers", counts.x, 0, false)
	_finalize_mesh(st_lines, "Lines", counts.y, 0, false)
	_finalize_mesh(st_buildings, "Buildings", counts.z, 0, false, BaseMaterial3D.CULL_BACK)

	_finalize_mesh(st_outer_ground, "OuterGroundLayers", outer_counts.x, 0, false)
	_finalize_mesh(st_outer_lines, "OuterLines", outer_counts.y, 0, false)
	_finalize_mesh(st_outer_buildings, "OuterBuildings", outer_counts.z, 0, false, BaseMaterial3D.CULL_BACK)


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


## Terrain elevation at world position (x, z), plus a small per-layer offset
## to keep layers from z-fighting each other, plus the overall
## drape_height_offset.
func _terrain_y(terrain: TerrainRGBLoader, x: float, z: float, offset: float) -> float:
	return terrain.get_elevation_at_global(to_global(Vector3(x, 0.0, z))) + offset + drape_height_offset


static func _ensure_ccw(ring: PackedVector2Array) -> PackedVector2Array:
	var area := 0.0
	for i in range(ring.size()):
		var a: Vector2 = ring[i]
		var b: Vector2 = ring[(i + 1) % ring.size()]
		area += (a.x * b.y - b.x * a.y)
	if area < 0.0:
		ring.reverse()
	return ring


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


## Same as _add_polygon_flat, but each vertex samples the terrain under it
## (plus `offset`) instead of using one fixed y - so the polygon follows the
## ground's contour instead of slicing through it on sloped terrain.
func _add_polygon_draped(st: SurfaceTool, rings: Array, extent: int, color: Color, terrain: TerrainRGBLoader, offset: float, world_offset: Vector2) -> int:
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
			var a: Vector2 = world_ring[indices[i]] + world_offset
			var b: Vector2 = world_ring[indices[i + 1]] + world_offset
			var c: Vector2 = world_ring[indices[i + 2]] + world_offset
			st.set_color(color)
			st.add_vertex(Vector3(a.x, _terrain_y(terrain, a.x, a.y, offset), a.y))
			st.set_color(color)
			st.add_vertex(Vector3(b.x, _terrain_y(terrain, b.x, b.y, offset), b.y))
			st.set_color(color)
			st.add_vertex(Vector3(c.x, _terrain_y(terrain, c.x, c.y, offset), c.y))
			count += 3
	return count


## Buildings sit on a single base elevation sampled at their footprint's
## centroid (not per-vertex) so walls stay vertical and roofs stay flat -
## reasonable for a building-sized footprint, unlike the larger ground layers.
func _add_building(st: SurfaceTool, rings: Array, extent: int, height: float, color: Color, terrain: TerrainRGBLoader, world_offset: Vector2) -> int:
	var base_y := 0.0
	if rings.size() > 0:
		var outer := _world_ring(rings[0], extent)
		if outer.size() > 0:
			var centroid := Vector2.ZERO
			for p in outer:
				centroid += p
			centroid = centroid / outer.size() + world_offset
			base_y = _terrain_y(terrain, centroid.x, centroid.y, 0.0)
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


func _add_line(st: SurfaceTool, rings: Array, extent: int, width: float, color: Color, terrain: TerrainRGBLoader, offset: float, world_offset: Vector2) -> int:
	var count := 0
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
			var ya0 := _terrain_y(terrain, a0.x, a0.y, offset)
			var ya1 := _terrain_y(terrain, a1.x, a1.y, offset)
			var yb0 := _terrain_y(terrain, b0.x, b0.y, offset)
			var yb1 := _terrain_y(terrain, b1.x, b1.y, offset)
			st.set_color(color); st.add_vertex(Vector3(a0.x, ya0, a0.y))
			st.set_color(color); st.add_vertex(Vector3(a1.x, ya1, a1.y))
			st.set_color(color); st.add_vertex(Vector3(b1.x, yb1, b1.y))
			st.set_color(color); st.add_vertex(Vector3(a0.x, ya0, a0.y))
			st.set_color(color); st.add_vertex(Vector3(b1.x, yb1, b1.y))
			st.set_color(color); st.add_vertex(Vector3(b0.x, yb0, b0.y))
			count += 6
	return count


## All meshes (ground, lines, buildings) use normal depth testing against
## the terrain and each other - the small per-layer Y offsets applied in
## _render_layers (water, roads, waterways) are what keep those from
## z-fighting, not this function. Buildings use CULL_BACK instead of the
## default CULL_DISABLED so their own back/interior faces don't compete
## with front faces for the same pixels; ordinary convex building
## footprints render correctly with backface culling alone.
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


## Adds one tile's layers into the given SurfaceTools - shared across the
## whole grid, so all tiles end up merged into three meshes total rather
## than three per tile - offsetting every vertex by world_offset. Returns
## per-surface vertex counts as Vector3i(ground, lines, buildings) so the
## caller can accumulate a running total across tiles.
func _render_layers(layers: Dictionary, terrain: TerrainRGBLoader, world_offset: Vector2, st_ground: SurfaceTool, st_lines: SurfaceTool, st_buildings: SurfaceTool) -> Vector3i:
	# Ground: landcover, landuse, water - draped onto the terrain surface,
	# drawn low to high so water and landuse don't z-fight with landcover.
	var ground_count := 0
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
			ground_count += _add_polygon_draped(st_ground, feat["rings"], extent, col, terrain, 0.0, world_offset)
	if layers.has("water"):
		var extent: int = layers["water"]["extent"]
		for feat in layers["water"]["features"]:
			if feat["type"] == GEOM_POLYGON:
				ground_count += _add_polygon_draped(st_ground, feat["rings"], extent, LAYER_COLORS["water"], terrain, -0.15, world_offset)

	# Roads + waterway lines, draped slightly above the ground layers.
	var lines_count := 0
	if layers.has("transportation"):
		var extent: int = layers["transportation"]["extent"]
		for feat in layers["transportation"]["features"]:
			if feat["type"] != GEOM_LINESTRING:
				continue
			var cls: String = feat["props"].get("class", "minor")
			var style = ROAD_STYLE.get(cls, ROAD_STYLE_DEFAULT)
			lines_count += _add_line(st_lines, feat["rings"], extent, style["width"], style["color"], terrain, 0.05, world_offset)
	if layers.has("waterway"):
		var extent: int = layers["waterway"]["extent"]
		for feat in layers["waterway"]["features"]:
			if feat["type"] == GEOM_LINESTRING:
				lines_count += _add_line(st_lines, feat["rings"], extent, 2.0, Color(0.3, 0.5, 0.8), terrain, 0.02, world_offset)

	# Buildings, extruded from the terrain surface.
	var buildings_count := 0
	if layers.has("building"):
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
			buildings_count += _add_building(st_buildings, feat["rings"], extent, height, color, terrain, world_offset)

	return Vector3i(ground_count, lines_count, buildings_count)
