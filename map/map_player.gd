extends CharacterBody3D

## Minimal stand-in player for the Arduino map.
## Move with the arrow keys. Implements `take_damage()` so enemy attacks have
## something to hit, and `apply_knockback()` so a charging enemy can throw the
## player around; being slammed into a wall while flying adds extra damage.
## It prints health and respawns when it reaches zero or when it somehow leaves
## the board.

signal hurt(amount: float)
signal died

@export var move_speed: float = 6.0
@export var max_health: float = 100.0
@export var gravity: float = 9.8

@export_group("Knockback")
## How fast a knockback impulse bleeds off, in metres per second squared.
@export var knockback_friction: float = 16.0
## How much of the normal movement input still gets through at full knockback
## speed. 0 = no control at all while being thrown.
@export var knockback_control: float = 0.15
## Knocked-back players sliding slower than this do not take wall-slam damage.
@export var wall_slam_min_speed: float = 2.0

var health: float

var _spawn_transform: Transform3D
var _knockback: Vector3 = Vector3.ZERO
var _knockback_wall_damage: float = 0.0
var _wall_slam_used: bool = false


func _ready() -> void:
	add_to_group(&"player")
	health = max_health
	_spawn_transform = global_transform


func _physics_process(delta: float) -> void:
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")

	var knockback_speed := _flat_speed(_knockback)
	var control := 1.0
	if knockback_speed > 0.05:
		# The stronger the throw, the less steering the player gets.
		control = clampf(1.0 - knockback_speed / 12.0, knockback_control, 1.0)

	velocity.x = input.x * move_speed * control + _knockback.x
	velocity.z = input.y * move_speed * control + _knockback.z

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	move_and_slide()

	if knockback_speed > 0.05:
		_check_wall_slam(knockback_speed)
		_knockback = _knockback.move_toward(Vector3.ZERO, knockback_friction * delta)

	if global_position.y < -10.0:
		_respawn()


func take_damage(amount: float) -> void:
	if amount <= 0.0:
		return
	health -= amount
	hurt.emit(amount)
	print("Player hit for ", amount, " (health ", health, "/", max_health, ")")
	if health <= 0.0:
		print("Player destroyed, respawning.")
		health = max_health
		died.emit()
		_respawn()


## Throws the player away from the attacker. `wall_damage` is applied once if
## the flight ends against a wall instead of open space.
func apply_knockback(force: Vector3, wall_damage: float = 0.0) -> void:
	_knockback += Vector3(force.x, 0.0, force.z)
	_knockback_wall_damage = maxf(wall_damage, _knockback_wall_damage)
	_wall_slam_used = false


func _check_wall_slam(speed: float) -> void:
	if _wall_slam_used or _knockback_wall_damage <= 0.0 or speed < wall_slam_min_speed:
		return
	for index in get_slide_collision_count():
		var normal := get_slide_collision(index).get_normal()
		if absf(normal.y) < 0.6:
			_wall_slam_used = true
			_knockback *= 0.2
			print("Player slammed into a wall for ", _knockback_wall_damage, " extra damage.")
			take_damage(_knockback_wall_damage)
			return


func _respawn() -> void:
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO
	_knockback_wall_damage = 0.0
	_wall_slam_used = false


func _flat_speed(velocity_3d: Vector3) -> float:
	return Vector2(velocity_3d.x, velocity_3d.z).length()
