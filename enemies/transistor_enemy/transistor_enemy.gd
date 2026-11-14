extends CharacterBody3D

## AI-controlled MOSFET transistor enemy.
##
## Behaviour:
##   IDLE      -> patrols nothing, just stands at its spawn point.
##   CHASE     -> player is inside `detection_radius`, closes in until
##                `stop_distance` is reached.
##   ATTACK    -> holds its preferred distance and fires at the player
##                whenever `attack_cooldown` has elapsed.
##   RETURNING -> the player left `lose_target_radius`; walks back to spawn
##                and drops back to IDLE.
##
## The player is found through the `player_group` group (or a fixed
## `player_path` when one is set), so no collision layers need to be wired up.

signal player_detected(player: Node3D)
signal player_lost
signal projectile_fired(projectile: Node3D, direction: Vector3)
signal state_changed(previous: State, current: State)

enum State { IDLE, CHASE, ATTACK, RETURNING }

@export_group("Detection")
## Player is noticed within this distance, in metres.
@export var detection_radius: float = 18.0
## Once chasing, the enemy only gives up beyond this distance. Keep it larger
## than `detection_radius` so the enemy does not flicker at the edge.
@export var lose_target_radius: float = 26.0
## Group the player node is expected to be in.
@export var player_group: StringName = &"player"
## Optional fixed player path; overrides `player_group` when set.
@export var player_path: NodePath
## How often (seconds) the group lookup is refreshed.
@export var scan_interval: float = 0.2

@export_group("Movement")
## Slightly faster than a typical player so the enemy can keep up when the
## player keeps moving; it still stops at `stop_distance`.
@export var chase_speed: float = 7.0
@export var return_speed: float = 4.5
@export var acceleration: float = 14.0
## Preferred gap to the player once the enemy is in range.
@export var stop_distance: float = 6.0
## How quickly the body turns towards its target, in radians per second.
@export var turn_speed: float = 6.0
@export var gravity_scale: float = 1.0

@export_group("Combat")
## Distance at which the enemy starts shooting. Shots happen from
## `stop_distance`, so keep this >= `stop_distance`.
@export var attack_range: float = 12.0
@export var attack_cooldown: float = 1.5
@export var projectile_scene: PackedScene
@export var projectile_speed: float = 26.0
@export var projectile_damage: float = 15.0
## Height above the player origin that the enemy aims for.
@export var aim_height: float = 0.9
## Random deviation applied to each shot, in degrees. 0 = perfect accuracy.
@export var aim_inaccuracy: float = 1.5
@export var muzzle_path: NodePath = ^"Muzzle"

var state: State = State.IDLE
var target: Node3D = null

var _attack_cooldown_left: float = 0.0
var _scan_left: float = 0.0
var _cached_player: Node3D = null
var _muzzle: Node3D = null
var _spawn_transform: Transform3D
var _gravity: float = 9.8


func _ready() -> void:
	add_to_group(&"enemies")
	_spawn_transform = global_transform
	_muzzle = get_node_or_null(muzzle_path)
	if _muzzle == null:
		push_warning("%s: muzzle node '%s' not found, shots will not spawn." % [name, muzzle_path])
	if projectile_scene == null:
		push_warning("%s: no projectile scene assigned, enemy cannot attack." % name)
	if not player_path.is_empty():
		target = get_node_or_null(player_path) as Node3D
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_scan_left = 0.0


func _physics_process(delta: float) -> void:
	_attack_cooldown_left = maxf(_attack_cooldown_left - delta, 0.0)
	_update_target(delta)

	match state:
		State.IDLE:
			_decelerate(delta)
		State.CHASE, State.ATTACK:
			_process_pursuit(delta)
		State.RETURNING:
			_process_return(delta)

	_apply_gravity(delta)
	move_and_slide()


# --- Target tracking -------------------------------------------------------

func _update_target(delta: float) -> void:
	var player := _resolve_player(delta)
	if target != null and not is_instance_valid(target):
		target = null

	if target == null:
		if player != null and _flat_distance_to(player) <= detection_radius:
			_acquire(player)
		elif state != State.RETURNING and state != State.IDLE:
			_set_state(State.RETURNING)
	else:
		if player == null:
			_release(false)
		elif target == player and _flat_distance_to(player) > lose_target_radius:
			_release(true)


