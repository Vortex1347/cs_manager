# bot_brain.gd
# Локальный AI бота: получает командный intent, utility/combat plan и реализует micro-поведение, бой, intel и objective-экшены.
# Зависимости: bot_stats.gd, bomb_controller.gd, bot_loadout.gd, grenade.gd, NavigationAgent3D, weapon.gd

extends CharacterBody3D
class_name BotBrain

signal enemy_spotted(reporter_id: int, enemy_id: int, position: Vector3)
signal enemy_lost(reporter_id: int, enemy_id: int)
signal requesting_suppression(reporter_id: int, position: Vector3, priority: float)
signal bot_died(bot_id: int, killer_id: int)
signal state_changed(bot_id: int, new_state: int)
signal damage_taken(bot_id: int, amount: int, source_id: int)
signal audio_event_emitted(event: Dictionary)

enum BotState { IDLE, PATROL, SPOTTED_ENEMY, ENGAGE, RETREAT, DEAD }

const MOVE_SPEED: float = 4.2
const WALL_COLLISION_LAYER: int = 1
const SMOKE_COLLISION_LAYER: int = 2
const TEAM_COLLISION_LAYER_CT: int = 4
const TEAM_COLLISION_LAYER_T: int = 8
const FOV_HALF_ANGLE_DEG: float = 150.0
const PERCEPTION_TICK: float = 0.1
const AGGRESSION_PEEK_THRESHOLD: float = 0.6
const ROUTE_REACHED_DISTANCE: float = 1.5
const BOMB_PICKUP_RANGE: float = 2.2
const HOLD_SCAN_SPEED_DEG: float = 35.0
const GRENADE_SCENE = preload("res://scenes/weapons/grenade.tscn")
const IntelEventDataScript = preload("res://scripts/game/intel_event_data.gd")
const LINEUP_TIMEOUT: float = 4.2
const UTILITY_THROW_DISTANCE: float = 0.9
const CLOSE_ENEMY_ABORT_DISTANCE: float = 7.0
const FOOTSTEP_EMIT_INTERVAL: float = 0.7
const FOOTSTEP_SPEED_THRESHOLD: float = 1.2
const FOOTSTEP_TTL: float = 1.6
const GUNSHOT_TTL: float = 2.4
const GRENADE_TTL: float = 1.9
const COMBAT_MEMORY_DECAY: float = 0.25
const COMBAT_SNAP_DISTANCE: float = 1.0
const PEEK_CYCLE_BASE: float = 0.95
const TRADE_SWING_WINDOW: float = 1.6
const CLEAR_POINT_RADIUS: float = 1.0
const INTEL_PROMOTE_THRESHOLD: float = 0.28
const LABEL_UPDATE_INTERVAL: float = 0.28

@export var stats: BotStats
@export var team_node_path: NodePath

@onready var nav_agent: NavigationAgent3D = $NavAgent
@onready var perception_area: Area3D = $PerceptionArea
@onready var reaction_timer: Timer = $ReactionTimer
@onready var perception_timer: Timer = $PerceptionTimer
@onready var eye_pos: Marker3D = $EyePosition
@onready var weapon: Node3D = get_node_or_null("Weapon")
@onready var debug_label: Label3D = get_node_or_null("DebugLabel")

var current_state: BotState = BotState.IDLE
var visible_enemies: Array[Node3D] = []
var last_known_enemy_pos: Vector3 = Vector3.ZERO
var last_seen_time: float = 0.0
var role_name: String = "unassigned"
var current_intent: String = "idle"
var target_zone_name: String = ""
var bomb_controller = null
var tactical_map = null
var current_loadout = null
var duty_package: Dictionary = {}
var bomb_task: Dictionary = {}
var grenade_inventory: Array[String] = []
var current_money: int = 0
var utility_plan: Array = []
var active_lineup_id: String = ""
var combat_directive: Dictionary = {}

var _is_blinded: bool = false
var _is_live: bool = false
var _is_bomb_carrier: bool = false
var _team: Node = null
var _patrol_waypoints: Array[Vector3] = []
var _current_waypoint_idx: int = 0
var _route_finished: bool = true
var _dwell_timer: float = 0.0
var _dwelling: bool = false
var _body_mesh: MeshInstance3D = null
var _bomb_indicator: MeshInstance3D = null
var _scan_timer: float = 0.0
var _scan_dir: float = 1.0
var _threat_dir: Vector3 = Vector3.ZERO
var _rl_mode: bool = false
var _utility_state_name: String = "idle"
var _utility_state_timer: float = 0.0
var _utility_throw_wait: float = 0.0
var _active_utility_index: int = -1
var _dynamic_path: Array[Vector3] = []
var _dynamic_target: Vector3 = Vector3.ZERO
var _live_phase_age: float = 0.0
var _heard_events: Array = []
var _peek_cycle_timer: float = 0.0
var _trade_swing_timer: float = 0.0
var _clear_point_index: int = 0
var _footstep_timer: float = 0.0
var _last_shot_time: float = -100.0
var _last_heard_source: String = "none"
var _last_spotted_source: String = "none"
var _last_audio_lane: String = ""
var _current_fire_mode: String = "tap"
var _current_engagement_profile: String = "mid"
var _gunfight_block_reason: String = "idle"
var _gunfight_reason: String = "idle"
var _accuracy_pressure: float = 0.0
var _commit_window_timer: float = 0.0
var _stabilize_timer: float = 0.0
var _stabilize_required: bool = false
var _is_stabilized_for_shot: bool = true
var _label_verbose: bool = false
var _label_update_cooldown: float = 0.0
var rl_server: RLServer = null

func _ready() -> void:
	reaction_timer.one_shot = true
	reaction_timer.timeout.connect(_on_reaction_timeout)
	perception_timer.wait_time = PERCEPTION_TICK
	perception_timer.autostart = true
	perception_timer.timeout.connect(_perception_tick)
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	if weapon and weapon.has_signal("shot_fired"):
		weapon.shot_fired.connect(_on_weapon_shot_fired)
	if not team_node_path.is_empty():
		_team = get_node(team_node_path)
	_body_mesh = get_node_or_null("Body")

func _physics_process(delta: float) -> void:
	if current_state == BotState.DEAD:
		return
	if not _is_live:
		velocity = Vector3.ZERO
		return
	_live_phase_age += delta
	_label_update_cooldown = maxf(0.0, _label_update_cooldown - delta)
	_decay_local_intel(delta)
	_trade_swing_timer = maxf(0.0, _trade_swing_timer - delta)
	_footstep_timer = maxf(0.0, _footstep_timer - delta)
	_commit_window_timer = maxf(0.0, _commit_window_timer - delta)
	if _rl_mode:
		_apply_rl_action()
		return
	match current_state:
		BotState.IDLE:
			_hold_position(delta)
		BotState.PATROL:
			_state_patrol(delta)
		BotState.SPOTTED_ENEMY:
			_state_spotted(delta)
		BotState.ENGAGE:
			_state_engage(delta)
		BotState.RETREAT:
			_state_retreat(delta)

func _change_state(new_state: BotState) -> void:
	_exit_state(current_state)
	current_state = new_state
	_enter_state(new_state)
	emit_signal("state_changed", stats.bot_id, new_state)
	_update_label()

func _enter_state(new_state: BotState) -> void:
	match new_state:
		BotState.SPOTTED_ENEMY:
			reaction_timer.wait_time = stats.reaction_time
			reaction_timer.start()
		BotState.RETREAT:
			if not _begin_fallback_route():
				_navigate_to(_find_cover_position())

func _exit_state(old_state: BotState) -> void:
	if old_state == BotState.SPOTTED_ENEMY:
		reaction_timer.stop()

func _state_patrol(delta: float) -> void:
	if _dwelling:
		_process_dwell(delta)
		return
	if _process_utility(delta):
		return
	match current_intent:
		"recover_bomb":
			_state_recover_bomb()
		"plant":
			_state_plant(delta)
		"defuse":
			_state_defuse(delta)
		"retake":
			_state_retake(delta)
		"guard_bomb", "hold", "support", "lurk", "save", "rotate", "cover_planter", "anti_defuse_nade", "fallback_hold":
			_state_route_then_hold(delta, true)
		"take_space", "entry_after_flash":
			_state_route_then_hold(delta, false)
		_:
			_state_route_then_hold(delta, true)

