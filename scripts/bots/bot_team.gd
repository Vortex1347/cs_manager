# bot_team.gd
# Командный AI-слой: закупка, планы, utility, combat directives, slot reservation и sound/visual intel.
# Зависимости: bot_brain.gd, combat_directive.gd, tactical_map.gd, bomb_controller.gd, bot_loadout.gd

extends Node
class_name BotTeam

const CombatDirectiveScript = preload("res://scripts/bots/combat_directive.gd")

signal team_enemy_sighted(enemy_id: int, last_known_pos: Vector3)
signal suppression_assigned(assignee_id: int, target_pos: Vector3)
signal strategy_changed(new_strategy: int)
signal rotate_to_site(site_name: String, count: int)
signal all_bots_dead()
signal plan_changed(plan_name: String)
signal utility_call_changed(summary: String)
signal combat_call_changed(summary: String)
signal intel_summary_changed(summary: String)

enum TeamStrategy { DEFAULT, RUSH_A, RUSH_B, SPLIT, ECO }

const ROTATION_ENEMY_THRESHOLD: float = 1.8
const ENEMY_SITE_RADIUS: float = 15.0
const INTEL_DECAY_PER_SECOND: float = 0.18
const VISUAL_TTL: float = 3.4
const AUDIO_TTL: float = 2.2

var bots: Dictionary = {}
var blackboard: Dictionary = {
	"spotted_enemies": {},
	"intel_events": [],
	"bomb_planted": false,
	"bomb_site": "",
	"strategy": TeamStrategy.DEFAULT,
	"active_count": 5,
	"bomb_state": "none",
	"round_serial": 0,
	"fallback_carrier_id": -1,
}

var team_side: BotStats.Team = BotStats.Team.CT
var current_strategy: TeamStrategy = TeamStrategy.DEFAULT
var current_plan_name: String = "hold"
var current_utility_call: String = "none"
var current_combat_call: String = "none"
var current_intel_summary: String = "quiet"
var tactical_map = null
var bomb_controller = null
var _rotation_timer: float = 0.0
var _rotation_cooldown: float = 2.4
var _active_lineup_ids: Array[String] = []
var _slot_reservations: Dictionary = {}
var _combat_assignments: Dictionary = {}
var _duty_packages: Dictionary = {}

func _process(delta: float) -> void:
	_decay_blackboard_confidence(delta)
	_decay_intel_events(delta)
	if team_side != BotStats.Team.CT:
		return
	if bomb_controller and bomb_controller.is_planted():
		return
	_rotation_timer -= delta
	if _rotation_timer <= 0.0:
		_evaluate_rotation()
		_rotation_timer = _rotation_cooldown

func configure(side: BotStats.Team, map_ref, bomb_ref) -> void:
	team_side = side
	tactical_map = map_ref
	bomb_controller = bomb_ref
	set_process(true)

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
	if team_side == BotStats.Team.T and bomb_controller and not bomb_controller.is_planted():
		assign_round_plan()

func assign_buy_plan(team_money_snapshot: Dictionary, round_context: Dictionary) -> Dictionary:
	var plan: Dictionary = {}
	var preview_roles = _predict_roles()
	var kit_candidates: Array = []
	if team_side == BotStats.Team.CT:
		kit_candidates = _get_alive_bots()
		kit_candidates.sort_custom(func(a, b):
			return _score_bot(a, "defuser") > _score_bot(b, "defuser"))
	var max_kits = min(2, kit_candidates.size())
	var econ_tier = _get_econ_tier(team_money_snapshot, round_context)
	var root = get_parent().get_parent() if get_parent() and get_parent().get_parent() else null
	var economy = root.get_node_or_null("Economy") if root else null
	if economy == null:
		return plan
	for bot in _get_alive_bots():
		var role_name = preview_roles.get(bot.stats.bot_id, "support")
		var buy_profile = _choose_buy_profile(role_name, econ_tier)
		var preferred_grenades = _get_preferred_grenades(role_name, buy_profile)
		var allow_defuse_kit = team_side == BotStats.Team.CT and bot in kit_candidates.slice(0, max_kits)
		plan[bot.stats.bot_id] = economy.auto_buy(
			bot.stats.bot_id,
			int(team_money_snapshot.get(bot.stats.bot_id, 0)),
			"T" if team_side == BotStats.Team.T else "CT",
			buy_profile,
			role_name,
			allow_defuse_kit,
			preferred_grenades
		)
	return plan

func assign_round_plan() -> Dictionary:
	if tactical_map == null:
		return {}
	_reset_round_assignments()
	if team_side == BotStats.Team.T:
		_assign_t_plan()
	else:
		_assign_ct_plan()
	assign_combat_plan()
	_refresh_summaries()
	return _duty_packages.duplicate(true)

func assign_combat_plan() -> void:
	for bot_id in _combat_assignments.keys():
		var bot: BotBrain = bots.get(bot_id)
		if bot == null:
			continue
		var directive: Dictionary = _combat_assignments[bot_id].get("directive", {})
		if not directive.is_empty():
			bot.assign_combat_directive(directive)

func notify_bomb_event(event_name: String, data: Dictionary = {}) -> void:
	match event_name:
		"round_reset":
			blackboard["bomb_planted"] = false
			blackboard["bomb_site"] = ""
			blackboard["bomb_state"] = "carried"
			current_utility_call = "none"
		"bomb_dropped":
			blackboard["bomb_state"] = "dropped"
			request_objective_replan("bomb_dropped", data)
		"bomb_picked_up":
			blackboard["bomb_state"] = "carried"
			request_objective_replan("bomb_picked_up", data)
		"plant_started":
			blackboard["bomb_state"] = "planting"
			blackboard["bomb_site"] = data.get("site_id", "")
			request_objective_replan("plant_started", data)
		"plant_completed":
			blackboard["bomb_planted"] = true
			blackboard["bomb_site"] = data.get("site_id", "")
			blackboard["bomb_state"] = "planted"
			request_objective_replan("plant_completed", data)
		"defuse_started":
			blackboard["bomb_state"] = "defusing"
			request_objective_replan("defuse_started", data)
		"defuse_completed", "bomb_exploded":
			blackboard["bomb_planted"] = false
			blackboard["bomb_state"] = event_name
			blackboard["bomb_site"] = ""
			current_utility_call = "none"
	_refresh_summaries()

func request_objective_replan(reason: String, data: Dictionary = {}) -> void:
	match reason:
		"bomb_dropped":
			if team_side == BotStats.Team.T:
				_assign_t_recover_plan(Vector3(data.get("position", Vector3.ZERO)))
			else:
				_assign_ct_contest_drop(Vector3(data.get("position", Vector3.ZERO)))
		"bomb_picked_up":
			if team_side == BotStats.Team.T and not blackboard["bomb_planted"]:
				assign_round_plan()
		"plant_started":
			var site_id = String(data.get("site_id", blackboard.get("bomb_site", "")))
			if site_id != "":
				if team_side == BotStats.Team.T:
					_assign_cover_planter(site_id)
				else:
					request_rotation(site_id, 2)
		"plant_completed":
			var planted_site_id = String(data.get("site_id", blackboard.get("bomb_site", "")))
			if planted_site_id != "":
				if team_side == BotStats.Team.T:
					_assign_post_plant(planted_site_id)
				else:
					_assign_retake(planted_site_id)
		"defuse_started":
			var defuse_site_id = String(data.get("site_id", blackboard.get("bomb_site", "")))
			if defuse_site_id != "":
				if team_side == BotStats.Team.T:
					_assign_post_plant(defuse_site_id)
				else:
					_assign_retake(defuse_site_id)
		"carrier_died", "planter_died", "defuser_died", "save_call":
			if team_side == BotStats.Team.T and blackboard["bomb_planted"]:
				_assign_post_plant(String(blackboard.get("bomb_site", "")))
			elif team_side == BotStats.Team.CT and blackboard["bomb_planted"]:
				_assign_retake(String(blackboard.get("bomb_site", "")))
			else:
				assign_round_plan()

