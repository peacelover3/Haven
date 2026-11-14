extends SceneTree

var _scene: Node3D
var _cam: Camera3D
var _frame := 0


func _initialize() -> void:
	_scene = (load("res://map/haven_map.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(_scene)
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_scene.add_child(_cam)


func _process(_delta: float) -> bool:
	_frame += 1
	_cam.current = true

	if _frame == 12:
		_cam.global_position = Vector3(0.06, 16.0, 11.0)
		_cam.look_at(Vector3(0.06, 1.0, 0.0))
	elif _frame == 20:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_map.png")
		print("saved map shot")
		var charger := _scene.get_node_or_null("ChargerEnemy") as Node3D
		var dip := _scene.get_node_or_null("DipEnemy") as Node3D
		if charger != null:
			_cam.global_position = charger.global_position + Vector3(1.4, 1.0, 1.4)
			_cam.look_at(charger.global_position + Vector3(0, 0.28, 0))
			print("charger shot from ", _cam.global_position)
		_cam.current = true
	elif _frame == 26:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_charger.png")
		print("saved charger shot")
		var dip := _scene.get_node_or_null("DipEnemy") as Node3D
		if dip != null:
			_cam.global_position = dip.global_position + Vector3(1.4, 1.0, 1.4)
			_cam.look_at(dip.global_position + Vector3(0, 0.3, 0))
		_cam.current = true
	elif _frame == 32:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_dip.png")
		print("saved dip shot")
		return true

	return false
