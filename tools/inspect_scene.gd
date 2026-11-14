extends SceneTree

var _scene: Node3D
var _tick := 0


func _initialize() -> void:
	_scene = (load("res://map/haven_map.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(_scene)


func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		var merged := _scene.get_node_or_null("ModelMerged") as MeshInstance3D
		var collision := _scene.get_node_or_null("ModelCollision") as StaticBody3D
		print("MAP merged_surfaces=", merged.mesh.get_surface_count() if merged and merged.mesh else -1,
			" collision_shapes=", collision.get_child_count() if collision else -1)

	if _tick % 60 == 0:
		var player := _scene.get_node_or_null("Player") as Node3D
		var charger := _scene.get_node_or_null("ChargerEnemy") as Node3D
		var dip := _scene.get_node_or_null("DipEnemy") as Node3D
		var post: Vector3 = charger.get_guard_position()
		print("t=", _tick / 60.0, "s hp ", player.health,
			" | charger state ", charger.state, " pos ", charger.global_position,
			" post_dist ", snappedf(Vector2(charger.global_position.x - post.x, charger.global_position.z - post.z).length(), 0.01),
			" | dip state ", dip.state, " pos ", dip.global_position)

	return _tick >= 700
