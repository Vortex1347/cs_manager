# game_manager.gd
# Главный контроллер игры. Держит ссылки на команды, RoundManager, Economy.
# Зависимости: round_manager.gd, bot_team.gd (через дочерние узлы)

extends Node3D

signal match_started()
signal match_ended(winner_team: String)
signal pause_toggled(is_paused: bool)

const ROUNDS_TO_WIN: int = 9999
const MAX_ROUNDS: int = 99999

@export var map_scene: PackedScene
@export var bot_scene: PackedScene

@onready var round_manager: Node = $RoundManager
@onready var economy: Node = $Economy
@onready var team_ct: Node = $TeamCT
@onready var team_t: Node = $TeamT
@onready var box_map: Node3D = $BoxMap
var team_ct_script: BotTeam
var team_t_script: BotTeam
@onready var camera: Camera3D = $MainCamera
@onready var hud: CanvasLayer = $HUD

var score_ct: int = 0
var score_t: int = 0
var is_paused: bool = false
var match_active: bool = false

# RL: опциональный сервер для Python-обучения (null = обычный FSM режим)
@export var rl_training_mode: bool = false
var _rl_server: RLServer = null
var _prev_goal_dist: Dictionary = {}   # bot_id → предыдущая дистанция до цели (shaping)

func _ready() -> void:
	_ensure_team_scripts()
	_assign_bot_stats()
	_setup_bots()
	if rl_training_mode:
		_rl_server = RLServer.new()
		add_child(_rl_server)
		print("GameManager: RL training mode ON — порт 9002")
	_wire_systems()
	if rl_training_mode:
		_enable_rl_on_bots()
	# Ждём пока nav_baker запечёт NavMesh (2 кадра + запас)
	await get_tree().create_timer(0.5).timeout
	start_match()

func _setup_bots() -> void:
	var patrol_root: Node3D = box_map.get_node_or_null("PatrolPoints") if box_map else null
	if not patrol_root:
		return

	var ct_a_wps:   Array[Vector3] = _load_waypoints(patrol_root, "CT_SiteA_%d", 6)
	var ct_mida_wps: Array[Vector3] = _load_waypoints(patrol_root, "CT_MidA_%d", 6)
	var ct_b_wps:   Array[Vector3] = _load_waypoints(patrol_root, "CT_SiteB_%d", 6)
	var t_a_wps:    Array[Vector3] = _load_waypoints(patrol_root, "T_RushA_%d", 6)
	var t_mida_wps: Array[Vector3] = _load_waypoints(patrol_root, "T_MidA_%d", 6)
	var t_b_wps:    Array[Vector3] = _load_waypoints(patrol_root, "T_RushB_%d", 6)

	# CT: 0-1=A long, 2=mid к A, 3-4=B long
	var ct_idx: int = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		if ct_idx < 2:
			bot.set_patrol_waypoints(ct_a_wps)
		elif ct_idx == 2:
			bot.set_patrol_waypoints(ct_mida_wps)
		else:
			bot.set_patrol_waypoints(ct_b_wps)
		ct_idx += 1

	# T: 0-1=A long (носитель среди них), 2=mid к A, 3-4=B long
	var t_idx: int = 0
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		if t_idx < 2:
			bot.set_patrol_waypoints(t_a_wps)
		elif t_idx == 2:
			bot.set_patrol_waypoints(t_mida_wps)
		else:
			bot.set_patrol_waypoints(t_b_wps)
		t_idx += 1

	# CT ждут угрозу с севера (z < 0 — сторона T)
	for bot in team_ct.get_children():
		if bot.has_method("set_threat_direction"):
			bot.set_threat_direction(Vector3(0, 0, -1))
	# T ждут угрозу с юга (z > 0 — сторона CT)
	for bot in team_t.get_children():
		if bot.has_method("set_threat_direction"):
			bot.set_threat_direction(Vector3(0, 0, 1))

