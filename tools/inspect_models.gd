extends SceneTree

var _frame := 0
var _started := false


func _model_aabb(path: String) -> void:
	var packed := load(path) as PackedScene
	if packed == null:
		print(path, ": FAILED TO LOAD")
		return
	var inst := packed.instantiate() as Node3D
	root.add_child(inst)
	var bounds := AABB()
	var first := true
	var mesh_count := 0
	var surfaces := 0
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		mesh_count += 1
		surfaces += mi.mesh.get_surface_count()
		var box: AABB = mi.global_transform * mi.get_aabb()
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	print(path, " | meshes ", mesh_count, " | surfaces ", surfaces, " | size ", bounds.size, " | center ", bounds.get_center())
	inst.queue_free()


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false
	if _started:
		return true
	_started = true

	_model_aabb("res://enemies/use/555.glb")
	_model_aabb("res://enemies/use/Integrated Circuit DIP.glb")
	_model_aabb("res://models/transistors.glb")

	var map := load("res://haven map.glb") as PackedScene
	if map != null:
		var m := map.instantiate() as Node3D
		m.transform = Transform3D(Basis(Vector3(350, 0, 0), Vector3(0, 0, 350), Vector3(0, -350, 0)), Vector3(-36.05, -0.175, -24.5))
		root.add_child(m)
		var mesh_instances := 0
		var surfaces := 0
		var materials := {}
		var collidable := 0
		var bounds := AABB()
		var first := true
		for node in m.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			mesh_instances += 1
			surfaces += mi.mesh.get_surface_count()
			for s in mi.mesh.get_surface_count():
				materials[mi.mesh.surface_get_material(s)] = true
			var box: AABB = mi.global_transform * mi.get_aabb()
			if first:
				bounds = box
				first = false
			else:
				bounds = bounds.merge(box)
			if maxf(box.size.x, maxf(box.size.y, box.size.z)) >= 0.25:
				collidable += 1
		print("MAP | mesh instances ", mesh_instances, " | surfaces ", surfaces, " | unique materials ", materials.size(), " | parts >= 0.25m ", collidable)
		print("MAP | world size ", bounds.size, " | center ", bounds.get_center())
		m.queue_free()

	return true
