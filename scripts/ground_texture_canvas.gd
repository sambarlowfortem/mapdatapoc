## Minimal draw surface for MVTTileRenderer._build_and_apply_ground_texture()
## - draws pre-triangulated, already-pixel-space polygons directly via
## CanvasItem, in list order (ground entries first, line entries after, so
## lines always paint over ground - no depth test or elevation involved).
extends Node2D

var polygons: Array = []  # [{points: PackedVector2Array, color: Color}, ...] in draw order

func _draw() -> void:
	for entry in polygons:
		draw_colored_polygon(entry["points"], entry["color"])
