extends SceneTree

var _scenario := "charger"
var _tick := 0
var _player: CharacterBody3D
var _enemy: Node3D
var _max_tick := 480


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_scenario = args[0]

	var world := Node3D.new()
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(20, 0.5, 20)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.25, 0)
	world.add_child(floor_body)

	if _scenario == "charger":
		var wall := StaticBody3D.new()
		var wall_shape := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(0.4, 3, 4)
		wall_shape.shape = wall_box
		wall.add_child(wall_shape)
		wall.position = Vector3(1.5, 1.5, 0)
		world.add_child(wall)

	_player = CharacterBody3D.new()
	_player.set_script(load("res://map/map_player.gd"))
	var player_shape := CollisionShape3D.new()
	var player_capsule := CapsuleShape3D.new()
	player_capsule.radius = 0.1
	player_capsule.height = 0.5
	player_shape.shape = player_capsule
	player_shape.position = Vector3(0, 0.25, 0)
	_player.add_child(player_shape)
	_player.position = Vector3(0, 0.05, 0)
	world.add_child(_player)

	if _scenario == "charger":
		_enemy = (load("res://enemies/charger_enemy/charger_enemy.tscn") as PackedScene).instantiate()
		_enemy.position = Vector3(-2.2, 0.05, 0)
	else:
		_enemy = (load("res://enemies/dip_enemy/dip_enemy.tscn") as PackedScene).instantiate()
		_enemy.position = Vector3(0, 0.05, 6.0)
	world.add_child(_enemy)
	print("--- scenario: ", _scenario)


func _projectiles() -> Array:
	var found := []
	for node in root.find_children("*", "Node3D", true, false):
		var script: Script = node.get_script()
		if script != null and String(script.resource_path).ends_with("energy_projectile.gd"):
			found.append(node)
	return found


func _physics_process(_delta: float) -> bool:
	_tick += 1
	if _tick % 20 == 0:
		var bolts := _projectiles()
		var bolt_text := ""
		for bolt in bolts:
			bolt_text += str(bolt.global_position)
		print("tick=", _tick, " player ", _player.global_position, " hp ", _player.health,
			" | enemy ", _enemy.global_position, " state ", _enemy.state,
			" | bolts ", bolts.size(), " ", bolt_text)
	return _tick >= _max_tick
