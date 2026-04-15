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

func _process(delta: float) -> void:
	if _is_planting:
		_plant_timer += delta
		if _plant_timer >= PLANT_DURATION:
			_complete_plant()

	if bomb_planted and not bomb_exploded_flag:
		if _is_defusing:
			_defuse_timer += delta
			var duration = DEFUSE_DURATION_WITH_KIT if _has_defuse_kit(_defusing_bot_id) else DEFUSE_DURATION_BASE
			if _defuse_timer >= duration:
				_complete_defuse()
		else:
			_bomb_countdown -= delta
			if _bomb_countdown <= 0.0:
				_explode()

func begin_plant(bot_id: int) -> void:
	if bomb_planted or _is_planting:
		return
	_is_planting = true
	_plant_timer = 0.0
	_planting_bot_id = bot_id
	emit_signal("plant_started", site_id, bot_id)

func cancel_plant() -> void:
	_is_planting = false
	_plant_timer = 0.0
	_planting_bot_id = -1

func begin_defuse(bot_id: int) -> void:
	if not bomb_planted or _is_defusing or bomb_exploded_flag:
		return
	_is_defusing = true
	_defuse_timer = 0.0
	_defusing_bot_id = bot_id
	emit_signal("defuse_started", site_id, bot_id)

func cancel_defuse() -> void:
	_is_defusing = false
	_defuse_timer = 0.0
	_defusing_bot_id = -1

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
	set_process(false)

func _complete_plant() -> void:
	_is_planting = false
	bomb_planted = true
	_bomb_countdown = BOMB_TIMER
	set_process(true)
	emit_signal("plant_completed", site_id)

func _complete_defuse() -> void:
	_is_defusing = false
	bomb_planted = false
	emit_signal("defuse_completed", site_id)

func _explode() -> void:
	bomb_exploded_flag = true
	emit_signal("bomb_exploded", site_id)

func _has_defuse_kit(bot_id: int) -> bool:
	for bot in get_tree().get_nodes_in_group("ct_bots"):
		if bot is BotBrain and bot.stats.bot_id == bot_id:
			return bot.stats.has_defuse_kit
	return false
