# game_manager.gd
# Главный контроллер игры. Держит ссылки на команды, RoundManager, Economy.
# Зависимости: round_manager.gd, bot_team.gd (через дочерние узлы)

extends Node3D

signal match_started()
signal match_ended(winner_team: String)
signal pause_toggled(is_paused: bool)

const ROUNDS_TO_WIN: int = 16
const MAX_ROUNDS: int = 30

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

func _ready() -> void:
	_ensure_team_scripts()
	_assign_bot_stats()
	_setup_bots()
	_wire_systems()
	# Ждём пока nav_baker запечёт NavMesh (2 кадра + запас)
	await get_tree().create_timer(0.5).timeout
	start_match()

func _setup_bots() -> void:
	var patrol_root: Node3D = box_map.get_node_or_null("PatrolPoints") if box_map else null
	if not patrol_root:
		return

	var ct_a_wps: Array[Vector3] = _load_waypoints(patrol_root, "CT_SiteA_%d", 4)
	var ct_b_wps: Array[Vector3] = _load_waypoints(patrol_root, "CT_SiteB_%d", 4)
	var t_a_wps:  Array[Vector3] = _load_waypoints(patrol_root, "T_RushA_%d", 4)
	var t_b_wps:  Array[Vector3] = _load_waypoints(patrol_root, "T_RushB_%d", 4)

	var ct_idx: int = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		# Боты 0-2 защищают сайт A, 3-4 — сайт B
		bot.set_patrol_waypoints(ct_a_wps if ct_idx < 3 else ct_b_wps)
		ct_idx += 1

	var t_idx: int = 0
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		# Боты 0-2 рашат A, 3-4 — рашат B
		bot.set_patrol_waypoints(t_a_wps if t_idx < 3 else t_b_wps)
		t_idx += 1

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
		team_ct_script.register_bot(bot)
		bot.bot_died.connect(_on_bot_died)
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

	team_ct_script.all_bots_dead.connect(func(): round_manager.end_round("T", "elimination"))
	team_t_script.all_bots_dead.connect(func(): round_manager.end_round("CT", "elimination"))

	# Подключить бомбсайты
	for site_path in ["Zones/ZoneSiteA", "Zones/ZoneSiteB"]:
		var site = box_map.get_node_or_null(site_path) if box_map else null
		if not site:
			continue
		site.plant_completed.connect(func(_sid): economy.reward_plant(_get_bomb_carrier_id()))
		site.bomb_exploded.connect(func(_sid): round_manager.end_round("T", "bomb_exploded"))
		site.defuse_completed.connect(func(_sid):
			economy.reward_defuse(_get_defuser_id())
			round_manager.end_round("CT", "defused")
		)

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
		s.aim_level      = randi_range(2, 5)
		s.reaction_time  = randf_range(0.5, 0.8)
		s.game_sense     = randi_range(2, 5)
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
		if spawn_root:
			var m = spawn_root.get_node_or_null("T_Spawn_%d" % (t_idx + 1))
			if m:
				bot.global_position = m.global_position
		# Первый T бот несёт бомбу
		if bot.has_method("set_bomb_carrier"):
			bot.set_bomb_carrier(not bomb_assigned)
			bomb_assigned = true
		bot.start_round()
		t_idx += 1

func _on_bot_died(_bot_id: int, killer_id: int) -> void:
	if killer_id >= 0:
		economy.reward_kill(killer_id)

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

func _end_match(winner: String) -> void:
	match_active = false
	emit_signal("match_ended", winner)
