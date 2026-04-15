# pause_controller.gd
# Обрабатывает паузу и обновляет HUD (таймер, фаза, счёт).
# Зависимости: game_manager.gd (сигнал pause_toggled)

extends CanvasLayer
class_name PauseController

@onready var pause_overlay: Control = $PauseOverlay
@onready var strategy_buttons: VBoxContainer = $PauseOverlay/CenterContainer/VBoxContainer/StrategyButtons
@onready var resume_button: Button = $PauseOverlay/CenterContainer/VBoxContainer/ResumeButton
@onready var timer_label: Label = $TimerLabel
@onready var phase_label: Label = $PhaseLabel
@onready var score_ct_label: Label = $ScoreBar/ScoreCT
@onready var score_t_label: Label = $ScoreBar/ScoreT

var _game_manager: Node = null

func _ready() -> void:
	pause_overlay.visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS  # работает в паузе
	resume_button.pressed.connect(_on_resume_pressed)

func connect_game_manager(gm: Node) -> void:
	_game_manager = gm
	gm.pause_toggled.connect(_on_pause_toggled)

func _on_pause_toggled(is_paused: bool) -> void:
	pause_overlay.visible = is_paused

func _on_resume_pressed() -> void:
	if _game_manager:
		_game_manager.toggle_pause()

func update_timer(secs: float) -> void:
	var m := int(secs) / 60
	var s := int(secs) % 60
	timer_label.text = "%d:%02d" % [m, s]

func update_phase(phase: int) -> void:
	match phase:
		0: phase_label.text = "BUY PHASE"
		1: phase_label.text = "LIVE"
		2: phase_label.text = "ROUND END"

func update_score(ct: int, t: int) -> void:
	score_ct_label.text = "CT: %d" % ct
	score_t_label.text = "T: %d" % t
