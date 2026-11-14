extends SceneTree

var _scene: Node3D
var _frame := 0


func _initialize() -> void:
	var packed := load("res://map/haven_map.tscn") as PackedScene
	_scene = packed.instantiate() as Node3D
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1

	if _frame == 2:
		var model := _scene.get_node_or_null("Model") as Node3D
		var merged := _scene.get_node_or_null("ModelMerged") as MeshInstance3D
		print("MODEL visible=", model.visible, " children=", model.get_child_count())
		if merged != null and merged.mesh != null:
			print("MERGED surfaces=", merged.mesh.get_surface_count(), " aabb=", merged.get_aabb().size)
		else:
			print("MERGED MISSING")
		var remaining := 0
		for node in _scene.find_children("*", "MeshInstance3D", true, false):
			if not (node as MeshInstance3D).visible:
				continue
			remaining += 1
		print("VISIBLE mesh instances in scene=", remaining)
		var coll := _scene.get_node_or_null("Model/ModelCollision")
		print("COLLISION body=", coll != null, " shapes=", coll.get_child_count() if coll else -1)

	if _frame % 60 == 0:
		var player := _scene.get_node_or_null("Player") as Node3D
		var charger := _scene.get_node_or_null("ChargerEnemy") as Node3D
		var dip := _scene.get_node_or_null("DipEnemy") as Node3D
		print("frame ", _frame,
			" | player ", player.global_position if player else "none", " hp ", player.health if player else -1,
			" | charger ", charger.global_position if charger else "none", " ", charger.state if charger else "",
			" | dip ", dip.global_position if dip else "none", " ", dip.state if dip else "")

	if _frame >= 480:
		return true
	return false
