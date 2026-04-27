# weapon.gd
# CS-like оружие: stateful gunplay-модель с точностью, burst pressure, движением и range-профилями.
# Зависимости: bot_stats.gd, bot_brain.gd (родитель)

extends Node3D
class_name Weapon

signal shot_fired(shooter_id: int, direction: Vector3)
signal hit_confirmed(shooter_id: int, target_id: int, damage: int)
signal reloading(weapon_name: String, duration: float)

enum WeaponType { PISTOL, SMG, RIFLE, AWP }

const WEAPON_DATA: Dictionary = {
	WeaponType.PISTOL: {
		"name": "Pistol",
		"damage": 35,
		"fire_rate": 0.25,
		"mag": 13,
		"reload": 2.2,
		"armor_factor": 0.50,
		"base_spread": 4.8,
		"moving_spread_penalty": 3.8,
		"burst_spread_gain": 0.6,
		"recovery_rate": 3.9,
		"ideal_range": 12.0,
		"falloff_start": 22.0,
		"burst_size_hint": 1,
	},
	WeaponType.SMG: {
		"name": "SMG",
		"damage": 26,
		"fire_rate": 0.08,
		"mag": 30,
		"reload": 1.9,
		"armor_factor": 0.55,
		"base_spread": 5.0,
		"moving_spread_penalty": 5.2,
		"burst_spread_gain": 0.95,
		"recovery_rate": 2.9,
		"ideal_range": 14.0,
		"falloff_start": 24.0,
		"burst_size_hint": 4,
	},
	WeaponType.RIFLE: {
		"name": "Rifle",
		"damage": 33,
		"fire_rate": 0.09,
		"mag": 30,
		"reload": 2.5,
		"armor_factor": 0.57,
		"base_spread": 3.0,
		"moving_spread_penalty": 4.4,
		"burst_spread_gain": 0.7,
		"recovery_rate": 4.8,
		"ideal_range": 24.0,
		"falloff_start": 36.0,
		"burst_size_hint": 3,
	},
	WeaponType.AWP: {
		"name": "AWP",
		"damage": 115,
		"fire_rate": 1.5,
		"mag": 10,
		"reload": 3.7,
		"armor_factor": 0.85,
		"base_spread": 0.65,
		"moving_spread_penalty": 8.5,
		"burst_spread_gain": 1.8,
		"recovery_rate": 5.5,
		"ideal_range": 42.0,
		"falloff_start": 58.0,
		"burst_size_hint": 1,
	},
}

const BOT_COLLISION_LAYER_CT: int = 4
const BOT_COLLISION_LAYER_T: int  = 8
const MAX_RANGE: float = 200.0
const RANGE_FALLOFF_DAMAGE: float = 0.45

var weapon_type: WeaponType = WeaponType.PISTOL
var damage: int = 35
var fire_rate: float = 0.25
var weapon_name: String = "Pistol"
var base_spread: float = 4.8
var moving_spread_penalty: float = 3.8
var burst_spread_gain: float = 0.6
var recovery_rate: float = 3.9
var ideal_range: float = 12.0
var falloff_start: float = 22.0
var burst_size_hint: int = 1

var _ammo: int = 13
var _max_ammo: int = 13
var _is_reloading: bool = false
var _reload_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _spread_pressure: float = 0.0
var _burst_shots: int = 0
var _time_since_last_shot: float = 99.0
var _last_fire_mode: String = "tap"
var _last_engagement_profile: String = "mid"
var _last_distance: float = 0.0
var _last_movement_ratio: float = 0.0
var _last_accuracy_penalty: float = 0.0
var _last_dynamic_spread: float = 0.0
var _last_stabilized: bool = true
var _last_reason: String = "ready"
var _last_damage: int = 0

func _ready() -> void:
	set_weapon_type(WeaponType.PISTOL)

func _process(delta: float) -> void:
	_time_since_last_shot += delta
	var owner_stats = _get_owner_stats()
	var aim_bonus = _get_aim_control_bonus(owner_stats)
	_spread_pressure = maxf(0.0, _spread_pressure - delta * recovery_rate * (1.0 + aim_bonus))
	if _time_since_last_shot > maxf(fire_rate * 2.2, 0.25):
		_burst_shots = 0
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
	base_spread = data["base_spread"]
	moving_spread_penalty = data["moving_spread_penalty"]
	burst_spread_gain = data["burst_spread_gain"]
	recovery_rate = data["recovery_rate"]
	ideal_range = data["ideal_range"]
	falloff_start = data["falloff_start"]
	burst_size_hint = data["burst_size_hint"]
	_spread_pressure = 0.0
	_burst_shots = 0
	_time_since_last_shot = 99.0
	_last_reason = "ready"

