## Debug HUD: every frame, calls TerrainRGBLoader.get_elevation_at_global()
## at `marker_path`'s position - the exact same function
## MVTTileRenderer._terrain_y() calls to place every building - and shows
## the result on screen. Lets elevation-sampling behavior be watched live
## (e.g. moving the marker around) instead of only from one-off print
## diagnostics.
extends Label

@export var terrain_path: NodePath
@export var marker_path: NodePath

func _process(_delta: float) -> void:
	var terrain := get_node_or_null(terrain_path) as TerrainRGBLoader
	var marker := get_node_or_null(marker_path) as Node3D
	if terrain == null or marker == null:
		text = "terrain/marker not found"
		return
	var pos := marker.global_position
	var elevation := terrain.get_elevation_at_global(pos)
	text = "Terrain elevation at marker (x=%.1f, z=%.1f): %.2f m" % [pos.x, pos.z, elevation]
