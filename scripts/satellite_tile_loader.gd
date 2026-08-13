## Fetches satellite raster tiles (jpg) over HTTP and applies them to
## `terrain` as two independent layers (see TerrainRGBLoader.
## apply_ground_texture/apply_overlay_texture), each composited into its
## own mosaic texture at its own resolution rather than baking both into
## one shared-resolution texture (which would force the high-res patch
## down to the low-res background's pixel density, or blow up the low-res
## background's texture size to match the high-res patch):
##
## - BASE layer (base_url_template): one low-res tile per terrain grid
##   tile, at `terrain`'s own zoom/grid (terrain.tile_z/tile_x/tile_y/
##   grid_radius) - covers the WHOLE terrain footprint.
## - OVERLAY layer (overlay_url_template): the same three concentric,
##   non-overlapping rings MVTTileRenderer uses for vector data - see that
##   class's doc comment for the exact alignment scheme - but shifted one
##   zoom level finer throughout: a 2x2 block at tile_z+1 in the center
##   (covering the footprint of the single tile_z tile at tile_x/tile_y), a
##   4x4-window ring at tile_z around that (aligned to tile_z-1
##   boundaries), and one ring of tile_z-1 tiles around that - covers a
##   much smaller high-detail patch layered on top of the base. If
##   overlay_url_template can't be reached, falls back to just 4 tiles at
##   tile_z-2 from overlay_fallback_url_template instead - see
##   _load_overlay_fallback().
##
## Either url_template can be left empty to skip that layer entirely. Each
## fetched tile is just an axis-aligned rect at its real Web Mercator
## footprint (no triangulation needed, unlike the vector ground texture,
## since satellite tiles are already simple squares in this projection with
## no rotation involved).
##
## Every tile (all three sources) goes through TileCache first - see
## _cached_get() - so repeat loads of an already-visited area cost no
## network traffic at all.
##
## This node does NOT fetch/render on its own - like MVTTileRenderer, it
## waits for render_draped() to be called once a terrain grid is ready to
## drape onto (normally triggered by TerrainRGBLoader.satellite_tile_path).
extends Node3D
class_name SatelliteTileLoader

## URL template for the low-res base layer - {z}/{x}/{y} substituted, e.g.
## "http://172.16.0.250:8089/data/satellite_lowres/{z}/{x}/{y}.jpg". Fetched
## at terrain's own tile_z/tile_x/tile_y/grid_radius, one tile per terrain
## grid tile. Left empty, no base layer is applied.
@export var base_url_template: String = ""

## URL template for the high-res overlay layer - {z}/{x}/{y} substituted
## (plus any query string, e.g. an API key, already baked in), e.g.
## "https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=...".
## Used for all three rings - satellite imagery doesn't have a separate
## higher-detail source the way vector tiles do, only the requested zoom
## differs per ring. Left empty, no overlay layer is applied.
@export var overlay_url_template: String = ""

## Fallback URL template used ONLY when overlay_url_template can't be
## reached (probed with a single request before committing to the full
## 3-ring pyramid, so an unreachable API fails fast instead of waiting out
## 31 individual timeouts) - {z}/{x}/{y} substituted, e.g.
## "http://172.16.0.250:8089/data/satellite_lowres/{z}/{x}/{y}.jpg". Just 4
## tiles at tile_z-2, chosen so tile_x/tile_y end up as close to the middle
## of the 4-tile block as possible - see _load_overlay_fallback(). Left
## empty, the overlay layer is simply skipped if the primary source fails.
@export var overlay_fallback_url_template: String = ""

## Testing-only toggle: when true, skips the overlay_url_template probe
## entirely and goes straight to overlay_fallback_url_template, as if the
## primary source were unreachable. Flip back to false for normal operation.
@export var simulate_overlay_unreachable: bool = false

## z/x/y of the tile the overlay is centered on - the reference "mid" ring,
## analogous to MVTTileRenderer.tile_z/tile_x/tile_y but one zoom level
## finer (e.g. 15 here if MVTTileRenderer.tile_z is 14). The center 2x2
## block covers this tile's footprint at tile_z+1; the outer ring sits at
## tile_z-1.
@export var tile_z: int = 15
@export var tile_x: int = 0
@export var tile_y: int = 0

## Real-world latitude (degrees), same as MVTTileRenderer.lat/TerrainRGBLoader.lat.
@export var lat: float = 0.0

