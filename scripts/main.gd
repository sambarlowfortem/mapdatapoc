## Scene entry point: given real-world coordinates (lat/lon), computes which
## tile contains them - at each node's own configured zoom - for both the
## terrain and vector tile loaders, then kicks off loading. World (0,0,0) is
## defined to be exactly (lat, lon) at ground level - see TileSource.world_offset()
## (horizontal) and TerrainRGBLoader._compute_origin_elevation() (vertical).
extends Node3D

## Real-world coordinates (degrees) the scene should be centered on - this
## point becomes world (0,0,0) horizontally, at ground level vertically.
##fortem
var lat: float = 40.3471
var lon: float = -111.7582

#var lat: float = 47.7403
#var lon: float = -122.3385
#47.7403,-122.3385
## TerrainRGBLoader and MVTTileRenderer nodes to position from lat/lon.
## Each keeps its own tile_z (desired zoom/detail level) as already
## configured on the node - only tile_x/tile_y/lat/lon get computed and
## overwritten (lat/lon are needed for TileSource's world-offset math and
## Web Mercator scale correction, see TileSource.ground_scale()).
@export var terrain_path: NodePath
@export var tile_path: NodePath

## Optional SatelliteTileLoader node - left empty, no satellite tiles are
## positioned/loaded.
@export var satellite_path: NodePath


func _ready() -> void:
	# Evict least-recently-used tiles if the on-disk cache (see TileCache)
	# has grown past its size cap - done once here, up front, rather than
	# after every individual tile write, since it has to walk the whole
	# cache tree.
	TileCache.enforce_size_cap()
	print("TileCache: using ", TileCache.root_dir())

	var terrain := get_node_or_null(terrain_path) as TerrainRGBLoader
	var tile := get_node_or_null(tile_path) as MVTTileRenderer
	if terrain == null:
		push_warning("main: terrain_path %s not found or not a TerrainRGBLoader" % terrain_path)
		return
	if tile == null:
		push_warning("main: tile_path %s not found or not an MVTTileRenderer" % tile_path)
		return

	var terrain_tile := TileSource.lat_lon_to_tile(lat, lon, terrain.tile_z)
	terrain.tile_x = terrain_tile.x
	terrain.tile_y = terrain_tile.y
	terrain.lat = lat
	terrain.lon = lon

	var vector_tile := TileSource.lat_lon_to_tile(lat, lon, tile.tile_z)
	tile.tile_x = vector_tile.x
	tile.tile_y = vector_tile.y
	tile.lat = lat
	tile.lon = lon

	var satellite := get_node_or_null(satellite_path) as SatelliteTileLoader
	if satellite != null:
		var satellite_tile := TileSource.lat_lon_to_tile(lat, lon, satellite.tile_z)
		satellite.tile_x = satellite_tile.x
		satellite.tile_y = satellite_tile.y
		satellite.lat = lat
		satellite.lon = lon

	# terrain.start_loading() also triggers the vector/satellite tile
	# loaders (via vector_tile_path/satellite_tile_path -> render_draped())
	# once the terrain grid is ready - see
	# TerrainRGBLoader._trigger_draped_renderer().
	terrain.start_loading()
