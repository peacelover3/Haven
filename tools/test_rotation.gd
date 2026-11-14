extends SceneTree

var _frame := 0
var _root: Node3D


func _initialize() -> void:
	_root = Node3D.new()
	root.add_child(_root)

	var light := DirectionalLight3D.new()
	light.transform = Transform3D(Basis.from_euler(Vector3(-0.8, 0.5, 0)), Vector3(0, 4, 0))
	_root.add_child(light)

	var floor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(6, 0.1, 4)
	floor_mesh.mesh = box
	floor_mesh.position = Vector3(0, -0.05, 0)
	_root.add_child(floor_mesh)

	var packed := load("res://enemies/use/Integrated Circuit DIP.glb") as PackedScene
	var rotations := [Vector3.ZERO, Vector3(-90, 0, 0), Vector3(0, 0, 90)]
	for i in rotations.size():
		var holder := Node3D.new()
		holder.position = Vector3((i - 1) * 0.75, 0, 0)
		_root.add_child(holder)
		var model := packed.instantiate() as Node3D
		holder.add_child(model)
		model.rotation_degrees = rotations[i]
		model.scale = Vector3.ONE * 30.0
		var bounds := AABB()
		var first := true
		for node in model.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			var part: AABB = mi.get_aabb()
			bounds = part if first else bounds.merge(part)
			first = false
		holder.position.y = -bounds.position.y
		print(i, " rot ", rotations[i], " size ", bounds.size, " center ", bounds.get_center())
		# Do not let the three copies collide with anything; they are visuals only.

	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.fov = 55.0
	cam.position = Vector3(0.0, 0.55, 1.5)
	cam.look_at(Vector3(0, 0.12, 0))
	cam.current = true


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 12:
		root.get_viewport().get_texture().get_image().save_png("res://tools/shot_rotations.png")
		print("saved rotations")
		return true
	return false
