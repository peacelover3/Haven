extends CharacterBody3D

## 555-timer charger enemy.
##
## Behaviour:
##   IDLE      -> waits at its post.
##   CHASE     -> walks at the player once they are inside `detection_radius`.
##   WINDUP    -> inside `charge_range` it plants itself, faces the player and
##                pulses (the telegraph) for `windup_time`.
##   DASH      -> launches itself at `dash_speed` for `dash_time`. Touching the
##                player deals `contact_damage` and throws them with
##                `knockback_force`; if that throw ends against a wall the
##                player takes `wall_slam_damage` as well.
##   RECOVER   -> stands around for `dash_cooldown` before charging again.
##   RETURNING -> the player escaped; walks back to its post.
##   DEAD      -> health reached zero; stops acting and despawns.
##
## The player is found through the `player_group` group (or a fixed
## `player_path` when one is set), so no collision layers need to be wired up.
## Damage is dealt by calling `take_damage(amount)` on this node.

signal player_detected(player: Node3D)
signal player_lost
signal hit_player(push_direction: Vector3)
signal state_changed(previous: State, current: State)
signal damaged(amount: float)
signal died

enum State { IDLE, CHASE, WINDUP, DASH, RECOVER, RETURNING, DEAD }

@export_group("Detection")
@export var detection_radius: float = 9.0
## Once chasing, the enemy only gives up beyond this distance.
@export var lose_target_radius: float = 14.0
@export var player_group: StringName = &"player"
@export var player_path: NodePath
@export var scan_interval: float = 0.25

@export_group("Movement")
@export var chase_speed: float = 3.2
@export var return_speed: float = 2.4
@export var acceleration: float = 18.0
@export var turn_speed: float = 8.0
@export var gravity_scale: float = 1.0

@export_group("Charge attack")
## Gap at which the enemy commits to a charge.
@export var charge_range: float = 4.0
## Telegraph time before the dash starts. The visual puffs up while winding up.
@export var windup_time: float = 0.45
@export var dash_speed: float = 10.0
@export var dash_time: float = 0.32
## Rest after a charge, during which it will not charge again.
@export var dash_cooldown: float = 1.2
## How close the dash has to pass to count as a hit, in metres.
@export var hit_radius: float = 0.8
@export var contact_damage: float = 8.0
## Speed the player is thrown at when the charge connects.
@export var knockback_force: float = 7.5
## Extra damage when that throw slams the player into a wall.
@export var wall_slam_damage: float = 14.0
@export var visual_path: NodePath = ^"Visual"
## How much the visual grows while winding up (1.0 = no pulse).
@export var windup_pulse: float = 0.18

@export_group("Health")
@export var max_health: float = 80.0
## Seconds the corpse stays in the scene after dying. Negative keeps it.
@export var death_despawn_delay: float = 2.0

var state: State = State.IDLE
var target: Node3D = null
var health: float = 0.0

var _windup_left: float = 0.0
var _dash_left: float = 0.0
var _recover_left: float = 0.0
var _dash_direction: Vector3 = Vector3.FORWARD
var _scan_left: float = 0.0
var _cached_player: Node3D = null
var _visual: Node3D = null
var _visual_scale: Vector3 = Vector3.ONE
var _spawn_transform: Transform3D
var _gravity: float = 9.8
var _dead: bool = false


func _ready() -> void:
	add_to_group(&"enemies")
	health = max_health
	_spawn_transform = global_transform
	_visual = get_node_or_null(visual_path) as Node3D
	if _visual != null:
		_visual_scale = _visual.scale
	if not player_path.is_empty():
		target = get_node_or_null(player_path) as Node3D
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_scan_left = 0.0


func _physics_process(delta: float) -> void:
	if _dead:
		_apply_gravity(delta)
		move_and_slide()
		return

	_recover_left = maxf(_recover_left - delta, 0.0)
	_update_target(delta)

	match state:
		State.IDLE:
			_decelerate(delta)
		State.CHASE:
			_process_chase(delta)
		State.WINDUP:
			_process_windup(delta)
		State.DASH:
			_process_dash(delta)
		State.RECOVER:
			_decelerate(delta)
			if _recover_left <= 0.0:
				_set_state(State.CHASE)
		State.RETURNING:
			_process_return(delta)

	_apply_gravity(delta)
	move_and_slide()

	if state == State.DASH:
		_check_dash_hit()

	_update_pulse(delta)

	if global_position.y < -20.0:
		global_position = _spawn_transform.origin
		velocity = Vector3.ZERO


func is_alive() -> bool:
	return not _dead


# --- Health ----------------------------------------------------------------

