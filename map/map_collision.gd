extends Node3D

## Bakes a box collider for every visible part of the map model and merges the
## model's thousands of tiny parts into a handful of draw calls.
##
## The imported Arduino model is a composite of hundreds of small meshes
## (header pins, chips, USB shell, capacitors...). Walking on it with a single
## flat slab felt wrong, so this builds one tight-ish box per part, in world
## space, under a single StaticBody3D. Colliders are generated at runtime
## because the mesh is imported, not authored in this project.
##
## The same import costs roughly one draw call per surface: this copy of the
## model has ~1000 MeshInstance3D nodes with ~10k surfaces between them, so the
## GPU is asked to draw the board ten thousand times per frame (and again for
## the shadow map). The parts are merged into one mesh per material, which
## brings the map down to a few dozen draw calls. The originals are then
## hidden, so only the merged copy is rendered.
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
## Combine the model's parts into one mesh per material. Big rendering win;
## turn off to inspect the original imported nodes.
@export var merge_meshes: bool = true
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

	# Collect the parts once; both the colliders and the merged mesh read from
	# this list, and the originals are dropped afterwards.
	var parts: Array[MeshInstance3D] = []
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			parts.append(mesh_instance)

	_build_colliders(parent, parts, to_parent)
	if merge_meshes:
		_merge_parts(parent, parts, to_parent)


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


## Merges every part into one mesh per (material, vertex format) pair, then
## hides the original model. Geometry is baked into the parent's space, matching
## the generated colliders.
func _merge_parts(parent: Node3D, parts: Array[MeshInstance3D], to_parent: Transform3D) -> void:
	var started := Time.get_ticks_msec()
	var groups: Dictionary = {}

	for mesh_instance in parts:
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

	if combined.get_surface_count() == 0:
		return

	var merged := MeshInstance3D.new()
	merged.name = merged_mesh_name
	merged.mesh = combined
	merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(merged)

	# Only the merged copy is drawn from now on.
	visible = false
	for mesh_instance in parts:
		mesh_instance.queue_free()

	print("%s: merged %d parts into %d surfaces in %d ms" % [
		name, parts.size(), combined.get_surface_count(), Time.get_ticks_msec() - started
	])


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
