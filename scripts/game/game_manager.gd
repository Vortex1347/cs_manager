# game_manager.gd
# Главный игровой цикл: команды, карта, бомба, economy, HUD и роутинг combat/audio intel для sandbox-матча.
# Зависимости: round_manager.gd, economy.gd, bot_team.gd, bomb_controller.gd, tactical_map.gd

extends Node3D

signal match_started()
signal match_ended(winner_team: String)
signal pause_toggled(is_paused: bool)

const IntelEventDataScript = preload("res://scripts/game/intel_event_data.gd")

const ROUNDS_TO_WIN: int = 16
const MAX_ROUNDS: int = 30
const CLUSTER_DIST: float = 8.0
const DEFUSE_PROXIMITY: float = 4.0
const PLANT_INTEL_TTL: float = 3.6
const DEATH_INTEL_TTL: float = 2.0
const HUD_REFRESH_INTERVAL: float = 0.18
const OBSERVER_REFRESH_INTERVAL: float = 0.45

@export var map_scene: PackedScene
@export var bot_scene: PackedScene
@export var rl_training_mode: bool = false

@onready var round_manager: Node = $RoundManager
@onready var economy: Node = $Economy
@onready var team_ct: Node = $TeamCT
@onready var team_t: Node = $TeamT
@onready var tactical_map = $BoxMap
@onready var bomb_controller = $BombController
@onready var camera: Camera3D = $MainCamera
@onready var hud: CanvasLayer = $HUD

var team_ct_script: BotTeam
var team_t_script: BotTeam
var score_ct: int = 0
var score_t: int = 0
var is_paused: bool = false
var match_active: bool = false
var lineup_debug_visible: bool = false
var combat_debug_visible: bool = false
var observer_debug_visible: bool = false
var _hud_refresh_queued: bool = false
var _observer_refresh_queued: bool = false
var _last_hud_refresh_time: float = -10.0
var _last_observer_refresh_time: float = -10.0

var _rl_server: RLServer = null
var _prev_goal_dist: Dictionary = {}

func _ready() -> void:
	if map_scene and tactical_map and tactical_map.has_method("bind_map_scene"):
		var imported_map = map_scene.instantiate()
		if imported_map is Node3D:
			tactical_map.bind_map_scene(imported_map)
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
	set_process(true)
	await get_tree().create_timer(0.5).timeout
	start_match()

func _setup_bots() -> void:
	team_ct_script.configure(BotStats.Team.CT, tactical_map, bomb_controller)
	team_t_script.configure(BotStats.Team.T, tactical_map, bomb_controller)
	for bot in _all_bots():
		if not bot.has_method("start_round"):
			continue
		bot.set_bomb_controller(bomb_controller)
		bot.set_tactical_map(tactical_map)
		bot.set_threat_direction(Vector3(0, 0, 1) if bot.stats.team == BotStats.Team.CT else Vector3(0, 0, -1))