func _state_route_then_hold(delta: float, hold_when_done: bool) -> void:
	if not _route_finished:
		_move_along_route()
		return
	if _process_combat_hold(delta):
		return
	if hold_when_done:
		_hold_position(delta)
	else:
		_start_dwell(maxf(0.2, stats.get_angle_dwell_time() * 0.25))

func _state_plant(delta: float) -> void:
	if bomb_controller == null:
		_state_route_then_hold(delta, true)
		return
	if not _is_bomb_carrier and bomb_controller.get_state_name() == "dropped":
		current_intent = "recover_bomb"
		_state_recover_bomb()
		return
	if not _route_finished:
		_move_along_route()
		return
	var site = _get_bombsite_at_position()
	if site and _is_bomb_carrier:
		if _should_delay_plant(site.site_id):
			_hold_position(delta)
			return
		velocity = Vector3.ZERO
		move_and_slide()
		if bomb_controller.begin_plant(self, site):
			_start_dwell(bomb_controller.PLANT_DURATION + 0.2)
		return
	_hold_position(delta)

func _state_defuse(delta: float) -> void:
	if bomb_controller == null or not bomb_controller.is_planted():
		_state_route_then_hold(delta, true)
		return
	if not _route_finished:
		_move_along_route()
		return
	var site = _get_bombsite_at_position()
	if site and visible_enemies.is_empty() and _can_start_defuse(site.site_id):
		bomb_controller.begin_defuse(self, site)
		return
	_hold_position(delta)

func _state_retake(delta: float) -> void:
	if not _route_finished:
		_move_along_route()
		return
	if _process_combat_hold(delta):
		return
	var site = _get_bombsite_at_position()
	if site and visible_enemies.is_empty() and bomb_controller and bomb_controller.is_planted() and _can_start_defuse(site.site_id):
		bomb_controller.begin_defuse(self, site)
		return
	_hold_position(delta)

func _state_recover_bomb() -> void:
	if bomb_controller == null or bomb_controller.get_state_name() != "dropped":
		return
	if _should_abort_bomb_recovery():
		if _begin_fallback_route():
			current_intent = "save"
		else:
			_hold_position(get_physics_process_delta_time())
		return
	var drop_pos = bomb_controller.get_dropped_position()
	if drop_pos == Vector3.ZERO:
		return
	_navigate_to(drop_pos)
	_move_toward_target(_get_next_navigation_point())
	if global_position.distance_to(drop_pos) <= BOMB_PICKUP_RANGE:
		bomb_controller.pickup_bomb(stats.bot_id)
		set_bomb_carrier(true)

func _state_spotted(_delta: float) -> void:
	if not visible_enemies.is_empty():
		last_known_enemy_pos = visible_enemies[0].global_position
	if last_known_enemy_pos != Vector3.ZERO:
		_face_toward(last_known_enemy_pos)

func _state_engage(delta: float) -> void:
	if visible_enemies.is_empty():
		_gunfight_block_reason = "lost_contact"
		var elapsed = Time.get_ticks_msec() / 1000.0 - last_seen_time
		if elapsed > stats.get_memory_duration():
			_change_state(BotState.PATROL)
			return
		if _should_trade_swing():
			_apply_trade_swing()
		elif _has_fallback_pressure():
			_change_state(BotState.RETREAT)
			return
		else:
			_navigate_to(last_known_enemy_pos)
			_move_toward_target(_get_next_navigation_point())
	else:
		last_known_enemy_pos = visible_enemies[0].global_position
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_last_spotted_source = _lane_label(_get_current_lane())
		_update_gunfight_context(visible_enemies[0], delta)
		_face_toward(last_known_enemy_pos)
		_apply_engage_micro()
		_attempt_gunfight_shot(visible_enemies[0], delta)
	if _should_retreat() and _has_fallback_pressure():
		_change_state(BotState.RETREAT)
	elif bomb_controller and bomb_controller.is_planted() and stats.team == BotStats.Team.CT and current_intent != "defuse":
		current_intent = "retake"
		target_zone_name = "retake"
	elif bomb_controller and bomb_controller.is_planted() and stats.team == BotStats.Team.T and current_intent == "plant":
		current_intent = "guard_bomb"
		target_zone_name = "post_plant"
	_hold_position(delta * 0.0)

func _state_retreat(delta: float) -> void:
	if not _route_finished and not _patrol_waypoints.is_empty():
		_move_along_route()
	else:
		_move_toward_target(_get_next_navigation_point())
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp)
	if hp_ratio > 0.55:
		_change_state(BotState.PATROL if visible_enemies.is_empty() else BotState.ENGAGE)
	elif visible_enemies.is_empty():
		_hold_position(delta)
	if stats.is_dead():
		_die(-1)

func _process_dwell(delta: float) -> void:
	_dwell_timer -= delta
	rotation.y += deg_to_rad(HOLD_SCAN_SPEED_DEG) * _scan_dir * delta
	if _dwell_timer <= 0.0:
		_dwelling = false
		_scan_timer = 0.0

func _hold_position(delta: float) -> void:
	velocity = Vector3.ZERO
	move_and_slide()
	if _process_combat_hold(delta):
		return
	if last_known_enemy_pos != Vector3.ZERO and Time.get_ticks_msec() / 1000.0 - last_seen_time < stats.get_memory_duration():
		_face_toward(last_known_enemy_pos)
		return
	if _threat_dir != Vector3.ZERO:
		_face_toward(global_position + _threat_dir)
	_scan_timer += delta
	if _scan_timer >= 1.2:
		_scan_timer = 0.0
		_scan_dir *= -1.0
	rotation.y += deg_to_rad(HOLD_SCAN_SPEED_DEG * 0.45) * _scan_dir * delta

func _process_combat_hold(delta: float) -> bool:
	if combat_directive.is_empty():
		return false
	_update_gunfight_context(visible_enemies[0] if not visible_enemies.is_empty() else null, delta)
	var base_pos = Vector3(combat_directive.get("hold_position", global_position))
	var look_at_pos = Vector3(combat_directive.get("look_at_position", base_pos))
	var shoulder_pos = Vector3(combat_directive.get("shoulder_position", base_pos))
	var wide_pos = Vector3(combat_directive.get("wide_position", base_pos))
	var fallback_pos = Vector3(combat_directive.get("fallback_position", base_pos))
	var last_target_pos = Vector3(combat_directive.get("last_target_position", Vector3.ZERO))
	var peek_mode = String(combat_directive.get("peek_mode", "hold_angle"))
	var confidence_threshold = float(combat_directive.get("confidence_threshold", 0.35))
	var threat_pos = _get_priority_threat_position()
	var intel_confidence = _get_current_intel_confidence()
	var should_commit = not visible_enemies.is_empty() or intel_confidence >= confidence_threshold or _trade_swing_timer > 0.0 or _commit_window_timer > 0.0
	var peek_cycle_scale = _get_peek_cycle_scale_modifier()
	var prefers_hold_shot = _prefers_hold_shot()
	match peek_mode:
		"reposition":
			if _move_to_anchor(base_pos):
				_face_toward(look_at_pos)
				return true
			combat_directive["peek_mode"] = "hold_angle"
			_update_label()
			return true
		"shoulder_peek":
			var cycle_target = shoulder_pos if _should_peek_now(delta, 1.0 * peek_cycle_scale) else base_pos
			if _move_to_anchor(cycle_target):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true
		"jiggle_info":
			var jiggle_target = shoulder_pos if _should_peek_now(delta, 0.65 * peek_cycle_scale) else base_pos
			if _move_to_anchor(jiggle_target):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true
		"wide_swing":
			var wide_target = shoulder_pos if prefers_hold_shot else (wide_pos if should_commit else base_pos)
			if _move_to_anchor(wide_target):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true
		"trade_swing":
			var trade_target = shoulder_pos if prefers_hold_shot else (wide_pos if _should_trade_swing() or should_commit else base_pos)
			if last_target_pos != Vector3.ZERO:
				_face_toward(last_target_pos)
			elif _move_to_anchor(trade_target):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true
		"clear_corner":
			if _process_clear_corner(base_pos, look_at_pos):
				return true
			return true
		"fallback_hold":
			var fallback_target = fallback_pos if _has_fallback_pressure() else base_pos
			if _move_to_anchor(fallback_target):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true
		_:
			if _move_to_anchor(base_pos):
				_face_toward(threat_pos if threat_pos != Vector3.ZERO else look_at_pos)
			return true

