# bomb_controller.gd
# Держит весь цикл бомбы: carried → dropped → planting → planted → defusing → defused/exploded.
# Зависимости: bombsite.gd (валидирует зону), bot_brain.gd (валидирует носителя/дефьюзера)

extends Node3D
class_name BombController

signal bomb_state_changed(state_name: String, site_id: String, carrier_id: int, world_pos: Vector3)
signal bomb_dropped(position: Vector3, bot_id: int)
signal bomb_picked_up(bot_id: int)
signal plant_started(site_id: String, bot_id: int)
signal plant_cancelled(site_id: String, bot_id: int)
signal plant_completed(site_id: String, bot_id: int)
signal defuse_started(site_id: String, bot_id: int)
signal defuse_cancelled(site_id: String, bot_id: int)
signal defuse_completed(site_id: String, bot_id: int)
signal bomb_exploded(site_id: String)
signal countdown_updated(seconds_remaining: float)

enum BombState { NONE, CARRIED, DROPPED, PLANTING, PLANTED, DEFUSING, DEFUSED, EXPLODED }

const PLANT_DURATION: float = 3.2
const DEFUSE_DURATION_BASE: float = 10.0
const DEFUSE_DURATION_WITH_KIT: float = 5.0
const BOMB_TIMER: float = 40.0
const PICKUP_RADIUS: float = 2.2

var current_state: BombState = BombState.NONE
var carrier_id: int = -1
var fallback_carrier_id: int = -1
var planted_site_id: String = ""
var site_target_id: String = ""
var dropped_position: Vector3 = Vector3.ZERO
var active_planter_id: int = -1
var active_defuser_id: int = -1

var _planted_site = null
var _plant_timer: float = 0.0
var _defuse_timer: float = 0.0
var _bomb_countdown: float = 0.0
var _bomb_mesh: MeshInstance3D = null
var _last_logged_second: int = -1

func _ready() -> void:
	add_to_group("bomb_controller")
	set_process(false)

func _process(delta: float) -> void:
	match current_state:
		BombState.PLANTING:
			_process_planting(delta)
		BombState.PLANTED:
			_process_countdown(delta)
		BombState.DEFUSING:
			_process_defusing(delta)

func reset() -> void:
	current_state = BombState.NONE
	carrier_id = -1
	fallback_carrier_id = -1
	planted_site_id = ""
	site_target_id = ""
	dropped_position = Vector3.ZERO
	active_planter_id = -1
	active_defuser_id = -1
	_planted_site = null
	_plant_timer = 0.0
	_defuse_timer = 0.0
	_bomb_countdown = 0.0
	_last_logged_second = -1
	_remove_bomb_visual()
	set_process(false)
	_emit_state()

func assign_carrier(bot_id: int, next_carrier_id: int = -1, preferred_site_id: String = "") -> void:
	if bot_id < 0:
		return
	current_state = BombState.CARRIED
	carrier_id = bot_id
	fallback_carrier_id = next_carrier_id
	active_planter_id = -1
	active_defuser_id = -1
	planted_site_id = ""
	if preferred_site_id != "":
		site_target_id = preferred_site_id
	dropped_position = Vector3.ZERO
	_planted_site = null
	_plant_timer = 0.0
	_defuse_timer = 0.0
	_bomb_countdown = 0.0
	_remove_bomb_visual()
	set_process(false)
	_emit_state()

func drop_bomb(world_pos: Vector3, from_bot_id: int) -> void:
	if current_state == BombState.PLANTED or current_state == BombState.DEFUSING:
		return
	current_state = BombState.DROPPED
	carrier_id = -1
	active_planter_id = -1
	dropped_position = world_pos
	_spawn_or_move_bomb_visual(world_pos)
	set_process(false)
	emit_signal("bomb_dropped", world_pos, from_bot_id)
	_emit_state()

func pickup_bomb(bot_id: int) -> void:
	if current_state != BombState.DROPPED:
		return
	assign_carrier(bot_id, fallback_carrier_id, site_target_id)
	emit_signal("bomb_picked_up", bot_id)

func begin_plant(bot, site) -> bool:
	if bot == null or site == null:
		return false
	if current_state != BombState.CARRIED or carrier_id != bot.stats.bot_id:
		return false
	if not site.contains_point(bot.global_position):
		return false
	current_state = BombState.PLANTING
	active_planter_id = bot.stats.bot_id
	planted_site_id = site.site_id
	site_target_id = site.site_id
	_planted_site = site
	_plant_timer = 0.0
	_spawn_or_move_bomb_visual(site.global_position + Vector3(0, 0.3, 0))
	set_process(true)
	emit_signal("plant_started", planted_site_id, active_planter_id)
	_emit_state()
	return true

