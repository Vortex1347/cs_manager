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
@onready var bomb_status_label: Label = $BombStatus
@onready var ct_health_panel: VBoxContainer = $CTHealthPanel
@onready var t_health_panel: VBoxContainer = $THealthPanel

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

func update_bomb_status(text: String) -> void:
	if bomb_status_label:
		bomb_status_label.text = text

func update_bot_health(ct_hps: Array, t_hps: Array) -> void:
	if not ct_health_panel or not t_health_panel:
		return
	var ct_labels := ct_health_panel.get_children()
	for i in range(min(ct_hps.size(), ct_labels.size())):
		var hp: int = ct_hps[i]
		ct_labels[i].text = "CT_%d: %d" % [i, hp]
		ct_labels[i].modulate = Color(0.4, 0.8, 1.0) if hp > 0 else Color(0.4, 0.4, 0.4)
	var t_labels := t_health_panel.get_children()
	for i in range(min(t_hps.size(), t_labels.size())):
		var hp: int = t_hps[i]
		t_labels[i].text = "T_%d: %d" % [i, hp]
		t_labels[i].modulate = Color(1.0, 0.6, 0.2) if hp > 0 else Color(0.4, 0.4, 0.4)
