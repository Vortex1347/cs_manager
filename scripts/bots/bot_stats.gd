# bot_stats.gd
# Статы бота: хранит параметры, влияющие на поведение AI.
# Зависимости: нет (Resource, сериализуется для системы улучшений)

extends Resource
class_name BotStats

enum Team { CT, T }

const MAX_HP: int = 100
const MAX_AIM_LEVEL: int = 10
const MIN_AIM_LEVEL: int = 1
const MIN_REACTION_TIME: float = 0.1
const MAX_REACTION_TIME: float = 1.5

@export var bot_id: int = 0
@export var team: Team = Team.CT
@export var display_name: String = "Bot"

# --- Основные статы (влияют на AI) ---
@export_range(1, 10) var aim_level: int = 3
@export var reaction_time: float = 0.8      # секунды до первого выстрела
@export_range(1, 10) var game_sense: int = 3 # позиционирование, холд углов
@export_range(0.0, 1.0) var aggression: float = 0.5  # 0=пассивный, 1=агрессивный

# --- Здоровье ---
@export var max_hp: int = MAX_HP
var current_hp: int = MAX_HP

# --- Для системы улучшений ---
@export var upgrade_cost_aim: int = 2
@export var upgrade_cost_reaction: int = 3
@export var upgrade_cost_sense: int = 2

func reset_hp() -> void:
	current_hp = max_hp

func take_damage(amount: int) -> void:
	current_hp = max(0, current_hp - amount)

func is_dead() -> bool:
	return current_hp <= 0

# Возвращает порог отступления: доля HP при которой бот отступает
func get_retreat_threshold() -> float:
	return 0.35 - aggression * 0.25

# Длительность памяти о последней позиции врага (сек)
func get_memory_duration() -> float:
	return 2.0 + game_sense * 0.3

# Время ожидания на вейпоинте с холдом угла (сек)
func get_angle_dwell_time() -> float:
	return 0.5 + (game_sense - 1) * (3.5 / 9.0)

# Угол разброса в градусах
func get_spread_angle() -> float:
	return 10.0 * pow(0.9, aim_level - 1)