func notify_intel_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	var source_team = int(event.get("source_team", -1))
	if source_team == int(team_side):
		return
	var normalized = event.duplicate(true)
	if String(normalized.get("lane_id", "")) == "" and tactical_map:
		normalized["lane_id"] = tactical_map.get_lane_id_from_position(normalized.get("world_pos", Vector3.ZERO))
	blackboard["intel_events"].append(normalized)
	for bot in _get_alive_bots():
		bot.notify_heard_event(normalized)
	_rotation_timer = minf(_rotation_timer, 0.2)
	_refresh_summaries()

func request_rotation(site_name: String, count: int) -> void:
	if team_side != BotStats.Team.CT or tactical_map == null:
		return
	var route_id = "ct_rotate_a" if site_name == "A" else "ct_rotate_b"
	var candidates = _get_alive_bots()
	candidates.sort_custom(func(a, b):
		return _score_bot(a, "rotator") > _score_bot(b, "rotator"))
	var assigned = 0
	for bot in candidates:
		if assigned >= count:
			break
		if bot.get_role_name() in ["anchor", "a_anchor", "b_anchor"]:
			continue
		var profile_id = "ct_long_contest" if site_name == "A" else "ct_b_window"
		var directive = _build_directive(profile_id, -1, "reposition")
		_apply_order(bot, "mid_rotator", "rotate", "site_%s" % site_name.to_lower(), tactical_map.get_route(route_id), _get_lineup_steps_for_bot("ct_hold_a" if site_name == "A" else "ct_hold_b", "rotator"), directive, site_name, _make_bomb_task("rotate_%s" % site_name.to_lower(), site_name, "default", "site_%s" % site_name.to_lower(), "", false, "rotate"), "ct_hold_a" if site_name == "A" else "ct_hold_b")
		assigned += 1
	if assigned > 0:
		current_plan_name = "rotate_%s" % site_name.to_lower()
		current_combat_call = "CT rotate %s x%d" % [site_name, assigned]
		emit_signal("rotate_to_site", site_name, assigned)
		emit_signal("plan_changed", current_plan_name)
		_refresh_summaries()

func request_trade_swing(dead_bot_id: int, killer_pos: Vector3) -> void:
	if not _combat_assignments.has(dead_bot_id):
		return
	var assignment = _combat_assignments[dead_bot_id]
	var partner_id = int(assignment.get("trade_partner_id", -1))
	var partner: BotBrain = bots.get(partner_id)
	if partner == null or partner.current_state == BotBrain.BotState.DEAD:
		return
	var partner_assignment: Dictionary = _combat_assignments.get(partner_id, {})
	var updated = partner_assignment.get("directive", {}).duplicate(true)
	if updated.is_empty():
		updated = assignment.get("directive", {}).duplicate(true)
	if updated.is_empty():
		return
	updated["peek_mode"] = "trade_swing"
	updated["last_target_position"] = killer_pos
	updated["confidence_threshold"] = 0.18
	updated["trade_partner_id"] = dead_bot_id
	partner.assign_combat_directive(updated)
	_combat_assignments[partner_id]["directive"] = updated
	current_combat_call = "%s trade swing -> %s" % [
		"T" if team_side == BotStats.Team.T else "CT",
		_tactical_lane_label(updated.get("lane_id", ""))
	]
	_refresh_summaries()

func get_plan_summary() -> String:
	return current_plan_name

func get_utility_summary() -> String:
	for brain in bots.values():
		var lineup_id = String(brain.get_active_lineup_id()) if brain.has_method("get_active_lineup_id") else ""
		if lineup_id != "":
			var side_name = "T" if team_side == BotStats.Team.T else "CT"
			return "%s util live: %s" % [side_name, lineup_id]
	return current_utility_call

func get_combat_summary() -> String:
	var live_trade_calls: Array[String] = []
	for brain in bots.values():
		if not brain.has_method("get_combat_summary"):
			continue
		var summary = String(brain.get_combat_summary())
		if summary.contains("trade_swing") or summary.contains("wide_swing") or summary.contains("fallback_hold"):
			live_trade_calls.append(summary)
	if not live_trade_calls.is_empty():
		return live_trade_calls[0]
	return current_combat_call

func get_gunfight_summary() -> String:
	var fallback_summary := ""
	for brain in bots.values():
		if not brain.has_method("get_gunfight_summary"):
			continue
		var summary = String(brain.get_gunfight_summary())
		if summary.contains("fired") or summary.contains("stabilizing") or summary.contains("moving") or summary.contains("awp_"):
			return summary
		if fallback_summary == "" and summary != "":
			fallback_summary = summary
	return fallback_summary if fallback_summary != "" else "quiet gunfight"

func get_intel_summary() -> String:
	return current_intel_summary

func get_active_lineup_ids() -> Array[String]:
	return _active_lineup_ids.duplicate()

func get_active_slot_ids() -> Array[String]:
	var slot_ids: Array[String] = []
	for slot_id in _slot_reservations.keys():
		slot_ids.append(String(slot_id))
	return slot_ids

func get_active_count() -> int:
	return blackboard["active_count"]

func get_average_game_sense() -> float:
	if bots.is_empty():
		return 1.0
	var total = 0.0
	for brain in bots.values():
		total += brain.stats.game_sense
	return total / bots.size()

func on_round_reset() -> void:
	blackboard["spotted_enemies"].clear()
	blackboard["intel_events"].clear()
	blackboard["bomb_planted"] = false
	blackboard["bomb_site"] = ""
	blackboard["bomb_state"] = "carried"
	blackboard["active_count"] = bots.size()
	blackboard["round_serial"] = int(blackboard.get("round_serial", 0)) + 1
	blackboard["fallback_carrier_id"] = -1
	current_plan_name = "hold"
	current_utility_call = "none"
	current_combat_call = "none"
	current_intel_summary = "quiet"
	_reset_round_assignments()

