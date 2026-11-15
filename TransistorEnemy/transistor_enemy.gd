class_name TransistorEnemy
extends CharacterBody3D

## AI-controlled MOSFET transistor enemy.
##
## Behaviour:
##   IDLE      -> stands at its post (spawn point, or the guard point node).
##   CHASE     -> player is inside `detection_radius`, closes in until
##                `stop_distance` is reached.
##   ATTACK    -> holds its preferred distance and fires at the player
##                whenever `attack_cooldown` has elapsed.
##   RETURNING -> the player left `lose_target_radius` or the guard area;
##                walks back to its post and drops back to IDLE.
##   DEAD      -> health reached zero; stops acting and despawns.
##
## Guarding: set `guard_radius` above zero and the enemy defends the area
## around `guard_point_path` (or its spawn point). It attacks any player who
## comes within `detection_radius`, but its own body never leaves the guard
## circle: at the rim it holds position and keeps shooting from there. When
## the player leaves `lose_target_radius` it walks back into its circle and
## wanders around inside it until duty calls again.
##
## The player is found through the `player_group` group (or a fixed
## `player_path` when one is set), so no collision layers need to be wired up.
## Damage is dealt by calling `take_damage(amount)` on this node.
##
## Navigation: if a NavigationAgent3D child is present and a navigation mesh
## covers the world, the enemy follows a path around obstacles. Without a
## navigation map it walks straight at its target, so the enemy works in scenes
## that have no navigation set up at all.

signal player_detected(player: Node3D)
signal player_lost
signal projectile_fired(projectile: Node3D, direction: Vector3)
signal state_changed(previous: State, current: State)
signal health_changed(current: float, maximum: float)
signal damaged(amount: float)
signal died

enum State { IDLE, CHASE, ATTACK, RETURNING, WANDER, DEAD }

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

@export_group("Guard")
## Radius of the area this enemy protects, in metres. The enemy attacks any
## player within detection range, but its own body stays inside this circle
## while fighting. 0 = guard no particular area, chase anywhere within the
## detection range.
@export var guard_radius: float = 0.0
## Optional node used as the guard post. Defaults to the spawn position.
@export var guard_point_path: NodePath
## How far the enemy's body may travel from its post while fighting, in
## metres. 0 keeps it inside the guard circle itself, so a guarding enemy
## holds its turf instead of being dragged across the map.
@export var leash_radius: float = 0.0

@export_group("Wander")
## Speed used while strolling around its post between fights.
@export var wander_speed: float = 1.1
## Seconds it stands still between wander legs (randomized around this).
@export var wander_pause: float = 1.6

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
## Follow a NavigationAgent3D path when a navigation map is available.
@export var use_navigation: bool = true
## Path to the NavigationAgent3D used for path following.
@export var navigation_agent_path: NodePath = ^"NavigationAgent3D"

@export_group("Combat")
## Distance at which the enemy starts shooting. Keep this >= `stop_distance`.
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

@export_group("Health")
@export var max_health: float = 100.0
## Seconds the corpse stays in the scene after dying. Negative keeps it.
@export var death_despawn_delay: float = 2.0

var state: State = State.IDLE
var target: Node3D = null
var health: float = 0.0

var _attack_cooldown_left: float = 0.0
var _scan_left: float = 0.0
var _cached_player: Node3D = null
var _muzzle: Node3D = null
var _nav_agent: NavigationAgent3D = null
var _guard_point: Node3D = null
var _home_goal: Vector3 = Vector3.INF
var _wander_pause_left: float = 0.0
var _stuck_left: float = 0.0
var _nav_goal: Vector3 = Vector3.INF
var _spawn_transform: Transform3D
var _gravity: float = 9.8
var _dead: bool = false


func _ready() -> void:
	add_to_group(&"enemies")
	health = max_health
	_spawn_transform = global_transform
	_muzzle = get_node_or_null(muzzle_path)
	_nav_agent = get_node_or_null(navigation_agent_path) as NavigationAgent3D
	_guard_point = get_node_or_null(guard_point_path) as Node3D
	if not guard_point_path.is_empty() and _guard_point == null:
		push_warning("%s: guard point '%s' not found, guarding the spawn point." % [name, guard_point_path])
	_pick_home_goal()
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

	_attack_cooldown_left = maxf(_attack_cooldown_left - delta, 0.0)
	_update_target(delta)

	match state:
		State.IDLE:
			_decelerate(delta)
		State.CHASE, State.ATTACK:
			_process_pursuit(delta)
		State.RETURNING:
			_process_return(delta)
		State.WANDER:
			_process_wander(delta)

	_apply_gravity(delta)
	move_and_slide()


func is_alive() -> bool:
	return not _dead


## World position this enemy defends and returns to.
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


## Distance the body may stray from its post while fighting. Falls back to the
## guard circle when `leash_radius` is not set explicitly.
func _leash_radius() -> float:
	if leash_radius > 0.0:
		return leash_radius
	return guard_radius


## Radius of the area it strolls around while off duty (its guard circle).
func _wander_radius() -> float:
	if guard_radius <= 0.0:
		return 0.0
	return minf(guard_radius, _leash_radius())


## Picks where the enemy walks when it has nothing to fight: a random point
## inside its guard circle, or its spawn point when it guards no area.
func _pick_home_goal() -> void:
	var radius := _wander_radius()
	if radius <= 0.0:
		_home_goal = get_guard_position()
		return
	var angle := randf() * TAU
	var distance := radius * randf_range(0.25, 0.9)
	var offset := Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
	_home_goal = get_guard_position() + offset