func take_damage(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	damaged.emit(amount)
	if health <= 0.0:
		_die()


func heal(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	health = minf(health + amount, max_health)


func _die() -> void:
	if _dead:
		return
	_dead = true
	target = null
	velocity = Vector3.ZERO
	_set_state(State.DEAD)
	if _visual != null:
		_visual.scale = _visual_scale
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	died.emit()
	if death_despawn_delay >= 0.0:
		await get_tree().create_timer(death_despawn_delay).timeout
		if is_instance_valid(self):
			queue_free()


# --- Target tracking -------------------------------------------------------

func _update_target(delta: float) -> void:
	var player := _resolve_player(delta)
	if target != null and not is_instance_valid(target):
		target = null

	if target == null:
		if player != null and _flat_distance_to(player) <= detection_radius:
			_acquire(player)
		elif state != State.RETURNING and state != State.IDLE and state != State.DASH:
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
	if state != State.RETURNING and state != State.DEAD:
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

func _process_chase(delta: float) -> void:
	if target == null:
		_set_state(State.RETURNING)
		return

	var flat_offset := _flat_offset_to(target.global_position)
	var distance := flat_offset.length()
	_face_direction(flat_offset, delta)

	if distance <= charge_range and _recover_left <= 0.0:
		_decelerate(delta)
		_begin_windup()
		return

	_move_flat(flat_offset.normalized(), chase_speed, delta)


func _begin_windup() -> void:
	if target == null:
		return
	_windup_left = maxf(windup_time, 0.0)
	_set_state(State.WINDUP)


func _process_windup(delta: float) -> void:
	if target == null:
		_set_state(State.RETURNING)
		return

	var flat_offset := _flat_offset_to(target.global_position)
	_face_direction(flat_offset, delta)
	_decelerate(delta)

	_windup_left -= delta
	if _windup_left > 0.0:
		return

	# Lock the direction once, so the player can side-step the charge.
	_dash_direction = flat_offset.normalized()
	if _dash_direction.is_zero_approx():
		_dash_direction = -global_basis.z
	_dash_left = maxf(dash_time, 0.0)
	if _visual != null:
		_visual.scale = _visual_scale
	_set_state(State.DASH)


func _process_dash(delta: float) -> void:
	velocity.x = _dash_direction.x * dash_speed
	velocity.z = _dash_direction.z * dash_speed
	_dash_left -= delta

	if _dash_left <= 0.0 or _is_against_wall():
		_end_dash()


func _check_dash_hit() -> void:
	if target == null or _flat_distance_to(target) > hit_radius:
		return

	var push := _dash_direction
	var offset := _flat_offset_to(target.global_position)
	if not offset.is_zero_approx():
		push = offset.normalized()

	# Knock the player around first: if that throw kills them, the respawn clears
	# the impulse instead of carrying it to the spawn point.
	if target.has_method("apply_knockback"):
		target.apply_knockback(push * knockback_force, wall_slam_damage)
	if target.has_method("take_damage"):
		target.take_damage(contact_damage)
	hit_player.emit(push)
	_end_dash()


func _end_dash() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_recover_left = maxf(dash_cooldown, 0.0)
	_set_state(State.RECOVER)


func _process_return(delta: float) -> void:
	var home_offset := _flat_offset_to(_spawn_transform.origin)

	if home_offset.length() <= 0.5:
		_decelerate(delta)
		rotation.y = lerp_angle(rotation.y, _spawn_transform.basis.get_euler().y, clampf(turn_speed * delta, 0.0, 1.0))
		if absf(angle_difference(rotation.y, _spawn_transform.basis.get_euler().y)) < 0.05:
			_set_state(State.IDLE)
		return

	_face_direction(home_offset, delta)
	_move_flat(home_offset.normalized(), return_speed, delta)


# --- Helpers ---------------------------------------------------------------

func _update_pulse(delta: float) -> void:
	if _visual == null:
		return
	if state == State.WINDUP and windup_time > 0.0:
		var progress := 1.0 - clampf(_windup_left / windup_time, 0.0, 1.0)
		_visual.scale = _visual_scale * (1.0 + windup_pulse * progress)
	elif not state == State.DASH:
		_visual.scale = _visual.scale.lerp(_visual_scale, clampf(10.0 * delta, 0.0, 1.0))


func _is_against_wall() -> bool:
	for index in get_slide_collision_count():
		if absf(get_slide_collision(index).get_normal().y) < 0.5:
			return true
	return false


func _flat_offset_to(point: Vector3) -> Vector3:
	var offset := point - global_position
	offset.y = 0.0
	return offset


func _flat_distance_to(node: Node3D) -> float:
	return _flat_offset_to(node.global_position).length()


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