func _assign_t_plan() -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	for bot in alive:
		bot.set_bomb_carrier(false)
	var pool = alive.duplicate()
	var carrier = _pop_best_bot(pool, "carrier")
	var entry = _pop_best_bot(pool, "entry")
	var second = _pop_best_bot(pool, "entry")
	var trade = _pop_best_bot(pool, "support")
	var lurker = _pop_best_bot(pool, "lurker")
	var fallback_carrier = _pop_best_bot(pool, "carrier")
	if carrier == null:
		return
	carrier.set_bomb_carrier(true)
	blackboard["fallback_carrier_id"] = fallback_carrier.stats.bot_id if fallback_carrier else -1
	var site_id := "A"
	var package_id := "t_default_a"
	var default_roll = int(blackboard.get("round_serial", 1)) % 4
	match current_strategy:
		TeamStrategy.RUSH_A:
			current_plan_name = "a_long_commit"
			site_id = "A"
			package_id = "t_a_long_commit"
		TeamStrategy.RUSH_B:
			current_plan_name = "b_exec"
			site_id = "B"
			package_id = "t_b_exec"
		TeamStrategy.SPLIT:
			current_plan_name = "a_cat_split"
			site_id = "A"
			package_id = "t_a_cat_split"
		TeamStrategy.ECO:
			current_plan_name = "b_contact"
			site_id = "B"
			package_id = ""
		_:
			if default_roll == 0:
				current_plan_name = "mid_to_b_split"
				site_id = "B"
				package_id = "t_mid_to_b"
			elif default_roll == 1:
				current_plan_name = "default_a_long"
				site_id = "A"
				package_id = "t_default_a"
			elif default_roll == 2:
				current_plan_name = "b_exec"
				site_id = "B"
				package_id = "t_b_exec"
			else:
				current_plan_name = "default_a_long"
				site_id = "A"
				package_id = "t_default_a"
	if bomb_controller:
		bomb_controller.assign_carrier(carrier.stats.bot_id, blackboard["fallback_carrier_id"], site_id)
		bomb_controller.set_site_target(site_id)

	match current_plan_name:
		"default_a_long", "a_long_commit":
			var entry_route = "a_long_commit_entry" if current_plan_name == "a_long_commit" else "default_a_long_entry"
			var second_route = "a_long_commit_trade" if current_plan_name == "a_long_commit" else "default_a_long_trade"
			var carrier_route = "a_long_commit_carrier" if current_plan_name == "a_long_commit" else "default_a_long_carrier"
			_apply_profile_order(entry, "entry", "take_space", "a_long", entry_route, "t_long_entry", second.stats.bot_id if second else -1, "A", _make_bomb_task("clear_site_for_plant", "A", "default", "a_long", "", true, "take_space"), package_id, "wide_swing")
			_apply_profile_order(second, "second", "take_space", "a_long", second_route, "t_long_trade", entry.stats.bot_id if entry else -1, "A", _make_bomb_task("escort_carrier", "A", "default", "a_long", "", true, "support"), package_id, "trade_swing")
			_apply_profile_order(trade, "trade", "take_space", "short_a", "default_a_long_support", "t_short_entry", carrier.stats.bot_id, "A", _make_bomb_task("clear_site_for_plant", "A", "default", "short_a", "", true, "take_space"), package_id, "clear_corner")
			_apply_profile_order(lurker, "lurker", "lurk", "mid", "default_a_long_lurk", "t_mid_lurk", -1, "A", _make_bomb_task("late_rotate_a", "A", "default", "mid", "", false, "lurk"), "", "hold_angle")
			_apply_profile_order(carrier, "carrier", "plant", "a_site", carrier_route, "t_short_trade", trade.stats.bot_id if trade else -1, "A", _make_bomb_task("carry", "A", "default", "a_site", "", true, "plant"), package_id, "clear_corner")
			_apply_profile_order(fallback_carrier, "second", "support", "a_long", second_route, "t_long_trade", carrier.stats.bot_id, "A", _make_bomb_task("escort_carrier", "A", "default", "a_long", "", true, "support"), "", "trade_swing")
			current_combat_call = "T A long take"
		"a_cat_split":
			_apply_profile_order(entry, "entry", "take_space", "a_long", "a_cat_split_long", "t_long_entry", second.stats.bot_id if second else -1, "A", _make_bomb_task("clear_site_for_plant", "A", "default", "a_long", "", true, "take_space"), package_id, "wide_swing")
			_apply_profile_order(second, "second", "take_space", "short_a", "a_cat_split_short", "t_short_entry", entry.stats.bot_id if entry else -1, "A", _make_bomb_task("clear_site_for_plant", "A", "default", "short_a", "", true, "take_space"), package_id, "clear_corner")
			_apply_profile_order(trade, "trade", "support", "a_long", "a_cat_split_long", "t_long_trade", entry.stats.bot_id if entry else -1, "A", _make_bomb_task("escort_carrier", "A", "default", "a_long", "", true, "support"), package_id, "trade_swing")
			_apply_profile_order(lurker, "lurker", "lurk", "mid", "default_a_long_lurk", "t_mid_lurk", -1, "A", _make_bomb_task("late_rotate_a", "A", "default", "mid", "", false, "lurk"), "", "hold_angle")
			_apply_profile_order(carrier, "carrier", "plant", "a_site", "a_cat_split_carrier", "t_short_trade", second.stats.bot_id if second else -1, "A", _make_bomb_task("carry", "A", "default", "a_site", "", true, "plant"), package_id, "clear_corner")
			_apply_profile_order(fallback_carrier, "trade", "support", "short_a", "a_cat_split_short", "t_short_trade", carrier.stats.bot_id, "A", _make_bomb_task("escort_carrier", "A", "default", "short_a", "", true, "support"), "", "trade_swing")
			current_combat_call = "T A cat split"
		"mid_to_b_split":
			_apply_profile_order(entry, "entry", "take_space", "mid_doors", "mid_to_b_split_mid", "t_mid_lurk", second.stats.bot_id if second else -1, "B", _make_bomb_task("clear_site_for_plant", "B", "default", "mid_doors", "", true, "take_space"), package_id, "wide_swing")
			_apply_profile_order(second, "second", "take_space", "b_tunnels", "mid_to_b_split_tunnels", "t_b_entry", entry.stats.bot_id if entry else -1, "B", _make_bomb_task("escort_carrier", "B", "default", "b_tunnels", "", true, "take_space"), package_id, "wide_swing")
			_apply_profile_order(trade, "trade", "support", "b_site", "b_exec_trade", "t_b_trade", second.stats.bot_id if second else -1, "B", _make_bomb_task("cover_planter", "B", "default", "b_site", "", true, "support"), package_id, "trade_swing")
			_apply_profile_order(lurker, "lurker", "lurk", "mid", "default_a_long_lurk", "t_mid_lurk", -1, "B", _make_bomb_task("fake_rotate_with_lurker", "B", "default", "mid", "", false, "lurk"), "", "hold_angle")
			_apply_profile_order(carrier, "carrier", "plant", "b_site", "mid_to_b_split_carrier", "t_b_trade", trade.stats.bot_id if trade else -1, "B", _make_bomb_task("carry", "B", "default", "b_site", "", true, "plant"), package_id, "clear_corner")
			_apply_profile_order(fallback_carrier, "second", "support", "b_site", "b_exec_trade", "t_b_trade", carrier.stats.bot_id, "B", _make_bomb_task("escort_carrier", "B", "default", "b_site", "", true, "support"), "", "trade_swing")
			current_combat_call = "T mid to B split"
		"b_contact":
			_apply_profile_order(entry, "entry", "take_space", "b_tunnels", "b_contact_entry", "t_b_entry", second.stats.bot_id if second else -1, "B", _make_bomb_task("clear_site_for_plant", "B", "default", "b_tunnels", "hard_contact_abort", true, "take_space"), "", "wide_swing")
			_apply_profile_order(second, "second", "take_space", "b_tunnels", "b_contact_trade", "t_b_trade", entry.stats.bot_id if entry else -1, "B", _make_bomb_task("escort_carrier", "B", "default", "b_tunnels", "hard_contact_abort", true, "support"), "", "trade_swing")
			_apply_profile_order(trade, "trade", "support", "b_window", "b_exec_support", "t_b_trade", carrier.stats.bot_id, "B", _make_bomb_task("secure_drop", "B", "default", "b_window", "hard_contact_abort", true, "support"), "", "hold_angle")
			_apply_profile_order(lurker, "lurker", "lurk", "mid", "default_a_long_lurk", "t_mid_lurk", -1, "B", _make_bomb_task("fake_rotate_with_lurker", "B", "default", "mid", "", false, "lurk"), "", "hold_angle")
			_apply_profile_order(carrier, "carrier", "plant", "b_site", "b_exec_carrier", "t_b_trade", trade.stats.bot_id if trade else -1, "B", _make_bomb_task("carry", "B", "default", "b_site", "hard_contact_abort", true, "plant"), "", "clear_corner")
			current_combat_call = "T B contact"
		_:
			_apply_profile_order(entry, "entry", "take_space", "b_tunnels", "b_exec_entry", "t_b_entry", second.stats.bot_id if second else -1, "B", _make_bomb_task("clear_site_for_plant", "B", "default", "b_tunnels", "", true, "take_space"), package_id, "wide_swing")
			_apply_profile_order(second, "second", "take_space", "b_site", "b_exec_trade", "t_b_trade", entry.stats.bot_id if entry else -1, "B", _make_bomb_task("escort_carrier", "B", "default", "b_site", "", true, "support"), package_id, "trade_swing")
			_apply_profile_order(trade, "trade", "support", "b_window", "b_exec_support", "t_b_trade", carrier.stats.bot_id, "B", _make_bomb_task("clear_site_for_plant", "B", "default", "b_window", "", true, "support"), package_id, "shoulder_peek")
			_apply_profile_order(lurker, "lurker", "lurk", "mid", "default_a_long_lurk", "t_mid_lurk", -1, "B", _make_bomb_task("late_rotate_b", "B", "default", "mid", "", false, "lurk"), "", "hold_angle")
			_apply_profile_order(carrier, "carrier", "plant", "b_site", "b_exec_carrier", "t_b_trade", trade.stats.bot_id if trade else -1, "B", _make_bomb_task("carry", "B", "default", "b_site", "", true, "plant"), package_id, "clear_corner")
			_apply_profile_order(fallback_carrier, "second", "support", "b_site", "b_exec_trade", "t_b_trade", carrier.stats.bot_id, "B", _make_bomb_task("escort_carrier", "B", "default", "b_site", "", true, "support"), "", "trade_swing")
			current_combat_call = "T B exec"
	if package_id != "":
		_set_active_lineups_from_package(package_id)
	emit_signal("plan_changed", current_plan_name)