## Keeps a movement direction from carrying the body past its leash: once at
## the edge, the outward component is cut so it slides along the rim instead
## of leaving its circle. Unlimited when no guard area is set.
func _clamp_to_guard_area(direction: Vector3) -> Vector3:
	var leash := _leash_radius()
	if leash <= 0.0 or direction.length_squared() < 0.0001:
		return direction
	var from_home := global_position - get_guard_position()
	from_home.y = 0.0
	var distance_home := from_home.length()
	if distance_home < leash - 0.05:
		return direction
	var outward := from_home / maxf(distance_home, 0.0001)
	if direction.dot(outward) <= 0.0:
		return direction
	var tangential := direction - outward * direction.dot(outward)
	if tangential.length_squared() < 0.0001:
		return Vector3.ZERO
	return tangential.normalized()


# --- Health ----------------------------------------------------------------

## Applies damage. Anything can call this; projectiles use it by name.
func take_damage(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	damaged.emit(amount)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_die()


func heal(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


func _die() -> void:
	if _dead:
		return
	_dead = true
	target = null
	velocity = Vector3.ZERO
	_set_state(State.DEAD)
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
		elif state != State.RETURNING and state != State.IDLE and state != State.WANDER:
			_pick_home_goal()
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
	_pick_home_goal()
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
		_pick_home_goal()
		_set_state(State.RETURNING)
		return

	var flat_offset := target.global_position - global_position
	flat_offset.y = 0.0
	var distance := flat_offset.length()

	var direction := _steer_towards(target.global_position, flat_offset.normalized())
	var move_direction := _clamp_to_guard_area(direction)
	if move_direction.length_squared() > 0.0001:
		_face_direction(move_direction, delta)
	else:
		# Held at the rim and nowhere to slide: keep looking at the player.
		_face_direction(flat_offset.normalized(), delta)

	if distance > stop_distance and move_direction.length_squared() > 0.0001:
		_move_flat(move_direction, chase_speed, delta)
		_set_state(State.CHASE)
	else:
		_decelerate(delta)
		if distance <= stop_distance:
			_set_state(State.ATTACK)

	if distance <= maxf(attack_range, stop_distance) and _attack_cooldown_left <= 0.0:
		_fire()


func _process_return(delta: float) -> void:
	var goal_offset := _home_goal - global_position
	goal_offset.y = 0.0

	if goal_offset.length() <= 0.35:
		_decelerate(delta)
		if _wander_radius() > 0.0:
			_wander_pause_left = randf_range(0.6, 1.4) * maxf(wander_pause, 0.01)
			_set_state(State.WANDER)
		else:
			rotation.y = lerp_angle(rotation.y, _spawn_transform.basis.get_euler().y, clampf(turn_speed * delta, 0.0, 1.0))
			if absf(angle_difference(rotation.y, _spawn_transform.basis.get_euler().y)) < 0.05:
				_set_state(State.IDLE)
		return

	var direction := _steer_towards(_home_goal, goal_offset.normalized())
	direction = _clamp_to_guard_area(direction)
	_face_direction(direction, delta)
	_move_flat(direction, return_speed, delta)
	_unstick_watchdog(delta)


## Off duty: stroll between random spots inside its guard circle, pausing in
## between, until the player comes back into detection range.
func _process_wander(delta: float) -> void:
	var goal_offset := _home_goal - global_position
	goal_offset.y = 0.0

	if goal_offset.length() <= 0.25:
		_decelerate(delta)
		_wander_pause_left -= delta
		if _wander_pause_left <= 0.0:
			_pick_home_goal()
		return

	var direction := _steer_towards(_home_goal, goal_offset.normalized())
	direction = _clamp_to_guard_area(direction)
	_face_direction(direction, delta)
	_move_flat(direction, wander_speed, delta)
	_unstick_watchdog(delta)


## If the body got wedged on the way somewhere and is not actually moving,
## pick a new goal instead of grinding against a part forever.
func _unstick_watchdog(delta: float) -> void:
	if _flat_speed(get_real_velocity()) < 0.15:
		_stuck_left += delta
		if _stuck_left > 1.5:
			_stuck_left = 0.0
			_pick_home_goal()
	else:
		_stuck_left = 0.0


func _flat_speed(velocity_3d: Vector3) -> float:
	return Vector2(velocity_3d.x, velocity_3d.z).length()


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


# --- Navigation ------------------------------------------------------------

## Direction to walk towards `point`, routed along a navigation path when the
## scene has a working navigation map. Falls back to `fallback` otherwise.
func _steer_towards(point: Vector3, fallback: Vector3) -> Vector3:
	if _nav_agent == null or not use_navigation:
		return fallback

	var map := _nav_agent.get_navigation_map()
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return fallback

	# Re-path only when the goal moved noticeably; querying the navigation
	# server every physics frame is wasteful on large nav meshes.
	if _nav_goal.distance_squared_to(point) > 0.25:
		_nav_goal = point
		_nav_agent.target_position = point
	if _nav_agent.is_navigation_finished():
		return fallback

	var next_point := _nav_agent.get_next_path_position()
	var direction := next_point - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return fallback
	return direction.normalized()


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
