## Scene entry point: given real-world coordinates (lat/lon), computes which
## tile contains them - at each node's own configured zoom - for both the
## terrain and vector tile loaders, then kicks off loading.
extends Node3D
@onready var camera_3d: Camera3D = $Camera3D
var camera_offset: Vector3
@onready var mesh_instance_3d: MeshInstance3D = $MeshInstance3D
@onready var origin_marker: Marker3D = $OriginMarker

@onready var node_3d: TerrainRGBLoader = $Node3D

## Real-world coordinates (degrees) the scene should be centered on.
##fortem
#var lat: float = 40.3471
#var lon: float = -111.7582

var lat: float = 47.7403
var lon: float = -122.3385
#47.7403,-122.3385
## TerrainRGBLoader and MVTTileRenderer nodes to position from lat/lon.
## Each keeps its own tile_z (desired zoom/detail level) as already
## configured on the node - only tile_x/tile_y/lat get computed and
## overwritten (lat is needed for TileSource's Web Mercator scale
## correction, see TileSource.ground_scale()).
@export var terrain_path: NodePath
@export var tile_path: NodePath


func _ready() -> void:
	var terrain := get_node_or_null(terrain_path) as TerrainRGBLoader
	var tile := get_node_or_null(tile_path) as MVTTileRenderer
	camera_offset = camera_3d.position
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

	var vector_tile := TileSource.lat_lon_to_tile(lat, lon, tile.tile_z)
	tile.tile_x = vector_tile.x
	tile.tile_y = vector_tile.y
	tile.lat = lat

	# terrain.start_loading() also triggers the vector tile (via
	# vector_tile_path -> render_draped()) once the terrain grid is ready -
	# see TerrainRGBLoader._start_vector_tile(). Awaited here (rather than
	# fired-and-forgotten) so the marker below can sample ground elevation
	# once the terrain tiles it needs have actually loaded.
	await terrain.start_loading()

	_place_lat_lon_marker(terrain)

func _process(delta: float) -> void:
	mesh_instance_3d.position = Vector3(origin_marker.position.x, node_3d.get_elevation_at_global(origin_marker.position), origin_marker.position.z)
	camera_3d.position = mesh_instance_3d.position + camera_offset
	

## Drops a Marker3D at the exact (lat, lon) from above, sitting on the
## terrain surface (not a flat y) - useful for eyeballing that the lat/lon ->
## world-space math lines up with the rendered terrain/vector tiles. Note:
## Marker3D only draws its gizmo cross in the editor viewport, not in the
## actual running game window.
func _place_lat_lon_marker(terrain: TerrainRGBLoader) -> void:
	var local_xz := TileSource.lat_lon_to_world(lat, lon, terrain.tile_z, terrain.tile_x, terrain.tile_y)
	var global_pos := terrain.to_global(Vector3(local_xz.x, 0.0, local_xz.y))
	global_pos.y = terrain.get_elevation_at_global(global_pos)

	var marker := Marker3D.new()
	marker.name = "LatLonMarker"
	#origin_marker.position = marker.position
	add_child(marker)
	marker.global_position = global_pos