func _assign_ct_plan() -> void:
	var pool = _get_alive_bots()
	if pool.is_empty():
		return
	current_plan_name = "hold_sites"
	var a_anchor = _pop_best_bot(pool, "anchor")
	var long_contest = _pop_best_bot(pool, "rotator")
	var mid_rotator = _pop_best_bot(pool, "rotator")
	var b_anchor = _pop_best_bot(pool, "anchor")
	var defuser = _pop_best_bot(pool, "defuser")
	_apply_profile_order(a_anchor, "a_anchor", "hold", "a_site", "ct_a_anchor", "ct_a_anchor", long_contest.stats.bot_id if long_contest else -1, "A", _make_bomb_task("hold_site", "A", "default", "a_site", "", false, "hold"), "ct_hold_a", "hold_angle")
	_apply_profile_order(long_contest, "long_contest", "hold", "a_long", "ct_long_contest", "ct_long_contest", a_anchor.stats.bot_id if a_anchor else -1, "A", _make_bomb_task("delay_entry", "A", "default", "a_long", "", false, "hold"), "ct_hold_a", "shoulder_peek")
	_apply_profile_order(mid_rotator, "mid_rotator", "hold", "mid", "ct_mid_info", "ct_mid_info", -1, "", _make_bomb_task("mid_info", "", "default", "mid", "", false, "hold"), "", "jiggle_info")
	_apply_profile_order(b_anchor, "b_anchor", "hold", "b_site", "ct_b_anchor", "ct_b_anchor", defuser.stats.bot_id if defuser else -1, "B", _make_bomb_task("hold_site", "B", "default", "b_site", "", false, "hold"), "ct_hold_b", "hold_angle")
	_apply_profile_order(defuser, "defuser", "hold", "b_window", "ct_b_window", "ct_b_window", b_anchor.stats.bot_id if b_anchor else -1, "B", _make_bomb_task("delay_entry", "B", "default", "b_window", "", false, "hold"), "ct_hold_b", "shoulder_peek")
	current_combat_call = "CT hold A/B with mid info"
	_set_active_lineups_from_package("ct_hold_a")
	_set_active_lineups_from_package("ct_hold_b")
	emit_signal("plan_changed", current_plan_name)

func _assign_t_recover_plan(drop_pos: Vector3) -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	var recover_bot = bots.get(int(blackboard.get("fallback_carrier_id", -1)))
	if recover_bot == null or recover_bot.current_state == BotBrain.BotState.DEAD:
		recover_bot = _get_nearest_bot(alive, drop_pos)
	var lane_id = tactical_map.get_lane_id_from_position(drop_pos) if tactical_map else "mid"
	var site_id = _site_from_lane(lane_id)
	var save_mode = alive.size() <= 2
	current_plan_name = "save" if save_mode else "recover_bomb"
	current_combat_call = "T save bomb" if save_mode else "T recover bomb"
	if bomb_controller:
		bomb_controller.set_site_target(site_id)
	for bot in alive:
		if bot == recover_bot:
			var recover_profile = "t_b_trade" if site_id == "B" else "t_long_trade"
			var recover_task = "save_bomb" if save_mode else "recover_drop"
			var recover_directive = _build_directive(recover_profile, -1, "reposition", drop_pos)
			_apply_order(bot, "carrier", "recover_bomb", lane_id, [drop_pos], [], recover_directive, site_id, _make_bomb_task(recover_task, site_id, "default", lane_id, "hard_contact_abort", true, "recover_bomb"))
			continue
		var support_route_id = "b_exec_trade" if site_id == "B" else "default_a_long_trade"
		var support_profile = "t_b_trade" if site_id == "B" else "t_long_trade"
		var support_intent = "save" if save_mode else "support"
		var support_task = "save_bomb" if save_mode else "secure_then_recover"
		_apply_profile_order(bot, bot.get_role_name(), support_intent, lane_id, support_route_id, support_profile, recover_bot.stats.bot_id if recover_bot else -1, site_id, _make_bomb_task(support_task, site_id, "default", lane_id, "hard_contact_abort", true, support_intent), "", "hold_angle")
	emit_signal("plan_changed", current_plan_name)

func _assign_ct_contest_drop(drop_pos: Vector3) -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	current_plan_name = "contest_drop"
	current_combat_call = "CT contest bomb"
	var lane_id = tactical_map.get_lane_id_from_position(drop_pos) if tactical_map else "mid"
	var site_id = tactical_map.get_site_id_from_position(drop_pos) if tactical_map else _site_from_lane(lane_id)
	var contest_bot = _get_nearest_bot(alive, drop_pos)
	_apply_order(contest_bot, "mid_rotator", "rotate", lane_id, [drop_pos], [], _build_directive("ct_mid_info", -1, "wide_swing", drop_pos), site_id, _make_bomb_task("contest_drop", site_id, "default", lane_id, "", false, "rotate"))
	for bot in alive:
		if bot == contest_bot:
			continue
		var hold_profile = "ct_a_anchor" if site_id == "A" else "ct_b_anchor"
		var hold_route = "ct_a_anchor" if site_id == "A" else "ct_b_anchor"
		_apply_profile_order(bot, bot.get_role_name(), "hold", "site_%s" % site_id.to_lower(), hold_route, hold_profile, contest_bot.stats.bot_id if contest_bot else -1, site_id, _make_bomb_task("hold_site", site_id, "default", "site_%s" % site_id.to_lower(), "", false, "hold"))
	emit_signal("plan_changed", current_plan_name)

