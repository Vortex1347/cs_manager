# bot_observer.gd
# Вычисляет observation vector (27 float, [0..1]) для RL-агента.
# Не использует абсолютные координаты → работает на любой карте.
# Зависимости: bot_brain.gd, bomb_controller.gd, bombsite.gd

extends Node
class_name BotObserver

const RAY_MAX_DIST: float = 15.0
const ENEMY_MAX_DIST: float = 40.0
const SITE_MAX_DIST: float = 60.0
const TEAMMATE_MAX_DIST: float = 60.0
const WALL_LAYER: int = 1

func get_obs(bot: BotBrain) -> PackedFloat32Array:
	var o = PackedFloat32Array()

	# 0-4: состояние
	o.append(float(bot.stats.current_hp) / float(bot.stats.max_hp))
	o.append(clamp(float(bot.stats.armor) / 100.0, 0.0, 1.0))
	o.append(1.0 if bot._is_bomb_carrier else 0.0)
	o.append(1.0 if _bomb_planted() else 0.0)
	o.append(_bomb_timer_ratio())

	# 5-12: 8 рейкастов по 45° вокруг бота (локальная геометрия карты)
	for i in range(8):
		var local_angle = i * PI / 4.0
		var world_dir = Vector3(sin(local_angle), 0.0, cos(local_angle)) \
			.rotated(Vector3.UP, bot.rotation.y)
		o.append(_ray_normalized(bot, world_dir))

	# 13-15: ближайший видимый враг
	var enemy = _nearest_visible_enemy(bot)
	if enemy:
		var d: Vector3 = enemy.global_position - bot.global_position
		d.y = 0.0
		var rel = fmod((atan2(d.x, d.z) - bot.rotation.y) / TAU + 1.0, 1.0)
		o.append(1.0)
		o.append(rel)
		o.append(min(d.length() / ENEMY_MAX_DIST, 1.0))
	else:
		o.append_array([0.0, 0.0, 0.0])

	# 16-17: ближайший сайт (цель)
	var site = _nearest_site(bot)
	if site:
		var d: Vector3 = site.global_position - bot.global_position
		d.y = 0.0
		var rel = fmod((atan2(d.x, d.z) - bot.rotation.y) / TAU + 1.0, 1.0)
		o.append(rel)
		o.append(min(d.length() / SITE_MAX_DIST, 1.0))
	else:
		o.append_array([0.0, 0.0])

	# 18-19: скорость (нормирована)
	o.append(clamp(bot.velocity.x / 5.0, -1.0, 1.0) * 0.5 + 0.5)
	o.append(clamp(bot.velocity.z / 5.0, -1.0, 1.0) * 0.5 + 0.5)

	# 20: teammate_has_bomb (кроме самого бота)
	o.append(1.0 if _teammate_has_bomb(bot) else 0.0)

	# 21-26: два ближайших живых тиммейта (angle, dist, hp)
	var mates = _nearest_teammates(bot, 2)
	for i in range(2):
		if i < mates.size():
			var mate: BotBrain = mates[i]
			var d: Vector3 = mate.global_position - bot.global_position
			d.y = 0.0
			var rel = fmod((atan2(d.x, d.z) - bot.rotation.y) / TAU + 1.0, 1.0)
			o.append(rel)
			o.append(min(d.length() / TEAMMATE_MAX_DIST, 1.0))
			o.append(float(mate.stats.current_hp) / float(mate.stats.max_hp))
		else:
			o.append_array([0.0, 1.0, 0.0])

	assert(o.size() == 27, "BotObserver: неверный размер observation: %d" % o.size())
	return o

# ── Helpers ──────────────────────────────────────────────────────────────────

func _ray_normalized(bot: BotBrain, dir: Vector3) -> float:
	var from = bot.global_position + Vector3(0, 0.9, 0)
	var to = from + dir * RAY_MAX_DIST
	var space = bot.get_world_3d().direct_space_state
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [bot]
	q.collision_mask = WALL_LAYER
	var hit = space.intersect_ray(q)
	if hit.is_empty():
		return 1.0
	return hit["position"].distance_to(from) / RAY_MAX_DIST

func _nearest_visible_enemy(bot: BotBrain) -> BotBrain:
	if not bot.visible_enemies.is_empty():
		return bot.visible_enemies[0]
	return null

func _nearest_site(bot: BotBrain) -> Node:
	var best: Node = null
	var best_d = INF
	for site in bot.get_tree().get_nodes_in_group("bombsites"):
		var d = bot.global_position.distance_to(site.global_position)
		if d < best_d:
			best_d = d
			best = site
	return best

func _bomb_planted() -> bool:
	var bomb = _get_bomb_controller()
	return bomb != null and bomb.is_planted()

func _bomb_timer_ratio() -> float:
	var bomb = _get_bomb_controller()
	return bomb.get_countdown_ratio() if bomb else 0.0

func _teammate_has_bomb(bot: BotBrain) -> bool:
	var parent = bot.get_parent()
	if parent == null:
		return false
	for other in parent.get_children():
		if other == bot:
			continue
		if other is BotBrain and other._is_bomb_carrier:
			return true
	return false

func _nearest_teammates(bot: BotBrain, count: int) -> Array:
	var parent = bot.get_parent()
	if parent == null:
		return []
	var mates: Array = []
	for other in parent.get_children():
		if other == bot or not (other is BotBrain):
			continue
		if not other._is_live or other.current_state == BotBrain.BotState.DEAD:
			continue
		mates.append(other)
	mates.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(bot.global_position) \
			< b.global_position.distance_squared_to(bot.global_position))
	return mates.slice(0, count)

func _get_bomb_controller():
	var controllers = get_tree().get_nodes_in_group("bomb_controller")
	if controllers.is_empty():
		return null
	return controllers[0]
