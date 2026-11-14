extends CharacterBody3D

## DIP IC heavy gunner enemy.
##
## Behaviour:
##   IDLE      -> waits at its post.
##   ENGAGE    -> walks a navigation path towards the player, at a slow shuffle
##                and from any direction, stopping `stop_distance` short. The
##                goal is clamped inside `move_range` of its post, so it can
##                never wander off. Paths come from the map's baked navigation
##                mesh (see map/map_collision.gd), so parts in the way are
##                walked around instead of blocking it. Without a navigation
##                map it falls back to walking straight at the player.
##   CHARGE    -> holds still, faces the player and builds up a shot for
##                `charge_time` (the visual pulses).
##   RETURNING -> the player escaped; walks back to its post.
##   DEAD      -> health reached zero; stops acting and despawns.
##
## It is a gun emplacement rather than a brawler: it follows slowly, stays
## within `move_range` of where it started, and shoots only what it can actually
## see (see `_has_clear_path`) inside `attack_range`, then only once every
## `attack_cooldown`. Shots are slow but hit hard: `projectile_damage` is far
## above the transistor enemy's bolt, and the bolt itself is the big heavy one
## from `heavy_bolt.tscn`. Damage is dealt by the projectile calling
## `take_damage(amount)` on the first body it hits.

signal player_detected(player: Node3D)
signal player_lost
signal projectile_fired(projectile: Node3D, direction: Vector3)
signal state_changed(previous: State, current: State)
signal damaged(amount: float)
signal died

enum State { IDLE, ENGAGE, CHARGE, RETURNING, DEAD }

@export_group("Detection")
## It notices the player within this distance and starts following.
@export var detection_radius: float = 3.5
## Once engaged, the enemy only gives up beyond this distance.
@export var lose_target_radius: float = 5.0
@export var player_group: StringName = &"player"
@export var player_path: NodePath
@export var scan_interval: float = 0.25

@export_group("Movement")
@export var navigation_agent_path: NodePath = ^"NavigationAgent3D"
@export var return_speed: float = 2.4
@export var acceleration: float = 16.0
@export var turn_speed: float = 7.0
@export var gravity_scale: float = 1.0
## How close it walks to the player before it stops closing in.
@export var stop_distance: float = 2.0
## How far it may roam from where it started. It always walks back into this
## range, so it can follow in every direction but never wanders off.
@export var move_range: float = 2.5
## How fast it shuffles towards the player, in metres per second. Keep this
## below the player's speed so it trails them instead of keeping up.
@export var shuffle_speed: float = 1.8

@export_group("Combat")
@export var attack_range: float = 7.0
@export var attack_cooldown: float = 2.6
## Telegraph time before the shot leaves the muzzle.
@export var charge_time: float = 0.7
@export var projectile_scene: PackedScene
@export var projectile_speed: float = 15.0
@export var projectile_damage: float = 34.0
## Height above the player origin that the enemy aims for.
@export var aim_height: float = 0.25
## Random deviation applied to each shot, in degrees. 0 = perfect accuracy.
@export var aim_inaccuracy: float = 1.0
@export var muzzle_path: NodePath = ^"Muzzle"
@export var visual_path: NodePath = ^"Visual"
## How much the visual grows while charging a shot (1.0 = no pulse).
@export var charge_pulse: float = 0.12

@export_group("Health")
@export var max_health: float = 120.0
## Seconds the corpse stays in the scene after dying. Negative keeps it.
@export var death_despawn_delay: float = 2.0

var state: State = State.IDLE
var target: Node3D = null
var health: float = 0.0

var _charge_left: float = 0.0
var _cooldown_left: float = 0.0
var _nav_agent: NavigationAgent3D = null
var _nav_goal: Vector3 = Vector3.INF
var _scan_left: float = 0.0
var _cached_player: Node3D = null
var _muzzle: Node3D = null
var _visual: Node3D = null
var _visual_scale: Vector3 = Vector3.ONE
var _spawn_transform: Transform3D
var _gravity: float = 9.8
var _dead: bool = false


func _ready() -> void:
	add_to_group(&"enemies")
	health = max_health
	_spawn_transform = global_transform
	_muzzle = get_node_or_null(muzzle_path)
	_nav_agent = get_node_or_null(navigation_agent_path) as NavigationAgent3D
	if _nav_agent != null:
		_nav_agent.max_speed = shuffle_speed
	_visual = get_node_or_null(visual_path) as Node3D
	if _visual != null:
		_visual_scale = _visual.scale
	if _muzzle == null:
		push_warning("%s: muzzle node '%s' not found, shots will not spawn." % [name, muzzle_path])
	if projectile_scene == null:
		push_warning("%s: no projectile scene assigned, enemy cannot attack." % name)
	if not player_path.is_empty():
		target = get_node_or_null(player_path) as Node3D
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_scan_left = 0.0


func _physics_process(delta: float) -> void:
	if _dead:
		_apply_gravity(delta)
		move_and_slide()
		return

	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	_update_target(delta)

	match state:
		State.IDLE:
			_decelerate(delta)
		State.ENGAGE:
			_process_engage(delta)
		State.CHARGE:
			_process_charge(delta)
		State.RETURNING:
			_process_return(delta)

	_apply_gravity(delta)
	move_and_slide()

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
	_set_state(State.ENGAGE)
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