func _assign_cover_planter(site_id: String) -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	current_plan_name = "plant_%s" % site_id.to_lower()
	current_combat_call = "T cover planter %s" % site_id
	var plant_slot = tactical_map.get_plant_slot(site_id, "default")
	var plant_pos = Vector3(plant_slot.get("position", tactical_map.get_site_position(site_id)))
	var post_routes = ["t_post_a_long", "t_post_a_short", "t_post_a_ramp"] if site_id == "A" else ["t_post_b_window", "t_post_b_tunnels", "t_post_b_back"]
	var post_profiles = ["post_a_long", "post_a_short", "post_a_ramp"] if site_id == "A" else ["post_b_window", "post_b_tunnels", "post_b_back"]
	var cover_index = 0
	for bot in alive:
		if bot._is_bomb_carrier:
			var plant_directive = _build_directive("t_short_trade" if site_id == "A" else "t_b_trade", -1, "clear_corner")
			_apply_order(bot, "carrier", "plant", "site_%s" % site_id.to_lower(), [plant_pos], [], plant_directive, site_id, _make_bomb_task("plant_default", site_id, String(plant_slot.get("slot_id", "default")), "site_%s" % site_id.to_lower(), "", true, "plant"))
			continue
		var route_id = post_routes[min(cover_index, post_routes.size() - 1)]
		var profile_id = post_profiles[min(cover_index, post_profiles.size() - 1)]
		_apply_profile_order(bot, "post_plant_anchor", "cover_planter", "site_%s" % site_id.to_lower(), route_id, profile_id, bomb_controller.get_carrier_id() if bomb_controller else -1, site_id, _make_bomb_task("cover_planter", site_id, String(plant_slot.get("slot_id", "default")), "site_%s" % site_id.to_lower(), "", true, "cover_planter"), "", "hold_angle")
		cover_index += 1
	emit_signal("plan_changed", current_plan_name)

func _assign_post_plant(site_id: String) -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	current_plan_name = "post_%s" % site_id.to_lower()
	current_combat_call = "T post plant %s" % site_id
	var route_ids = ["t_post_a_long", "t_post_a_short", "t_post_a_ramp"] if site_id == "A" else ["t_post_b_tunnels", "t_post_b_window", "t_post_b_back"]
	var profile_ids = ["post_a_long", "post_a_short", "post_a_ramp"] if site_id == "A" else ["post_b_tunnels", "post_b_window", "post_b_back"]
	var package_id = "t_post_plant_a" if site_id == "A" else "t_post_plant_b"
	alive.sort_custom(func(a, b):
		return _score_bot(a, "lurker") > _score_bot(b, "lurker"))
	for i in range(min(alive.size(), route_ids.size())):
		var role_name = "anti_defuse_thrower" if i == 1 else "post_plant_anchor"
		var intent = "anti_defuse_nade" if i == 1 else "guard_bomb"
		var task_type = "anti_defuse" if i == 1 else "reposition_post_plant"
		var partner_id = alive[0].stats.bot_id if i != 0 and not alive.is_empty() else (alive[1].stats.bot_id if alive.size() > 1 else -1)
		_apply_profile_order(alive[i], role_name, intent, "site_%s" % site_id.to_lower(), route_ids[i], profile_ids[i], partner_id, site_id, _make_bomb_task(task_type, site_id, "default", "site_%s" % site_id.to_lower(), "", true, intent), package_id, "hold_angle")
	_set_active_lineups_from_package(package_id)
	emit_signal("plan_changed", current_plan_name)

func _assign_retake(site_id: String) -> void:
	var alive = _get_alive_bots()
	if alive.is_empty():
		return
	if bomb_controller and bomb_controller.get_seconds_remaining() <= 9.0 and alive.size() <= 2:
		current_plan_name = "save_%s" % site_id.to_lower()
		current_combat_call = "CT save %s" % site_id
		var save_route = "ct_save_a" if site_id == "A" else "ct_save_b"
		for bot in alive:
			_apply_profile_order(bot, "save", "save", "save_%s" % site_id.to_lower(), save_route, "ct_mid_info", -1, site_id, _make_bomb_task("save", site_id, "default", "save_%s" % site_id.to_lower(), "", false, "save"), "", "fallback_hold")
		emit_signal("plan_changed", current_plan_name)
		return
	current_plan_name = "retake_%s" % site_id.to_lower()
	alive.sort_custom(func(a, b):
		return _score_bot(a, "defuser") > _score_bot(b, "defuser"))
	var route_ids = ["ct_retake_a_ct", "ct_retake_a_short"] if site_id == "A" else ["ct_retake_b_platform", "ct_retake_b_window", "ct_retake_b_door"]
	var profile_ids = ["retake_a_defuser", "retake_a_cover"] if site_id == "A" else ["retake_b_defuser", "retake_b_cover", "retake_b_door"]
	var package_id = "ct_retake_a" if site_id == "A" else "ct_retake_b"
	var defuser_id = alive[0].stats.bot_id if not alive.is_empty() else -1
	for i in range(min(alive.size(), route_ids.size())):
		var role = "defuser" if i == 0 else "retake_cover"
		var intent = "defuse" if i == 0 else "retake"
		var task_type = "defuse_primary" if i == 0 else "cover_defuser"
		var partner_id = alive[1].stats.bot_id if i == 0 and alive.size() > 1 else defuser_id
		var peek_mode = "fallback_hold" if i == 0 else "trade_swing"
		_apply_profile_order(alive[i], role, intent, "site_%s" % site_id.to_lower(), route_ids[i], profile_ids[i], partner_id, site_id, _make_bomb_task(task_type, site_id, "default", "site_%s" % site_id.to_lower(), "", true, intent), package_id, peek_mode)
	current_combat_call = "CT retake %s" % site_id
	_set_active_lineups_from_package(package_id)
	emit_signal("plan_changed", current_plan_name)

func _apply_profile_order(
	bot: BotBrain,
	role: String,
	intent: String,
	lane_target: String,
	route_id: String,
	profile_id: String,
	partner_id: int,
	site_target: String,
	bomb_task: Dictionary,
	package_id: String = "",
	peek_mode_override: String = "",
	target_pos: Vector3 = Vector3.ZERO
) -> void:
	if bot == null:
		return
	var route = tactical_map.get_route(route_id) if tactical_map else []
	var directive = _build_directive(profile_id, partner_id, peek_mode_override, target_pos)
	var utility_steps = _get_lineup_steps_for_bot(package_id, role) if package_id != "" else []
	_apply_order(bot, role, intent, lane_target, route, utility_steps, directive, site_target, bomb_task, package_id)

func _site_from_lane(lane_id: String) -> String:
	if lane_id in ["b_tunnels", "b_site", "b_window", "mid_doors"]:
		return "B"
	return "A"

func _get_lineup_steps_for_bot(package_id: String, role_name: String = "") -> Array:
	var steps = tactical_map.get_utility_package(package_id) if tactical_map else []
	if steps.is_empty():
		return []
	var filtered: Array = []
	for step in steps:
		var grenade_type = String(step.get("grenade_type", ""))
		var allow = false
		match role_name:
			"carrier":
				allow = grenade_type == "smoke"
			"entry", "second", "trade", "long_contest":
				allow = grenade_type == "flash"
			"support", "anchor", "a_anchor", "b_anchor", "post_plant_anchor":
				allow = grenade_type in ["smoke", "flash", "frag"]
			"rotator", "retaker", "retake_cover", "defuser", "mid_rotator":
				allow = grenade_type in ["smoke", "flash"]
			"post_plant", "anti_defuse_thrower":
				allow = grenade_type in ["frag", "flash"]
			_:
				allow = role_name != "lurker" or grenade_type != "smoke"
		if allow:
			filtered.append(step.duplicate(true))
	return filtered

