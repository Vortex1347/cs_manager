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
@onready var camera: Camera3D = $MainCamera
@onready var hud: CanvasLayer = $HUD

var score_ct: int = 0
var score_t: int = 0
var is_paused: bool = false
var match_active: bool = false

func _ready() -> void:
	round_manager.round_ended.connect(_on_round_ended)
	start_match()

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

func _on_round_ended(winner: String, _reason: String) -> void:
	if winner == "CT":
		score_ct += 1
	elif winner == "T":
		score_t += 1

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
