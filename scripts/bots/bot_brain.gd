# bot_brain.gd
# FSM бота: IDLE → PATROL → SPOTTED_ENEMY → ENGAGE → RETREAT → DEAD
# Зависимости: bot_stats.gd (Resource), NavigationAgent3D, weapon.gd (дочерний узел)

extends CharacterBody3D
class_name BotBrain

signal enemy_spotted(reporter_id: int, enemy_id: int, position: Vector3)
signal enemy_lost(reporter_id: int, enemy_id: int)
signal requesting_suppression(reporter_id: int, position: Vector3, priority: float)
signal bot_died(bot_id: int, killer_id: int)
signal state_changed(bot_id: int, new_state: int)
signal damage_taken(bot_id: int, amount: int, source_id: int)

enum BotState { IDLE, PATROL, SPOTTED_ENEMY, ENGAGE, RETREAT, DEAD }

const MOVE_SPEED: float = 4.0
const WALL_COLLISION_LAYER: int = 1   # слой "walls" из project.godot
const SMOKE_COLLISION_LAYER: int = 2  # слой "smoke"
const FOV_HALF_ANGLE_DEG: float = 60.0
const PERCEPTION_TICK: float = 0.1
const AGGRESSION_PEEK_THRESHOLD: float = 0.6

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
var _is_blinded: bool = false
var _team: Node = null
var _patrol_waypoints: Array[Vector3] = []
var _current_waypoint_idx: int = 0
var _dwell_timer: float = 0.0
var _dwelling: bool = false

func _ready() -> void:
	reaction_timer.one_shot = true
	reaction_timer.timeout.connect(_on_reaction_timeout)
	perception_timer.wait_time = PERCEPTION_TICK
	perception_timer.autostart = true
	perception_timer.timeout.connect(_perception_tick)
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	if not team_node_path.is_empty():
		_team = get_node(team_node_path)

func _physics_process(delta: float) -> void:
	if current_state == BotState.DEAD:
		return
	match current_state:
		BotState.IDLE:     pass
		BotState.PATROL:   _state_patrol(delta)
		BotState.SPOTTED_ENEMY: _state_spotted(delta)
		BotState.ENGAGE:   _state_engage(delta)
		BotState.RETREAT:  _state_retreat(delta)

# ── Смена состояния ─────────────────────────────────────────────────────────

func _change_state(new_state: BotState) -> void:
	_exit_state(current_state)
	current_state = new_state
	_enter_state(new_state)
	emit_signal("state_changed", stats.bot_id, new_state)
	if debug_label:
		debug_label.text = BotState.keys()[new_state]

func _enter_state(s: BotState) -> void:
	match s:
		BotState.PATROL:
			_pick_next_waypoint()
		BotState.SPOTTED_ENEMY:
			reaction_timer.wait_time = stats.reaction_time
			reaction_timer.start()
		BotState.ENGAGE:
			pass
		BotState.RETREAT:
			_navigate_to(_find_cover_position())

func _exit_state(s: BotState) -> void:
	match s:
		BotState.SPOTTED_ENEMY:
			reaction_timer.stop()

# ── Состояния ───────────────────────────────────────────────────────────────

func _state_patrol(delta: float) -> void:
	if _patrol_waypoints.is_empty():
		return
	if _dwelling:
		_dwell_timer -= delta
		if _dwell_timer <= 0.0:
			_dwelling = false
			_pick_next_waypoint()
		return
	_move_toward_target(nav_agent.get_next_path_position())
	if nav_agent.is_navigation_finished():
		_dwell_timer = stats.get_angle_dwell_time() if _current_waypoint_uses_angle_hold() else 0.3
		_dwelling = true

func _state_spotted(_delta: float) -> void:
	# Обновляем позицию врага пока ждём реакцию
	if not visible_enemies.is_empty():
		last_known_enemy_pos = visible_enemies[0].global_position
	# Поворачиваемся в сторону врага
	if last_known_enemy_pos != Vector3.ZERO:
		_face_toward(last_known_enemy_pos)

func _state_engage(_delta: float) -> void:
	if visible_enemies.is_empty():
		# Враг исчез — проверяем память
		var elapsed = Time.get_ticks_msec() / 1000.0 - last_seen_time
		if elapsed > stats.get_memory_duration():
			_change_state(BotState.PATROL)
			return
		# Идём к последней известной позиции
		_navigate_to(last_known_enemy_pos)
	else:
		last_known_enemy_pos = visible_enemies[0].global_position
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_face_toward(last_known_enemy_pos)
		if stats.aggression > AGGRESSION_PEEK_THRESHOLD:
			_navigate_to(last_known_enemy_pos)
		# Стрельба через weapon
		if weapon and weapon.has_method("try_fire"):
			weapon.try_fire(visible_enemies[0], stats)

	if _should_retreat():
		_change_state(BotState.RETREAT)

func _state_retreat(_delta: float) -> void:
	_move_toward_target(nav_agent.get_next_path_position())
	# Если восстановились и снова видим врага — обратно в бой
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp)
	if hp_ratio > 0.5 and not visible_enemies.is_empty():
		_change_state(BotState.ENGAGE)
	# Если умерли
	if stats.is_dead():
		_die(-1)

