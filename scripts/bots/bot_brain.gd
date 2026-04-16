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
const FOV_HALF_ANGLE_DEG: float = 150.0  # 300° обзор, слепая зона 60° сзади
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
var _is_live: bool = false
var _is_bomb_carrier: bool = false
var _team: Node = null
var _patrol_waypoints: Array[Vector3] = []
var _current_waypoint_idx: int = 0
var _dwell_timer: float = 0.0
var _dwelling: bool = false
var _body_mesh: MeshInstance3D = null
var _bomb_indicator: MeshInstance3D = null
var _bomb_site_target: Vector3 = Vector3.ZERO
var _scan_timer: float = 0.0
var _scan_dir: float = 1.0
var _pickup_target: Vector3 = Vector3.ZERO
var _threat_dir: Vector3 = Vector3.ZERO   # направление откуда ждём врагов
var _rl_mode: bool = false                # true = управляет Python через RLServer
var rl_server: RLServer = null            # устанавливается из game_manager

func _ready() -> void:
	reaction_timer.one_shot = true
	reaction_timer.timeout.connect(_on_reaction_timeout)
	perception_timer.wait_time = PERCEPTION_TICK
	perception_timer.autostart = true
	perception_timer.timeout.connect(_perception_tick)
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	if not team_node_path.is_empty():
		_team = get_node(team_node_path)
	_body_mesh = get_node_or_null("Body")

func _physics_process(delta: float) -> void:
	if current_state == BotState.DEAD:
		return
	if not _is_live:
		velocity = Vector3.ZERO
		return
	if _rl_mode:
		_apply_rl_action()
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
	_update_label()

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
	# CT: мгновенно бросает патруль и бежит дефузить бомбу
	if _bomb_site_target != Vector3.ZERO and stats.team == BotStats.Team.CT:
		_navigate_to(_bomb_site_target)
		_move_toward_target(nav_agent.get_next_path_position())
		_try_defuse()
		return

	# T: бежит подобрать упавшую бомбу
	if _pickup_target != Vector3.ZERO and stats.team == BotStats.Team.T:
		_navigate_to(_pickup_target)
		_move_toward_target(nav_agent.get_next_path_position())
		if global_position.distance_to(_pickup_target) < 2.0:
			_is_bomb_carrier = true
			_pickup_target = Vector3.ZERO
		return

	if _dwelling:
		_dwell_timer -= delta
		# Медленно вращается на 360° — полный обзор местности
		rotation.y += deg_to_rad(90.0) * delta
		if _dwell_timer <= 0.0:
			_dwelling = false
			_scan_timer = 0.0
			_pick_next_waypoint()
		return

	# T non-carrier: бежит защищать заложенную бомбу
	if _bomb_site_target != Vector3.ZERO and stats.team == BotStats.Team.T and not _is_bomb_carrier:
		_navigate_to(_bomb_site_target)
		_move_toward_target(nav_agent.get_next_path_position())
		return

	# T bomb carrier: идёт к ближайшему сайту и сажает бомбу
	if _is_bomb_carrier and stats.team == BotStats.Team.T:
		var site := _get_bombsite_at_position()
		if site and not site.bomb_planted and not site.bomb_exploded_flag:
			site.begin_plant(stats.bot_id)
			_dwelling = true
			_dwell_timer = site.PLANT_DURATION + 0.2
			return
		# Ещё не на сайте → навигируем к ближайшему
		var nearest := _get_nearest_bombsite()
		if nearest and not nearest.bomb_planted:
			_navigate_to(nearest.global_position)
			_move_toward_target(nav_agent.get_next_path_position())
		return

	if _patrol_waypoints.is_empty():
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
	# CT: если бомба заложена — дефуз важнее боя, бежим на сайт
	if stats.team == BotStats.Team.CT and _bomb_site_target != Vector3.ZERO:
		_navigate_to(_bomb_site_target)
		_move_toward_target(nav_agent.get_next_path_position())
		_try_defuse()
		# Стреляем на ходу если видим врага
		if not visible_enemies.is_empty() and weapon and weapon.has_method("try_fire"):
			_face_toward(visible_enemies[0].global_position)
			weapon.try_fire(visible_enemies[0], stats)
		if _should_retreat():
			_change_state(BotState.RETREAT)
		return

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
	if current_state == BotState.DEAD or _is_blinded or not _is_live:
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
	if body is BotBrain and body.current_state == BotBrain.BotState.DEAD:
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
	if not _is_live or current_state == BotState.DEAD:
		velocity = Vector3.ZERO
		return
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

# ── Бомба ───────────────────────────────────────────────────────────────────

func set_bomb_carrier(v: bool) -> void:
	_is_bomb_carrier = v
	_update_label()
	if v and not _bomb_indicator:
		_bomb_indicator = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.28
		sphere.height = 0.56
		_bomb_indicator.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.2, 0.05)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.1, 0.0)
		mat.emission_energy_multiplier = 5.0
		_bomb_indicator.material_override = mat
		_bomb_indicator.position = Vector3(0, 2.2, 0)
		add_child(_bomb_indicator)
	elif _bomb_indicator:
		_bomb_indicator.visible = v

func _get_bombsite_at_position() -> Bombsite:
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site.contains_point(global_position):
			return site
	return null

func _get_nearest_bombsite() -> Bombsite:
	var best: Bombsite = null
	var best_d: float = INF
	for site in get_tree().get_nodes_in_group("bombsites"):
		var d: float = global_position.distance_to(site.global_position)
		if d < best_d:
			best_d = d
			best = site
	return best

func _try_defuse() -> void:
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site.bomb_planted and not site.bomb_exploded_flag:
			if global_position.distance_to(site.global_position) < 6.0:
				site.begin_defuse(stats.bot_id)

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

