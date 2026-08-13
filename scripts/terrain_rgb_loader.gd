## Fetches a grid of Terrain-RGB elevation tiles over HTTP (webp/png encoded
## DEM, MapTiler/Mapbox style: height = -10000 + (R*65536 + G*256 + B) * 0.1),
## centered on (tile_z, tile_x, tile_y), and builds a heightmap mesh for each
## at full extent (no cropping) - that way any georeferencing mismatch shows
## up visually instead of being hidden. The center tile's center is world
## (0,0,0); every other loaded tile (terrain or vector) is placed relative
## to it. Once the whole grid has loaded, triggers the vector tile node (see
## `vector_tile_path`) to render draped onto this terrain's surface via
## get_elevation_at_global().
##
## Does NOT start loading on its own - call start_loading() once tile_x/
## tile_y (and anything else) are set the way you want them. This matters
## if something else (e.g. main.gd, computing tile_x/tile_y from lat/lon)
## needs to configure this node first: Godot calls children's _ready()
## before their parent's, so a parent can't reliably beat this node's own
## _ready() to the punch - hence loading has to be opt-in instead.
##
## IMPORTANT - not yet tested against a real tile: unlike the MVT parser
## (which was checked against actual bytes from 3090.pbf), no sample
## terrain tile was available to verify against, so double check the
## decoded elevations against a known point before trusting this.
extends Node3D
class_name TerrainRGBLoader

## URL template for fetching tiles - {z}/{x}/{y} are substituted, e.g.
## "http://172.16.0.250:8089/data/terrain/{z}/{x}/{y}.webp".
@export var url_template: String = ""

## Zoom/x/y of the CENTER tile of the grid - this tile's center becomes
## world (0,0,0).
@export var tile_z: int = 11
@export var tile_x: int = 0
@export var tile_y: int = 0

## Real-world latitude (degrees) this grid is centered on - set by main.gd
## alongside tile_x/tile_y. Needed to correct Web Mercator's latitude-
## dependent scale distortion (see TileSource.ground_scale()); without it,
## tile_size_meters is inflated by 1/cos(lat), stretching the whole map.
@export var lat: float = 0.0

## How many tiles out from the center to load in each direction - 0 loads
## just the center tile, 1 loads a 3x3 grid, 2 a 5x5 grid, etc.
@export var grid_radius: int = 0

## Read every Nth pixel instead of every pixel. 1 = full resolution
## (a 512x512 tile = ~262k pixels = ~524k triangles - probably too much
## for a first look). 4-8 is a more reasonable starting point.
@export var sample_stride: int = 4

@export var height_exaggeration: float = 1.0

## Node to trigger once this terrain grid has loaded - normally the
## MVTTileRenderer ("Tile") node. Left empty, nothing else is triggered.
## Requires a render_draped(terrain) method (MVTTileRenderer has one).
@export var vector_tile_path: NodePath = ^""

## Optional second node to trigger alongside vector_tile_path - normally a
## SatelliteTileLoader. Left empty, nothing else is triggered. Also requires
## a render_draped(terrain) method.
@export var satellite_tile_path: NodePath = ^""

## Fallback/base terrain color, shown wherever apply_ground_texture()'s
## baked texture doesn't cover (or before it's applied at all).
const BASE_GROUND_COLOR := Color(0.5, 0.55, 0.42)

const GROUND_TEXTURE_SHADER := preload("res://shaders/terrain_ground_texture.gdshader")

var tile_size_meters: float = 0.0
var _tile_images: Dictionary = {}  # Vector2i(x,y) -> Image, keyed by actual tile coords
var _terrain_meshes: Array[MeshInstance3D] = []
var _ground_shader_mat: ShaderMaterial = null


func start_loading() -> void:
	print("READY")
	if url_template == "":
		push_warning("TerrainRGBLoader: no url_template set")
		return
	print("READY2")
	tile_size_meters = TileSource.size_meters(tile_z, lat)

	var coords := TileSource.grid_coords(tile_x, tile_y, grid_radius)

	var loaded := 0
	for i in range(coords.size()):
		print("READY3 (%d/%d)" % [i + 1, coords.size()])
		var data: PackedByteArray = await _cached_get(url_template, tile_z, coords[i].x, coords[i].y)
		if data.is_empty():
			continue
		var img := _image_from_buffer(data, url_template)
		if img == null:
			push_error("TerrainRGBLoader: could not decode terrain tile %s" % [coords[i]])
			continue
		if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGB8)
		_tile_images[coords[i]] = img
		var offset := TileSource.world_offset(tile_z, coords[i].x, coords[i].y, tile_z, tile_x, tile_y, lat)
		_build_heightmap(img, Vector3(offset.x, 0.0, offset.y), "Terrain_%d_%d" % [coords[i].x, coords[i].y])
		loaded += 1
	print("TerrainRGBLoader: loaded %d/%d tiles" % [loaded, coords.size()])

	_trigger_draped_renderer(vector_tile_path, "vector_tile_path")
	_trigger_draped_renderer(satellite_tile_path, "satellite_tile_path")


