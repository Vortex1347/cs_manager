# weapon.gd
# Базовое оружие: raycast стрельба, формула разброса на основе aim_level.
# Зависимости: bot_stats.gd (передаётся при выстреле), bot_brain.gd (родитель)

extends Node3D
class_name Weapon

signal shot_fired(shooter_id: int, direction: Vector3)
signal hit_confirmed(shooter_id: int, target_id: int, damage: int)

const BOT_COLLISION_LAYER_CT: int = 4   # layer 3 в project.godot
const BOT_COLLISION_LAYER_T: int = 8    # layer 4 в project.godot
const MAX_RANGE: float = 50.0

@export var damage: int = 25
@export var fire_rate: float = 0.1      # секунды между выстрелами
@export var weapon_name: String = "Rifle"

var _fire_cooldown: float = 0.0
var _owner_brain: BotBrain = null

func _ready() -> void:
	_owner_brain = get_parent() as BotBrain

func _process(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

func try_fire(target: Node3D, stats: BotStats) -> bool:
	if _fire_cooldown > 0.0:
		return false
	_fire_cooldown = fire_rate
	_do_fire(target, stats)
	return true

func _do_fire(target: Node3D, stats: BotStats) -> void:
	var spread_rad = deg_to_rad(stats.get_spread_angle())
	var dir = (target.global_position + Vector3(0, 0.9, 0) - global_position).normalized()

	# Применяем случайный конусный разброс
	dir = dir.rotated(Vector3.UP, randf_range(-spread_rad, spread_rad))
	dir = dir.rotated(global_transform.basis.x, randf_range(-spread_rad * 0.5, spread_rad * 0.5))

	emit_signal("shot_fired", stats.bot_id, dir)

	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 0.9, 0),
		global_position + Vector3(0, 0.9, 0) + dir * MAX_RANGE
	)
	query.exclude = [get_parent()]
	query.collision_mask = BOT_COLLISION_LAYER_CT | BOT_COLLISION_LAYER_T

	var result = space.intersect_ray(query)
	if result.is_empty():
		return

	var hit_body = result["collider"]
	if hit_body and hit_body.has_method("apply_damage"):
		hit_body.apply_damage(damage, stats.bot_id)
		var target_id = hit_body.stats.bot_id if hit_body is BotBrain else -1
		emit_signal("hit_confirmed", stats.bot_id, target_id, damage)