func _load_waypoints(root: Node3D, pattern: String, count: int) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for i in range(1, count + 1):
		var m = root.get_node_or_null(pattern % i)
		if m:
			result.append(m.global_position)
	return result

func _wire_systems() -> void:
	var all_ids: Array = []

	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		team_ct_script.register_bot(bot)  # register_bot уже подключает bot_died → BotTeam._on_bot_died
		bot.bot_died.connect(_on_bot_died) # game_manager слушает отдельно (экономика + бомба)
		all_ids.append(bot.stats.bot_id)

	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		team_t_script.register_bot(bot)
		bot.bot_died.connect(_on_bot_died)
		all_ids.append(bot.stats.bot_id)

	economy.initialize(all_ids)

	round_manager.round_started.connect(_on_round_started)
	round_manager.round_ended.connect(_on_round_ended)
	round_manager.round_ended.connect(_on_round_ended_economy)
	round_manager.time_updated.connect(_on_time_updated)
	round_manager.phase_changed.connect(_on_phase_changed)

	if rl_training_mode:
		for bot in team_ct.get_children():
			if bot.has_method("start_round"):
				bot.bot_died.connect(_on_bot_died_rl)
		for bot in team_t.get_children():
			if bot.has_method("start_round"):
				bot.bot_died.connect(_on_bot_died_rl)
		round_manager.round_ended.connect(_on_round_ended_rl)

	team_ct_script.all_bots_dead.connect(func(): round_manager.end_round("T", "elimination"))
	team_t_script.all_bots_dead.connect(func(): round_manager.end_round("CT", "elimination"))

	# Подключить бомбсайты
	for site_path in ["Zones/ZoneSiteA", "Zones/ZoneSiteB"]:
		var site = box_map.get_node_or_null(site_path) if box_map else null
		if not site:
			continue
		site.plant_started.connect(func(sid, _bid): _set_bomb_status("💣 Сажают бомбу на %s..." % sid))
		site.plant_completed.connect(func(sid):
			economy.reward_plant(_get_bomb_carrier_id())
			_notify_bomb_planted(site.global_position)
			_set_bomb_status("💣 БОМБА НА САЙТЕ %s!" % sid)
			if self._rl_server:
				self._rl_server.add_reward(_get_bomb_carrier_id(), 5.0)
		)
		site.defuse_started.connect(func(sid, _bid): _set_bomb_status("🔧 Дефузят на %s..." % sid))
		site.defuse_completed.connect(func(sid):
			economy.reward_defuse(_get_defuser_id())
			round_manager.end_round("CT", "defused")
			_set_bomb_status("✅ РАЗМИНИРОВАНО")
			if self._rl_server:
				self._rl_server.add_reward(_get_defuser_id(), 8.0)
		)
		site.bomb_exploded.connect(func(sid):
			round_manager.end_round("T", "bomb_exploded")
			_set_bomb_status("💥 ВЗРЫВ НА %s!" % sid)
		)

	# HP всех ботов → HUD
	for bot in team_ct.get_children() + team_t.get_children():
		if bot.has_method("start_round"):
			bot.damage_taken.connect(func(_id, _amt, _src): _update_hud_health())
	_update_hud_health()

func _ensure_team_scripts() -> void:
	# Если на узлах TeamCT/TeamT нет bot_team.gd — создаём дочерний узел со скриптом
	team_ct_script = team_ct.get_node_or_null("BotTeamScript")
	if team_ct_script == null:
		team_ct_script = BotTeam.new()
		team_ct_script.name = "BotTeamScript"
		team_ct.add_child(team_ct_script)

	team_t_script = team_t.get_node_or_null("BotTeamScript")
	if team_t_script == null:
		team_t_script = BotTeam.new()
		team_t_script.name = "BotTeamScript"
		team_t.add_child(team_t_script)