## Returns tile (z,x,y) from `template`'s on-disk cache (see TileCache) if
## present, otherwise fetches it live and writes it to the cache on success.
func _cached_get(template: String, z: int, x: int, y: int) -> PackedByteArray:
	var cache_path := TileCache.path_for(template, z, x, y)
	var cached := TileCache.read(cache_path)
	if not cached.is_empty():
		return cached
	var data := await _http_get(TileSource.url_for(template, z, x, y))
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
		push_error("TerrainRGBLoader: could not start request for %s (error %d)" % [url, err])
		req.queue_free()
		return PackedByteArray()
	var response: Array = await req.request_completed
	req.queue_free()
	var http_result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]
	if http_result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("TerrainRGBLoader: request to %s failed (result %d, code %d)" % [url, http_result, response_code])
		return PackedByteArray()
	return body


func _trigger_draped_renderer(path: NodePath, export_name: String) -> void:
	if path.is_empty():
		return
	var target := get_node_or_null(path)
	if target == null:
		push_warning("TerrainRGBLoader: %s %s not found" % [export_name, path])
		return
	if target.has_method("render_draped"):
		target.render_draped(self)


## Applies `tex` as the BASE layer of every loaded terrain tile's ground
## texture, world-space-mapped so the same material/uniforms work
## regardless of each tile's own local offset. `bbox_min`/`bbox_size` are
## the world-space XZ rectangle `tex` covers. See apply_overlay_texture()
## for layering a smaller, higher-detail texture on top of this.
func apply_ground_texture(tex: Texture2D, bbox_min: Vector2, bbox_size: Vector2) -> void:
	var mat := _get_or_create_ground_shader_mat()
	mat.set_shader_parameter("ground_texture", tex)
	mat.set_shader_parameter("bbox_min", bbox_min)
	mat.set_shader_parameter("bbox_size", bbox_size)


## Applies `tex` as an OVERLAY layer, drawn on top of the base layer
## (apply_ground_texture()) wherever `tex`'s own world-space bbox covers -
## e.g. a small high-resolution satellite patch over a much larger low-
## resolution background, without baking both into one texture at a single
## shared resolution. Safe to call before apply_ground_texture(); the base
## layer just shows base_color until that's applied too.
func apply_overlay_texture(tex: Texture2D, bbox_min: Vector2, bbox_size: Vector2) -> void:
	var mat := _get_or_create_ground_shader_mat()
	mat.set_shader_parameter("overlay_texture", tex)
	mat.set_shader_parameter("overlay_bbox_min", bbox_min)
	mat.set_shader_parameter("overlay_bbox_size", bbox_size)
	mat.set_shader_parameter("overlay_enabled", true)


## One shader material shared by every terrain mesh, created lazily on
## first use - apply_ground_texture() and apply_overlay_texture() both
## write into the SAME instance so either can be called first, and updates
## from one are visible without disturbing whatever the other already set.
func _get_or_create_ground_shader_mat() -> ShaderMaterial:
	if _ground_shader_mat == null:
		_ground_shader_mat = ShaderMaterial.new()
		_ground_shader_mat.shader = GROUND_TEXTURE_SHADER
		_ground_shader_mat.set_shader_parameter("base_color", BASE_GROUND_COLOR)
		for mi in _terrain_meshes:
			mi.material_override = _ground_shader_mat
	return _ground_shader_mat