func start_reload() -> void:
	if _is_reloading or _ammo == _max_ammo:
		return
	_is_reloading = true
	_reload_timer = WEAPON_DATA[weapon_type]["reload"]
	_last_reason = "reloading"
	emit_signal("reloading", weapon_name, _reload_timer)

func try_fire(target: Node3D, stats: BotStats, context: Dictionary = {}) -> bool:
	if _fire_cooldown > 0.0:
		_last_reason = "cooldown"
		return false
	if _is_reloading:
		_last_reason = "reloading"
		return false
	if _ammo <= 0:
		start_reload()
		_last_reason = "empty"
		return false
	var distance = global_position.distance_to(target.global_position)
	var dynamic_spread = _get_dynamic_spread(stats, distance, context)
	_ammo -= 1
	_fire_cooldown = fire_rate
	_time_since_last_shot = 0.0
	_burst_shots += 1
	_spread_pressure += burst_spread_gain * _get_fire_mode_pressure_multiplier(String(context.get("fire_mode", "tap")))
	_last_fire_mode = String(context.get("fire_mode", "tap"))
	_last_engagement_profile = String(context.get("engagement_profile", get_engagement_profile(distance)))
	_last_distance = distance
	_last_movement_ratio = clampf(float(context.get("movement_ratio", 0.0)), 0.0, 1.25)
	_last_stabilized = bool(context.get("stabilized", false))
	_last_dynamic_spread = dynamic_spread
	_last_accuracy_penalty = dynamic_spread - _get_base_accuracy_floor(stats)
	_last_reason = String(context.get("shot_reason", "fired"))
	_last_damage = damage
	if _ammo == 0:
		start_reload()
	_do_fire(target, stats, dynamic_spread, distance)
	return true

func _do_fire(target: Node3D, stats: BotStats, spread_deg: float, distance: float) -> void:
	var spread_rad = deg_to_rad(spread_deg)
	var eye_pos = global_position + Vector3(0, 0.9, 0)
	var dir = (target.global_position + Vector3(0, 0.9, 0) - eye_pos).normalized()
	dir = dir.rotated(Vector3.UP, randf_range(-spread_rad, spread_rad))
	dir = dir.rotated(global_transform.basis.x, randf_range(-spread_rad * 0.5, spread_rad * 0.5))
	emit_signal("shot_fired", stats.bot_id, dir)

	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(eye_pos, eye_pos + dir * MAX_RANGE)
	query.exclude = [get_parent()]
	query.collision_mask = BOT_COLLISION_LAYER_CT | BOT_COLLISION_LAYER_T | 1

	var result = space.intersect_ray(query)
	var hit_pos = result["position"] if not result.is_empty() else eye_pos + dir * minf(distance, 50.0)
	var tc: Color = Color(0.3, 0.8, 1.0) if stats.team == BotStats.Team.CT else Color(1.0, 0.55, 0.1)
	_spawn_tracer(eye_pos, hit_pos, tc)
	if result.is_empty():
		return
	var hit_body = result["collider"]
	if not hit_body or not hit_body.has_method("apply_damage"):
		return
	if hit_body is BotBrain and hit_body.stats.team == stats.team:
		return

	var raw_damage = _get_damage_for_distance(distance)
	if hit_body is BotBrain and hit_body.stats.armor > 0:
		raw_damage = int(raw_damage * WEAPON_DATA[weapon_type]["armor_factor"])
	_last_damage = raw_damage
	hit_body.apply_damage(raw_damage, stats.bot_id, eye_pos)
	var target_id = hit_body.stats.bot_id if hit_body is BotBrain else -1
	emit_signal("hit_confirmed", stats.bot_id, target_id, raw_damage)

func get_accuracy_state() -> Dictionary:
	return {
		"spread_pressure": _spread_pressure,
		"burst_shots": _burst_shots,
		"time_since_last_shot": _time_since_last_shot,
		"movement_ratio": _last_movement_ratio,
		"dynamic_spread": _last_dynamic_spread,
		"accuracy_penalty": _last_accuracy_penalty,
		"stabilized": _last_stabilized,
		"fire_mode": _last_fire_mode,
		"engagement_profile": _last_engagement_profile,
		"reason": _last_reason,
		"distance": _last_distance,
		"ammo": _ammo,
	}

