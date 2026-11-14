extends Node3D

## Builds collision for the map model and swaps in its merged mesh.
##
## The imported Arduino model is a composite of hundreds of small meshes
## (header pins, chips, USB shell, capacitors...). Walking on it with a single
## flat slab felt wrong, so this builds one tight-ish box per part, in world
## space, under a single StaticBody3D. Colliders are generated at runtime
## because the mesh is imported, not authored in this project.
##
## Rendering: this copy of the model has ~1000 MeshInstance3D nodes with ~10k
## surfaces between them, so the GPU is asked to draw the board ten thousand
## times per frame (and again for the shadow map). `merged_mesh` is the same
## geometry with one surface per material: 23 draw calls instead of 10,235.
## It is baked ahead of time by tools/bake_map.gd, because reading mesh data
## back from the renderer takes seconds while the game is running. Re-run that
## script after the model changes.
##
## Attach to the model root. The generated body is a sibling of it, so scaling
## or moving the model keeps the colliders correct.

## Turn off to fall back to whatever colliders the level already has.
@export var enabled: bool = true
## Physics layer the generated colliders live on.
@export_flags_3d_physics var collision_layer: int = 1
## Parts smaller than this (in world metres, largest side) get no collider.
## Keeps thousands of model detail meshes out of the physics server.
@export var min_part_size: float = 0.15
## Parts flatter than this (in world metres, smallest side) get no collider.
## Silkscreen, copper traces and solder mask are surfaces, not obstacles.
@export var min_part_thickness: float = 0.0
## Colliders thinner than this are thickened, so characters and bolts do not
## slip through single-sided surfaces.
@export var min_thickness: float = 0.08
## Baked copy of the model with one surface per material, assigned in the scene.
## Generate it with `godot --headless --path . --script res://tools/bake_map.gd`.
@export var merged_mesh: ArrayMesh
## Name of the node that holds the merged copy of the model.
@export var merged_mesh_name: String = "ModelMerged"

var _fallback_material: StandardMaterial3D = null


func _ready() -> void:
	if not enabled:
		return

	var parent := get_parent() as Node3D
	if parent == null:
		push_warning("%s: needs a Node3D parent for its colliders." % name)
		return

	var to_parent := parent.global_transform.affine_inverse()

	# Collected once: the colliders and the merged copy both read from this list.
	var parts: Array[MeshInstance3D] = []
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			parts.append(mesh_instance)

	_build_colliders(parent, parts, to_parent)

	if merged_mesh != null:
		_use_merged_mesh(parent, parts)
	else:
		push_warning("%s: no baked merged mesh assigned, drawing every part separately. Run tools/bake_map.gd." % name)


func _build_colliders(parent: Node3D, parts: Array[MeshInstance3D], to_parent: Transform3D) -> void:
	var body := StaticBody3D.new()
	body.name = "ModelCollision"
	body.collision_layer = collision_layer
	body.collision_mask = 0

	for mesh_instance in parts:
		var box: AABB = (to_parent * mesh_instance.global_transform) * mesh_instance.get_aabb()
		var size := box.size
		if maxf(size.x, maxf(size.y, size.z)) < min_part_size:
			continue
		if minf(size.x, minf(size.y, size.z)) < min_part_thickness:
			continue

		var shape := BoxShape3D.new()
		shape.size = Vector3(
			maxf(size.x, min_thickness),
			maxf(size.y, min_thickness),
			maxf(size.z, min_thickness)
		)

		var collider := CollisionShape3D.new()
		collider.name = "Part_" + String(mesh_instance.name)
		collider.shape = shape
		collider.position = box.get_center()
		body.add_child(collider)

	# The scene root may still be assembling its children while this runs, so
	# the body is attached once setup settles.
	parent.add_child.call_deferred(body)


## Shows the baked mesh in place of the thousands of imported parts.
func _use_merged_mesh(parent: Node3D, parts: Array[MeshInstance3D]) -> void:
	var merged := MeshInstance3D.new()
	merged.name = merged_mesh_name
	merged.mesh = merged_mesh
	merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child.call_deferred(merged)

	# Only the merged copy is drawn from now on.
	visible = false
	for mesh_instance in parts:
		mesh_instance.queue_free()


## Merges the model into one surface per (material, vertex format) pair, in the
## parent's space. Slow while a game is running (every surface has to be read
## back from the renderer), so it is only called by tools/bake_map.gd.
func build_merged_mesh(to_parent: Transform3D) -> ArrayMesh:
	var groups: Dictionary = {}

	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var xform := to_parent * mesh_instance.global_transform
		var mesh := mesh_instance.mesh
		for surface in mesh.get_surface_count():
			var material := _surface_material(mesh_instance, surface)
			# Surfaces with different vertex layouts cannot share a SurfaceTool.
			var key := "%d:%d" % [material.get_instance_id(), mesh.surface_get_format(surface)]
			var group: Dictionary = groups.get(key, {})
			var tool: SurfaceTool = group.get("tool")
			if tool == null:
				tool = SurfaceTool.new()
				tool.begin(Mesh.PRIMITIVE_TRIANGLES)
				group = {"tool": tool, "material": material}
				groups[key] = group
			tool.append_from(mesh, surface, xform)

	var combined := ArrayMesh.new()
	for key in groups:
		var group: Dictionary = groups[key]
		var tool: SurfaceTool = group["tool"]
		tool.set_material(group["material"])
		tool.commit(combined)
	return combined


func _surface_material(mesh_instance: MeshInstance3D, surface: int) -> Material:
	var material := mesh_instance.get_surface_override_material(surface)
	if material == null:
		material = mesh_instance.mesh.surface_get_material(surface)
	if material == null:
		material = mesh_instance.material_override
	if material == null:
		if _fallback_material == null:
			_fallback_material = StandardMaterial3D.new()
			_fallback_material.albedo_color = Color(0.62, 0.66, 0.7)
			_fallback_material.roughness = 0.6
		material = _fallback_material
	return material