func cancel_plant() -> void:
	if current_state != BombState.PLANTING:
		return
	var cancelled_site = planted_site_id
	var cancelled_bot = active_planter_id
	current_state = BombState.CARRIED
	active_planter_id = -1
	planted_site_id = ""
	_planted_site = null
	_plant_timer = 0.0
	_remove_bomb_visual()
	set_process(false)
	emit_signal("plant_cancelled", cancelled_site, cancelled_bot)
	_emit_state()

func begin_defuse(bot, site) -> bool:
	if bot == null or site == null:
		return false
	if current_state != BombState.PLANTED:
		return false
	if site.site_id != planted_site_id:
		return false
	if not site.contains_point(bot.global_position):
		return false
	current_state = BombState.DEFUSING
	active_defuser_id = bot.stats.bot_id
	_defuse_timer = 0.0
	set_process(true)
	emit_signal("defuse_started", planted_site_id, active_defuser_id)
	_emit_state()
	return true

func cancel_defuse() -> void:
	if current_state != BombState.DEFUSING:
		return
	var cancelled_bot = active_defuser_id
	current_state = BombState.PLANTED
	active_defuser_id = -1
	_defuse_timer = 0.0
	set_process(true)
	emit_signal("defuse_cancelled", planted_site_id, cancelled_bot)
	_emit_state()

func cancel_defuse_by(bot_id: int) -> void:
	if active_defuser_id == bot_id:
		cancel_defuse()

func get_state_name() -> String:
	return BombState.keys()[current_state].to_lower()

func is_planted() -> bool:
	return current_state == BombState.PLANTED or current_state == BombState.DEFUSING

func get_dropped_position() -> Vector3:
	return dropped_position

func get_carrier_id() -> int:
	return carrier_id

func get_fallback_carrier_id() -> int:
	return fallback_carrier_id

func set_fallback_carrier_id(bot_id: int) -> void:
	fallback_carrier_id = bot_id

func set_site_target(site_id: String) -> void:
	site_target_id = site_id.to_upper()

func get_site_target() -> String:
	return planted_site_id if planted_site_id != "" else site_target_id

func get_countdown_ratio() -> float:
	if not is_planted():
		return 0.0
	return clamp(_bomb_countdown / BOMB_TIMER, 0.0, 1.0)

func get_countdown_seconds() -> float:
	return _bomb_countdown

func get_seconds_remaining() -> float:
	return _bomb_countdown

func get_plant_progress() -> float:
	if current_state != BombState.PLANTING:
		return 0.0
	return clampf(_plant_timer / PLANT_DURATION, 0.0, 1.0)

func get_defuse_progress() -> float:
	if current_state != BombState.DEFUSING:
		return 0.0
	var duration = DEFUSE_DURATION_WITH_KIT if _has_defuse_kit(active_defuser_id) else DEFUSE_DURATION_BASE
	return clampf(_defuse_timer / duration, 0.0, 1.0)

func get_planted_site():
	return _planted_site

func get_active_site_id() -> String:
	return planted_site_id if planted_site_id != "" else site_target_id

func get_active_planter_id() -> int:
	return active_planter_id

func get_active_defuser_id() -> int:
	return active_defuser_id

func get_active_site_position() -> Vector3:
	if _planted_site:
		return _planted_site.global_position
	return Vector3.ZERO

func is_defuse_in_progress() -> bool:
	return current_state == BombState.DEFUSING

func _process_planting(delta: float) -> void:
	var planter = _find_bot_by_id(active_planter_id)
	if planter == null or planter.current_state == BotBrain.BotState.DEAD or not planter._is_live:
		cancel_plant()
		return
	if _planted_site == null or not _planted_site.contains_point(planter.global_position):
		cancel_plant()
		return
	_plant_timer += delta
	_update_bomb_visual_plant(_plant_timer / PLANT_DURATION)
	if _plant_timer >= PLANT_DURATION:
		_complete_plant(planter)