func _move_to_anchor(target_pos: Vector3) -> bool:
	if target_pos == Vector3.ZERO:
		velocity = Vector3.ZERO
		move_and_slide()
		return true
	if global_position.distance_to(target_pos) <= COMBAT_SNAP_DISTANCE:
		velocity = Vector3.ZERO
		move_and_slide()
		return true
	_navigate_to(target_pos)
	_move_toward_target(_get_next_navigation_point())
	return false

func _should_peek_now(delta: float, cycle_scale: float) -> bool:
	_peek_cycle_timer += delta
	var cycle = maxf(0.3, (PEEK_CYCLE_BASE - stats.aggression * 0.35) * cycle_scale)
	if _peek_cycle_timer >= cycle:
		_peek_cycle_timer = 0.0
		_scan_dir *= -1.0
	return _scan_dir > 0.0

func _process_clear_corner(base_pos: Vector3, fallback_look_at: Vector3) -> bool:
	var clear_points: Array = combat_directive.get("clear_points", [])
	if clear_points.is_empty():
		if _move_to_anchor(base_pos):
			_face_toward(fallback_look_at)
		return true
	_clear_point_index = clampi(_clear_point_index, 0, clear_points.size() - 1)
	var point = Vector3(clear_points[_clear_point_index])
	if _move_to_anchor(base_pos):
		_face_toward(point)
		if global_position.distance_to(base_pos) <= COMBAT_SNAP_DISTANCE:
			if point.distance_to(last_known_enemy_pos) <= CLEAR_POINT_RADIUS or _peek_cycle_timer >= maxf(0.25, stats.reaction_time):
				_clear_point_index = (_clear_point_index + 1) % clear_points.size()
				_peek_cycle_timer = 0.0
			else:
				_peek_cycle_timer += get_physics_process_delta_time()
	return true

func _apply_engage_micro() -> void:
	var peek_mode = String(combat_directive.get("peek_mode", "hold_angle"))
	var wide_pos = Vector3(combat_directive.get("wide_position", global_position))
	var shoulder_pos = Vector3(combat_directive.get("shoulder_position", global_position))
	var fallback_pos = Vector3(combat_directive.get("fallback_position", global_position))
	var trade_partner_id = int(combat_directive.get("trade_partner_id", -1))
	var has_partner = trade_partner_id >= 0
	var prefers_hold_shot = _prefers_hold_shot()
	match peek_mode:
		"trade_swing":
			if prefers_hold_shot:
				_move_to_anchor(shoulder_pos)
			elif _should_trade_swing():
				_move_to_anchor(wide_pos)
			else:
				_move_to_anchor(Vector3(combat_directive.get("hold_position", global_position)))
		"wide_swing":
			if prefers_hold_shot:
				_move_to_anchor(shoulder_pos)
			elif stats.aggression > 0.38 or has_partner or _commit_window_timer > 0.0:
				_move_to_anchor(wide_pos)
			else:
				velocity = Vector3.ZERO
				move_and_slide()
		"shoulder_peek", "jiggle_info":
			var peek_target = shoulder_pos if stats.aggression > 0.3 or has_partner or _commit_window_timer > 0.0 else Vector3(combat_directive.get("hold_position", global_position))
			_move_to_anchor(peek_target)
		"fallback_hold":
			if _should_retreat():
				_move_to_anchor(fallback_pos)
			else:
				velocity = Vector3.ZERO
				move_and_slide()
		_:
			if prefers_hold_shot:
				velocity = Vector3.ZERO
				move_and_slide()
			elif stats.aggression > AGGRESSION_PEEK_THRESHOLD or has_partner or _commit_window_timer > 0.0:
				_navigate_to(last_known_enemy_pos)
				_move_toward_target(_get_next_navigation_point())
			else:
				velocity = Vector3.ZERO
				move_and_slide()

func _has_fallback_pressure() -> bool:
	return _should_retreat() or _get_current_intel_confidence() > 0.7

func _should_trade_swing() -> bool:
	if _trade_swing_timer > 0.0:
		return true
	if visible_enemies.is_empty():
		return false
	return stats.aggression > 0.42 or float(stats.current_hp) / float(stats.max_hp) > 0.55

func _apply_trade_swing() -> void:
	var wide_pos = Vector3(combat_directive.get("wide_position", last_known_enemy_pos))
	if wide_pos != Vector3.ZERO:
		_move_to_anchor(wide_pos)
	else:
		_navigate_to(last_known_enemy_pos)
		_move_toward_target(_get_next_navigation_point())

func _update_gunfight_context(target: Node3D, delta: float) -> void:
	if weapon == null or not weapon.has_method("get_engagement_profile"):
		return
	var distance := 0.0
	if target != null:
		distance = global_position.distance_to(target.global_position)
	else:
		var threat_pos = _get_priority_threat_position()
		if threat_pos != Vector3.ZERO:
			distance = global_position.distance_to(threat_pos)
	var hint = String(combat_directive.get("engagement_profile_hint", ""))
	var computed_profile = String(weapon.get_engagement_profile(distance))
	_current_engagement_profile = hint if hint != "" and target == null else computed_profile
	if weapon.has_method("get_default_fire_mode"):
		_current_fire_mode = String(combat_directive.get("preferred_fire_mode", "")) if String(combat_directive.get("preferred_fire_mode", "")) != "" else String(weapon.get_default_fire_mode(distance))
	else:
		_current_fire_mode = String(combat_directive.get("preferred_fire_mode", "tap"))
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp) if stats else 1.0
	var peek_mode = String(combat_directive.get("peek_mode", "hold_angle"))
	if hp_ratio < 0.34 and _current_engagement_profile != "close":
		_current_fire_mode = "tap"
		_gunfight_reason = "wounded"
	elif weapon.has_method("get_weapon_type_name") and String(weapon.get_weapon_type_name()) == "awp":
		_current_fire_mode = "awp_hold"
		_gunfight_reason = "awp_hold"
	elif _current_engagement_profile == "close" and _current_fire_mode == "tap" and peek_mode in ["wide_swing", "trade_swing"]:
		_current_fire_mode = "burst"
		_gunfight_reason = "close_convert"
	else:
		_gunfight_reason = "%s_%s" % [_current_engagement_profile, peek_mode]
	_stabilize_required = bool(combat_directive.get("stabilize_before_peek", false)) or _current_fire_mode in ["tap", "burst", "awp_hold"] or _current_engagement_profile == "long"
	if _current_fire_mode == "spray_commit" and _current_engagement_profile == "close":
		_stabilize_required = false
	var movement_ratio = clampf(velocity.length() / MOVE_SPEED, 0.0, 1.25)
	var stabilize_window = float(combat_directive.get("stabilize_window", 0.1))
	var counter_window = float(combat_directive.get("counter_strafe_window", 0.06))
	if movement_ratio <= 0.16:
		_stabilize_timer = minf(_stabilize_timer + delta, stabilize_window + counter_window)
	else:
		_stabilize_timer = maxf(0.0, _stabilize_timer - delta * 0.5)
	_is_stabilized_for_shot = not _stabilize_required or _stabilize_timer >= stabilize_window
	if target != null and _commit_window_timer <= 0.0:
		_commit_window_timer = float(combat_directive.get("commit_window", 0.45))
	if weapon.has_method("get_accuracy_state"):
		_accuracy_pressure = float(weapon.get_accuracy_state().get("accuracy_penalty", 0.0))

