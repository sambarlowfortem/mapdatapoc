## Minimal draw surface for SatelliteTileLoader._composite_and_apply() -
## draws each fetched satellite tile as a plain axis-aligned rect at its
## already-pixel-space position, in draw order (coarsest zoom first, finest
## last) so finer center imagery ends up on top of the coarser rings
## around it.
extends Node2D

var tiles: Array = []  # [{texture: Texture2D, rect: Rect2}] in draw order

func _draw() -> void:
	for entry in tiles:
		draw_texture_rect(entry["texture"], entry["rect"], false)