func _process_countdown(delta: float) -> void:
	_bomb_countdown -= delta
	emit_signal("countdown_updated", _bomb_countdown)
	var sec = int(_bomb_countdown)
	if sec != _last_logged_second:
		_last_logged_second = sec
		if sec <= 10 and sec >= 0:
			print("💣 [%s] Взрыв через %d..." % [planted_site_id, sec])
		elif sec in [20, 30]:
			print("💣 [%s] Взрыв через %d секунд" % [planted_site_id, sec])
	if _bomb_countdown <= 0.0:
		_explode()

func _process_defusing(delta: float) -> void:
	var defuser = _find_bot_by_id(active_defuser_id)
	if defuser == null or defuser.current_state == BotBrain.BotState.DEAD or not defuser._is_live:
		cancel_defuse()
		return
	if _planted_site == null or not _planted_site.contains_point(defuser.global_position):
		cancel_defuse()
		return
	_process_countdown(delta)
	if current_state != BombState.DEFUSING:
		return
	_defuse_timer += delta
	var duration = DEFUSE_DURATION_WITH_KIT if _has_defuse_kit(active_defuser_id) else DEFUSE_DURATION_BASE
	if _defuse_timer >= duration:
		_complete_defuse()

func _complete_plant(planter) -> void:
	current_state = BombState.PLANTED
	carrier_id = -1
	active_planter_id = -1
	_bomb_countdown = BOMB_TIMER
	_last_logged_second = int(BOMB_TIMER)
	_set_bomb_visual_planted()
	set_process(true)
	print("💣 БОМБА ПОСТАВЛЕНА на сайте %s! (40 сек)" % planted_site_id)
	emit_signal("plant_completed", planted_site_id, planter.stats.bot_id)
	_emit_state()

func _complete_defuse() -> void:
	var finished_defuser = active_defuser_id
	current_state = BombState.DEFUSED
	_bomb_countdown = 0.0
	active_defuser_id = -1
	set_process(false)
	_remove_bomb_visual()
	print("✅ БОМБА РАЗМИНИРОВАНА на сайте %s!" % planted_site_id)
	emit_signal("defuse_completed", planted_site_id, finished_defuser)
	_emit_state()

func _explode() -> void:
	current_state = BombState.EXPLODED
	set_process(false)
	print("💥 БОМБА ВЗОРВАЛАСЬ на сайте %s!" % planted_site_id)
	emit_signal("bomb_exploded", planted_site_id)
	_emit_state()

func _find_bot_by_id(bot_id: int):
	for group_name in ["ct_bots", "t_bots"]:
		for bot in get_tree().get_nodes_in_group(group_name):
			if bot is BotBrain and bot.stats.bot_id == bot_id:
				return bot
	return null

func _has_defuse_kit(bot_id: int) -> bool:
	var bot = _find_bot_by_id(bot_id)
	return bot != null and bot.stats.has_defuse_kit

func _emit_state() -> void:
	emit_signal("bomb_state_changed", get_state_name(), planted_site_id, carrier_id, _get_world_position())

func _get_world_position() -> Vector3:
	if _bomb_mesh:
		return _bomb_mesh.global_position
	if current_state == BombState.DROPPED:
		return dropped_position
	if _planted_site:
		return _planted_site.global_position
	var carrier = _find_bot_by_id(carrier_id)
	return carrier.global_position if carrier else Vector3.ZERO

func _spawn_or_move_bomb_visual(world_pos: Vector3) -> void:
	if _bomb_mesh == null:
		_bomb_mesh = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(0.9, 0.5, 0.65)
		_bomb_mesh.mesh = box
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.12, 0.12, 0.12)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.4, 0.0)
		mat.emission_energy_multiplier = 3.4
		_bomb_mesh.material_override = mat
		add_child(_bomb_mesh)
	_bomb_mesh.global_position = world_pos + Vector3(0, 0.32, 0)

func _update_bomb_visual_plant(t: float) -> void:
	if _bomb_mesh == null:
		return
	var pulse = abs(sin(t * PI * 6.0))
	var mat = _bomb_mesh.material_override as StandardMaterial3D
	if mat:
		mat.emission_energy_multiplier = lerp(1.0, 6.0, pulse)

func _set_bomb_visual_planted() -> void:
	if _bomb_mesh == null:
		return
	if _planted_site:
		_bomb_mesh.global_position = _planted_site.global_position + Vector3(0, 0.3, 0)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.0, 0.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.0, 0.0)
	mat.emission_energy_multiplier = 8.0
	_bomb_mesh.material_override = mat

func _remove_bomb_visual() -> void:
	if _bomb_mesh:
		_bomb_mesh.queue_free()
		_bomb_mesh = null