func _wire_systems() -> void:
	var all_ids: Array = []
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		bot.add_to_group("ct_bots")
		team_ct_script.register_bot(bot)
		_connect_bot_runtime(bot)
		all_ids.append(bot.stats.bot_id)
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		bot.add_to_group("t_bots")
		team_t_script.register_bot(bot)
		_connect_bot_runtime(bot)
		all_ids.append(bot.stats.bot_id)
	economy.initialize(all_ids)

	round_manager.round_started.connect(_on_round_started)
	round_manager.round_ended.connect(_on_round_ended)
	round_manager.round_ended.connect(_on_round_ended_economy)
	round_manager.time_updated.connect(_on_time_updated)
	round_manager.phase_changed.connect(_on_phase_changed)

	team_ct_script.all_bots_dead.connect(func(): round_manager.end_round("T", "elimination"))
	team_t_script.all_bots_dead.connect(func():
		if bomb_controller and bomb_controller.is_planted():
			return
		round_manager.end_round("CT", "elimination")
	)
	for signal_source in [team_ct_script, team_t_script]:
		signal_source.plan_changed.connect(func(_summary: String): _update_strategy_hud())
		signal_source.strategy_changed.connect(func(_strategy: int): _update_strategy_hud())
		signal_source.utility_call_changed.connect(func(_summary: String): _update_strategy_hud())
		signal_source.combat_call_changed.connect(func(_summary: String): _update_strategy_hud())
		signal_source.intel_summary_changed.connect(func(_summary: String): _update_strategy_hud())

	bomb_controller.bomb_dropped.connect(_on_bomb_dropped)
	bomb_controller.bomb_picked_up.connect(_on_bomb_picked_up)
	bomb_controller.plant_started.connect(_on_plant_started)
	bomb_controller.plant_cancelled.connect(_on_plant_cancelled)
	bomb_controller.plant_completed.connect(_on_plant_completed)
	bomb_controller.defuse_started.connect(_on_defuse_started)
	bomb_controller.defuse_cancelled.connect(_on_defuse_cancelled)
	bomb_controller.defuse_completed.connect(_on_defuse_completed)
	bomb_controller.bomb_exploded.connect(_on_bomb_exploded)
	bomb_controller.countdown_updated.connect(_on_bomb_countdown_updated)

	if hud and hud.has_method("connect_game_manager"):
		hud.connect_game_manager(self)
	if hud and hud.has_signal("strategy_selected"):
		hud.strategy_selected.connect(_on_strategy_selected)
	if hud and hud.has_method("set_observer_mode"):
		hud.set_observer_mode(false)
	for bot in _all_bots():
		if bot.has_method("set_label_verbose"):
			bot.set_label_verbose(false)
	_update_hud_health()
	_update_strategy_hud()

	if rl_training_mode:
		for bot in _all_bots():
			if bot.has_method("start_round"):
				bot.bot_died.connect(_on_bot_died_rl)
				bot.damage_taken.connect(_on_damage_taken_rl)
		round_manager.round_ended.connect(_on_round_ended_rl)

func _connect_bot_runtime(bot: BotBrain) -> void:
	bot.bot_died.connect(_on_bot_died)
	bot.damage_taken.connect(func(_id, _amt, _src): _update_hud_health())
	if bot.has_signal("audio_event_emitted"):
		bot.audio_event_emitted.connect(_on_bot_audio_event)

func _ensure_team_scripts() -> void:
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
	var ct_id = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		var s = BotStats.new()
		s.bot_id = ct_id
		s.team = BotStats.Team.CT
		s.display_name = "CT_%d" % ct_id
		s.aim_level = 5 + (ct_id % 3)
		s.reaction_time = 0.55 - float(ct_id) * 0.04
		s.game_sense = 4 + (ct_id % 3)
		s.aggression = 0.32 + float(ct_id) * 0.05
		bot.stats = s
		ct_id += 1

	var t_id = 10
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		var s = BotStats.new()
		s.bot_id = t_id
		s.team = BotStats.Team.T
		s.display_name = "T_%d" % (t_id - 10)
		s.aim_level = 5 + ((t_id - 10) % 3)
		s.reaction_time = 0.62 - float(t_id - 10) * 0.05
		s.game_sense = 4 + ((t_id - 10) % 3)
		s.aggression = 0.42 + float(t_id - 10) * 0.06
		bot.stats = s
		t_id += 1

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and match_active:
		toggle_pause()
	elif event.is_action_pressed("toggle_lineup_debug"):
		_toggle_lineup_debug()
	elif event.is_action_pressed("toggle_combat_debug"):
		_toggle_combat_debug()
	elif event.is_action_pressed("toggle_observer_debug"):
		_toggle_observer_debug()

func start_match() -> void:
	score_ct = 0
	score_t = 0
	match_active = true
	emit_signal("match_started")
	if hud and hud.has_method("update_score"):
		hud.update_score(score_ct, score_t)
	round_manager.start_round()

func toggle_pause() -> void:
	is_paused = !is_paused
	get_tree().paused = is_paused
	emit_signal("pause_toggled", is_paused)

