extends SceneTree

var _scene: Node3D
var _tick := 0


func _initialize() -> void:
	_scene = (load("res://map/haven_map.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(_scene)
	var charger := _scene.get_node("ChargerEnemy")
	charger.state_changed.connect(_on_charger_state)


func _on_charger_state(previous: int, current: int) -> void:
	var charger := _scene.get_node("ChargerEnemy") as CharacterBody3D
	var player := _scene.get_node("Player") as Node3D
	print("   charger ", previous, "->", current, " pos ", charger.global_position, " vel ", charger.velocity,
		" dist ", snappedf(charger.global_position.distance_to(player.global_position), 0.01),
		" clear ", charger._has_clear_path(player.global_position), " dir ", charger._dash_direction,
		" slides ", charger.get_slide_collision_count())


func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		var model := _scene.get_node_or_null("Model") as Node3D
		var merged := _scene.get_node_or_null("ModelMerged") as MeshInstance3D
		var collision := _scene.get_node_or_null("ModelCollision") as StaticBody3D
		var visible_meshes := 0
		for node in _scene.find_children("*", "MeshInstance3D", true, false):
			if (node as MeshInstance3D).visible:
				visible_meshes += 1
		print("MAP model_visible=", model.visible,
			" merged_surfaces=", merged.mesh.get_surface_count() if merged and merged.mesh else -1,
			" collision_shapes=", collision.get_child_count() if collision else -1,
			" visible_meshes=", visible_meshes)

	if _tick % 30 == 0:
		var player := _scene.get_node_or_null("Player") as Node3D
		var charger := _scene.get_node_or_null("ChargerEnemy") as Node3D
		var dip := _scene.get_node_or_null("DipEnemy") as Node3D
		print("t=", _tick / 60.0, "s hp ", player.health,
			" player ", player.global_position,
			" | charger state ", charger.state, " aabb_dist ", snappedf(charger.global_position.distance_to(player.global_position), 0.01),
			" | dip state ", dip.state)

	return _tick >= 420