func _on_enemy_spotted(reporter_id: int, enemy_id: int, pos: Vector3) -> void:
	blackboard["spotted_enemies"][enemy_id] = {
		"position": pos,
		"last_seen_time": Time.get_ticks_msec() / 1000.0,
		"reported_by": reporter_id,
		"confidence": 1.0
	}
	var lane_id = tactical_map.get_lane_id_from_position(pos) if tactical_map else "unknown"
	blackboard["intel_events"].append({
		"event_type": "visual_contact",
		"world_pos": pos,
		"lane_id": lane_id,
		"confidence": 1.0,
		"ttl": VISUAL_TTL,
		"source_team": 1 - int(team_side),
		"source_bot_id": enemy_id,
		"detail": "visual",
	})
	emit_signal("team_enemy_sighted", enemy_id, pos)
	for bot_id in bots:
		if bot_id != reporter_id:
			bots[bot_id].receive_team_intel(enemy_id, pos)
	_refresh_summaries()

func _on_enemy_lost(_reporter_id: int, enemy_id: int) -> void:
	if enemy_id in blackboard["spotted_enemies"]:
		blackboard["spotted_enemies"][enemy_id]["confidence"] *= 0.5

func _on_suppression_requested(reporter_id: int, pos: Vector3, _priority: float) -> void:
	var best_id = -1
	var best_dist = INF
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
	var dead_assignment: Dictionary = _duty_packages.get(bot_id, {})
	var dead_bomb_task: Dictionary = dead_assignment.get("bomb_task", {})
	var alive = 0
	for brain in bots.values():
		if brain.current_state != BotBrain.BotState.DEAD:
			alive += 1
	blackboard["active_count"] = alive
	for slot_id in _slot_reservations.keys():
		if _slot_reservations[slot_id] == bot_id:
			_slot_reservations.erase(slot_id)
			break
	if alive == 0:
		emit_signal("all_bots_dead")
	if String(dead_bomb_task.get("task_type", "")) in ["carry", "plant_default", "recover_drop"] or bot_id == int(blackboard.get("fallback_carrier_id", -2)):
		request_objective_replan("carrier_died", {"bot_id": bot_id})
	elif String(dead_bomb_task.get("task_type", "")) == "cover_defuser" or dead_assignment.get("role", "") == "defuser":
		request_objective_replan("defuser_died", {"bot_id": bot_id})
	elif String(dead_bomb_task.get("task_type", "")) == "cover_planter":
		request_objective_replan("planter_died", {"bot_id": bot_id})
	_refresh_summaries()

func _evaluate_rotation() -> void:
	var a_count = _count_pressure_for_site("A")
	var b_count = _count_pressure_for_site("B")
	var avg_sense = get_average_game_sense()
	_rotation_cooldown = clamp(3.0 - avg_sense * 0.18, 1.2, 3.0)
	if a_count >= ROTATION_ENEMY_THRESHOLD and b_count < 1.2:
		request_rotation("A", 1 if get_active_count() <= 3 else 2)
	elif b_count >= ROTATION_ENEMY_THRESHOLD and a_count < 1.2:
		request_rotation("B", 1 if get_active_count() <= 3 else 2)

func _count_pressure_for_site(site_id: String) -> float:
	var pressure := 0.0
	var site_pos = tactical_map.get_site_position(site_id) if tactical_map else Vector3.ZERO
	for enemy_id in blackboard["spotted_enemies"]:
		var entry = blackboard["spotted_enemies"][enemy_id]
		if entry["confidence"] > 0.2 and site_pos != Vector3.ZERO and entry["position"].distance_to(site_pos) < ENEMY_SITE_RADIUS:
			pressure += entry["confidence"] * 1.5
	for event in blackboard["intel_events"]:
		if _event_matches_site(event, site_id):
			pressure += float(event.get("confidence", 0.0))
	return pressure

func _event_matches_site(event: Dictionary, site_id: String) -> bool:
	var lane_id = String(event.get("lane_id", ""))
	if site_id == "A":
		return lane_id in ["a_long", "a_site", "short_a", "mid"]
	return lane_id in ["b_tunnels", "b_site", "b_window", "mid_doors"]

func _decay_blackboard_confidence(delta: float) -> void:
	for enemy_id in blackboard["spotted_enemies"]:
		blackboard["spotted_enemies"][enemy_id]["confidence"] -= delta * 0.12
	var to_remove = []
	for enemy_id in blackboard["spotted_enemies"]:
		if blackboard["spotted_enemies"][enemy_id]["confidence"] <= 0.0:
			to_remove.append(enemy_id)
	for enemy_id in to_remove:
		blackboard["spotted_enemies"].erase(enemy_id)

func _decay_intel_events(delta: float) -> void:
	var keep: Array = []
	for event in blackboard["intel_events"]:
		var updated = event.duplicate(true)
		updated["ttl"] = float(updated.get("ttl", AUDIO_TTL)) - delta
		updated["confidence"] = maxf(0.0, float(updated.get("confidence", 0.0)) - delta * INTEL_DECAY_PER_SECOND)
		if updated["ttl"] > 0.0 and updated["confidence"] > 0.0:
			keep.append(updated)
	blackboard["intel_events"] = keep

func _reset_round_assignments() -> void:
	_active_lineup_ids.clear()
	_slot_reservations.clear()
	_combat_assignments.clear()
	_duty_packages.clear()

func _apply_order(
	bot: BotBrain,
	role: String,
	intent: String,
	lane_target: String,
	route: Array[Vector3],
	utility_plan: Array,
	combat_directive: Dictionary,
	site_target: String = "",
	bomb_task: Dictionary = {},
	utility_package_id: String = "",
	rotate_conditions: Dictionary = {},
	fallback_assignment: Dictionary = {}
) -> void:
	if bot == null:
		return
	var route_copy: Array[Vector3] = []
	for point in route:
		route_copy.append(point)
	var utility_copy: Array = []
	for step in utility_plan:
		utility_copy.append(step.duplicate(true))
	var duty_package = {
		"site_target": site_target,
		"lane_target": lane_target,
		"role": role,
		"intent": intent,
		"trade_partner_id": int(combat_directive.get("trade_partner_id", -1)),
		"bomb_task": bomb_task.duplicate(true),
		"rotate_conditions": rotate_conditions.duplicate(true),
		"fallback_assignment": fallback_assignment.duplicate(true),
		"utility_package_id": utility_package_id,
		"utility_plan": utility_copy,
		"combat_directive": combat_directive.duplicate(true),
		"route": route_copy,
	}
	if bot.has_method("assign_duty_package"):
		bot.assign_duty_package(duty_package)
	else:
		bot.assign_round_order(role, intent, lane_target, route_copy)
		bot.assign_utility_plan(utility_copy)
		bot.assign_combat_directive(combat_directive)
	if tactical_map:
		bot.set_tactical_map(tactical_map)
	var slot_id = String(combat_directive.get("slot_id", ""))
	if slot_id != "":
		_slot_reservations[slot_id] = bot.stats.bot_id
	_duty_packages[bot.stats.bot_id] = duty_package.duplicate(true)
	_combat_assignments[bot.stats.bot_id] = {
		"role": role,
		"intent": intent,
		"directive": combat_directive.duplicate(true),
		"trade_partner_id": int(combat_directive.get("trade_partner_id", -1)),
	}