func _on_round_started(_round_num: int) -> void:
	var ct_spawns: Array = tactical_map.get_spawn_positions("CT") if tactical_map and tactical_map.has_method("get_spawn_positions") else []
	var t_spawns: Array = tactical_map.get_spawn_positions("T") if tactical_map and tactical_map.has_method("get_spawn_positions") else []
	team_ct_script.on_round_reset()
	team_t_script.on_round_reset()
	team_ct_script.notify_bomb_event("round_reset")
	team_t_script.notify_bomb_event("round_reset")
	bomb_controller.reset()
	_set_bomb_status("")

	var ct_idx = 0
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		if ct_idx < ct_spawns.size():
			bot.global_position = Vector3(ct_spawns[ct_idx])
		bot.start_round()
		ct_idx += 1

	var t_idx = 0
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		if t_idx < t_spawns.size():
			bot.global_position = Vector3(t_spawns[t_idx])
		bot.start_round()
		t_idx += 1

	team_ct_script.assign_round_plan()
	team_t_script.assign_round_plan()
	_update_hud_health()
	_update_strategy_hud()

func _on_bot_died(bot_id: int, killer_id: int) -> void:
	if killer_id >= 0:
		economy.reward_kill(killer_id)
	var dead_bot = _find_bot_by_id(bot_id)
	var killer_bot = _find_bot_by_id(killer_id)
	var killer_pos = killer_bot.global_position if killer_bot else (dead_bot.global_position if dead_bot else Vector3.ZERO)
	if dead_bot:
		var own_team = team_ct_script if dead_bot.stats.team == BotStats.Team.CT else team_t_script
		own_team.request_trade_swing(bot_id, killer_pos)
		_route_intel_event(_make_intel_event("death", dead_bot.global_position, int(dead_bot.stats.team), bot_id, 0.7, DEATH_INTEL_TTL, "death"))
		if dead_bot._is_bomb_carrier and bomb_controller.get_state_name() == "carried":
			bomb_controller.drop_bomb(dead_bot.global_position, bot_id)
	_update_hud_health()
	_update_strategy_hud()

func _on_round_ended_economy(winner: String, _reason: String) -> void:
	economy.reward_round_end(winner, _collect_team_ids(team_ct), _collect_team_ids(team_t))

func _on_time_updated(secs: float) -> void:
	if hud and hud.has_method("update_timer"):
		hud.update_timer(secs)
	_update_strategy_hud()

func _on_phase_changed(phase: int) -> void:
	if phase == 0:
		_do_auto_buy()
	elif phase == 1:
		for bot in _all_bots():
			if bot.has_method("begin_live_phase"):
				bot.begin_live_phase()
	elif phase == 2:
		for bot in _all_bots():
			if bot.has_method("freeze_bot"):
				bot.freeze_bot()
	if hud and hud.has_method("update_phase"):
		hud.update_phase(phase)
	_update_strategy_hud()

func _do_auto_buy() -> void:
	var round_context = {
		"round_number": round_manager.round_number,
		"score_ct": score_ct,
		"score_t": score_t,
	}
	var ct_plan = team_ct_script.assign_buy_plan(economy.get_team_money(_collect_team_ids(team_ct)), round_context)
	var t_plan = team_t_script.assign_buy_plan(economy.get_team_money(_collect_team_ids(team_t)), round_context)
	for bot in team_ct.get_children():
		if not bot.has_method("start_round"):
			continue
		_apply_loadout(bot, ct_plan.get(bot.stats.bot_id))
	for bot in team_t.get_children():
		if not bot.has_method("start_round"):
			continue
		_apply_loadout(bot, t_plan.get(bot.stats.bot_id))

func _apply_loadout(bot: Node, loadout) -> void:
	if loadout == null or not bot.has_method("apply_loadout"):
		return
	bot.apply_loadout(loadout, economy.get_money(bot.stats.bot_id))

func _on_strategy_selected(strategy: int) -> void:
	team_t_script.set_strategy(strategy)
	_update_strategy_hud()