func _attempt_gunfight_shot(target: Node3D, delta: float) -> bool:
	if weapon == null or target == null or not weapon.has_method("try_fire"):
		return false
	_update_gunfight_context(target, delta)
	var distance = global_position.distance_to(target.global_position)
	var movement_ratio = clampf(velocity.length() / MOVE_SPEED, 0.0, 1.25)
	var hold_for_stabilize = _stabilize_required and not _is_stabilized_for_shot
	if _current_fire_mode == "awp_hold" and movement_ratio > 0.06:
		_gunfight_block_reason = "awp_moving"
		return false
	if hold_for_stabilize and movement_ratio > 0.14:
		_gunfight_block_reason = "moving"
		return false
	if hold_for_stabilize:
		_gunfight_block_reason = "stabilizing"
		return false
	if _current_fire_mode == "tap" and movement_ratio > 0.32:
		_gunfight_block_reason = "tap_move"
		return false
	if _current_engagement_profile == "long" and _current_fire_mode == "spray_commit":
		_current_fire_mode = "burst"
		_gunfight_reason = "long_burst"
	var fired = weapon.try_fire(target, stats, {
		"movement_ratio": movement_ratio,
		"distance": distance,
		"fire_mode": _current_fire_mode,
		"stabilized": _is_stabilized_for_shot,
		"peek_mode": String(combat_directive.get("peek_mode", "hold_angle")),
		"engagement_profile": _current_engagement_profile,
		"shot_reason": _gunfight_reason,
	})
	_gunfight_block_reason = "fired" if fired else String(weapon.get_accuracy_state().get("reason", "hold"))
	if fired:
		_last_shot_time = Time.get_ticks_msec() / 1000.0
		if _current_fire_mode in ["tap", "burst", "awp_hold"]:
			_stabilize_timer = maxf(0.0, _stabilize_timer - float(combat_directive.get("counter_strafe_window", 0.06)))
	return fired

func _prefers_hold_shot() -> bool:
	if weapon == null or not weapon.has_method("get_weapon_type_name"):
		return false
	var weapon_type_name = String(weapon.get_weapon_type_name())
	return weapon_type_name == "awp" or (_current_engagement_profile == "long" and _current_fire_mode in ["tap", "awp_hold"])

func _get_peek_cycle_scale_modifier() -> float:
	if weapon == null or not weapon.has_method("get_weapon_type_name"):
		return 1.0
	match String(weapon.get_weapon_type_name()):
		"smg":
			return 0.82
		"awp":
			return 1.22
		_:
			return 1.0

func _start_dwell(duration: float) -> void:
	_dwelling = true
	_dwell_timer = duration

func _move_along_route() -> void:
	if _patrol_waypoints.is_empty():
		_route_finished = true
		velocity = Vector3.ZERO
		move_and_slide()
		return
	var target = _patrol_waypoints[_current_waypoint_idx]
	_navigate_to(target)
	_move_toward_target(_get_next_navigation_point())
	var reached_target = global_position.distance_to(target) <= ROUTE_REACHED_DISTANCE or nav_agent.is_navigation_finished()
	if not reached_target:
		return
	if _current_waypoint_idx < _patrol_waypoints.size() - 1:
		_current_waypoint_idx += 1
		_navigate_to(_patrol_waypoints[_current_waypoint_idx])
	else:
		_route_finished = true
		velocity = Vector3.ZERO
		move_and_slide()

func _process_utility(delta: float) -> bool:
	if tactical_map == null or utility_plan.is_empty():
		return false
	if _active_utility_index == -1:
		_active_utility_index = _find_triggered_utility_step()
		if _active_utility_index == -1:
			return false
		_begin_utility_step(_active_utility_index)
	var step: Dictionary = utility_plan[_active_utility_index]
	var lineup = tactical_map.get_lineup(String(step.get("lineup_id", "")))
	if lineup.is_empty():
		_finish_utility_step(true)
		return false
	if not _has_grenade(String(step.get("grenade_type", ""))):
		_finish_utility_step(true)
		return false
	if _utility_state_name == "setup_lineup":
		_utility_state_timer += delta
		if _should_abort_lineup():
			_finish_utility_step(true)
			return false
		var target_pos = lineup["step_out_position"] if lineup["step_out_position"] != Vector3.ZERO and _utility_state_timer < LINEUP_TIMEOUT * 0.5 else lineup["start_position"]
		_navigate_to(target_pos)
		_move_toward_target(_get_next_navigation_point())
		if global_position.distance_to(target_pos) <= ROUTE_REACHED_DISTANCE + 0.3:
			_utility_state_name = "throw_utility"
			_update_label()
		elif _utility_state_timer >= LINEUP_TIMEOUT:
			_finish_utility_step(true)
			return false
		return true
	if _utility_state_name == "throw_utility":
		var aim_pos = lineup["aim_position"]
		if aim_pos == Vector3.ZERO:
			_finish_utility_step(true)
			return false
		_face_toward(aim_pos)
		var thrown = _throw_active_grenade(lineup)
		_utility_throw_wait = _get_wait_after_throw(String(step.get("grenade_type", "")))
		_utility_state_name = "wait_for_pop" if thrown else "idle"
		if not thrown:
			_finish_utility_step(true)
			return false
		_update_label()
		return true
	if _utility_state_name == "wait_for_pop":
		_utility_throw_wait -= delta
		_hold_position(delta)
		if _utility_throw_wait <= 0.0:
			_apply_follow_intent(String(step.get("follow_intent", "")))
			_finish_utility_step(true)
			return false
		return true
	return false

func _begin_utility_step(index: int) -> void:
	var step: Dictionary = utility_plan[index]
	active_lineup_id = String(step.get("lineup_id", ""))
	_utility_state_name = "setup_lineup"
	_utility_state_timer = 0.0
	_update_label()

func _finish_utility_step(mark_consumed: bool) -> void:
	if _active_utility_index >= 0 and mark_consumed and _active_utility_index < utility_plan.size():
		utility_plan[_active_utility_index]["consumed"] = true
	active_lineup_id = ""
	_utility_state_name = "idle"
	_utility_state_timer = 0.0
	_utility_throw_wait = 0.0
	_active_utility_index = -1
	_update_label()

func _find_triggered_utility_step() -> int:
	for i in range(utility_plan.size()):
		var step: Dictionary = utility_plan[i]
		if bool(step.get("consumed", false)):
			continue
		if not _has_grenade(String(step.get("grenade_type", ""))):
			utility_plan[i]["consumed"] = true
			continue
		var trigger_name = String(step.get("trigger", ""))
		match trigger_name:
			"on_round_start":
				if _live_phase_age >= maxf(0.35, stats.reaction_time * 0.55):
					return i
			"on_reach_zone":
				if _route_finished or _is_near_target_zone():
					return i
			"on_contact":
				if not visible_enemies.is_empty():
					return i
			"before_plant":
				if _should_throw_before_plant():
					return i
			"after_plant":
				if bomb_controller and bomb_controller.is_planted():
					return i
			"on_defuse_started":
				if bomb_controller and bomb_controller.is_defuse_in_progress():
					return i
			"on_retake_start":
				if bomb_controller and bomb_controller.is_planted() and current_intent in ["retake", "defuse"]:
					return i
	return -1

func _should_throw_before_plant() -> bool:
	if bomb_controller == null or bomb_controller.is_planted():
		return false
	if current_intent not in ["plant", "support", "cover_planter"]:
		return false
	if _is_bomb_carrier and _route_finished:
		return true
	return _is_near_target_zone()

func _should_abort_lineup() -> bool:
	if not visible_enemies.is_empty():
		return global_position.distance_to(visible_enemies[0].global_position) <= CLOSE_ENEMY_ABORT_DISTANCE
	return _get_current_intel_confidence() > 0.78 and stats.game_sense < 6

func _is_near_target_zone() -> bool:
	if _patrol_waypoints.is_empty():
		return false
	var goal = _patrol_waypoints[_patrol_waypoints.size() - 1]
	return global_position.distance_to(goal) <= 4.0