func get_engagement_profile(distance: float) -> String:
	if distance <= ideal_range * 0.65:
		return "close"
	if distance <= falloff_start:
		return "mid"
	return "long"

func get_debug_summary() -> String:
	return "%s %s %s %s acc+%.2f %s" % [
		weapon_name,
		_last_fire_mode,
		"STAB" if _last_stabilized else "MOVE",
		_last_engagement_profile,
		_last_accuracy_penalty,
		_last_reason,
	]

func get_default_fire_mode(distance: float) -> String:
	var engagement = get_engagement_profile(distance)
	match weapon_type:
		WeaponType.SMG:
			return "spray_commit" if engagement == "close" else "burst"
		WeaponType.RIFLE:
			return "tap" if engagement == "long" else "burst"
		WeaponType.AWP:
			return "awp_hold"
		_:
			return "tap" if engagement == "long" else "burst"

func get_weapon_type_name() -> String:
	return WeaponType.keys()[weapon_type].to_lower()

func _get_dynamic_spread(stats: BotStats, distance: float, context: Dictionary) -> float:
	var movement_ratio = clampf(float(context.get("movement_ratio", 0.0)), 0.0, 1.25)
	var stabilized = bool(context.get("stabilized", false))
	var fire_mode = String(context.get("fire_mode", "tap"))
	var peek_mode = String(context.get("peek_mode", "hold_angle"))
	var engagement = String(context.get("engagement_profile", get_engagement_profile(distance)))
	var spread = _get_base_accuracy_floor(stats)
	var movement_penalty = moving_spread_penalty * movement_ratio
	if stabilized:
		movement_penalty *= 0.4
	spread += movement_penalty
	spread += _spread_pressure
	if _time_since_last_shot < fire_rate * 1.45:
		spread += burst_spread_gain * 0.35
	match fire_mode:
		"tap":
			spread *= 0.88
		"burst":
			spread += maxf(0.0, float(_burst_shots) - 1.0) * burst_spread_gain * 0.55
		"spray_commit":
			spread += maxf(0.0, float(_burst_shots) - 1.0) * burst_spread_gain * 0.95
		"awp_hold":
			spread *= 0.42 if stabilized else 2.2
	if peek_mode in ["wide_swing", "trade_swing"]:
		spread += 0.5 if fire_mode == "spray_commit" else 0.8
	elif peek_mode in ["hold_angle", "fallback_hold"]:
		spread *= 0.92
	if engagement == "long" and fire_mode != "awp_hold":
		spread += 0.8
	elif engagement == "close" and fire_mode == "spray_commit":
		spread *= 0.94
	if distance > falloff_start:
		var overflow = minf(distance - falloff_start, 40.0)
		spread += overflow * 0.08
	return maxf(0.2, spread)

func _get_base_accuracy_floor(stats: BotStats) -> float:
	var aim_factor = remap(float(stats.aim_level), 1.0, 10.0, 1.45, 0.55)
	return base_spread * aim_factor

func _get_damage_for_distance(distance: float) -> int:
	if distance <= falloff_start:
		return damage
	var overflow = clampf((distance - falloff_start) / maxf(MAX_RANGE - falloff_start, 1.0), 0.0, 1.0)
	var mult = lerpf(1.0, RANGE_FALLOFF_DAMAGE, overflow)
	return max(1, int(round(damage * mult)))

func _get_fire_mode_pressure_multiplier(fire_mode: String) -> float:
	match fire_mode:
		"spray_commit":
			return 1.2
		"burst":
			return 0.9
		"awp_hold":
			return 0.45
		_:
			return 0.6

func _get_aim_control_bonus(stats: BotStats) -> float:
	if stats == null:
		return 0.0
	return remap(float(stats.aim_level), 1.0, 10.0, 0.0, 0.8)

func _get_owner_stats():
	var owner = get_parent()
	if owner and owner.get("stats") != null:
		return owner.stats
	return null

func _spawn_tracer(from: Vector3, to: Vector3, col: Color = Color(1.0, 0.95, 0.4)) -> void:
	var dist = from.distance_to(to)
	if dist < 0.1:
		return
	var tracer = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	mesh.size = Vector3(0.04, 0.04, dist)
	tracer.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 4.0
	tracer.material_override = mat
	get_tree().current_scene.add_child(tracer)
	tracer.global_position = (from + to) * 0.5
	tracer.look_at(to, Vector3.UP)
	get_tree().create_timer(0.06).timeout.connect(tracer.queue_free)
