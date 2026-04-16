# bombsite.gd
# Бомбсайт: Area3D с логикой закладки и разминирования бомбы.
# Зависимости: round_manager.gd (слушает round_ended для сброса)

extends Area3D
class_name Bombsite

signal plant_started(site_id: String, planter_id: int)
signal plant_completed(site_id: String)
signal defuse_started(site_id: String, defuser_id: int)
signal defuse_completed(site_id: String)
signal bomb_exploded(site_id: String)

const PLANT_DURATION: float = 3.2
const DEFUSE_DURATION_BASE: float = 10.0
const DEFUSE_DURATION_WITH_KIT: float = 5.0
const BOMB_TIMER: float = 40.0

@export var site_id: String = "A"

var bomb_planted: bool = false
var bomb_exploded_flag: bool = false
var _plant_timer: float = 0.0
var _defuse_timer: float = 0.0
var _bomb_countdown: float = 0.0
var _planting_bot_id: int = -1
var _defusing_bot_id: int = -1
var _is_planting: bool = false
var _is_defusing: bool = false
var _last_logged_second: int = -1
var _bomb_mesh: MeshInstance3D = null  # визуальный объект бомбы на сайте

func _process(delta: float) -> void:
	if _is_planting:
		var planter: BotBrain = _find_planter(_planting_bot_id)
		if planter == null \
				or not planter._is_live \
				or planter.current_state == BotBrain.BotState.DEAD \
				or not contains_point(planter.global_position):
			cancel_plant()
		else:
			_plant_timer += delta
			_update_bomb_visual_plant(_plant_timer / PLANT_DURATION)
			if _plant_timer >= PLANT_DURATION:
				_complete_plant()

	if bomb_planted and not bomb_exploded_flag:
		if _is_defusing:
			var defuser: BotBrain = _find_defuser(_defusing_bot_id)
			if defuser == null \
					or not defuser._is_live \
					or defuser.current_state == BotBrain.BotState.DEAD \
					or not contains_point(defuser.global_position):
				cancel_defuse()
			else:
				_defuse_timer += delta
				var duration := DEFUSE_DURATION_WITH_KIT if _has_defuse_kit(_defusing_bot_id) else DEFUSE_DURATION_BASE
				if _defuse_timer >= duration:
					_complete_defuse()
		else:
			_bomb_countdown -= delta
			var sec := int(_bomb_countdown)
			if sec != _last_logged_second:
				_last_logged_second = sec
				if sec <= 10:
					print("💣 [%s] Взрыв через %d..." % [site_id, sec])
				elif sec in [20, 30]:
					print("💣 [%s] Взрыв через %d секунд" % [site_id, sec])
			if _bomb_countdown <= 0.0:
				_explode()

func begin_plant(bot_id: int) -> void:
	if bomb_planted or _is_planting:
		return
	_is_planting = true
	_plant_timer = 0.0
	_planting_bot_id = bot_id
	_spawn_bomb_visual()
	set_process(true)
	emit_signal("plant_started", site_id, bot_id)

func cancel_plant() -> void:
	_is_planting = false
	_plant_timer = 0.0
	_planting_bot_id = -1
	if not bomb_planted:
		_remove_bomb_visual()
		set_process(false)

func begin_defuse(bot_id: int) -> void:
	if not bomb_planted or _is_defusing or bomb_exploded_flag:
		return
	_is_defusing = true
	_defuse_timer = 0.0
	_defusing_bot_id = bot_id
	set_process(true)
	print("🔧 [%s] Дефуз начат (бот %d)" % [site_id, bot_id])
	emit_signal("defuse_started", site_id, bot_id)

func cancel_defuse() -> void:
	_is_defusing = false
	_defuse_timer = 0.0
	_defusing_bot_id = -1
	print("❌ [%s] Дефуз прерван" % site_id)

func cancel_defuse_by(bot_id: int) -> void:
	if _defusing_bot_id == bot_id:
		cancel_defuse()

func _ready() -> void:
	add_to_group("bombsites")
	set_process(false)

func reset() -> void:
	bomb_planted = false
	bomb_exploded_flag = false
	_is_planting = false
	_is_defusing = false
	_plant_timer = 0.0
	_defuse_timer = 0.0
	_bomb_countdown = 0.0
	_planting_bot_id = -1
	_defusing_bot_id = -1
	_remove_bomb_visual()
	set_process(false)

func _complete_plant() -> void:
	_is_planting = false
	bomb_planted = true
	_bomb_countdown = BOMB_TIMER
	_last_logged_second = int(BOMB_TIMER)
	_set_bomb_visual_planted()
	set_process(true)
	print("💣 БОМБА ПОСТАВЛЕНА на сайте %s! (40 сек)" % site_id)
	emit_signal("plant_completed", site_id)

func _complete_defuse() -> void:
	_is_defusing = false
	bomb_planted = false
	set_process(false)
	print("✅ БОМБА РАЗМИНИРОВАНА на сайте %s!" % site_id)
	emit_signal("defuse_completed", site_id)

func _explode() -> void:
	bomb_exploded_flag = true
	print("💥 БОМБА ВЗОРВАЛАСЬ на сайте %s!" % site_id)
	emit_signal("bomb_exploded", site_id)

func _has_defuse_kit(bot_id: int) -> bool:
	for bot in get_tree().get_nodes_in_group("ct_bots"):
		if bot is BotBrain and bot.stats.bot_id == bot_id:
			return bot.stats.has_defuse_kit
	return false

func contains_point(pos: Vector3) -> bool:
	var shape_node: CollisionShape3D = get_node_or_null("CollisionShape3D")
	if shape_node == null or shape_node.shape == null:
		return false
	var box := shape_node.shape as BoxShape3D
	if box == null:
		return false
	var local: Vector3 = to_local(pos)
	var ext: Vector3 = box.size * 0.5
	return abs(local.x) <= ext.x and abs(local.z) <= ext.z

func _find_planter(id: int) -> BotBrain:
	for bot in get_tree().get_nodes_in_group("t_bots"):
		if bot is BotBrain and bot.stats.bot_id == id:
			return bot
	return null

func _find_defuser(id: int) -> BotBrain:
	for bot in get_tree().get_nodes_in_group("ct_bots"):
		if bot is BotBrain and bot.stats.bot_id == id:
			return bot
	return null

# ── Визуал бомбы ─────────────────────────────────────────────────────────────

func _spawn_bomb_visual() -> void:
	if _bomb_mesh:
		return
	_bomb_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	_bomb_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.1, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.0)
	mat.emission_energy_multiplier = 2.0
	_bomb_mesh.material_override = mat
	_bomb_mesh.position = Vector3(0, 0.3, 0)
	add_child(_bomb_mesh)

# t=[0..1] — прогресс установки: мигаем чаще по мере завершения
func _update_bomb_visual_plant(t: float) -> void:
	if not _bomb_mesh:
		return
	var pulse: float = abs(sin(t * PI * 6.0))
	var mat := _bomb_mesh.material_override as StandardMaterial3D
	if mat:
		mat.emission_energy_multiplier = lerp(1.0, 6.0, pulse)

func _set_bomb_visual_planted() -> void:
	if not _bomb_mesh:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.0, 0.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.0, 0.0)
	mat.emission_energy_multiplier = 8.0
	_bomb_mesh.material_override = mat

func _remove_bomb_visual() -> void:
	if _bomb_mesh:
		_bomb_mesh.queue_free()
		_bomb_mesh = null