func _throw_active_grenade(lineup: Dictionary) -> bool:
	var grenade_name = String(lineup.get("grenade_type", ""))
	if not _remove_grenade(grenade_name):
		return false
	var grenade = GRENADE_SCENE.instantiate()
	if grenade == null:
		return false
	var origin = eye_pos.global_position + (-global_transform.basis.z) * UTILITY_THROW_DISTANCE + Vector3(0, 0.2, 0)
	var target = Vector3(lineup.get("aim_position", origin))
	var throw_strength = float(lineup.get("throw_strength", 12.0))
	var velocity_vec = _calculate_throw_velocity(origin, target, throw_strength)
	get_tree().current_scene.add_child(grenade)
	if grenade.has_method("set_grenade_type_by_name"):
		grenade.set_grenade_type_by_name(grenade_name)
	if grenade.has_signal("grenade_detonated"):
		grenade.grenade_detonated.connect(_on_grenade_detonated)
	grenade.throw(origin, velocity_vec, stats.bot_id)
	return true

func _calculate_throw_velocity(origin: Vector3, target: Vector3, throw_strength: float) -> Vector3:
	var flat = target - origin
	flat.y = 0.0
	var flat_dir = flat.normalized() if flat.length() > 0.1 else -global_transform.basis.z
	var arc_height = clamp(flat.length() * 0.18 + 5.0, 5.0, 9.5)
	return flat_dir * throw_strength + Vector3.UP * arc_height

func _get_wait_after_throw(grenade_name: String) -> float:
	match grenade_name:
		"flash":
			return maxf(0.25, stats.reaction_time * 0.45)
		"smoke":
			return 0.65
		_:
			return 0.35

func _apply_follow_intent(follow_intent: String) -> void:
	match follow_intent:
		"entry_after_flash":
			current_intent = "take_space"
			if not combat_directive.is_empty():
				combat_directive["peek_mode"] = "wide_swing"
		"cover_planter":
			current_intent = "cover_planter"
			if not combat_directive.is_empty():
				combat_directive["peek_mode"] = "hold_angle"
		"anti_defuse_nade":
			current_intent = "anti_defuse_nade"
		"guard_bomb":
			current_intent = "guard_bomb"
		"retake":
			current_intent = "retake"
		"hold":
			current_intent = "hold"
		"trade_swing":
			current_intent = "take_space"
			if not combat_directive.is_empty():
				combat_directive["peek_mode"] = "trade_swing"
				_trade_swing_timer = TRADE_SWING_WINDOW
				_commit_window_timer = float(combat_directive.get("commit_window", 0.45))
		_:
			if follow_intent != "":
				current_intent = follow_intent

func _has_grenade(grenade_name: String) -> bool:
	return grenade_name in grenade_inventory

func _remove_grenade(grenade_name: String) -> bool:
	var idx = grenade_inventory.find(grenade_name)
	if idx == -1:
		return false
	grenade_inventory.remove_at(idx)
	_update_label()
	return true

func _perception_tick() -> void:
	if current_state == BotState.DEAD or _is_blinded or not _is_live:
		visible_enemies.clear()
		return
	var previous_enemy_id = _get_bot_id(visible_enemies[0]) if not visible_enemies.is_empty() else -1
	visible_enemies.clear()
	for body in perception_area.get_overlapping_bodies():
		if not _is_enemy(body):
			continue
		if not _is_in_fov(body.global_position):
			continue
		if not _has_line_of_sight(body):
			continue
		visible_enemies.append(body)
	visible_enemies.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(global_position) < b.global_position.distance_squared_to(global_position))
	if not visible_enemies.is_empty():
		last_known_enemy_pos = visible_enemies[0].global_position
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_last_spotted_source = _lane_label(_get_current_lane())
		if current_state == BotState.PATROL or current_state == BotState.IDLE or current_state == BotState.RETREAT:
			emit_signal("enemy_spotted", stats.bot_id, _get_bot_id(visible_enemies[0]), visible_enemies[0].global_position)
			_change_state(BotState.SPOTTED_ENEMY)
	elif previous_enemy_id >= 0 and current_state == BotState.ENGAGE:
		emit_signal("enemy_lost", stats.bot_id, previous_enemy_id)

func _is_in_fov(target_pos: Vector3) -> bool:
	var to_target = (target_pos - global_position).normalized()
	var forward = -global_transform.basis.z
	return forward.dot(to_target) > cos(deg_to_rad(FOV_HALF_ANGLE_DEG))

func _has_line_of_sight(target: Node3D) -> bool:
	var from = eye_pos.global_position
	var to = target.global_position + Vector3(0, 1.4, 0)
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self]
	query.collision_mask = WALL_COLLISION_LAYER | SMOKE_COLLISION_LAYER
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _is_enemy(body: Node3D) -> bool:
	if not body.has_method("get_team"):
		return false
	if body is BotBrain and body.current_state == BotBrain.BotState.DEAD:
		return false
	return body.get_team() != stats.team

func _get_bot_id(body: Node3D) -> int:
	if body is BotBrain:
		return body.stats.bot_id
	return -1

func _navigate_to(target: Vector3) -> void:
	_dynamic_target = target
	if tactical_map and tactical_map.has_method("build_path"):
		_dynamic_path = tactical_map.build_path(global_position, target)
	else:
		_dynamic_path = [target]
		nav_agent.target_position = target

func _get_next_navigation_point() -> Vector3:
	while not _dynamic_path.is_empty() and global_position.distance_to(_dynamic_path[0]) <= ROUTE_REACHED_DISTANCE:
		_dynamic_path.remove_at(0)
	if not _dynamic_path.is_empty():
		return _dynamic_path[0]
	return nav_agent.get_next_path_position()

func _move_toward_target(next_pos: Vector3) -> void:
	var direction = next_pos - global_position
	direction.y = 0.0
	if direction.length() > 0.1:
		var distance = direction.length()
		direction = direction.normalized()
		velocity = direction * minf(MOVE_SPEED, maxf(1.2, distance * 2.0))
		move_and_slide()
		_emit_footstep_event_if_needed(velocity.length())
	else:
		velocity = Vector3.ZERO
		move_and_slide()

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	if not _is_live or current_state == BotState.DEAD:
		velocity = Vector3.ZERO
		return
	# Legacy hook for old navmesh flow. Runtime movement now follows authored path graph.
	if _dynamic_path.is_empty():
		velocity = safe_velocity
		move_and_slide()
		_emit_footstep_event_if_needed(velocity.length())

func _face_toward(target_pos: Vector3) -> void:
	var dir = target_pos - global_position
	dir.y = 0.0
	if dir.length() > 0.01:
		look_at(global_position + dir, Vector3.UP)

func _find_cover_position() -> Vector3:
	var fallback_pos = Vector3(combat_directive.get("fallback_position", Vector3.ZERO))
	if fallback_pos != Vector3.ZERO:
		return fallback_pos
	if last_known_enemy_pos == Vector3.ZERO:
		return global_position
	var away = (global_position - last_known_enemy_pos).normalized() * 8.0
	return global_position + away

func _begin_fallback_route() -> bool:
	if tactical_map == null:
		return false
	var route_id = String(combat_directive.get("fallback_route_id", ""))
	if route_id == "":
		return false
	var route = tactical_map.get_fallback_route(route_id)
	if route.is_empty():
		return false
	set_patrol_waypoints(route)
	current_intent = "fallback_hold"
	return true

func _should_retreat() -> bool:
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp)
	return hp_ratio < stats.get_retreat_threshold()

func assign_round_order(new_role_name: String, intent: String, target_zone: String, route: Array[Vector3]) -> void:
	role_name = new_role_name
	current_intent = intent
	target_zone_name = target_zone
	set_patrol_waypoints(route)
	_trade_swing_timer = 0.0
	_clear_point_index = 0
	_update_label()

func assign_utility_plan(steps: Array) -> void:
	utility_plan.clear()
	for step in steps:
		utility_plan.append(step.duplicate(true))
	_active_utility_index = -1
	active_lineup_id = ""
	_utility_state_name = "idle"
	_update_label()