func _on_bomb_dropped(position: Vector3, bot_id: int) -> void:
	team_t_script.notify_bomb_event("bomb_dropped", {"position": position, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("bomb_dropped", {"position": position, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("bomb_drop", position, int(BotStats.Team.T), bot_id, 0.85, 2.4, "bomb_drop"))
	_set_bomb_status("💣 Бомба упала")
	_update_strategy_hud()

func _on_bomb_picked_up(bot_id: int) -> void:
	var picker = _find_bot_by_id(bot_id)
	for bot in team_t.get_children():
		if bot.has_method("set_bomb_carrier"):
			bot.set_bomb_carrier(bot.stats.bot_id == bot_id)
	team_t_script.notify_bomb_event("bomb_picked_up", {"bot_id": bot_id})
	team_ct_script.notify_bomb_event("bomb_picked_up", {"bot_id": bot_id})
	_route_intel_event(_make_intel_event("bomb_pickup", picker.global_position if picker else Vector3.ZERO, int(BotStats.Team.T), bot_id, 0.72, 2.0, "bomb_pickup"))
	_set_bomb_status("💣 Бомба поднята")
	_update_strategy_hud()

func _on_plant_started(site_id: String, bot_id: int) -> void:
	var site_pos = tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO
	team_t_script.notify_bomb_event("plant_started", {"site_id": site_id, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("plant_started", {"site_id": site_id, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("plant_start", site_pos, int(BotStats.Team.T), bot_id, 0.92, PLANT_INTEL_TTL, site_id))
	_set_bomb_status("💣 Сажают бомбу на %s..." % site_id)
	_update_strategy_hud()

func _on_plant_cancelled(site_id: String, bot_id: int) -> void:
	team_t_script.notify_bomb_event("bomb_picked_up", {"bot_id": bot_id})
	team_ct_script.notify_bomb_event("bomb_picked_up", {"bot_id": bot_id})
	_route_intel_event(_make_intel_event("plant_cancel", tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO, int(BotStats.Team.T), bot_id, 0.62, 1.5, site_id))
	_set_bomb_status("❌ Plant на %s сорван" % site_id)
	_update_strategy_hud()

func _on_plant_completed(site_id: String, bot_id: int) -> void:
	var site_pos = tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO
	for bot in team_t.get_children():
		if bot.has_method("set_bomb_carrier"):
			bot.set_bomb_carrier(false)
	economy.reward_plant(bot_id)
	team_t_script.notify_bomb_event("plant_completed", {"site_id": site_id, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("plant_completed", {"site_id": site_id, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("plant_complete", site_pos, int(BotStats.Team.T), bot_id, 1.0, PLANT_INTEL_TTL, site_id))
	_set_bomb_status("💣 БОМБА НА САЙТЕ %s!" % site_id)
	if _rl_server:
		_rl_server.add_reward(bot_id, 5.0)
	_update_strategy_hud()

func _on_defuse_started(site_id: String, bot_id: int) -> void:
	var site_pos = tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO
	team_t_script.notify_bomb_event("defuse_started", {"site_id": site_id, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("defuse_started", {"site_id": site_id, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("defuse_start", site_pos, int(BotStats.Team.CT), bot_id, 0.98, 3.2, site_id))
	_set_bomb_status("🔧 Дефузят на %s..." % site_id)
	_update_strategy_hud()

func _on_defuse_cancelled(site_id: String, bot_id: int) -> void:
	team_t_script.notify_bomb_event("plant_completed", {"site_id": site_id, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("plant_completed", {"site_id": site_id, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("defuse_cancel", tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO, int(BotStats.Team.CT), bot_id, 0.6, 1.8, site_id))
	_set_bomb_status("❌ Дефуз сорван")
	_update_strategy_hud()

func _on_defuse_completed(site_id: String, bot_id: int) -> void:
	economy.reward_defuse(bot_id)
	team_t_script.notify_bomb_event("defuse_completed", {"site_id": site_id, "bot_id": bot_id})
	team_ct_script.notify_bomb_event("defuse_completed", {"site_id": site_id, "bot_id": bot_id})
	_route_intel_event(_make_intel_event("defuse_complete", tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO, int(BotStats.Team.CT), bot_id, 1.0, 2.2, site_id))
	round_manager.end_round("CT", "defused")
	_set_bomb_status("✅ РАЗМИНИРОВАНО")
	if _rl_server:
		_rl_server.add_reward(bot_id, 8.0)
	_update_strategy_hud()

func _on_bomb_exploded(site_id: String) -> void:
	var site_pos = tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO
	team_t_script.notify_bomb_event("bomb_exploded", {"site_id": site_id})
	team_ct_script.notify_bomb_event("bomb_exploded", {"site_id": site_id})
	_route_intel_event(_make_intel_event("bomb_exploded", site_pos, int(BotStats.Team.T), -1, 1.0, 2.0, site_id))
	round_manager.end_round("T", "bomb_exploded")
	_set_bomb_status("💥 ВЗРЫВ НА %s!" % site_id)
	_update_strategy_hud()

func _on_bomb_countdown_updated(seconds_remaining: float) -> void:
	if hud and hud.has_method("update_bomb_countdown"):
		hud.update_bomb_countdown(seconds_remaining, bomb_controller.get_state_name())

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
	if observer_debug_visible:
		_observer_refresh_queued = true

func _update_strategy_hud() -> void:
	_schedule_hud_refresh(true)

func _schedule_hud_refresh(observer_too: bool = false) -> void:
	_hud_refresh_queued = true
	_observer_refresh_queued = _observer_refresh_queued or observer_too or observer_debug_visible
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last_hud_refresh_time >= HUD_REFRESH_INTERVAL:
		_flush_hud_refresh()
	if _observer_refresh_queued and now - _last_observer_refresh_time >= OBSERVER_REFRESH_INTERVAL:
		_flush_observer_refresh()

func _flush_hud_refresh() -> void:
	_hud_refresh_queued = false
	_last_hud_refresh_time = Time.get_ticks_msec() / 1000.0
	if hud and hud.has_method("update_team_plans"):
		hud.update_team_plans(team_ct_script.get_plan_summary(), team_t_script.get_plan_summary())
	if hud and hud.has_method("update_utility_call"):
		hud.update_utility_call("%s | %s" % [team_ct_script.get_utility_summary(), team_t_script.get_utility_summary()])
	if hud and hud.has_method("update_combat_call"):
		hud.update_combat_call("CT combat: %s | T combat: %s" % [team_ct_script.get_combat_summary(), team_t_script.get_combat_summary()])
	if hud and hud.has_method("update_intel_summary"):
		hud.update_intel_summary("CT intel: %s | T intel: %s" % [team_ct_script.get_intel_summary(), team_t_script.get_intel_summary()])
	if hud and hud.has_method("update_gunfight_summary"):
		hud.update_gunfight_summary("CT gun: %s | T gun: %s" % [team_ct_script.get_gunfight_summary(), team_t_script.get_gunfight_summary()])
	if lineup_debug_visible and tactical_map and tactical_map.has_method("set_highlighted_lineups"):
		var lineups: Array[String] = []
		lineups.append_array(team_ct_script.get_active_lineup_ids())
		lineups.append_array(team_t_script.get_active_lineup_ids())
		tactical_map.set_highlighted_lineups(lineups)
	elif tactical_map and tactical_map.has_method("set_highlighted_lineups"):
		tactical_map.set_highlighted_lineups([])
	if combat_debug_visible and tactical_map and tactical_map.has_method("set_highlighted_slots"):
		var slots: Array[String] = []
		slots.append_array(team_ct_script.get_active_slot_ids())
		slots.append_array(team_t_script.get_active_slot_ids())
		tactical_map.set_highlighted_slots(slots)
	elif tactical_map and tactical_map.has_method("set_highlighted_slots"):
		tactical_map.set_highlighted_slots([])
	if observer_debug_visible:
		_observer_refresh_queued = true

func _flush_observer_refresh() -> void:
	if not observer_debug_visible or not hud or not hud.has_method("update_bot_panels"):
		_observer_refresh_queued = false
		return
	_observer_refresh_queued = false
	_last_observer_refresh_time = Time.get_ticks_msec() / 1000.0
	hud.update_bot_panels(_collect_bot_debug(team_ct), _collect_bot_debug(team_t))

func _set_bomb_status(text: String) -> void:
	if hud and hud.has_method("update_bomb_status"):
		hud.update_bomb_status(text)

func _toggle_lineup_debug() -> void:
	lineup_debug_visible = not lineup_debug_visible
	if tactical_map and tactical_map.has_method("set_lineup_debug_visible"):
		tactical_map.set_lineup_debug_visible(lineup_debug_visible)
	if hud and hud.has_method("update_lineup_debug"):
		hud.update_lineup_debug(lineup_debug_visible)
	_update_strategy_hud()

func _toggle_combat_debug() -> void:
	combat_debug_visible = not combat_debug_visible
	if tactical_map and tactical_map.has_method("set_combat_debug_visible"):
		tactical_map.set_combat_debug_visible(combat_debug_visible)
	if hud and hud.has_method("update_combat_debug"):
		hud.update_combat_debug(combat_debug_visible)
	_update_strategy_hud()

func _toggle_observer_debug() -> void:
	observer_debug_visible = not observer_debug_visible
	if hud and hud.has_method("set_observer_mode"):
		hud.set_observer_mode(observer_debug_visible)
	for bot in _all_bots():
		if bot.has_method("set_label_verbose"):
			bot.set_label_verbose(observer_debug_visible)
	_update_strategy_hud()

func _end_match(winner: String) -> void:
	match_active = false
	emit_signal("match_ended", winner)

func _collect_team_ids(team_node: Node) -> Array:
	var ids: Array = []
	for bot in team_node.get_children():
		if bot.has_method("start_round"):
			ids.append(bot.stats.bot_id)
	return ids

func _find_bot_by_id(bot_id: int):
	for bot in _all_bots():
		if bot.has_method("start_round") and bot.stats.bot_id == bot_id:
			return bot
	return null

func _all_bots() -> Array:
	var bots: Array = []
	for bot in team_ct.get_children():
		if bot.has_method("start_round"):
			bots.append(bot)
	for bot in team_t.get_children():
		if bot.has_method("start_round"):
			bots.append(bot)
	return bots

func _collect_bot_debug(team_node: Node) -> Array:
	var lines: Array = []
	for bot in team_node.get_children():
		if not bot.has_method("start_round"):
			continue
		lines.append({
			"text": bot.get_observability_summary() if bot.has_method("get_observability_summary") else ("%s %dHP" % [bot.stats.display_name, bot.stats.current_hp]),
			"alive": bot.current_state != BotBrain.BotState.DEAD and not bot.stats.is_dead(),
		})
	return lines

func _make_intel_event(event_type: String, world_pos: Vector3, source_team: int, source_bot_id: int, confidence: float, ttl: float, detail: String) -> Dictionary:
	var intel_event = IntelEventDataScript.new()
	intel_event.event_type = event_type
	intel_event.world_pos = world_pos
	intel_event.lane_id = tactical_map.get_lane_id_from_position(world_pos) if tactical_map else "unknown"
	intel_event.confidence = confidence
	intel_event.ttl = ttl
	intel_event.source_team = source_team
	intel_event.source_bot_id = source_bot_id
	intel_event.detail = detail
	intel_event.volume = confidence
	return intel_event.to_dict()

func _route_intel_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	team_ct_script.notify_intel_event(event)
	team_t_script.notify_intel_event(event)
	_update_strategy_hud()

func _on_bot_audio_event(event: Dictionary) -> void:
	_route_intel_event(event)

func _process(_delta: float) -> void:
	var now = Time.get_ticks_msec() / 1000.0
	if _hud_refresh_queued and now - _last_hud_refresh_time >= HUD_REFRESH_INTERVAL:
		_flush_hud_refresh()
	if _observer_refresh_queued and now - _last_observer_refresh_time >= OBSERVER_REFRESH_INTERVAL:
		_flush_observer_refresh()

func _physics_process(_delta: float) -> void:
	if _rl_server and _rl_server.is_connected:
		var all_bots: Array = []
		for bot in _all_bots():
			if bot.has_method("start_round"):
				all_bots.append(bot)
		_shape_rewards(all_bots)
		_rl_server.send_step(all_bots)

func _shape_rewards(all_bots: Array) -> void:
	var planted_site_pos = bomb_controller.get_active_site_position() if bomb_controller and bomb_controller.is_planted() else Vector3.ZERO
	var carrier_pos = Vector3.ZERO
	var carrier_bot = _find_bot_by_id(bomb_controller.carrier_id) if bomb_controller else null
	if carrier_bot and carrier_bot._is_live:
		carrier_pos = carrier_bot.global_position
	for bot in all_bots:
		if not bot._is_live or bot.current_state == BotBrain.BotState.DEAD:
			continue
		var bid = bot.stats.bot_id
		_rl_server.add_reward(bid, 0.002)
		var goal_pos = Vector3.ZERO
		var approach_mult = 0.01
		if bot.stats.team == BotStats.Team.CT:
			if planted_site_pos != Vector3.ZERO:
				goal_pos = planted_site_pos
				approach_mult = 0.03
				if bot.global_position.distance_to(goal_pos) < DEFUSE_PROXIMITY:
					_rl_server.add_reward(bid, 0.05)
		else:
			if bot._is_bomb_carrier:
				var nearest_site = tactical_map.get_site_position("A")
				var b_site = tactical_map.get_site_position("B")
				if b_site != Vector3.ZERO and bot.global_position.distance_to(b_site) < bot.global_position.distance_to(nearest_site):
					nearest_site = b_site
				goal_pos = nearest_site
				approach_mult = 0.02
			elif planted_site_pos != Vector3.ZERO:
				goal_pos = planted_site_pos
				approach_mult = 0.02
			elif carrier_pos != Vector3.ZERO:
				var dist_to_carrier = bot.global_position.distance_to(carrier_pos)
				if dist_to_carrier < CLUSTER_DIST:
					_rl_server.add_reward(bid, (1.0 - dist_to_carrier / CLUSTER_DIST) * 0.006)
				else:
					goal_pos = carrier_pos
					approach_mult = 0.015
		if goal_pos == Vector3.ZERO:
			_prev_goal_dist.erase(bid)
			continue
		var cur_d = bot.global_position.distance_to(goal_pos)
		if _prev_goal_dist.has(bid):
			var delta_d = _prev_goal_dist[bid] - cur_d
			if delta_d > 0.0:
				_rl_server.add_reward(bid, delta_d * approach_mult)
		_prev_goal_dist[bid] = cur_d

func _enable_rl_on_bots() -> void:
	for bot in _all_bots():
		if bot.has_method("enable_rl_mode"):
			bot.enable_rl_mode(_rl_server)

func _on_bot_died_rl(bot_id: int, killer_id: int) -> void:
	if not _rl_server:
		return
	_rl_server.add_reward(bot_id, -1.0)
	if killer_id >= 0:
		_rl_server.add_reward(killer_id, 2.0)
	_rl_server.set_done(bot_id)

func _on_damage_taken_rl(_bot_id: int, amount: int, source_id: int) -> void:
	if not _rl_server:
		return
	if source_id >= 0:
		_rl_server.add_reward(source_id, float(amount) * 0.02)

func _on_round_ended_rl(winner: String, _reason: String) -> void:
	if not _rl_server:
		return
	var ct_ids = _collect_team_ids(team_ct)
	var t_ids = _collect_team_ids(team_t)
	var win_ids = ct_ids if winner == "CT" else t_ids
	var lose_ids = t_ids if winner == "CT" else ct_ids
	for id in win_ids:
		_rl_server.add_reward(id, 3.0)
	for id in lose_ids:
		_rl_server.set_done(id)
	for id in win_ids:
		_rl_server.set_done(id)
