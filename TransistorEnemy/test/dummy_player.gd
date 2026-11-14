class_name DummyPlayer
extends CharacterBody3D

## Stand-in player used by the module's test scene.
##
## Walks a circle so the enemy has something to chase, and implements
## `take_damage()` so incoming bolts have something to hit. It is not a
## controller; replace it with your own player in a real project.

signal health_changed(current: float, maximum: float)

@export var wander_radius: float = 6.0
@export var wander_speed: float = 2.4
@export var max_health: float = 100.0

var health: float = 0.0

var _angle: float = 0.0
var _gravity: float = 9.8


func _ready() -> void:
	health = max_health
	add_to_group(&"player")
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	health_changed.emit(health, max_health)


func _physics_process(delta: float) -> void:
	_angle += (wander_speed / maxf(wander_radius, 0.1)) * delta
	var goal := Vector3(cos(_angle), 0.0, sin(_angle)) * wander_radius
	var to_goal := goal - global_position
	to_goal.y = 0.0

	if to_goal.length() > 0.05:
		var direction := to_goal.normalized()
		velocity.x = direction.x * wander_speed
		velocity.z = direction.z * wander_speed
		rotation.y = atan2(-direction.x, -direction.z)

	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0

	move_and_slide()


func take_damage(amount: float) -> void:
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	print("[DummyPlayer] hit for %.0f, health %.0f/%.0f" % [amount, health, max_health])
	if health <= 0.0:
		# The test dummy does not die; it resets so the demo keeps running.
		health = max_health
		health_changed.emit(health, max_health)
		print("[DummyPlayer] recovered to %.0f health" % health)