func assign_combat_directive(directive: Dictionary) -> void:
	combat_directive = directive.duplicate(true)
	_peek_cycle_timer = 0.0
	_trade_swing_timer = TRADE_SWING_WINDOW if String(combat_directive.get("peek_mode", "")) == "trade_swing" else 0.0
	_commit_window_timer = float(combat_directive.get("commit_window", 0.45)) if String(combat_directive.get("peek_mode", "")) in ["trade_swing", "wide_swing"] else 0.0
	_clear_point_index = 0
	_current_fire_mode = String(combat_directive.get("preferred_fire_mode", "tap"))
	_current_engagement_profile = String(combat_directive.get("engagement_profile_hint", "mid"))
	_stabilize_required = bool(combat_directive.get("stabilize_before_peek", false))
	_stabilize_timer = 0.0
	_is_stabilized_for_shot = not _stabilize_required
	if Vector3(combat_directive.get("look_at_position", Vector3.ZERO)) != Vector3.ZERO:
		_threat_dir = (Vector3(combat_directive.get("look_at_position", Vector3.ZERO)) - global_position).normalized()
	_update_label()

func assign_duty_package(duty: Dictionary) -> void:
	duty_package = duty.duplicate(true)
	var route: Array[Vector3] = []
	for point in duty_package.get("route", []):
		route.append(Vector3(point))
	assign_round_order(
		String(duty_package.get("role", "unassigned")),
		String(duty_package.get("intent", "idle")),
		String(duty_package.get("lane_target", duty_package.get("site_target", ""))),
		route
	)
	assign_utility_plan(duty_package.get("utility_plan", []))
	assign_combat_directive(duty_package.get("combat_directive", {}))
	update_bomb_task(duty_package.get("bomb_task", {}))

func update_bomb_task(task: Dictionary) -> void:
	bomb_task = task.duplicate(true)
	if bomb_task.is_empty():
		return
	if bomb_task.has("task_intent") and String(bomb_task.get("task_intent", "")) != "":
		current_intent = String(bomb_task.get("task_intent", current_intent))
	if bomb_task.has("lane_target") and String(bomb_task.get("lane_target", "")) != "":
		target_zone_name = String(bomb_task.get("lane_target", target_zone_name))
	_update_label()

func notify_heard_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	_heard_events.append(event.duplicate(true))
	_last_heard_source = "%s:%s" % [_lane_label(String(event.get("lane_id", "unknown"))), String(event.get("event_type", "noise"))]
	var confidence = float(event.get("confidence", 0.0))
	if confidence >= INTEL_PROMOTE_THRESHOLD:
		last_known_enemy_pos = Vector3(event.get("world_pos", Vector3.ZERO))
		last_seen_time = Time.get_ticks_msec() / 1000.0 - maxf(0.0, 1.0 - confidence)
	if current_state == BotState.IDLE:
		_change_state(BotState.PATROL)
	_update_label()

func apply_loadout(loadout, money_after_buy: int) -> void:
	current_loadout = loadout.clone() if loadout else null
	current_money = money_after_buy
	grenade_inventory = current_loadout.grenades.duplicate() if current_loadout else []
	stats.armor = current_loadout.armor_value if current_loadout else 0
	stats.has_defuse_kit = current_loadout.has_defuse_kit if current_loadout else false
	if weapon and current_loadout:
		match current_loadout.weapon_type:
			"rifle":
				weapon.set_weapon_type(Weapon.WeaponType.RIFLE)
			"smg":
				weapon.set_weapon_type(Weapon.WeaponType.SMG)
			"awp":
				weapon.set_weapon_type(Weapon.WeaponType.AWP)
			_:
				weapon.set_weapon_type(Weapon.WeaponType.PISTOL)
	_update_label()

func get_grenade_names() -> Array[String]:
	return grenade_inventory.duplicate()

func get_loadout_summary() -> String:
	if current_loadout == null:
		return "no loadout"
	return current_loadout.get_summary()

func get_combat_summary() -> String:
	var lane_id = String(combat_directive.get("lane_id", _get_current_lane()))
	var partner_id = int(combat_directive.get("trade_partner_id", -1))
	var mode = String(combat_directive.get("peek_mode", "hold_angle"))
	return "%s %s lane:%s tp:%d fm:%s" % [role_name, mode, _lane_label(lane_id), partner_id, _current_fire_mode]

func get_gunfight_summary() -> String:
	return "%s %s %s %s %.2f %s" % [
		stats.display_name if stats else "Bot",
		_current_fire_mode,
		_current_engagement_profile,
		"STAB" if _is_stabilized_for_shot else "MOVE",
		_accuracy_pressure,
		_gunfight_block_reason,
	]

func get_observability_summary() -> String:
	var hp = stats.current_hp if stats else 0
	var weapon_text = weapon.weapon_name if weapon != null else "Pistol"
	var grenades = ",".join(grenade_inventory) if not grenade_inventory.is_empty() else "-"
	var combat_mode = String(combat_directive.get("peek_mode", "hold"))
	var lane_id = String(combat_directive.get("lane_id", _get_current_lane()))
	var partner_id = int(combat_directive.get("trade_partner_id", -1))
	var intel_text = _last_heard_source if _last_heard_source != "none" else _last_spotted_source
	if intel_text == "none":
		intel_text = "-"
	var weapon_state = weapon.get_debug_summary() if weapon and weapon.has_method("get_debug_summary") else "-"
	return "%s %dHP $%d %s | %s/%s | %s %s tp:%d | FM:%s %s %s acc:%.2f %s | WS:%s | G:%s | I:%s" % [
		stats.display_name if stats else "Bot",
		hp,
		current_money,
		weapon_text,
		role_name,
		current_intent,
		combat_mode,
		_lane_label(lane_id),
		partner_id,
		_current_fire_mode,
		_current_engagement_profile,
		"STAB" if _is_stabilized_for_shot else "MOVE",
		_accuracy_pressure,
		_gunfight_block_reason,
		weapon_state,
		grenades,
		intel_text,
	]

func get_compact_status_summary() -> String:
	var site_id = String(duty_package.get("site_target", bomb_task.get("site_id", "")))
	var lane_id = String(duty_package.get("lane_target", combat_directive.get("lane_id", _get_current_lane())))
	var bomb_icon = "⬢" if _is_bomb_carrier else ("⌁" if current_intent == "defuse" else ("⚑" if current_intent in ["plant", "cover_planter"] else ""))
	return "%s%s%s%s" % [
		_role_icon(role_name),
		_intent_icon(current_intent),
		bomb_icon,
		_lane_code(lane_id) if lane_id != "" else site_id,
	]

func get_verbose_status_summary() -> String:
	var site_id = String(duty_package.get("site_target", bomb_task.get("site_id", "")))
	var lane_id = String(duty_package.get("lane_target", combat_directive.get("lane_id", _get_current_lane())))
	var bomb_task_type = String(bomb_task.get("task_type", "-"))
	return "%s site:%s lane:%s role:%s intent:%s bomb:%s util:%s combat:%s" % [
		stats.display_name if stats else "Bot",
		site_id,
		lane_id,
		role_name,
		current_intent,
		bomb_task_type,
		active_lineup_id if active_lineup_id != "" else _utility_state_name,
		String(combat_directive.get("peek_mode", "hold_angle")),
	]

func get_active_lineup_id() -> String:
	return active_lineup_id

func set_patrol_waypoints(waypoints: Array[Vector3]) -> void:
	_patrol_waypoints = waypoints.duplicate()
	_current_waypoint_idx = 0
	_dynamic_path.clear()
	_dynamic_target = Vector3.ZERO
	_route_finished = _patrol_waypoints.is_empty()
	if not _route_finished:
		_navigate_to(_patrol_waypoints[_current_waypoint_idx])

func clear_route() -> void:
	_patrol_waypoints.clear()
	_current_waypoint_idx = 0
	_dynamic_path.clear()
	_dynamic_target = Vector3.ZERO
	_route_finished = true

func get_team() -> BotStats.Team:
	return stats.team

func get_role_name() -> String:
	return role_name

func get_intent_name() -> String:
	return current_intent

func set_threat_direction(dir: Vector3) -> void:
	_threat_dir = dir.normalized()

func set_bomb_controller(controller) -> void:
	bomb_controller = controller

func set_tactical_map(map_ref) -> void:
	tactical_map = map_ref

func set_label_verbose(value: bool) -> void:
	_label_verbose = value
	_label_update_cooldown = 0.0
	_update_label()

func enable_rl_mode(server: RLServer) -> void:
	rl_server = server
	_rl_mode = true

