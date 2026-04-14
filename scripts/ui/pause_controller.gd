# pause_controller.gd
# Обрабатывает паузу: показывает/скрывает оверлей, слушает game_manager.
# Зависимости: game_manager.gd (сигнал pause_toggled)

extends CanvasLayer
class_name PauseController

@onready var pause_overlay: Control = $PauseOverlay
@onready var strategy_buttons: VBoxContainer = $PauseOverlay/StrategyButtons
@onready var resume_button: Button = $PauseOverlay/ResumeButton

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