func _process_engage(delta: float) -> void:
	if target == null:
		_set_state(State.RETURNING)
		return

	var flat_offset := _flat_offset_to(target.global_position)
	var distance := flat_offset.length()

	# Follow from any direction, stopping `stop_distance` short, but never past
	# `move_range` of the post: the goal is clamped into that circle.
	if distance > stop_distance:
		var goal := target.global_position - flat_offset / distance * stop_distance
		goal = _clamp_to_post(goal)
		if not _move_towards(goal, shuffle_speed, delta):
			_face_direction(flat_offset, delta)
	else:
		_decelerate(delta)
		_face_direction(flat_offset, delta)

	# Only shoot what it can actually see, from inside its firing range.
	if distance <= attack_range and _cooldown_left <= 0.0 and _has_clear_path(target.global_position):
		_charge_left = maxf(charge_time, 0.0)
		_set_state(State.CHARGE)


func _process_charge(delta: float) -> void:
	if target == null:
		_set_state(State.RETURNING)
		return

	var flat_offset := _flat_offset_to(target.global_position)
	_face_direction(flat_offset, delta)
	_decelerate(delta)

	_charge_left -= delta
	if _charge_left > 0.0:
		return

	_fire()
	_cooldown_left = maxf(attack_cooldown, 0.0)
	_set_state(State.ENGAGE)


func _process_return(delta: float) -> void:
	var home_offset := _flat_offset_to(_spawn_transform.origin)

	if home_offset.length() <= 0.5:
		_decelerate(delta)
		rotation.y = lerp_angle(rotation.y, _spawn_transform.basis.get_euler().y, clampf(turn_speed * delta, 0.0, 1.0))
		if absf(angle_difference(rotation.y, _spawn_transform.basis.get_euler().y)) < 0.05:
			_set_state(State.IDLE)
		return

	if not _move_towards(_spawn_transform.origin, return_speed, delta):
		_face_direction(home_offset, delta)


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

	projectile_fired.emit(projectile, direction)


# --- Helpers ---------------------------------------------------------------

func _update_pulse(delta: float) -> void:
	if _visual == null:
		return
	if state == State.CHARGE and charge_time > 0.0:
		var progress := 1.0 - clampf(_charge_left / charge_time, 0.0, 1.0)
		_visual.scale = _visual_scale * (1.0 + charge_pulse * progress)
	else:
		_visual.scale = _visual.scale.lerp(_visual_scale, clampf(10.0 * delta, 0.0, 1.0))


## True when there is still board underfoot half a metre ahead.
func _has_floor_ahead(direction: Vector3) -> bool:
	if direction.length_squared() < 0.0001:
		return true
	var from := global_position + direction.normalized() * 0.45 + Vector3.UP * 0.4
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## Next flat step towards `goal`, following the navigation mesh when there is
## one. The goal only re-paths when it actually moves, so standing still costs
## nothing.
func _direction_to_goal(goal: Vector3) -> Vector3:
	if _nav_agent != null and _nav_agent.get_navigation_map().is_valid():
		if _nav_goal.distance_squared_to(goal) > 0.25:
			_nav_goal = goal
			_nav_agent.target_position = goal
		var step := _flat_offset_to(_nav_agent.get_next_path_position())
		if step.length_squared() > 0.0004:
			return step.normalized()

	var remaining := _flat_offset_to(goal)
	if remaining.length_squared() < 0.0025:
		return Vector3.ZERO
	return remaining.normalized()


## Walks towards `goal`. Returns false when it cannot move (arrived or blocked).
func _move_towards(goal: Vector3, speed: float, delta: float) -> bool:
	var direction := _direction_to_goal(goal)
	if direction.length_squared() < 0.0001:
		_decelerate(delta)
		return false
	# The board has hard edges; walking off one would drop it into the void.
	if not _has_floor_ahead(direction):
		_decelerate(delta)
		return false
	_move_flat(direction, speed, delta)
	_face_direction(direction, delta)
	return true


## Keeps a point inside `move_range` of where the enemy started.
func _clamp_to_post(point: Vector3) -> Vector3:
	var home := _spawn_transform.origin
	var from_home := Vector3(point.x - home.x, 0.0, point.z - home.z)
	if from_home.length() > move_range:
		from_home = from_home.normalized() * move_range
	return Vector3(home.x + from_home.x, point.y, home.z + from_home.z)


## True when nothing blocks a shot at `point`. Checked at a few heights so low
## parts still stop a bolt that would clip them.
func _has_clear_path(point: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [get_rid()]
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())

	var heights: Array[float] = [0.12, 0.26, 0.4]
	for height in heights:
		var from := global_position + Vector3.UP * height
		var query := PhysicsRayQueryParameters3D.create(from, point + Vector3.UP * height)
		query.collision_mask = 1
		query.exclude = exclude
		if not space.intersect_ray(query).is_empty():
			return false
	return true


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


func _apply_spread(direction: Vector3, max_angle: float) -> Vector3:
	var yaw_axis := direction.cross(Vector3.UP)
	if yaw_axis.length_squared() < 0.001:
		yaw_axis = direction.cross(Vector3.RIGHT)
	yaw_axis = yaw_axis.normalized()
	var pitch_axis := direction.cross(yaw_axis).normalized()

	var spread := direction.rotated(yaw_axis, randf_range(-max_angle, max_angle))
	spread = spread.rotated(pitch_axis, randf_range(-max_angle, max_angle))
	return spread.normalized()