## Samples the decoded terrain elevation directly under `global_pos` (only
## its x/z are used), picking whichever loaded grid tile actually covers
## that position, then interpolating across the SAME strided grid quad
## (and diagonal triangle split) that _build_heightmap() actually renders -
## so draped features (ground/roads/buildings) land exactly on the visible
## terrain surface instead of an independently-sampled nearest pixel that
## can disagree with it slightly (a real source of z-fighting/gaps against
## the terrain mesh, not just an ordering problem). Returns 0.0 if no
## loaded tile covers it.
func get_elevation_at_global(global_pos: Vector3) -> float:
	if tile_size_meters == 0.0:
		return 0.0
	var local := to_local(global_pos)
	var cx := int(round(local.x / tile_size_meters))
	var cy := int(round(local.z / tile_size_meters))
	var key := Vector2i(tile_x + cx, tile_y + cy)
	if not _tile_images.has(key):
		return 0.0
	var img: Image = _tile_images[key]
	var cols = max(1, img.get_width() / sample_stride)
	var rows = max(1, img.get_height() / sample_stride)

	var fx: float = clamp(local.x / tile_size_meters - cx + 0.5, 0.0, 1.0)
	var fz: float = clamp(local.z / tile_size_meters - cy + 0.5, 0.0, 1.0)

	# Continuous position in the same grid space _build_heightmap() uses.
	var gx_cont: float = clamp(fx * cols, 0.0, float(cols))
	var gy_cont: float = clamp(fz * rows, 0.0, float(rows))
	var gx0: int = clamp(int(gx_cont), 0, cols - 1)
	var gy0: int = clamp(int(gy_cont), 0, rows - 1)
	var u: float = gx_cont - gx0
	var v: float = gy_cont - gy0

	var h00 := _sample_grid_elevation(img, gx0, gy0)
	var h10 := _sample_grid_elevation(img, gx0 + 1, gy0)
	var h01 := _sample_grid_elevation(img, gx0, gy0 + 1)
	var h11 := _sample_grid_elevation(img, gx0 + 1, gy0 + 1)

	# Same diagonal split _build_heightmap() triangulates: (p00,p10,p11)
	# covers u>=v, (p00,p11,p01) covers v>=u - barycentric height on
	# whichever triangle (u,v) actually falls in.
	if u >= v:
		return h00 * (1.0 - u) + h10 * (u - v) + h11 * v
	else:
		return h00 * (1.0 - v) + h01 * (v - u) + h11 * u


## Elevation at strided grid point (gx, gy) of `img`, decoded exactly the
## way _build_heightmap() samples its height grid - shared so
## get_elevation_at_global() always interpolates the identical surface the
## mesh was actually built from, rather than a separately-tuned lookup that
## could drift out of sync with it.
func _sample_grid_elevation(img: Image, gx: int, gy: int) -> float:
	var px: int = min(gx * sample_stride, img.get_width() - 1)
	var py: int = min(gy * sample_stride, img.get_height() - 1)
	return _decode_elevation(img.get_pixel(px, py)) * height_exaggeration


## Decodes an image buffer, picking the format from the URL's extension
## (png vs webp) since there's no file extension-based auto-detect for
## in-memory buffers the way Image.load() has for paths.
func _image_from_buffer(data: PackedByteArray, url: String) -> Image:
	var img := Image.new()
	var err: int
	if url.get_extension().to_lower() == "png":
		err = img.load_png_from_buffer(data)
	else:
		err = img.load_webp_from_buffer(data)
	if err != OK:
		return null
	return img


func _decode_elevation(c: Color) -> float:
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	return -10000.0 + float(r * 65536 + g * 256 + b) * 0.1


func _build_heightmap(img: Image, offset: Vector3, mesh_name: String) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var cols = max(1, w / sample_stride)
	var rows = max(1, h / sample_stride)

	# Precompute the height grid first (avoids re-decoding shared corners).
	# Shares _sample_grid_elevation with get_elevation_at_global() so that
	# function always interpolates the exact surface built here.
	var heights := []
	for gy in range(rows + 1):
		var row := PackedFloat32Array()
		row.resize(cols + 1)
		for gx in range(cols + 1):
			row[gx] = _sample_grid_elevation(img, gx, gy)
		heights.append(row)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := tile_size_meters * 0.5

	for gy in range(rows):
		for gx in range(cols):
			var x0 = -half + (float(gx) / cols) * tile_size_meters
			var x1 = -half + (float(gx + 1) / cols) * tile_size_meters
			var z0 = -half + (float(gy) / rows) * tile_size_meters
			var z1 = -half + (float(gy + 1) / rows) * tile_size_meters

			var h00: float = heights[gy][gx]
			var h10: float = heights[gy][gx + 1]
			var h01: float = heights[gy + 1][gx]
			var h11: float = heights[gy + 1][gx + 1]

			var p00 := Vector3(x0, h00, z0)
			var p10 := Vector3(x1, h10, z0)
			var p01 := Vector3(x0, h01, z1)
			var p11 := Vector3(x1, h11, z1)

			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)

	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = mesh_name
	mi.position = offset
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BASE_GROUND_COLOR
	mi.material_override = mat
	add_child(mi)
	_terrain_meshes.append(mi)