func _assign_bot_stats() -> void:
	var ct_id: int = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		var s := BotStats.new()
		s.bot_id = ct_id
		s.team = BotStats.Team.CT
		s.display_name = "CT_%d" % ct_id
		s.aim_level      = randi_range(4, 7)
		s.reaction_time  = randf_range(0.3, 0.6)
		s.game_sense     = randi_range(3, 6)
		s.aggression     = randf_range(0.3, 0.6)
		bot.stats = s
		ct_id += 1

	var t_id: int = 10
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		var s := BotStats.new()
		s.bot_id = t_id
		s.team = BotStats.Team.T
		s.display_name = "T_%d" % (t_id - 10)
		s.aim_level      = randi_range(4, 7)
		s.reaction_time  = randf_range(0.4, 0.7)
		s.game_sense     = randi_range(3, 6)
		s.aggression     = randf_range(0.4, 0.7)
		bot.stats = s
		t_id += 1

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and match_active:
		toggle_pause()

func start_match() -> void:
	score_ct = 0
	score_t = 0
	match_active = true
	emit_signal("match_started")
	round_manager.start_round()

func toggle_pause() -> void:
	is_paused = !is_paused
	get_tree().paused = is_paused
	emit_signal("pause_toggled", is_paused)

func _on_round_started(_round_num: int) -> void:
	var spawn_root = box_map.get_node_or_null("SpawnPoints") if box_map else null
	team_ct_script.on_round_reset()
	team_t_script.on_round_reset()

	# Сброс бомбсайтов
	for site_path in ["Zones/ZoneSiteA", "Zones/ZoneSiteB"]:
		var s = box_map.get_node_or_null(site_path) if box_map else null
		if s:
			s.reset()

	_set_bomb_status("")
	_update_hud_health()

	var ct_idx: int = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		bot.add_to_group("ct_bots")
		if spawn_root:
			var m = spawn_root.get_node_or_null("CT_Spawn_%d" % (ct_idx + 1))
			if m:
				bot.global_position = m.global_position
		bot.start_round()
		ct_idx += 1

	var t_idx: int = 0
	var bomb_assigned: bool = false
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		bot.add_to_group("t_bots")
		if spawn_root:
			var m = spawn_root.get_node_or_null("T_Spawn_%d" % (t_idx + 1))
			if m:
				bot.global_position = m.global_position
		bot.start_round()
		# Назначаем после start_round() — иначе start_round сбросит флаг
		if not bomb_assigned and bot.has_method("set_bomb_carrier"):
			bot.set_bomb_carrier(true)
			bomb_assigned = true
		t_idx += 1

func _on_bot_died(bot_id: int, killer_id: int) -> void:
	if killer_id >= 0:
		economy.reward_kill(killer_id)
	_check_bomb_carrier_died(bot_id)

func _on_round_ended_economy(winner: String, _reason: String) -> void:
	var ct_ids: Array = []
	var t_ids: Array = []
	for bot in team_ct.get_children():
		if bot.has_method("start_round"):
			ct_ids.append(bot.stats.bot_id)
	for bot in team_t.get_children():
		if bot.has_method("start_round"):
			t_ids.append(bot.stats.bot_id)
	economy.reward_round_end(winner, ct_ids, t_ids)

func _on_time_updated(secs: float) -> void:
	if hud and hud.has_method("update_timer"):
		hud.update_timer(secs)

func _on_phase_changed(phase: int) -> void:
	if phase == 0:  # BUY_PHASE
		_do_auto_buy()
	elif phase == 1:  # LIVE
		for bot in team_ct.get_children():
			if bot.has_method("begin_live_phase"):
				bot.begin_live_phase()
		for bot in team_t.get_children():
			if bot.has_method("begin_live_phase"):
				bot.begin_live_phase()
	elif phase == 2:  # ROUND_END — сразу замораживаем всех
		for bot in team_ct.get_children():
			if bot.has_method("freeze_bot"):
				bot.freeze_bot()
		for bot in team_t.get_children():
			if bot.has_method("freeze_bot"):
				bot.freeze_bot()
	if hud and hud.has_method("update_phase"):
		hud.update_phase(phase)

