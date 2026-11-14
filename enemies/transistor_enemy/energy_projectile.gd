extends Node3D

## Fictional energy bolt fired by enemies.
##
## The projectile is a plain Node3D, not a physics body: each physics frame it
## sweeps a ray from its previous position to its new one, so fast shots cannot
## tunnel through thin walls. Anything it hits that implements
## `take_damage(amount: float)` receives damage.

signal impacted(hit_position: Vector3, collider: Object)

@export_group("Motion")
## Travel speed in metres per second.
@export var speed: float = 26.0
## Seconds before the bolt despawns on its own.
@export var lifetime: float = 4.0

@export_group("Combat")
## Damage passed to `take_damage()` on the first thing the bolt hits.
@export var damage: float = 15.0
## Physics layers the bolt collides with (layer 1 by default).
@export_flags_3d_physics var collision_mask: int = 1

var _direction: Vector3 = Vector3.FORWARD
var _shooter_rid: RID
var _age: float = 0.0


## Starts the bolt moving. Call after adding it to the tree and positioning it.
func launch(direction: Vector3, shooter: CollisionObject3D = null, speed_override: float = -1.0, damage_override: float = -1.0) -> void:
	if speed_override > 0.0:
		speed = speed_override
	if damage_override > 0.0:
		damage = damage_override

	_direction = direction.normalized()
	if _direction.is_zero_approx():
		_direction = -global_basis.z

	if shooter != null:
		_shooter_rid = shooter.get_rid()

	_age = 0.0
	var up := Vector3.UP
	if absf(_direction.dot(up)) > 0.99:
		up = Vector3.BACK
	look_at(global_position + _direction, up)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= lifetime:
		queue_free()
		return

	var from := global_position
	var to := from + _direction * speed * delta

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	if _shooter_rid.is_valid():
		query.exclude = [_shooter_rid]

	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		global_position = to
		return

	global_position = hit.position
	_impact(hit.get("collider"))


func _impact(collider: Object) -> void:
	if collider != null and collider.has_method("take_damage"):
		collider.take_damage(damage)
	impacted.emit(global_position, collider)
	queue_free()