# ── Восприятие ──────────────────────────────────────────────────────────────

func _perception_tick() -> void:
	if current_state == BotState.DEAD or _is_blinded:
		visible_enemies.clear()
		return
	visible_enemies.clear()
	for body in perception_area.get_overlapping_bodies():
		if not _is_enemy(body):
			continue
		if not _is_in_fov(body.global_position):
			continue
		if not _has_line_of_sight(body):
			continue
		visible_enemies.append(body)

	if not visible_enemies.is_empty():
		match current_state:
			BotState.PATROL:
				emit_signal("enemy_spotted", stats.bot_id,
					_get_bot_id(visible_enemies[0]), visible_enemies[0].global_position)
				_change_state(BotState.SPOTTED_ENEMY)
	elif current_state == BotState.ENGAGE:
		pass  # обрабатывается в _state_engage

func _is_in_fov(target_pos: Vector3) -> bool:
	var to_target = (target_pos - global_position).normalized()
	var forward = -global_transform.basis.z
	return forward.dot(to_target) > cos(deg_to_rad(FOV_HALF_ANGLE_DEG))

func _has_line_of_sight(target: Node3D) -> bool:
	var from = eye_pos.global_position
	var to = target.global_position + Vector3(0, 1.4, 0)
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self]
	query.collision_mask = WALL_COLLISION_LAYER | SMOKE_COLLISION_LAYER
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _is_enemy(body: Node3D) -> bool:
	if not body.has_method("get_team"):
		return false
	return body.get_team() != stats.team

func _get_bot_id(body: Node3D) -> int:
	if body is BotBrain:
		return body.stats.bot_id
	return -1

# ── Движение ────────────────────────────────────────────────────────────────

func _navigate_to(target: Vector3) -> void:
	nav_agent.target_position = target

func _move_toward_target(next_pos: Vector3) -> void:
	var direction = (next_pos - global_position)
	direction.y = 0.0
	if direction.length() > 0.1:
		direction = direction.normalized()
		nav_agent.velocity = direction * MOVE_SPEED
		# Движение происходит только в _on_velocity_computed (avoidance callback)
	else:
		velocity = Vector3.ZERO
		move_and_slide()

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity = safe_velocity
	move_and_slide()

func _face_toward(target_pos: Vector3) -> void:
	var dir = (target_pos - global_position)
	dir.y = 0.0
	if dir.length() > 0.01:
		look_at(global_position + dir, Vector3.UP)

func _find_cover_position() -> Vector3:
	# Простая эвристика: отступить назад от врага
	if last_known_enemy_pos == Vector3.ZERO:
		return global_position
	var away = (global_position - last_known_enemy_pos).normalized() * 8.0
	return global_position + away

func _should_retreat() -> bool:
	var hp_ratio = float(stats.current_hp) / float(stats.max_hp)
	return hp_ratio < stats.get_retreat_threshold()

# ── Патруль ─────────────────────────────────────────────────────────────────

func set_patrol_waypoints(waypoints: Array[Vector3]) -> void:
	_patrol_waypoints = waypoints
	_current_waypoint_idx = 0

func _pick_next_waypoint() -> void:
	if _patrol_waypoints.is_empty():
		return
	_current_waypoint_idx = (_current_waypoint_idx + 1) % _patrol_waypoints.size()
	_navigate_to(_patrol_waypoints[_current_waypoint_idx])

func _current_waypoint_uses_angle_hold() -> bool:
	return stats.game_sense >= 7

# ── Публичные методы ─────────────────────────────────────────────────────────

func get_team() -> BotStats.Team:
	return stats.team

func receive_team_intel(enemy_id: int, pos: Vector3) -> void:
	# Обновляем известную позицию врага от команды
	if current_state == BotState.PATROL or current_state == BotState.IDLE:
		last_known_enemy_pos = pos
		last_seen_time = Time.get_ticks_msec() / 1000.0

func apply_damage(amount: int, source_id: int) -> void:
	stats.take_damage(amount)
	emit_signal("damage_taken", stats.bot_id, amount, source_id)
	if stats.is_dead():
		_die(source_id)

func start_round() -> void:
	stats.reset_hp()
	visible_enemies.clear()
	last_known_enemy_pos = Vector3.ZERO
	_change_state(BotState.PATROL)

# ── Таймеры ─────────────────────────────────────────────────────────────────

func _on_reaction_timeout() -> void:
	if current_state != BotState.SPOTTED_ENEMY:
		return
	if not visible_enemies.is_empty():
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_change_state(BotState.ENGAGE)
	else:
		# Враг исчез во время реакции — идём проверить
		_navigate_to(last_known_enemy_pos)
		_change_state(BotState.PATROL)

# ── Смерть ──────────────────────────────────────────────────────────────────

func _die(killer_id: int) -> void:
	_change_state(BotState.DEAD)
	velocity = Vector3.ZERO
	emit_signal("bot_died", stats.bot_id, killer_id)
	# Визуально "укладываем" бота
	var mesh = get_node_or_null("Body")
	if mesh:
		mesh.rotation_degrees.z = 90.0

func apply_flash(duration: float) -> void:
	_is_blinded = true
	await get_tree().create_timer(duration).timeout
	_is_blinded = false