func _make_bomb_task(
	task_type: String,
	site_id: String,
	slot_id: String = "default",
	must_hold_lane: String = "",
	abort_conditions: String = "",
	reassign_on_death: bool = true,
	task_intent: String = ""
) -> Dictionary:
	return {
		"task_type": task_type,
		"site_id": site_id,
		"slot_id": slot_id,
		"must_hold_lane": must_hold_lane,
		"abort_conditions": abort_conditions,
		"reassign_on_death": reassign_on_death,
		"task_intent": task_intent,
	}

func _build_directive(profile_id: String, trade_partner_id: int, peek_mode_override: String = "", target_pos: Vector3 = Vector3.ZERO) -> Dictionary:
	var profile = tactical_map.get_hold_profile(profile_id) if tactical_map else {}
	if profile.is_empty():
		return {}
	var slot_id = _reserve_slot(String(profile.get("slot_id", "")), String(profile.get("lane_id", "")))
	var slot = tactical_map.get_cover_slot(slot_id) if tactical_map else {}
	var directive = CombatDirectiveScript.new()
	directive.hold_zone = profile_id
	directive.hold_arc = {
		"look_at_position": slot.get("look_at_position", profile.get("look_at_position", Vector3.ZERO)),
		"lane_id": profile.get("lane_id", ""),
	}
	directive.peek_mode = peek_mode_override if peek_mode_override != "" else String(profile.get("peek_mode", "hold_angle"))
	directive.trade_partner_id = trade_partner_id
	directive.fallback_route_id = String(profile.get("fallback_route_id", ""))
	directive.reposition_slot = slot_id
	directive.confidence_threshold = float(profile.get("confidence_threshold", 0.45))
	directive.lane_id = String(profile.get("lane_id", ""))
	directive.slot_id = slot_id
	directive.hold_position = slot.get("position", profile.get("hold_position", Vector3.ZERO))
	directive.look_at_position = slot.get("look_at_position", profile.get("look_at_position", Vector3.ZERO))
	directive.shoulder_position = profile.get("shoulder_position", directive.hold_position)
	directive.wide_position = profile.get("wide_position", directive.hold_position)
	var fallback = tactical_map.get_fallback_route(directive.fallback_route_id) if tactical_map else []
	directive.fallback_position = fallback[1] if fallback.size() > 1 else fallback[0] if fallback.size() == 1 else directive.hold_position
	directive.clear_points = profile.get("clear_points", []).duplicate()
	directive.last_target_position = target_pos
	var gunfight_defaults = _get_gunfight_defaults(profile_id, directive.peek_mode)
	directive.engagement_profile_hint = String(gunfight_defaults.get("engagement_profile_hint", ""))
	directive.preferred_fire_mode = String(gunfight_defaults.get("preferred_fire_mode", ""))
	directive.stabilize_before_peek = bool(gunfight_defaults.get("stabilize_before_peek", false))
	directive.stabilize_window = float(gunfight_defaults.get("stabilize_window", 0.1))
	directive.counter_strafe_window = float(gunfight_defaults.get("counter_strafe_window", 0.06))
	directive.commit_window = float(gunfight_defaults.get("commit_window", 0.45))
	return directive.to_dict()

func _get_gunfight_defaults(profile_id: String, peek_mode: String) -> Dictionary:
	var defaults := {
		"engagement_profile_hint": "mid",
		"preferred_fire_mode": "burst",
		"stabilize_before_peek": true,
		"stabilize_window": 0.09,
		"counter_strafe_window": 0.06,
		"commit_window": 0.42,
	}
	if profile_id.begins_with("t_long_entry") or profile_id.begins_with("t_b_entry") or profile_id.begins_with("t_short_entry"):
		defaults["engagement_profile_hint"] = "close"
		defaults["preferred_fire_mode"] = "spray_commit" if peek_mode == "wide_swing" else "burst"
		defaults["stabilize_before_peek"] = false
		defaults["stabilize_window"] = 0.05
		defaults["counter_strafe_window"] = 0.04
		defaults["commit_window"] = 0.62
	elif profile_id.begins_with("t_long_trade") or profile_id.begins_with("t_b_trade") or profile_id.begins_with("t_short_trade"):
		defaults["engagement_profile_hint"] = "mid"
		defaults["preferred_fire_mode"] = "burst"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.07
		defaults["counter_strafe_window"] = 0.05
		defaults["commit_window"] = 0.48
	elif profile_id.begins_with("ct_a_anchor") or profile_id.begins_with("ct_b_anchor"):
		defaults["engagement_profile_hint"] = "long"
		defaults["preferred_fire_mode"] = "tap"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.14
		defaults["counter_strafe_window"] = 0.07
		defaults["commit_window"] = 0.26
	elif profile_id.begins_with("ct_mid_info"):
		defaults["engagement_profile_hint"] = "long"
		defaults["preferred_fire_mode"] = "tap"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.12
		defaults["commit_window"] = 0.22
	elif profile_id.begins_with("ct_long_contest") or profile_id.begins_with("ct_b_window") or profile_id.begins_with("ct_short_hold"):
		defaults["engagement_profile_hint"] = "mid"
		defaults["preferred_fire_mode"] = "burst"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.08
		defaults["commit_window"] = 0.34
	elif profile_id.begins_with("retake_"):
		defaults["engagement_profile_hint"] = "mid"
		defaults["preferred_fire_mode"] = "burst"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.08
		defaults["commit_window"] = 0.38
	elif profile_id.begins_with("post_"):
		defaults["engagement_profile_hint"] = "mid"
		defaults["preferred_fire_mode"] = "tap"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.1
		defaults["commit_window"] = 0.3
	elif profile_id.begins_with("t_mid_lurk"):
		defaults["engagement_profile_hint"] = "long"
		defaults["preferred_fire_mode"] = "tap"
		defaults["stabilize_before_peek"] = true
		defaults["stabilize_window"] = 0.11
		defaults["commit_window"] = 0.24
	if peek_mode == "trade_swing":
		defaults["preferred_fire_mode"] = "burst"
		defaults["commit_window"] = maxf(float(defaults["commit_window"]), 0.5)
	elif peek_mode == "wide_swing":
		defaults["stabilize_before_peek"] = false
		defaults["commit_window"] = maxf(float(defaults["commit_window"]), 0.58)
	elif peek_mode == "fallback_hold":
		defaults["preferred_fire_mode"] = "tap"
		defaults["stabilize_before_peek"] = true
		defaults["commit_window"] = minf(float(defaults["commit_window"]), 0.28)
	return defaults

func _reserve_slot(slot_id: String, lane_id: String) -> String:
	if slot_id == "":
		return ""
	if not _slot_reservations.has(slot_id):
		_slot_reservations[slot_id] = -1
		return slot_id
	var fallback_slot = tactical_map.find_free_cover_slot(lane_id, _slot_reservations.keys()) if tactical_map else ""
	if fallback_slot != "":
		_slot_reservations[fallback_slot] = -1
		return fallback_slot
	return slot_id

func _refresh_summaries() -> void:
	_emit_utility_summary()
	var new_combat_summary = current_combat_call
	var live_trade = get_combat_summary()
	if live_trade != "":
		new_combat_summary = live_trade
	if new_combat_summary != current_combat_call:
		current_combat_call = new_combat_summary
	emit_signal("combat_call_changed", current_combat_call)
	current_intel_summary = _summarize_intel()
	emit_signal("intel_summary_changed", current_intel_summary)