func _do_auto_buy() -> void:
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		var items = economy.auto_buy(bot.stats.bot_id, economy.get_money(bot.stats.bot_id), "CT")
		_apply_loadout(bot, items)
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		var items = economy.auto_buy(bot.stats.bot_id, economy.get_money(bot.stats.bot_id), "T")
		_apply_loadout(bot, items)

func _apply_loadout(bot: Node, items: Array) -> void:
	var weapon_node = bot.get_node_or_null("Weapon")
	if not weapon_node:
		return
	for item in items:
		match item:
			"rifle":      weapon_node.set_weapon_type(Weapon.WeaponType.RIFLE)
			"smg":        weapon_node.set_weapon_type(Weapon.WeaponType.SMG)
			"pistol":     weapon_node.set_weapon_type(Weapon.WeaponType.PISTOL)
			"armor":      bot.stats.armor = 100
			"defuse_kit": bot.stats.has_defuse_kit = true

func _check_bomb_carrier_died(dead_id: int) -> void:
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		if bot.stats.bot_id != dead_id:
			continue
		if not bot._is_bomb_carrier:
			return
		var drop_pos: Vector3 = bot.global_position
		bot._is_bomb_carrier = false
		# Передать бомбу ближайшему живому T
		var nearest = _find_nearest_alive_t(drop_pos, dead_id)
		if nearest:
			nearest.go_pick_up_bomb(drop_pos)
		# CT бегут к позиции упавшей бомбы
		for ct in team_ct.get_children():
			if ct.has_method("on_bomb_dropped"):
				ct.on_bomb_dropped(drop_pos)
		return

func _find_nearest_alive_t(pos: Vector3, exclude_id: int) -> Node:
	var best: Node = null
	var best_dist: float = INF
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		if bot.stats.bot_id == exclude_id:
			continue
		if bot.stats.is_dead():
			continue
		var d = bot.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = bot
	return best

func _notify_bomb_planted(site_pos: Vector3) -> void:
	for bot in team_ct.get_children():
		if bot.has_method("start_round") and bot.has_method("on_bomb_planted"):
			bot.on_bomb_planted(site_pos)
	for bot in team_t.get_children():
		if bot.has_method("start_round") and bot.has_method("on_bomb_planted"):
			bot.on_bomb_planted(site_pos)

func _get_bomb_carrier_id() -> int:
	for bot in team_t.get_children():
		if bot.has_method("set_bomb_carrier") and bot._is_bomb_carrier:
			return bot.stats.bot_id
	return -1

func _get_defuser_id() -> int:
	for bot in team_ct.get_children():
		if bot.has_method("start_round") and bot.stats.is_dead() == false:
			return bot.stats.bot_id
	return -1

func _on_round_ended(winner: String, _reason: String) -> void:
	if winner == "CT":
		score_ct += 1
	elif winner == "T":
		score_t += 1
	if hud and hud.has_method("update_score"):
		hud.update_score(score_ct, score_t)

	if score_ct >= ROUNDS_TO_WIN:
		_end_match("CT")
	elif score_t >= ROUNDS_TO_WIN:
		_end_match("T")
	elif score_ct + score_t >= MAX_ROUNDS:
		_end_match("DRAW")
	else:
		# Небольшая пауза между раундами
		await get_tree().create_timer(3.0).timeout
		round_manager.start_round()

func _update_hud_health() -> void:
	if not hud or not hud.has_method("update_bot_health"):
		return
	var ct_hps: Array = []
	var t_hps: Array = []
	for bot in team_ct.get_children():
		if bot.has_method("start_round"):
			ct_hps.append(bot.stats.current_hp)
	for bot in team_t.get_children():
		if bot.has_method("start_round"):
			t_hps.append(bot.stats.current_hp)
	hud.update_bot_health(ct_hps, t_hps)