## Target texel density (meters/pixel) for the overlay mosaic. Real
## satellite tiles are fixed-resolution (typically 256x256), so the center
## (finest zoom) ring is native-resolution-limited well before this in
## practice; coarser rings cover more ground at the same source pixel count
## and just end up more stretched, same as any zoomed-out satellite
## basemap. Clamped by max_texture_size so the composited texture doesn't
## blow up regardless of how large the outer ring's footprint turns out to
## be.
@export var overlay_meters_per_pixel: float = 1.5

## Multiplicative color correction applied to the overlay layer only, not
## the base - base_url_template and overlay_url_template often come from
## different imagery providers with different color grading, so the seam
## between them can look like an obvious color jump even when the imagery
## itself lines up pixel-perfect. Tune this in the editor while looking at
## the seam; (1,1,1) (white) leaves the overlay unchanged.
@export var overlay_tint: Color = Color(1.0, 1.0, 1.0)

## Target texel density (meters/pixel) for the base mosaic - much coarser
## than the overlay by default since it covers the whole terrain grid (a
## much larger area) from a source that's already low-res.
@export var base_meters_per_pixel: float = 8.0

@export var max_texture_size: int = 8192


func render_draped(terrain: TerrainRGBLoader) -> void:
	if base_url_template == "" and overlay_url_template == "":
		push_warning("SatelliteTileLoader: neither base_url_template nor overlay_url_template set")
		return

	if base_url_template != "":
		await _load_base_layer(terrain)
	if overlay_url_template != "":
		await _load_overlay_layer(terrain)


## Fetches one low-res tile per terrain grid tile (terrain's own
## tile_z/tile_x/tile_y/grid_radius - the exact same grid TerrainRGBLoader
## itself loaded), composites them, and applies the result as the base
## layer covering the whole terrain footprint.
func _load_base_layer(terrain: TerrainRGBLoader) -> void:
	var coords := TileSource.grid_coords(terrain.tile_x, terrain.tile_y, terrain.grid_radius)
	var fetched := await _fetch_tiles(base_url_template, coords.map(func(c): return {"z": terrain.tile_z, "x": c.x, "y": c.y}), terrain)
	print("SatelliteTileLoader: loaded %d/%d base tiles" % [fetched["loaded"], coords.size()])
	if not fetched["has_bounds"]:
		return
	var tex := await _composite(fetched["entries"], fetched["bounds"], base_meters_per_pixel)
	if tex != null:
		terrain.apply_ground_texture(tex, fetched["bounds"].position, fetched["bounds"].size)


## If every tile the pyramid needs is already cached, loads it straight
## from disk unconditionally - no network touched at all, not even the
## reachability probe, since a full cache hit is genuinely just as good as
## a live fetch regardless of whether the API happens to be reachable right
## now (this check runs even under simulate_overlay_unreachable - that flag
## only fakes the PROBE's outcome, see below, not whether cached data is
## real and usable). Otherwise probes overlay_url_template with a single
## LIVE (never cache-satisfied - a cache hit here would tell us nothing
## about current reachability) request before committing to fetching the
## rest - an unreachable API fails this one request (worst case, one
## timeout) rather than however many of the remaining tiles are actually
## missing. Falls back to overlay_fallback_url_template if the probe fails
## (or simulate_overlay_unreachable forces it to be skipped and treated as
## failed, for testing the fallback path without needing a real outage - to
## exercise that alongside a cache hit too, clear/rename the cache folder
## first). A successful probe's bytes are cached too, so the pyramid fetch
## that follows doesn't re-request that same tile live.
func _load_overlay_layer(terrain: TerrainRGBLoader) -> void:
	var specs := _overlay_pyramid_specs()

	if _all_cached(overlay_url_template, specs):
		await _load_overlay_pyramid(terrain, specs)
		return

	var reachable := false
	if not simulate_overlay_unreachable:
		var probe_z := tile_z + 1
		var probe_x := tile_x * 2
		var probe_y := tile_y * 2
		var probe_url := TileSource.url_for(overlay_url_template, probe_z, probe_x, probe_y)
		print("SENDING REQUEST TO ", probe_url, " (overlay reachability probe)")
		var probe_data := await _http_get(probe_url)
		reachable = not probe_data.is_empty()
		if reachable:
			TileCache.write(TileCache.path_for(overlay_url_template, probe_z, probe_x, probe_y), probe_data)

	if reachable:
		await _load_overlay_pyramid(terrain, specs)
	else:
		push_warning("SatelliteTileLoader: overlay_url_template unreachable, falling back to overlay_fallback_url_template")
		await _load_overlay_fallback(terrain)


