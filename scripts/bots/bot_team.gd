# bot_team.gd
# Командный менеджер: блэкборд, сигналы между ботами, тактические решения.
# Зависимости: bot_brain.gd, bot_stats.gd

extends Node
class_name BotTeam

signal team_enemy_sighted(enemy_id: int, last_known_pos: Vector3)
signal suppression_assigned(assignee_id: int, target_pos: Vector3)
signal strategy_changed(new_strategy: int)
signal rotate_to_site(site_name: String, count: int)
signal all_bots_dead()

enum TeamStrategy { DEFAULT, RUSH_A, RUSH_B, SPLIT, ECO }

const ROTATION_ENEMY_THRESHOLD: int = 3  # столько врагов на сайте → ротируем
const FRAG_CLUSTER_RADIUS: float = 4.0

var bots: Dictionary = {}           # bot_id → BotBrain
var blackboard: Dictionary = {
	"spotted_enemies": {},           # enemy_id → {position, last_seen_time, confidence}
	"bomb_planted": false,
	"bomb_site": "",
	"strategy": TeamStrategy.DEFAULT,
	"active_count": 5,
}
var current_strategy: TeamStrategy = TeamStrategy.DEFAULT
var _rotation_timer: float = 0.0
var _rotation_cooldown: float = 3.0

func _process(delta: float) -> void:
	_decay_blackboard_confidence(delta)
	_rotation_timer -= delta
	if _rotation_timer <= 0.0:
		_evaluate_rotation()
		_rotation_timer = _rotation_cooldown

func register_bot(brain: BotBrain) -> void:
	bots[brain.stats.bot_id] = brain
	brain.enemy_spotted.connect(_on_enemy_spotted)
	brain.enemy_lost.connect(_on_enemy_lost)
	brain.requesting_suppression.connect(_on_suppression_requested)
	brain.bot_died.connect(_on_bot_died)

func set_strategy(strategy: TeamStrategy) -> void:
	current_strategy = strategy
	blackboard["strategy"] = strategy
	emit_signal("strategy_changed", strategy)

func get_active_count() -> int:
	return blackboard["active_count"]

func get_average_game_sense() -> float:
	if bots.is_empty():
		return 1.0
	var total = 0.0
	for brain in bots.values():
		total += brain.stats.game_sense
	return total / bots.size()

# ── Сигналы от ботов ────────────────────────────────────────────────────────

func _on_enemy_spotted(reporter_id: int, enemy_id: int, pos: Vector3) -> void:
	blackboard["spotted_enemies"][enemy_id] = {
		"position": pos,
		"last_seen_time": Time.get_ticks_msec() / 1000.0,
		"reported_by": reporter_id,
		"confidence": 1.0
	}
	emit_signal("team_enemy_sighted", enemy_id, pos)
	# Оповещаем остальных ботов
	for bot_id in bots:
		if bot_id != reporter_id:
			bots[bot_id].receive_team_intel(enemy_id, pos)

func _on_enemy_lost(reporter_id: int, enemy_id: int) -> void:
	if enemy_id in blackboard["spotted_enemies"]:
		blackboard["spotted_enemies"][enemy_id]["confidence"] *= 0.5

func _on_suppression_requested(reporter_id: int, pos: Vector3, priority: float) -> void:
	# Ищем свободного бота для прикрытия
	var best_id: int = -1
	var best_dist: float = INF
	for bot_id in bots:
		if bot_id == reporter_id:
			continue
		var brain: BotBrain = bots[bot_id]
		if brain.current_state == BotBrain.BotState.DEAD:
			continue
		var d = brain.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best_id = bot_id
	if best_id != -1:
		emit_signal("suppression_assigned", best_id, pos)

func _on_bot_died(bot_id: int, _killer_id: int) -> void:
	blackboard["active_count"] = max(0, blackboard["active_count"] - 1)
	if blackboard["active_count"] == 0:
		emit_signal("all_bots_dead")

# ── Ротация CT ───────────────────────────────────────────────────────────────

func _evaluate_rotation() -> void:
	var a_count = _count_enemies_near_site("A")
	var b_count = _count_enemies_near_site("B")
	var avg_sense = get_average_game_sense()
	_rotation_cooldown = 3.0 - avg_sense * 0.2

	if a_count >= ROTATION_ENEMY_THRESHOLD and b_count == 0:
		var rotate_count = 1 if get_active_count() <= 3 else 2
		emit_signal("rotate_to_site", "A", rotate_count)
	elif b_count >= ROTATION_ENEMY_THRESHOLD and a_count == 0:
		var rotate_count = 1 if get_active_count() <= 3 else 2
		emit_signal("rotate_to_site", "B", rotate_count)

func _count_enemies_near_site(site: String) -> int:
	var site_pos = Vector3(-20, 0, 15) if site == "A" else Vector3(20, 0, 15)
	var count = 0
	for entry in blackboard["spotted_enemies"].values():
		if entry["confidence"] > 0.3:
			if entry["position"].distance_to(site_pos) < 12.0:
				count += 1
	return count

# ── Блэкборд ─────────────────────────────────────────────────────────────────

func _decay_blackboard_confidence(delta: float) -> void:
	for enemy_id in blackboard["spotted_enemies"]:
		blackboard["spotted_enemies"][enemy_id]["confidence"] -= delta * 0.1
	# Чистим старые записи
	var to_remove = []
	for enemy_id in blackboard["spotted_enemies"]:
		if blackboard["spotted_enemies"][enemy_id]["confidence"] <= 0.0:
			to_remove.append(enemy_id)
	for enemy_id in to_remove:
		blackboard["spotted_enemies"].erase(enemy_id)

func on_bomb_planted(site: String) -> void:
	blackboard["bomb_planted"] = true
	blackboard["bomb_site"] = site

func on_round_reset() -> void:
	blackboard["spotted_enemies"].clear()
	blackboard["bomb_planted"] = false
	blackboard["bomb_site"] = ""
	blackboard["active_count"] = bots.size()