const _RL_DIRS: Array = [
	Vector3(0, 0, 0), Vector3(0, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 0),
	Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(-1, 0, 1), Vector3(-1, 0, 0), Vector3(-1, 0, -1)
]

func _apply_rl_action() -> void:
	if not rl_server:
		return
	var act: Dictionary = rl_server.get_action(stats.bot_id)
	var move_idx = clampi(int(act.get("move", 0)), 0, 8)
	var shoot = bool(act.get("shoot", false))
	var dir: Vector3 = _RL_DIRS[move_idx].normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * MOVE_SPEED
		velocity.z = dir.z * MOVE_SPEED
		_face_toward(global_position + dir)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()
	if shoot and weapon and not visible_enemies.is_empty():
		weapon.try_fire(visible_enemies[0], stats, {
			"movement_ratio": clampf(velocity.length() / MOVE_SPEED, 0.0, 1.25),
			"distance": global_position.distance_to(visible_enemies[0].global_position),
			"fire_mode": "burst",
			"stabilized": velocity.length() <= 0.1,
			"peek_mode": "hold_angle",
			"engagement_profile": "mid",
			"shot_reason": "rl",
		})
	if bomb_controller == null:
		return
	var site = _get_bombsite_at_position()
	if site and dir == Vector3.ZERO:
		if _is_bomb_carrier and stats.team == BotStats.Team.T and bomb_controller.get_state_name() == "carried":
			bomb_controller.begin_plant(self, site)
		elif stats.team == BotStats.Team.CT and bomb_controller.is_planted():
			bomb_controller.begin_defuse(self, site)

func set_bomb_carrier(value: bool) -> void:
	_is_bomb_carrier = value
	_update_label()
	if value and not _bomb_indicator:
		_bomb_indicator = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 0.28
		sphere.height = 0.56
		_bomb_indicator.mesh = sphere
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.2, 0.05)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.1, 0.0)
		mat.emission_energy_multiplier = 5.0
		_bomb_indicator.material_override = mat
		_bomb_indicator.position = Vector3(0, 2.2, 0)
		add_child(_bomb_indicator)
	elif _bomb_indicator:
		_bomb_indicator.visible = value

func _get_bombsite_at_position() -> Bombsite:
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site is Bombsite and site.contains_point(global_position):
			return site
	return null

func receive_team_intel(_enemy_id: int, pos: Vector3) -> void:
	last_known_enemy_pos = pos
	last_seen_time = Time.get_ticks_msec() / 1000.0
	_last_spotted_source = _lane_label(_get_current_lane())
	if current_state == BotState.IDLE:
		_change_state(BotState.PATROL)

func apply_damage(amount: int, source_id: int, source_pos: Vector3 = Vector3.ZERO) -> void:
	stats.take_damage(amount)
	emit_signal("damage_taken", stats.bot_id, amount, source_id)
	_update_label()
	if stats.is_dead():
		_die(source_id)
		return
	_react_to_damage(source_pos)

func _react_to_damage(source_pos: Vector3) -> void:
	if source_pos != Vector3.ZERO:
		last_known_enemy_pos = source_pos
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_last_spotted_source = _lane_label(tactical_map.get_lane_id_from_position(source_pos) if tactical_map else "unknown")
	if current_state == BotState.ENGAGE or current_state == BotState.SPOTTED_ENEMY or current_state == BotState.DEAD:
		return
	if source_pos != Vector3.ZERO:
		_face_toward(source_pos)
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp)
	if hp_ratio > 0.3:
		_change_state(BotState.ENGAGE)
	else:
		_change_state(BotState.RETREAT)

func start_round() -> void:
	_is_live = false
	_live_phase_age = 0.0
	stats.reset_hp()
	_apply_runtime_team_setup()
	visible_enemies.clear()
	last_known_enemy_pos = Vector3.ZERO
	last_seen_time = 0.0
	role_name = "unassigned"
	current_intent = "idle"
	target_zone_name = ""
	current_loadout = null
	duty_package.clear()
	bomb_task.clear()
	grenade_inventory.clear()
	current_money = 0
	active_lineup_id = ""
	utility_plan.clear()
	combat_directive.clear()
	_heard_events.clear()
	_last_heard_source = "none"
	_last_spotted_source = "none"
	_last_audio_lane = ""
	_current_fire_mode = "tap"
	_current_engagement_profile = "mid"
	_gunfight_block_reason = "idle"
	_gunfight_reason = "idle"
	_accuracy_pressure = 0.0
	_commit_window_timer = 0.0
	_stabilize_timer = 0.0
	_stabilize_required = false
	_is_stabilized_for_shot = true
	_label_verbose = false
	_label_update_cooldown = 0.0
	set_bomb_carrier(false)
	clear_route()
	_dwelling = false
	_dwell_timer = 0.0
	_scan_timer = 0.0
	_peek_cycle_timer = 0.0
	_trade_swing_timer = 0.0
	_clear_point_index = 0
	_footstep_timer = 0.0
	_active_utility_index = -1
	_utility_state_name = "idle"
	_utility_state_timer = 0.0
	_utility_throw_wait = 0.0
	if _body_mesh:
		_body_mesh.rotation_degrees.z = 0.0
	_set_team_color()
	_change_state(BotState.IDLE)

func begin_live_phase() -> void:
	if current_state == BotState.DEAD:
		return
	_is_live = true
	if current_state == BotState.IDLE:
		_change_state(BotState.PATROL)

func freeze_bot() -> void:
	_is_live = false
	velocity = Vector3.ZERO

func _on_reaction_timeout() -> void:
	if current_state != BotState.SPOTTED_ENEMY:
		return
	if not visible_enemies.is_empty():
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_change_state(BotState.ENGAGE)
	else:
		_change_state(BotState.PATROL)

func _die(killer_id: int) -> void:
	_change_state(BotState.DEAD)
	velocity = Vector3.ZERO
	if bomb_controller:
		bomb_controller.cancel_defuse_by(stats.bot_id)
	set_bomb_carrier(false)
	emit_signal("bot_died", stats.bot_id, killer_id)
	if _body_mesh:
		_body_mesh.rotation_degrees.z = 90.0
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.25, 0.25, 0.25)
		_body_mesh.material_override = mat

func _update_label() -> void:
	if not debug_label or not stats:
		return
	if _label_update_cooldown > 0.0:
		return
	_label_update_cooldown = LABEL_UPDATE_INTERVAL
	debug_label.visible = true
	if not _label_verbose:
		debug_label.text = get_compact_status_summary()
		return
	var state_name = BotState.keys()[current_state]
	var bomb_mark = " [B]" if _is_bomb_carrier else ""
	var grenade_text = ",".join(grenade_inventory) if not grenade_inventory.is_empty() else "-"
	var weapon_text = weapon.weapon_name if weapon != null else "Pistol"
	var utility_text = active_lineup_id if active_lineup_id != "" else _utility_state_name
	var combat_text = String(combat_directive.get("peek_mode", "hold_angle"))
	var trade_partner = int(combat_directive.get("trade_partner_id", -1))
	var lane_id = String(combat_directive.get("lane_id", _get_current_lane()))
	var weapon_state = weapon.get_debug_summary() if weapon and weapon.has_method("get_debug_summary") else "-"
	debug_label.text = "%s%s\n%s/%s\n$%d %s\nG:%s\nU:%s\nC:%s tp:%d %s\nF:%s %s %s %.2f %s\nW:%s\nI:%s | %s" % [
		state_name,
		bomb_mark,
		role_name,
		current_intent,
		current_money,
		weapon_text,
		grenade_text,
		utility_text,
		combat_text,
		trade_partner,
		_lane_label(lane_id),
		_current_fire_mode,
		_current_engagement_profile,
		"STAB" if _is_stabilized_for_shot else "MOVE",
		_accuracy_pressure,
		_gunfight_block_reason,
		weapon_state,
		_last_heard_source,
		_last_spotted_source,
	]

func _get_compact_label_text() -> String:
	var lane_id = String(combat_directive.get("lane_id", _get_current_lane()))
	return "%s%s%s%s" % [
		_role_icon(role_name),
		_intent_icon(current_intent),
		"💣" if _is_bomb_carrier else ("🔧" if current_intent == "defuse" else ("✦" if active_lineup_id != "" else "")),
		_lane_code(lane_id),
	]