## The three-ring pyramid's tile list (see class doc comment) - factored
## out of _load_overlay_pyramid() so _load_overlay_layer() can check cache
## coverage against it before deciding whether a live probe is even needed.
func _overlay_pyramid_specs() -> Array:
	var z_mid := tile_z
	var z_outer := tile_z - 1
	var z_center := tile_z + 1

	var mid_x0 := TileSource.aligned_window_start(tile_x)
	var mid_y0 := TileSource.aligned_window_start(tile_y)
	var outer_x0 := mid_x0 / 2
	var outer_y0 := mid_y0 / 2

	# Draw order matters: coarsest (outer) first, finest (center) last, so
	# finer imagery ends up on top of the coarser ring around it.
	var specs := []  # [{z, x, y}]
	for dy in range(-1, 3):
		for dx in range(-1, 3):
			if dx >= 0 and dx <= 1 and dy >= 0 and dy <= 1:
				continue  # inner 2x2 - covered by the mid ring below
			specs.append({"z": z_outer, "x": outer_x0 + dx, "y": outer_y0 + dy})
	for dy in range(4):
		for dx in range(4):
			var cx := mid_x0 + dx
			var cy := mid_y0 + dy
			if cx == tile_x and cy == tile_y:
				continue  # already covered by the 4 z_center tiles below
			specs.append({"z": z_mid, "x": cx, "y": cy})
	for c in [
		Vector2i(tile_x * 2, tile_y * 2),
		Vector2i(tile_x * 2 + 1, tile_y * 2),
		Vector2i(tile_x * 2, tile_y * 2 + 1),
		Vector2i(tile_x * 2 + 1, tile_y * 2 + 1),
	]:
		specs.append({"z": z_center, "x": c.x, "y": c.y})
	return specs


## True if every {z,x,y} in `specs` already has a cached file for
## `template` - a cheap existence check only, no reads.
func _all_cached(template: String, specs: Array) -> bool:
	for t in specs:
		if not FileAccess.file_exists(TileCache.path_for(template, t["z"], t["x"], t["y"])):
			return false
	return true


## Fetches the three-ring overlay pyramid (`specs`, from
## _overlay_pyramid_specs()), composites it, and applies the result as the
## overlay layer.
func _load_overlay_pyramid(terrain: TerrainRGBLoader, specs: Array) -> void:
	var fetched := await _fetch_tiles(overlay_url_template, specs, terrain)
	print("SatelliteTileLoader: loaded %d/%d overlay tiles" % [fetched["loaded"], specs.size()])
	if not fetched["has_bounds"]:
		return
	var tex := await _composite(fetched["entries"], fetched["bounds"], overlay_meters_per_pixel)
	if tex != null:
		terrain.apply_overlay_texture(tex, fetched["bounds"].position, fetched["bounds"].size, overlay_tint)


## Fetches 4 tiles at tile_z-2 from overlay_fallback_url_template, chosen so
## tile_x/tile_y (the reference tile two zooms finer) ends up as close to
## the middle of the 4-tile block as possible: tile_x/tile_y's own position
## within its tile_z-2 parent (a 4x4 window of tile_z tiles, so tile_x % 4
## and tile_y % 4 give that position directly - equivalent to checking
## which quadrant the original lat/lon falls in, without needing a separate
## lon export) picks which neighbor to extend toward on each axis: top-left
## quadrant -> add the tile above, the tile to the left, and their diagonal;
## top-right -> above/right/diagonal; bottom-left -> below/left/diagonal;
## bottom-right -> below/right/diagonal.
func _load_overlay_fallback(terrain: TerrainRGBLoader) -> void:
	if overlay_fallback_url_template == "":
		push_warning("SatelliteTileLoader: no overlay_fallback_url_template set, overlay layer skipped")
		return

	var z13 := tile_z - 2
	var z13_x0 := tile_x / 4
	var z13_y0 := tile_y / 4
	var dx := -1 if (tile_x % 4) < 2 else 1
	var dy := -1 if (tile_y % 4) < 2 else 1

	var to_fetch := []
	for c in [
		Vector2i(z13_x0, z13_y0),
		Vector2i(z13_x0 + dx, z13_y0),
		Vector2i(z13_x0, z13_y0 + dy),
		Vector2i(z13_x0 + dx, z13_y0 + dy),
	]:
		to_fetch.append({"z": z13, "x": c.x, "y": c.y})

	var fetched := await _fetch_tiles(overlay_fallback_url_template, to_fetch, terrain)
	print("SatelliteTileLoader: loaded %d/%d overlay fallback tiles" % [fetched["loaded"], to_fetch.size()])
	if not fetched["has_bounds"]:
		return
	var tex := await _composite(fetched["entries"], fetched["bounds"], overlay_meters_per_pixel)
	if tex != null:
		# No overlay_tint here (unlike _load_overlay_pyramid) - the fallback
		# source is meant to be the same local-server family as base_url_template,
		# not the API, so it shouldn't need the API-vs-local color correction.
		terrain.apply_overlay_texture(tex, fetched["bounds"].position, fetched["bounds"].size)


