# weapon.gd
# CS-like оружие: типы, урон, броня, ammo, перезарядка, friendly fire block.
# Зависимости: bot_stats.gd, bot_brain.gd (родитель)

extends Node3D
class_name Weapon

signal shot_fired(shooter_id: int, direction: Vector3)
signal hit_confirmed(shooter_id: int, target_id: int, damage: int)
signal reloading(weapon_name: String, duration: float)

enum WeaponType { PISTOL, SMG, RIFLE, AWP }

const WEAPON_DATA: Dictionary = {
	WeaponType.PISTOL: { "name": "Pistol",  "damage": 35,  "fire_rate": 0.25, "mag": 13, "reload": 2.2, "armor_factor": 0.50 },
	WeaponType.SMG:    { "name": "SMG",     "damage": 26,  "fire_rate": 0.08, "mag": 30, "reload": 1.9, "armor_factor": 0.55 },
	WeaponType.RIFLE:  { "name": "Rifle",   "damage": 33,  "fire_rate": 0.09, "mag": 30, "reload": 2.5, "armor_factor": 0.57 },
	WeaponType.AWP:    { "name": "AWP",     "damage": 115, "fire_rate": 1.5,  "mag": 10, "reload": 3.7, "armor_factor": 0.85 },
}

const BOT_COLLISION_LAYER_CT: int = 4
const BOT_COLLISION_LAYER_T: int  = 8
const MAX_RANGE: float = 200.0

var weapon_type: WeaponType = WeaponType.PISTOL
var damage: int = 35
var fire_rate: float = 0.25
var weapon_name: String = "Pistol"

var _ammo: int = 13
var _max_ammo: int = 13
var _is_reloading: bool = false
var _reload_timer: float = 0.0
var _fire_cooldown: float = 0.0

func _ready() -> void:
	set_weapon_type(WeaponType.PISTOL)

func _process(delta: float) -> void:
	if _fire_cooldown > 0.0:
		_fire_cooldown -= delta

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_is_reloading = false
			_ammo = _max_ammo

func set_weapon_type(type: WeaponType) -> void:
	weapon_type = type
	var data = WEAPON_DATA[type]
	damage = data["damage"]
	fire_rate = data["fire_rate"]
	weapon_name = data["name"]
	_max_ammo = data["mag"]
	_ammo = _max_ammo
	_is_reloading = false
	_reload_timer = 0.0

func start_reload() -> void:
	if _is_reloading or _ammo == _max_ammo:
		return
	_is_reloading = true
	_reload_timer = WEAPON_DATA[weapon_type]["reload"]
	emit_signal("reloading", weapon_name, _reload_timer)

func try_fire(target: Node3D, stats: BotStats) -> bool:
	if _fire_cooldown > 0.0 or _is_reloading:
		return false
	if _ammo <= 0:
		start_reload()
		return false
	_ammo -= 1
	_fire_cooldown = fire_rate
	if _ammo == 0:
		start_reload()
	_do_fire(target, stats)
	return true

func _do_fire(target: Node3D, stats: BotStats) -> void:
	var spread_rad = deg_to_rad(stats.get_spread_angle())
	var eye_pos = global_position + Vector3(0, 0.9, 0)
	var dir = (target.global_position + Vector3(0, 0.9, 0) - eye_pos).normalized()

	dir = dir.rotated(Vector3.UP, randf_range(-spread_rad, spread_rad))
	dir = dir.rotated(global_transform.basis.x, randf_range(-spread_rad * 0.5, spread_rad * 0.5))

	emit_signal("shot_fired", stats.bot_id, dir)

	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(eye_pos, eye_pos + dir * MAX_RANGE)
	query.exclude = [get_parent()]
	query.collision_mask = BOT_COLLISION_LAYER_CT | BOT_COLLISION_LAYER_T

	var result = space.intersect_ray(query)
	if result.is_empty():
		return

	var hit_body = result["collider"]
	if not hit_body or not hit_body.has_method("apply_damage"):
		return

	# Блок friendly fire
	if hit_body is BotBrain and hit_body.stats.team == stats.team:
		return

	# Урон с учётом брони
	var raw_damage = damage
	if hit_body is BotBrain and hit_body.stats.armor > 0:
		raw_damage = int(raw_damage * WEAPON_DATA[weapon_type]["armor_factor"])

	hit_body.apply_damage(raw_damage, stats.bot_id)
	var target_id = hit_body.stats.bot_id if hit_body is BotBrain else -1
	emit_signal("hit_confirmed", stats.bot_id, target_id, raw_damage)
