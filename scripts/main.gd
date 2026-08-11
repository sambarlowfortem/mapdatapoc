## Scene entry point: given real-world coordinates (lat/lon), computes which
## tile contains them - at each node's own configured zoom - for both the
## terrain and vector tile loaders, then kicks off loading.
extends Node3D

## Real-world coordinates (degrees) the scene should be centered on.
@export var lat: float = 40.3471
@export var lon: float = -111.7582

## TerrainRGBLoader and MVTTileRenderer nodes to position from lat/lon.
## Each keeps its own tile_z (desired zoom/detail level) as already
## configured on the node - only tile_x/tile_y get computed and overwritten.
@export var terrain_path: NodePath
@export var tile_path: NodePath


func _ready() -> void:
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

	var vector_tile := TileSource.lat_lon_to_tile(lat, lon, tile.tile_z)
	tile.tile_x = vector_tile.x
	tile.tile_y = vector_tile.y

	# terrain.start_loading() also triggers the vector tile (via
	# vector_tile_path -> render_draped()) once the terrain grid is ready -
	# see TerrainRGBLoader._start_vector_tile().
	terrain.start_loading()