## Fetches (serialized - see _http_get) each {z,x,y} in `specs` from
## `url_template` and computes its world-space footprint, so the overall
## bounding box is known before any compositing happens. Returns
## {entries: [{image, rect}] in fetch order, bounds: Rect2, has_bounds:
## bool, loaded: int}.
func _fetch_tiles(template: String, specs: Array, terrain: TerrainRGBLoader) -> Dictionary:
	var entries := []
	var bounds := Rect2()
	var has_bounds := false
	var loaded := 0
	for t in specs:
		var data: PackedByteArray = await _cached_get(template, t["z"], t["x"], t["y"])
		if data.is_empty():
			continue
		var img := Image.new()
		if img.load_jpg_from_buffer(data) != OK:
			push_warning("SatelliteTileLoader: could not decode tile z=%d x=%d y=%d" % [t["z"], t["x"], t["y"]])
			continue
		var size := TileSource.size_meters(t["z"], lat)
		var center := TileSource.world_offset(t["z"], t["x"], t["y"], terrain.tile_z, terrain.tile_x, terrain.tile_y, lat)
		var rect := Rect2(center - Vector2(size, size) * 0.5, Vector2(size, size))
		entries.append({"image": img, "rect": rect})
		bounds = rect if not has_bounds else bounds.merge(rect)
		has_bounds = true
		loaded += 1
	return {"entries": entries, "bounds": bounds, "has_bounds": has_bounds, "loaded": loaded}


## Rasterizes `entries` (each an already-decoded tile image plus its
## world-space footprint rect) into one mosaic texture at `mpp` meters/pixel
## (clamped by max_texture_size) via a plain 2D SubViewport - see
## MVTTileRenderer._build_and_apply_ground_texture for the world-space ->
## pixel-space convention (no flip needed). Returns null on capture failure.
func _composite(entries: Array, bounds: Rect2, mpp: float) -> Texture2D:
	var bbox_min := bounds.position
	var bbox_size := bounds.size
	var largest_px = max(bbox_size.x, bbox_size.y) / mpp
	if largest_px > max_texture_size:
		mpp *= largest_px / max_texture_size
	var tex_w = max(1, int(round(bbox_size.x / mpp)))
	var tex_h = max(1, int(round(bbox_size.y / mpp)))

	var canvas := preload("res://scripts/satellite_texture_canvas.gd").new()
	var px_tiles := []
	for entry in entries:
		var r: Rect2 = entry["rect"]
		var px_pos := (r.position - bbox_min) / mpp
		var px_size := r.size / mpp
		px_tiles.append({"texture": ImageTexture.create_from_image(entry["image"]), "rect": Rect2(px_pos, px_size)})
	canvas.tiles = px_tiles

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
		push_warning("SatelliteTileLoader: mosaic capture failed")
		return null

	return ImageTexture.create_from_image(img)


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
## awaited fully before the next one starts) - same reasoning as
## MVTTileRenderer._http_get: the tile server this pattern was written
## against doesn't handle many simultaneous connections well.
func _http_get(url: String) -> PackedByteArray:
	var req := HTTPRequest.new()
	add_child(req)
	req.timeout = 10.0  # a stalled request should fail loudly, not hang forever
	var err := req.request(url)
	if err != OK:
		push_error("SatelliteTileLoader: could not start request for %s (error %d)" % [url, err])
		req.queue_free()
		return PackedByteArray()
	var response: Array = await req.request_completed
	req.queue_free()
	var http_result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]
	if http_result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("SatelliteTileLoader: request to %s failed (result %d, code %d)" % [url, http_result, response_code])
		return PackedByteArray()
	return body