func _set_bomb_status(text: String) -> void:
	if hud and hud.has_method("update_bomb_status"):
		hud.update_bomb_status(text)

func _end_match(winner: String) -> void:
	match_active = false
	emit_signal("match_ended", winner)

# ── RL методы ────────────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	if _rl_server and _rl_server.is_connected:
		var all_bots: Array = []
		for bot in team_ct.get_children():
			if bot.has_method("start_round"):
				all_bots.append(bot)
		for bot in team_t.get_children():
			if bot.has_method("start_round"):
				all_bots.append(bot)
		_shape_rewards(all_bots)
		_rl_server.send_step(all_bots)

# Dense reward shaping — небольшая награда за приближение к цели (раз в кадр).
# T-carrier → идёт к ближайшему сайту. CT после plant → бежит к заложенной бомбе.
func _shape_rewards(all_bots: Array) -> void:
	var planted_site: Node = null
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site.bomb_planted and not site.bomb_exploded_flag:
			planted_site = site
			break
	for bot in all_bots:
		if not bot._is_live or bot.current_state == BotBrain.BotState.DEAD:
			continue
		var bid: int = bot.stats.bot_id
		var goal_pos: Vector3 = Vector3.ZERO
		if planted_site and bot.stats.team == BotStats.Team.CT:
			goal_pos = planted_site.global_position
		elif bot._is_bomb_carrier and bot.stats.team == BotStats.Team.T:
			var nearest: Node = null
			var best_d: float = INF
			for site2 in get_tree().get_nodes_in_group("bombsites"):
				if site2.bomb_planted: continue
				var dd: float = bot.global_position.distance_to(site2.global_position)
				if dd < best_d:
					best_d = dd
					nearest = site2
			if nearest:
				goal_pos = nearest.global_position
		if goal_pos == Vector3.ZERO:
			_prev_goal_dist.erase(bid)
			continue
		var cur_d: float = bot.global_position.distance_to(goal_pos)
		if _prev_goal_dist.has(bid):
			var delta_d: float = _prev_goal_dist[bid] - cur_d
			# Шейпинг: +0.01 за каждый метр приближения (около 0.04/кадр на скорости 4)
			if delta_d > 0.0:
				_rl_server.add_reward(bid, delta_d * 0.01)
		_prev_goal_dist[bid] = cur_d

func _enable_rl_on_bots() -> void:
	for bot in team_ct.get_children():
		if bot.has_method("enable_rl_mode"):
			bot.enable_rl_mode(_rl_server)
	for bot in team_t.get_children():
		if bot.has_method("enable_rl_mode"):
			bot.enable_rl_mode(_rl_server)

func _on_bot_died_rl(bot_id: int, killer_id: int) -> void:
	if not _rl_server:
		return
	_rl_server.add_reward(bot_id, -1.0)
	if killer_id >= 0:
		_rl_server.add_reward(killer_id, 2.0)  # убийца получает +2
	_rl_server.set_done(bot_id)

func _on_round_ended_rl(winner: String, _reason: String) -> void:
	if not _rl_server:
		return
	var ct_ids: Array = []
	var t_ids: Array = []
	for bot in team_ct.get_children():
		if bot.has_method("start_round"):
			ct_ids.append(bot.stats.bot_id)
	for bot in team_t.get_children():
		if bot.has_method("start_round"):
			t_ids.append(bot.stats.bot_id)
	var win_ids := ct_ids if winner == "CT" else t_ids
	var lose_ids := t_ids if winner == "CT" else ct_ids
	for id in win_ids:
		_rl_server.add_reward(id, 3.0)
	for id in lose_ids:
		_rl_server.set_done(id)
	for id in win_ids:
		_rl_server.set_done(id)