func _resolve_player(delta: float) -> Node3D:
	if not player_path.is_empty():
		var fixed := get_node_or_null(player_path)
		return fixed as Node3D

	if is_instance_valid(_cached_player) and _cached_player.is_inside_tree():
		return _cached_player

	_scan_left -= delta
	if _scan_left > 0.0:
		return null
	_scan_left = maxf(scan_interval, 0.0)

	var nearest: Node3D = null
	var nearest_distance := INF
	for node in get_tree().get_nodes_in_group(player_group):
		if node is Node3D:
			var distance := _flat_distance_to(node)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = node
	_cached_player = nearest
	return nearest


func _acquire(player: Node3D) -> void:
	if target == player:
		return
	target = player
	_set_state(State.CHASE)
	player_detected.emit(player)


func _release(announce: bool) -> void:
	target = null
	_cached_player = null
	if announce:
		player_lost.emit()
	if state != State.RETURNING:
		_set_state(State.RETURNING)


func _set_state(next_state: State) -> void:
	if next_state == state:
		return
	var previous := state
	state = next_state
	state_changed.emit(previous, next_state)


## Lets other systems (level triggers, damage) force this enemy onto a target.
func set_target(player: Node3D) -> void:
	if player == null:
		_release(true)
	else:
		_acquire(player)


# --- States ----------------------------------------------------------------

func _process_pursuit(delta: float) -> void:
	if target == null:
		_set_state(State.RETURNING)
		return

	var flat_offset := target.global_position - global_position
	flat_offset.y = 0.0
	var distance := flat_offset.length()

	_face_direction(flat_offset, delta)

	if distance > stop_distance:
		_move_flat(flat_offset.normalized(), chase_speed, delta)
		_set_state(State.CHASE)
	else:
		_decelerate(delta)
		_set_state(State.ATTACK)

	if distance <= maxf(attack_range, stop_distance) and _attack_cooldown_left <= 0.0:
		_fire()


func _process_return(delta: float) -> void:
	var home_offset := _spawn_transform.origin - global_position
	home_offset.y = 0.0

	if home_offset.length() <= 0.5:
		_decelerate(delta)
		rotation.y = lerp_angle(rotation.y, _spawn_transform.basis.get_euler().y, clampf(turn_speed * delta, 0.0, 1.0))
		if absf(angle_difference(rotation.y, _spawn_transform.basis.get_euler().y)) < 0.05:
			_set_state(State.IDLE)
		return

	_face_direction(home_offset, delta)
	_move_flat(home_offset.normalized(), return_speed, delta)


# --- Actions ---------------------------------------------------------------

func _fire() -> void:
	if projectile_scene == null or _muzzle == null or target == null:
		return

	var projectile := projectile_scene.instantiate() as Node3D
	if projectile == null:
		push_warning("%s: projectile scene root is not a Node3D." % name)
		return

	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_parent()
	parent.add_child(projectile)
	projectile.global_position = _muzzle.global_position

	var aim_point := target.global_position + Vector3.UP * aim_height
	var direction := (aim_point - _muzzle.global_position).normalized()
	if direction.is_zero_approx():
		direction = -global_basis.z
	if aim_inaccuracy > 0.0:
		direction = _apply_spread(direction, deg_to_rad(aim_inaccuracy))

	if projectile.has_method("launch"):
		projectile.launch(direction, self, projectile_speed, projectile_damage)
	else:
		projectile.look_at(projectile.global_position + direction, Vector3.UP)

	_attack_cooldown_left = maxf(attack_cooldown, 0.0)
	projectile_fired.emit(projectile, direction)


# --- Helpers ---------------------------------------------------------------

func _flat_distance_to(node: Node3D) -> float:
	var offset := node.global_position - global_position
	offset.y = 0.0
	return offset.length()


func _move_flat(direction: Vector3, speed: float, delta: float) -> void:
	var desired := direction * speed
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)


func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		return
	velocity.y -= _gravity * gravity_scale * delta


func _apply_spread(direction: Vector3, max_angle: float) -> Vector3:
	var yaw_axis := direction.cross(Vector3.UP)
	if yaw_axis.length_squared() < 0.001:
		yaw_axis = direction.cross(Vector3.RIGHT)
	yaw_axis = yaw_axis.normalized()
	var pitch_axis := direction.cross(yaw_axis).normalized()

	var spread := direction.rotated(yaw_axis, randf_range(-max_angle, max_angle))
	spread = spread.rotated(pitch_axis, randf_range(-max_angle, max_angle))
	return spread.normalized()
