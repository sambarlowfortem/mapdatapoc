extends Node

func _ready() -> void:
	var tile := get_node("../Tile")
	while true:
		await get_tree().create_timer(1.0).timeout
		if tile.get_child_count() > 0:
			var has_buildings := false
			for c in tile.get_children():
				if c.name == "Buildings" or c.name == "OuterBuildings":
					has_buildings = true
			if has_buildings:
				break
	await get_tree().create_timer(1.0).timeout

	var cam := get_node("../Camera3D") as Camera3D
	print("CAM DEBUG current=%s global_pos=%s global_basis_z=%s viewport_cam=%s" % [
		cam.current, cam.global_position, cam.global_transform.basis.z,
		get_viewport().get_camera_3d()
	])
	var terrain := get_node("../Node3D") as TerrainRGBLoader
	print("ELEV AT ORIGIN: %.1f" % terrain.get_elevation_at_global(Vector3.ZERO))

	var img := get_viewport().get_texture().get_image()
	img.save_png("/tmp/claude-1000/-home-sam-barlow-Documents-test-mapdatapoc/0f99d062-8a88-4501-b211-347c862216ea/scratchpad/experiment_tallboost.png")
	print("SCREENSHOT SAVED")
	#get_tree().quit()
