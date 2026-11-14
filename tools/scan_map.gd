extends SceneTree

var _frame := 0
var _done := false
var _scene: Node3D


func _initialize() -> void:
	_scene = (load("res://map/haven_map.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 30 or _done:
		return _frame >= 31
	_done = true

	var scene := _scene

	var player := scene.get_node_or_null("Player") as Node3D
	var chest := Vector3(2.0, 0.6, 4.8) if player == null else player.global_position + Vector3.UP * 0.3

	print("root children: ", scene.get_children())
	for node in scene.find_children("*", "StaticBody3D", true, false):
		print("static body: ", node.get_path(), " shapes=", node.get_child_count())
	for node in scene.find_children("*", "CollisionShape3D", true, false):
		print("  shape: ", node.get_path(), " disabled=", node.disabled)
	var space := scene.get_world_3d().direct_space_state
	var rows: Array[String] = []
	var z := 6.5
	while z >= -6.5:
		var line := ""
		var x := -10.0
		while x <= 10.0:
			var down := PhysicsRayQueryParameters3D.create(Vector3(x, 9.0, z), Vector3(x, -5.0, z))
			down.collision_mask = 1
			var floor_hit := space.intersect_ray(down)
			if floor_hit.is_empty():
				line += " "
				x += 0.5
				continue
			var stand: Vector3 = floor_hit.position + Vector3.UP * 0.3
			var sphere := SphereShape3D.new()
			sphere.radius = 0.28
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = sphere
			query.transform = Transform3D(Basis(), stand)
			query.collision_mask = 1
			var blocked := space.intersect_shape(query, 1).size() > 0

			var los := PhysicsRayQueryParameters3D.create(stand + Vector3.UP * 0.1, chest)
			los.collision_mask = 1
			if player != null:
				los.exclude = [player.get_rid()]
			var sees := space.intersect_ray(los).is_empty()

			if stand.distance_to(chest) < 0.6:
				line += "P"
			elif blocked:
				line += "#"
			elif sees:
				line += "+"
			else:
				line += "."
			x += 0.5
		rows.append("z=%5.1f %s" % [z, line])
		z -= 0.5

	for row in rows:
		print(row)

	var charge_spawn := scene.get_node_or_null("ChargerEnemy") as Node3D
	var dip_spawn := scene.get_node_or_null("DipEnemy") as Node3D
	print("player ", chest, " charger ", charge_spawn.global_position if charge_spawn else "?", " dip ", dip_spawn.global_position if dip_spawn else "?")
	return true
