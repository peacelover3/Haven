extends SceneTree

## Bakes the merged copy of the map model.
##
## Run after changing the map model:
##   godot --headless --path . --script res://tools/bake_map.gd
##
## It writes res://map/motherboard_map_merged.res, the one-surface-per-material
## copy the map scene renders instead of the thousands of separate imported
## parts.

const SCENE_PATH := "res://map/haven_map.tscn"
const OUTPUT_PATH := "res://map/motherboard_map_merged.res"

var _scene: Node3D
var _frame := 0
var _done := false


func _initialize() -> void:
	_scene = (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	# The scene's own collider/merge script is not needed for the bake.
	var model := _scene.get_node_or_null("Model")
	if model != null:
		model.set("enabled", false)
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3 or _done:
		return _frame >= 4
	_done = true

	var model := _scene.get_node_or_null("Model") as Node3D
	if model == null:
		push_error("bake_map: no Model node in %s" % SCENE_PATH)
		return true

	var parent_3d := model.get_parent() as Node3D
	if parent_3d == null:
		push_error("bake_map: the Model node needs a Node3D parent")
		return true

	var started := Time.get_ticks_msec()
	var to_parent := parent_3d.global_transform.affine_inverse()
	var merged := model.call("build_merged_mesh", to_parent) as ArrayMesh
	if merged == null or merged.get_surface_count() == 0:
		push_error("bake_map: merging produced no mesh")
		return true

	var error := ResourceSaver.save(merged, OUTPUT_PATH)
	if error != OK:
		push_error("bake_map: could not save %s (error %d)" % [OUTPUT_PATH, error])
		return true

	print("bake_map: %d surfaces, %d ms -> %s" % [
		merged.get_surface_count(), Time.get_ticks_msec() - started, OUTPUT_PATH
	])
	return true
