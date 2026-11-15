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

@export_group("Guard")
## Radius of the area this enemy protects, in metres. It only engages players
## inside it and walks back to its post when they leave. 0 = guard nothing and
## chase anywhere within the detection range.
@export var guard_radius: float = 0.0
## Optional node used as the guard post. Defaults to the spawn position.
@export var guard_point_path: NodePath
## Extra distance beyond `guard_radius` the player may stray before the enemy
## gives up. Prevents flicker at the edge of the area.
@export var guard_release_margin: float = 1.5

@export_group("Movement")
@export var chase_speed: float = 2
@export var return_speed: float = 2.4
@export var acceleration: float = 5.0
@export var turn_speed: float = 8.0
@export var gravity_scale: float = 1.0

@export_group("Charge attack")
## Gap at which the enemy commits to a charge.
@export var charge_range: float = 3.2
## Telegraph time before the dash starts. The visual puffs up while winding up.
@export var windup_time: float = 0.45
@export var dash_speed: float = 8.5
## Long enough that a charge started at `charge_range` can still reach.
@export var dash_time: float = 0.42
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
## How far sideways the enemy walks when a component blocks its path.
@export var avoid_probe_length: float = 1.5
## How long that sideways detour lasts before it heads for the player again.
@export var avoid_time: float = 0.7
## Seconds of getting nowhere before the enemy assumes it is wedged.
@export var stuck_time: float = 0.45

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
var _avoid_left: float = 0.0
var _avoid_dir: Vector3 = Vector3.ZERO
var _stuck_time: float = 0.0
var _scan_left: float = 0.0
var _cached_player: Node3D = null
var _guard_point: Node3D = null
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
	_guard_point = get_node_or_null(guard_point_path) as Node3D
	if not guard_point_path.is_empty() and _guard_point == null:
		push_warning("%s: guard point '%s' not found, guarding the spawn point." % [name, guard_point_path])
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
		# A body already touching a part ends its dash on the first frame unless
		# we look at whether the charge actually made progress. Compare against
		# the velocity the physics server achieved, not the commanded one: the
		# commanded dash velocity never drops, even when fully wedged.
		if state == State.DASH and dash_time - _dash_left > 0.06 and _flat_speed(get_real_velocity()) < dash_speed * 0.35:
			_end_dash()

	_update_pulse(delta)

	if global_position.y < -20.0:
		global_position = _spawn_transform.origin
		velocity = Vector3.ZERO


func is_alive() -> bool:
	return not _dead


## World position this enemy guards and returns to.
func get_guard_position() -> Vector3:
	if _guard_point != null and is_instance_valid(_guard_point):
		return _guard_point.global_position
	return _spawn_transform.origin


## True when `point` is inside the guarded area (always true when the enemy
## guards no particular area).
func is_inside_guard_area(point: Vector3) -> bool:
	if guard_radius <= 0.0:
		return true
	var offset := point - get_guard_position()
	offset.y = 0.0
	return offset.length() <= guard_radius


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
		if player != null and _flat_distance_to(player) <= detection_radius and is_inside_guard_area(player.global_position):
			_acquire(player)
		elif state != State.RETURNING and state != State.IDLE and state != State.DASH:
			_set_state(State.RETURNING)
	else:
		if player == null:
			_release(false)
		elif target == player and _flat_distance_to(player) > lose_target_radius:
			_release(true)
		elif target == player and guard_radius > 0.0 and not _inside_guard_area_with_margin(player.global_position):
			# The player escaped the protected area; go back on duty.
			_release(true)


func _inside_guard_area_with_margin(point: Vector3) -> bool:
	var offset := point - get_guard_position()
	offset.y = 0.0
	return offset.length() <= guard_radius + maxf(guard_release_margin, 0.0)


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

	# Only commit to a charge it can actually land; otherwise walk closer or
	# around whatever is in the way.
	if distance <= charge_range and _recover_left <= 0.0 and _has_clear_path(target.global_position):
		_decelerate(delta)
		_begin_windup()
		return

	var desired := flat_offset.normalized()

	# The board is covered in tall components, so a straight line at the player
	# wedges the enemy into them. Walk sideways around the blockage first.
	if _avoid_left > 0.0:
		_avoid_left -= delta
		_move_flat(_avoid_dir, chase_speed, delta)
		return

	# A wedged body reports no collision once it has stopped pushing, so the
	# body's own speed is what tells us it is making no progress.
	if _is_against_wall() or _flat_speed(velocity) < 0.5:
		_stuck_time += delta
	else:
		_stuck_time = 0.0
	if _stuck_time >= stuck_time:
		_stuck_time = 0.0
		_start_avoid(desired)
		_move_flat(_avoid_dir, chase_speed, delta)
		return

	_move_flat(desired, chase_speed, delta)


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

	if _dash_left <= 0.0:
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
	var home_offset := _flat_offset_to(get_guard_position())

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


## True when nothing blocks the enemy's body on the way to `point`.
## Raycasting at several heights is used instead of a shape cast: when the
## enemy is already pressed against a part, a shape cast starts inside it and
## reports the path as blocked even where the dash would connect.
func _has_clear_path(point: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [get_rid()]
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())

	var heights: Array[float] = [0.12, 0.26, 0.42]
	for height in heights:
		var from := global_position + Vector3.UP * height
		var query := PhysicsRayQueryParameters3D.create(from, point + Vector3.UP * height)
		query.collision_mask = 1
		query.exclude = exclude
		if not space.intersect_ray(query).is_empty():
			return false
	return true


func _start_avoid(desired: Vector3) -> void:
	var left := desired.rotated(Vector3.UP, PI * 0.5)
	var right := desired.rotated(Vector3.UP, -PI * 0.5)
	_avoid_dir = left if _clearance(left) >= _clearance(right) else right
	_avoid_left = avoid_time


## Free distance in a direction, capped at `avoid_probe_length`.
func _clearance(direction: Vector3) -> float:
	var from := global_position + Vector3.UP * 0.25
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * avoid_probe_length)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return avoid_probe_length
	return from.distance_to(hit.position)


func _is_against_wall() -> bool:
	for index in get_slide_collision_count():
		if absf(get_slide_collision(index).get_normal().y) < 0.5:
			return true
	return false


func _flat_speed(velocity_3d: Vector3) -> float:
	return Vector2(velocity_3d.x, velocity_3d.z).length()


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