func set_threat_direction(dir: Vector3) -> void:
	_threat_dir = dir.normalized()

func enable_rl_mode(server: RLServer) -> void:
	rl_server = server
	_rl_mode = true

# ── RL Action ────────────────────────────────────────────────────────────────
# Направления: 0=стоять, 1=N, 2=NE, 3=E, 4=SE, 5=S, 6=SW, 7=W, 8=NW
const _RL_DIRS: Array = [
	Vector3(0,0,0), Vector3(0,0,-1), Vector3(1,0,-1), Vector3(1,0,0),
	Vector3(1,0,1), Vector3(0,0,1), Vector3(-1,0,1), Vector3(-1,0,0), Vector3(-1,0,-1)
]

func _apply_rl_action() -> void:
	if not rl_server:
		return
	var act: Dictionary = rl_server.get_action(stats.bot_id)
	var move_idx: int = clamp(int(act.get("move", 0)), 0, 8)
	var shoot: bool = act.get("shoot", false)

	# Движение напрямую в velocity (минуем nav_agent avoidance — callback
	# асинхронный и требует avoidance_enabled → в RL-режиме просто двигаемся)
	var dir: Vector3 = _RL_DIRS[move_idx].normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * MOVE_SPEED
		velocity.z = dir.z * MOVE_SPEED
		_face_toward(global_position + dir)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()

	# Стрельба
	if shoot and weapon and not visible_enemies.is_empty():
		weapon.try_fire(visible_enemies[0], stats)

	# Автоматическая интеракция на сайте (interact не приходит из Python)
	# Plant/defuse требуют стоять на месте (dir == 0) — как в реальном CS
	var site := _get_bombsite_at_position()
	if site and dir == Vector3.ZERO:
		if _is_bomb_carrier and stats.team == BotStats.Team.T \
				and not site.bomb_planted and not site.bomb_exploded_flag:
			site.begin_plant(stats.bot_id)
		elif stats.team == BotStats.Team.CT \
				and site.bomb_planted and not site.bomb_exploded_flag:
			site.begin_defuse(stats.bot_id)

func go_pick_up_bomb(pos: Vector3) -> void:
	_pickup_target = pos
	_navigate_to(pos)

func on_bomb_dropped(drop_pos: Vector3) -> void:
	# CT: бежит к упавшей бомбе чтобы не дать подобрать
	if stats.team == BotStats.Team.CT:
		_bomb_site_target = drop_pos
		if current_state == BotState.PATROL or current_state == BotState.IDLE:
			_navigate_to(drop_pos)

func on_bomb_planted(site_pos: Vector3) -> void:
	# CT: дефузить — высший приоритет, бежим немедленно из любого состояния
	# T non-carrier: защищать заложенную бомбу
	if stats.team == BotStats.Team.CT or (stats.team == BotStats.Team.T and not _is_bomb_carrier):
		_bomb_site_target = site_pos
		_navigate_to(site_pos)

func receive_team_intel(enemy_id: int, pos: Vector3) -> void:
	# Обновляем известную позицию врага от команды
	if current_state == BotState.PATROL or current_state == BotState.IDLE:
		last_known_enemy_pos = pos
		last_seen_time = Time.get_ticks_msec() / 1000.0

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
	# Уже в бою — ничего не меняем
	if current_state == BotState.ENGAGE or current_state == BotState.SPOTTED_ENEMY or current_state == BotState.DEAD:
		return
	# Развернуться к стрелку
	if source_pos != Vector3.ZERO:
		_face_toward(source_pos)
	# Бой или отступление
	var hp_ratio: float = float(stats.current_hp) / float(stats.max_hp)
	if hp_ratio > 0.3:
		last_seen_time = Time.get_ticks_msec() / 1000.0
		_change_state(BotState.ENGAGE)
	else:
		_change_state(BotState.RETREAT)

func start_round() -> void:
	_is_live = false
	stats.reset_hp()
	visible_enemies.clear()
	last_known_enemy_pos = Vector3.ZERO
	_is_bomb_carrier = false
	_bomb_site_target = Vector3.ZERO
	_pickup_target = Vector3.ZERO
	_dwelling = false
	_dwell_timer = 0.0
	_scan_timer = 0.0
	# Сброс визуала смерти
	if _body_mesh:
		_body_mesh.rotation_degrees.z = 0.0
	if _bomb_indicator:
		_bomb_indicator.visible = false
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
	# Отменить дефуз если дефузил
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site.has_method("cancel_defuse_by"):
			site.cancel_defuse_by(stats.bot_id)
	if _bomb_indicator:
		_bomb_indicator.visible = false
	emit_signal("bot_died", stats.bot_id, killer_id)
	# Визуально: укладываем + серый цвет
	if _body_mesh:
		_body_mesh.rotation_degrees.z = 90.0
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.25, 0.25, 0.25)
		_body_mesh.material_override = mat

func _update_label() -> void:
	if not debug_label or not stats:
		return
	var state_name = BotState.keys()[current_state]
	var bomb_mark: String = " [B]" if _is_bomb_carrier else ""
	debug_label.text = "%s%s\nHP:%d AR:%d" % [state_name, bomb_mark, stats.current_hp, stats.armor]

func _set_team_color() -> void:
	if not _body_mesh or not stats:
		return
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.4, 0.9) if stats.team == BotStats.Team.CT else Color(0.9, 0.5, 0.1)
	_body_mesh.material_override = mat

func apply_flash(duration: float) -> void:
	_is_blinded = true
	await get_tree().create_timer(duration).timeout
	_is_blinded = false
