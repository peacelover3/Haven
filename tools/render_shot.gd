extends SceneTree

var _scene: Node3D
var _cam: Camera3D
var _frame := 0


func _initialize() -> void:
	_scene = (load("res://map/haven_map.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(_scene)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_scene.add_child(_cam)


func _process(_delta: float) -> bool:
	_frame += 1
	_cam.current = true

	var player := _scene.get_node("Player") as Node3D
	var charger := _scene.get_node("ChargerEnemy") as Node3D
	var dip := _scene.get_node("DipEnemy") as Node3D

	if _frame == 10:
		_cam.global_position = Vector3(1.5, 11.0, 11.0)
		_cam.look_at(Vector3(1.5, 0.3, 2.0))
	elif _frame == 18:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_map.png")
		print("saved map")
		_cam.global_position = dip.global_position + Vector3(0.55, 0.32, 0.55)
		_cam.look_at(dip.global_position + Vector3(0, 0.12, 0))
	elif _frame == 26:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_dip.png")
		print("saved dip")
		_cam.global_position = charger.global_position + Vector3(-0.7, 0.45, 0.7)
		_cam.look_at(charger.global_position + Vector3(0, 0.2, 0))
	elif _frame == 34:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_charger.png")
		print("saved charger")
		_cam.global_position = player.global_position + Vector3(1.2, 0.8, 1.6)
		_cam.look_at(dip.global_position + Vector3(0, 0.2, 0))
	elif _frame == 42:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_game.png")
		print("saved game view")
		return true

	return false