func _should_delay_plant(site_id: String) -> bool:
	if bomb_controller == null:
		return false
	if not _is_bomb_carrier:
		return false
	if current_intent not in ["plant", "carry_bomb", "carry", "clear_for_plant"]:
		return false
	if not visible_enemies.is_empty():
		return true
	var intel_confidence = _get_current_intel_confidence()
	if intel_confidence > 0.68 and not _has_nearby_teammate_cover(site_id):
		return true
	var slot = tactical_map.get_plant_slot(site_id, String(bomb_task.get("slot_id", "default"))) if tactical_map else {}
	if slot.is_empty():
		return false
	var plant_pos = Vector3(slot.get("position", global_position))
	return global_position.distance_to(plant_pos) > 2.8

func _can_start_defuse(site_id: String) -> bool:
	if bomb_controller == null:
		return false
	if not bomb_controller.is_planted():
		return false
	if site_id != bomb_controller.get_active_site_id():
		return false
	if not visible_enemies.is_empty():
		return false
	if _has_nearby_teammate_cover(site_id):
		return true
	var seconds_left = bomb_controller.get_seconds_remaining()
	if stats.has_defuse_kit:
		return seconds_left <= 9.0 or float(stats.current_hp) / float(stats.max_hp) > 0.65
	return seconds_left <= 5.5

func _should_abort_bomb_recovery() -> bool:
	if String(bomb_task.get("task_type", "")) == "save_bomb":
		return true
	if visible_enemies.is_empty():
		return false
	var enemy_distance = global_position.distance_to(visible_enemies[0].global_position)
	if enemy_distance > CLOSE_ENEMY_ABORT_DISTANCE:
		return false
	return float(stats.current_hp) / float(stats.max_hp) < 0.55 or String(bomb_task.get("abort_conditions", "")) == "hard_contact_abort"

func _has_nearby_teammate_cover(site_id: String) -> bool:
	var ally_group = "t_bots" if stats.team == BotStats.Team.T else "ct_bots"
	for ally in get_tree().get_nodes_in_group(ally_group):
		if ally == self or not (ally is BotBrain):
			continue
		if ally.current_state == BotState.DEAD:
			continue
		var ally_site = String(ally.duty_package.get("site_target", ally.bomb_task.get("site_id", ally.target_zone_name)))
		if ally_site != "" and ally_site != site_id:
			continue
		if ally.global_position.distance_to(global_position) <= 18.0:
			return true
	return false

func _role_icon(value: String) -> String:
	match value:
		"entry":
			return "▲"
		"trade", "second":
			return "◆"
		"support":
			return "●"
		"lurker":
			return "◌"
		"carrier":
			return "⬢"
		"a_anchor", "b_anchor", "anchor":
			return "■"
		"mid_rotator", "rotator":
			return "↺"
		"long_contest":
			return "▤"
		"retaker":
			return "✚"
		"defuser":
			return "✚"
		"post_plant", "post_plant_anchor":
			return "▣"
		"anti_defuse_thrower":
			return "✦"
		"save":
			return "⌂"
		_:
			return "•"

func _intent_icon(value: String) -> String:
	match value:
		"take_space", "rotate", "retake":
			return "→"
		"hold", "guard_bomb", "fallback_hold":
			return "◉"
		"recover_bomb":
			return "↓"
		"plant":
			return "⚑"
		"defuse":
			return "⌁"
		"support", "cover_planter":
			return "⟂"
		"lurk":
			return "◍"
		_:
			return ""

func _lane_code(lane_id: String) -> String:
	match lane_id:
		"a_long":
			return "AL"
		"a_site":
			return "AS"
		"short_a":
			return "SA"
		"mid":
			return "M"
		"mid_doors":
			return "MD"
		"b_tunnels":
			return "BT"
		"b_window":
			return "BW"
		"b_site":
			return "BS"
		"ct_spawn":
			return "CT"
		"t_spawn":
			return "TS"
		_:
			return ""

func _set_team_color() -> void:
	if not _body_mesh or not stats:
		return
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.4, 0.9) if stats.team == BotStats.Team.CT else Color(0.9, 0.5, 0.1)
	_body_mesh.material_override = mat

func _apply_runtime_team_setup() -> void:
	if not stats:
		return
	collision_layer = TEAM_COLLISION_LAYER_CT if stats.team == BotStats.Team.CT else TEAM_COLLISION_LAYER_T
	collision_mask = WALL_COLLISION_LAYER
	perception_area.collision_mask = TEAM_COLLISION_LAYER_CT | TEAM_COLLISION_LAYER_T

func apply_flash(duration: float) -> void:
	_is_blinded = true
	await get_tree().create_timer(duration).timeout
	_is_blinded = false

func _on_weapon_shot_fired(shooter_id: int, _direction: Vector3) -> void:
	if shooter_id != stats.bot_id:
		return
	_last_shot_time = Time.get_ticks_msec() / 1000.0
	_emit_audio_event("gunshot", global_position, 0.95, GUNSHOT_TTL, weapon.weapon_name if weapon else "weapon")

func _on_grenade_detonated(grenade_type: String, position: Vector3) -> void:
	_emit_audio_event("grenade_pop", position, 0.82, GRENADE_TTL, grenade_type.to_lower())

func _emit_footstep_event_if_needed(move_speed: float) -> void:
	if move_speed < FOOTSTEP_SPEED_THRESHOLD or _footstep_timer > 0.0:
		return
	_footstep_timer = maxf(0.25, FOOTSTEP_EMIT_INTERVAL - stats.aggression * 0.18)
	_emit_audio_event("footsteps", global_position, 0.46 + stats.aggression * 0.2, FOOTSTEP_TTL, role_name)

func _emit_audio_event(event_type: String, world_pos: Vector3, confidence: float, ttl: float, detail: String) -> void:
	if stats == null:
		return
	var lane_id = tactical_map.get_lane_id_from_position(world_pos) if tactical_map else "unknown"
	_last_audio_lane = lane_id
	var intel_event = IntelEventDataScript.new()
	intel_event.event_type = event_type
	intel_event.world_pos = world_pos
	intel_event.lane_id = lane_id
	intel_event.confidence = confidence
	intel_event.ttl = ttl
	intel_event.source_team = int(stats.team)
	intel_event.source_bot_id = stats.bot_id
	intel_event.detail = detail
	intel_event.volume = confidence
	emit_signal("audio_event_emitted", intel_event.to_dict())

func _decay_local_intel(delta: float) -> void:
	var keep: Array = []
	for event in _heard_events:
		var updated = event.duplicate(true)
		updated["ttl"] = float(updated.get("ttl", 0.0)) - delta
		updated["confidence"] = maxf(0.0, float(updated.get("confidence", 0.0)) - delta * COMBAT_MEMORY_DECAY)
		if float(updated.get("ttl", 0.0)) > 0.0 and float(updated.get("confidence", 0.0)) > 0.0:
			keep.append(updated)
	_heard_events = keep

func _get_priority_threat_position() -> Vector3:
	if not visible_enemies.is_empty():
		return visible_enemies[0].global_position
	if last_known_enemy_pos != Vector3.ZERO and Time.get_ticks_msec() / 1000.0 - last_seen_time < stats.get_memory_duration():
		return last_known_enemy_pos
	var best_confidence := -1.0
	var best_pos := Vector3.ZERO
	for event in _heard_events:
		var confidence = float(event.get("confidence", 0.0))
		if confidence > best_confidence:
			best_confidence = confidence
			best_pos = Vector3(event.get("world_pos", Vector3.ZERO))
	return best_pos

func _get_current_intel_confidence() -> float:
	if not visible_enemies.is_empty():
		return 1.0
	var best := 0.0
	for event in _heard_events:
		best = maxf(best, float(event.get("confidence", 0.0)))
	return best

func _get_current_lane() -> String:
	if tactical_map == null:
		return "unknown"
	return tactical_map.get_lane_id_from_position(global_position)

func _lane_label(lane_id: String) -> String:
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
			return "CT Spawn"
		"t_spawn":
			return "T Spawn"
		_:
			return lane_id.capitalize()