func _emit_utility_summary() -> void:
	var side_name = "T" if team_side == BotStats.Team.T else "CT"
	current_utility_call = "%s util: %s" % [side_name, ", ".join(_active_lineup_ids) if not _active_lineup_ids.is_empty() else "none"]
	emit_signal("utility_call_changed", current_utility_call)

func _summarize_intel() -> String:
	if blackboard["intel_events"].is_empty():
		return "quiet"
	var per_lane: Dictionary = {}
	for event in blackboard["intel_events"]:
		var lane_id = String(event.get("lane_id", "unknown"))
		per_lane[lane_id] = per_lane.get(lane_id, 0.0) + float(event.get("confidence", 0.0))
	var best_lane := "quiet"
	var best_value := -INF
	for lane_id in per_lane:
		if per_lane[lane_id] > best_value:
			best_value = per_lane[lane_id]
			best_lane = lane_id
	return "%s pressure %.2f" % [_tactical_lane_label(best_lane), best_value]

func _tactical_lane_label(lane_id: String) -> String:
	match lane_id:
		"a_long":
			return "A Long"
		"a_site":
			return "A Site"
		"short_a":
			return "Short A"
		"mid_doors":
			return "Mid Doors"
		"b_tunnels":
			return "B Tunnels"
		"b_window":
			return "B Window"
		"b_site":
			return "B Site"
		"mid":
			return "Mid"
		"ct_spawn":
			return "CT"
		"t_spawn":
			return "T Spawn"
		_:
			return lane_id.capitalize()

func _get_alive_bots() -> Array:
	var alive = []
	for brain in bots.values():
		if brain.current_state != BotBrain.BotState.DEAD and not brain.stats.is_dead():
			alive.append(brain)
	return alive

func _get_nearest_bot(pool: Array, pos: Vector3):
	var best = null
	var best_dist = INF
	for bot in pool:
		var d = bot.global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = bot
	return best

func _predict_roles() -> Dictionary:
	var roles: Dictionary = {}
	var pool = _get_alive_bots()
	if pool.is_empty():
		return roles
	var temp_pool = pool.duplicate()
	if team_side == BotStats.Team.T:
		var carrier = _pop_best_bot(temp_pool, "carrier")
		if carrier:
			roles[carrier.stats.bot_id] = "carrier"
		var entry = _pop_best_bot(temp_pool, "entry")
		if entry:
			roles[entry.stats.bot_id] = "entry"
		var second = _pop_best_bot(temp_pool, "entry")
		if second:
			roles[second.stats.bot_id] = "second"
		var lurker = _pop_best_bot(temp_pool, "lurker")
		if lurker:
			roles[lurker.stats.bot_id] = "lurker"
		for bot in temp_pool:
			roles[bot.stats.bot_id] = "support"
	else:
		var anchor_a = _pop_best_bot(temp_pool, "anchor")
		if anchor_a:
			roles[anchor_a.stats.bot_id] = "a_anchor"
		var long_contest = _pop_best_bot(temp_pool, "rotator")
		if long_contest:
			roles[long_contest.stats.bot_id] = "long_contest"
		var defuser = _pop_best_bot(temp_pool, "defuser")
		if defuser:
			roles[defuser.stats.bot_id] = "defuser"
		var anchor_b = _pop_best_bot(temp_pool, "anchor")
		if anchor_b:
			roles[anchor_b.stats.bot_id] = "b_anchor"
		for bot in temp_pool:
			roles[bot.stats.bot_id] = "mid_rotator"
	return roles

func _choose_buy_profile(role_name: String, econ_tier: String) -> String:
	if econ_tier == "eco":
		return "eco"
	if econ_tier == "half_buy":
		return "half_buy"
	if team_side == BotStats.Team.T:
		match current_strategy:
			TeamStrategy.RUSH_A:
				return "full_execute_a"
			TeamStrategy.RUSH_B:
				return "full_execute_b"
			TeamStrategy.SPLIT:
				return "full_execute_a"
			_:
				return "full_default"
	if role_name in ["a_anchor", "b_anchor"]:
		return "anchor_full"
	if role_name == "defuser":
		return "retake_full"
	return "rotator_full"

func _get_econ_tier(team_money_snapshot: Dictionary, round_context: Dictionary) -> String:
	if team_money_snapshot.is_empty():
		return "eco"
	var total = 0.0
	for amount in team_money_snapshot.values():
		total += float(amount)
	var average = total / team_money_snapshot.size()
	if current_strategy == TeamStrategy.ECO:
		return "eco"
	if average < 1800.0:
		return "eco"
	if average < 3300.0 or round_context.get("round_number", 1) <= 2:
		return "half_buy"
	return "full_buy"

func _get_preferred_grenades(role_name: String, buy_profile: String) -> Array[String]:
	if buy_profile == "eco":
		if role_name in ["entry", "anchor"] and randf() > 0.45:
			return ["flash"]
		return []
	if team_side == BotStats.Team.T:
		match role_name:
			"carrier":
				return ["smoke", "flash"]
			"entry", "second":
				return ["flash", "frag"]
			"support", "post_plant_anchor":
				return ["smoke", "flash", "frag"]
			"lurker":
				return ["flash", "smoke"]
			"anti_defuse_thrower":
				return ["frag", "flash"]
		return ["flash"]
	match role_name:
		"a_anchor", "b_anchor":
			return ["smoke", "flash"]
		"rotator", "retaker", "retake_cover", "mid_rotator", "long_contest":
			return ["flash", "smoke"]
		"defuser":
			return ["smoke", "flash"]
	return ["flash"]

func _set_active_lineups_from_package(package_id: String) -> void:
	for step in tactical_map.get_utility_package(package_id):
		var lineup_id = String(step.get("lineup_id", ""))
		if lineup_id != "" and not (lineup_id in _active_lineup_ids):
			_active_lineup_ids.append(lineup_id)

func _pop_best_bot(pool: Array, selector: String):
	var best_idx = -1
	var best_score = -INF
	for i in range(pool.size()):
		var bot = pool[i]
		var score = _score_bot(bot, selector)
		if score > best_score:
			best_score = score
			best_idx = i
	if best_idx == -1:
		return null
	var best = pool[best_idx]
	pool.remove_at(best_idx)
	return best

func _score_bot(bot: BotBrain, selector: String) -> float:
	match selector:
		"carrier":
			return bot.stats.game_sense * 3.0 + float(bot.stats.current_hp) * 0.02 - bot.stats.aggression
		"entry":
			return bot.stats.aggression * 4.0 + bot.stats.aim_level * 1.7 - bot.stats.reaction_time
		"lurker":
			return bot.stats.game_sense * 2.5 + bot.stats.aim_level - bot.stats.aggression * 0.5
		"anchor":
			return bot.stats.game_sense * 3.0 + (1.2 - bot.stats.reaction_time) * 2.0
		"defuser":
			return (10.0 if bot.stats.has_defuse_kit else 0.0) + bot.stats.game_sense * 2.0 + (1.2 - bot.stats.reaction_time) * 2.5
		"support":
			return bot.stats.game_sense * 2.0 + bot.stats.aim_level + bot.stats.reaction_time * -0.8
		_:
			return bot.stats.game_sense + bot.stats.aim_level + bot.stats.aggression

func _strategy_name(strategy: TeamStrategy) -> String:
	match strategy:
		TeamStrategy.RUSH_A:
			return "Rush A"
		TeamStrategy.RUSH_B:
			return "Rush B"
		TeamStrategy.SPLIT:
			return "Split"
		TeamStrategy.ECO:
			return "Eco"
		_:
			return "Default"
