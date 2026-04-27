# pause_controller.gd
# Управляет компактным icon-first HUD, паузой, observer-режимом и выбором стратегии.
# Зависимости: game_manager.gd (signals, summaries), hud_icon.gd (отрисовка минималистичных иконок)

extends CanvasLayer
class_name PauseController

signal strategy_selected(strategy: int)

@onready var pause_overlay: Control = $PauseOverlay
@onready var strategy_buttons: HBoxContainer = $PauseOverlay/CenterContainer/VBoxContainer/StrategyButtons
@onready var resume_button: Button = $PauseOverlay/CenterContainer/VBoxContainer/ResumeButton
@onready var timer_label: Label = $ScoreBar/TimerLabel
@onready var phase_label: Label = $ScoreBar/PhaseLabel
@onready var score_ct_label: Label = $ScoreBar/ScoreCT
@onready var score_t_label: Label = $ScoreBar/ScoreT

@onready var bomb_icon: Control = $StatusRow/BombItem/BombIcon
@onready var bomb_status_label: Label = $StatusRow/BombItem/BombStatus
@onready var bomb_timer_label: Label = $StatusRow/BombItem/BombTimerLabel
@onready var site_icon: Control = $StatusRow/SiteItem/SiteIcon
@onready var site_label: Label = $StatusRow/SiteItem/SiteLabel
@onready var ct_plan_icon: Control = $StatusRow/CTPlanItem/CTPlanIcon
@onready var ct_plan_label: Label = $StatusRow/CTPlanItem/CTPlanLabel
@onready var t_plan_icon: Control = $StatusRow/StrategyItem/StrategyIcon
@onready var strategy_label: Label = $StatusRow/StrategyItem/StrategyLabel
@onready var utility_icon: Control = $StatusRow/UtilityItem/UtilityIcon
@onready var utility_mini_label: Label = $StatusRow/UtilityItem/UtilityMiniLabel

@onready var observer_summary: HBoxContainer = $ObserverSummary
@onready var combat_label: Label = $ObserverSummary/CombatLabel
@onready var intel_label: Label = $ObserverSummary/IntelLabel
@onready var gunfight_label: Label = $ObserverSummary/GunfightLabel
@onready var lineup_debug_label: Label = $ObserverSummary/LineupDebugLabel
@onready var combat_debug_label: Label = $ObserverSummary/CombatDebugLabel
@onready var observer_panel: PanelContainer = $ObserverPanel
@onready var ct_health_panel: VBoxContainer = $ObserverPanel/ObserverRow/CTColumn/CTHealthPanel
@onready var t_health_panel: VBoxContainer = $ObserverPanel/ObserverRow/TColumn/THealthPanel

var _game_manager: Node = null
var _score_ct: int = 0
var _score_t: int = 0
var _alive_ct: int = 5
var _alive_t: int = 5
var _last_bomb_state: String = "idle"

func _ready() -> void:
	pause_overlay.visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	resume_button.pressed.connect(_on_resume_pressed)
	_bind_strategy_buttons()
	set_observer_mode(false)
	_apply_ct_plan_icon("H", "hold")
	_apply_t_plan_icon("A", "rush")
	_apply_site_focus("A")

func connect_game_manager(gm: Node) -> void:
	_game_manager = gm
	gm.pause_toggled.connect(_on_pause_toggled)

func set_observer_mode(value: bool) -> void:
	if observer_summary:
		observer_summary.visible = value
	if observer_panel:
		observer_panel.visible = value

func _on_pause_toggled(is_paused: bool) -> void:
	pause_overlay.visible = is_paused

func _on_resume_pressed() -> void:
	if _game_manager:
		_game_manager.toggle_pause()

func update_timer(secs: float) -> void:
	var m = int(secs) / 60
	var s = int(secs) % 60
	timer_label.text = "%d:%02d" % [m, s]

func update_phase(phase: int) -> void:
	match phase:
		0:
			phase_label.text = "BUY"
		1:
			phase_label.text = "LIVE"
		2:
			phase_label.text = "END"

func update_score(ct: int, t: int) -> void:
	_score_ct = ct
	_score_t = t
	_refresh_scorebar()

func update_bomb_status(text: String) -> void:
	var parsed = _parse_bomb_status(text)
	_last_bomb_state = parsed["state"]
	bomb_status_label.text = parsed["label"]
	bomb_status_label.modulate = parsed["color"]
	bomb_icon.set_icon_name(parsed["icon"])
	bomb_icon.set_accent(parsed["color"])
	if parsed["site"] != "":
		_apply_site_focus(parsed["site"])

func update_bomb_countdown(seconds_remaining: float, state_name: String) -> void:
	if state_name == "planted" or state_name == "defusing":
		bomb_timer_label.text = "%.1fs" % maxf(seconds_remaining, 0.0)
	else:
		bomb_timer_label.text = ""

func update_strategy(summary: String) -> void:
	var parsed = _parse_plan_summary(summary, false)
	_apply_t_plan_icon(parsed["label"], parsed["icon"])
	if parsed["site"] != "":
		_apply_site_focus(parsed["site"])

func update_team_plans(ct_summary: String, t_summary: String) -> void:
	var ct_parsed = _parse_plan_summary(ct_summary, true)
	var t_parsed = _parse_plan_summary(t_summary, false)
	_apply_ct_plan_icon(ct_parsed["label"], ct_parsed["icon"])
	_apply_t_plan_icon(t_parsed["label"], t_parsed["icon"])
	if _last_bomb_state in ["plant", "planted", "defuse"] and site_label.text != "":
		return
	if t_parsed["site"] != "":
		_apply_site_focus(t_parsed["site"])
	elif ct_parsed["site"] != "":
		_apply_site_focus(ct_parsed["site"])

func update_utility_call(summary: String) -> void:
	utility_mini_label.text = _compact_utility_text(summary)
	utility_icon.set_icon_name("utility")
	utility_icon.set_accent(Color(1.0, 0.88, 0.52, 1.0))

func update_combat_call(summary: String) -> void:
	if combat_label:
		combat_label.text = "combat %s" % _compact_summary(summary, 42)

func update_intel_summary(summary: String) -> void:
	if intel_label:
		intel_label.text = "intel %s" % _compact_summary(summary, 38)

func update_gunfight_summary(summary: String) -> void:
	if gunfight_label:
		gunfight_label.text = "gun %s" % _compact_summary(summary, 40)

func update_lineup_debug(is_visible: bool) -> void:
	if lineup_debug_label:
		lineup_debug_label.text = "L %s" % ("on" if is_visible else "off")

func update_combat_debug(is_visible: bool) -> void:
	if combat_debug_label:
		combat_debug_label.text = "K %s" % ("on" if is_visible else "off")

func update_bot_health(ct_hps: Array, t_hps: Array) -> void:
	_alive_ct = 0
	_alive_t = 0
	for hp in ct_hps:
		if int(hp) > 0:
			_alive_ct += 1
	for hp in t_hps:
		if int(hp) > 0:
			_alive_t += 1
	_refresh_scorebar()

func update_bot_panels(ct_entries: Array, t_entries: Array) -> void:
	_apply_bot_panel(ct_health_panel, ct_entries, Color(0.4, 0.8, 1.0), Color(0.45, 0.45, 0.45))
	_apply_bot_panel(t_health_panel, t_entries, Color(1.0, 0.62, 0.22), Color(0.45, 0.45, 0.45))

func _apply_bot_panel(panel: VBoxContainer, entries: Array, alive_color: Color, dead_color: Color) -> void:
	if panel == null:
		return
	var labels = panel.get_children()
	for i in range(labels.size()):
		var label = labels[i]
		if i >= entries.size():
			label.text = ""
			continue
		var entry: Dictionary = entries[i]
		label.text = String(entry.get("text", ""))
		label.modulate = alive_color if bool(entry.get("alive", true)) else dead_color

func _refresh_scorebar() -> void:
	score_ct_label.text = "%d · %d" % [_score_ct, _alive_ct]
	score_t_label.text = "%d · %d" % [_score_t, _alive_t]

func _apply_ct_plan_icon(label_text: String, icon_id: String) -> void:
	ct_plan_label.text = label_text
	ct_plan_icon.set_icon_name(icon_id)
	ct_plan_icon.set_accent(Color(0.58, 0.84, 1.0, 1.0))

func _apply_t_plan_icon(label_text: String, icon_id: String) -> void:
	strategy_label.text = label_text
	t_plan_icon.set_icon_name(icon_id)
	t_plan_icon.set_accent(Color(1.0, 0.71, 0.34, 1.0))

func _apply_site_focus(site_name: String) -> void:
	var site = site_name.to_upper()
	site_label.text = site if site in ["A", "B"] else "-"
	site_icon.set_icon_name("site_a" if site != "B" else "site_b")
	site_icon.set_accent(Color(0.96, 0.83, 0.28, 1.0) if site != "B" else Color(0.98, 0.64, 0.20, 1.0))

func _parse_bomb_status(summary: String) -> Dictionary:
	var text = summary.to_lower()
	var result = {
		"label": "idle",
		"icon": "bomb",
		"color": Color(1.0, 0.82, 0.19, 1.0),
		"state": "idle",
		"site": "",
	}
	if text == "":
		return result
	if text.contains("упала"):
		result["label"] = "drop"
		result["state"] = "drop"
	elif text.contains("поднята"):
		result["label"] = "carry"
		result["state"] = "carry"
	elif text.contains("сажают"):
		result["label"] = "plant"
		result["icon"] = "plant"
		result["state"] = "plant"
	elif text.contains("дефуз"):
		result["label"] = "def"
		result["icon"] = "defuse"
		result["state"] = "defuse"
	elif text.contains("взрыв"):
		result["label"] = "boom"
		result["icon"] = "bomb"
		result["color"] = Color(1.0, 0.42, 0.12, 1.0)
		result["state"] = "boom"
	elif text.contains("разминир"):
		result["label"] = "safe"
		result["icon"] = "defuse"
		result["color"] = Color(0.58, 1.0, 0.58, 1.0)
		result["state"] = "safe"
	if text.contains("a"):
		result["site"] = "A"
	elif text.contains("b"):
		result["site"] = "B"
	return result

func _parse_plan_summary(summary: String, is_ct: bool) -> Dictionary:
	var text = summary.to_lower()
	var result = {
		"label": "H" if is_ct else "A",
		"icon": "hold" if is_ct else "rush",
		"site": "",
	}
	if text.contains("eco"):
		result["label"] = "E"
		result["icon"] = "save"
		return result
	if text.contains("mid_to_b") or text.contains("split b"):
		result["label"] = "M→B"
		result["icon"] = "split"
		result["site"] = "B"
		return result
	if text.contains("recover_bomb") or text.contains("contest_drop"):
		result["label"] = "REC"
		result["icon"] = "rotate"
		return result
	if text.contains("plant_a") or text.contains("post_a"):
		result["label"] = "P-A"
		result["icon"] = "plant"
		result["site"] = "A"
		return result
	if text.contains("plant_b") or text.contains("post_b"):
		result["label"] = "P-B"
		result["icon"] = "plant"
		result["site"] = "B"
		return result
	if text.contains("split") or text.contains("cat"):
		result["label"] = "⇆A"
		result["icon"] = "split"
		result["site"] = "A"
		return result
	if text.contains("rotate_a") or text.contains("retake_a"):
		result["label"] = "R-A"
		result["icon"] = "rotate"
		result["site"] = "A"
		return result
	if text.contains("rotate_b") or text.contains("retake_b"):
		result["label"] = "R-B"
		result["icon"] = "rotate"
		result["site"] = "B"
		return result
	if text.contains("b_exec") or text.contains("default_b") or text.contains("b_contact"):
		result["label"] = "B"
		result["icon"] = "rush" if not is_ct else "hold"
		result["site"] = "B"
		return result
	if text.contains("a_long") or text.contains("default_a") or text.contains("a_hold") or text.contains("a_long_commit"):
		result["label"] = "A"
		result["icon"] = "rush" if not is_ct else "hold"
		result["site"] = "A"
		return result
	if is_ct and text.contains("hold"):
		result["label"] = "A/B"
		result["icon"] = "hold"
	elif text.contains("save"):
		result["label"] = "S"
		result["icon"] = "save"
	return result

func _compact_utility_text(summary: String) -> String:
	var compact = summary.strip_edges()
	if compact == "":
		return "-"
	var count = compact.count(",") + 1 if compact.contains(":") and compact.find(":") < compact.length() - 1 else 0
	if count <= 0:
		if compact.to_lower().contains("none"):
			return "-"
		return "1"
	return str(min(count, 9))

func _compact_summary(summary: String, max_len: int) -> String:
	var compact = summary.strip_edges().replace("CT ", "").replace("T ", "")
	if compact.length() <= max_len:
		return compact
	return compact.substr(0, max_len)

func _bind_strategy_buttons() -> void:
	var mapping = {
		"BtnRushA": 1,
		"BtnRushB": 2,
		"BtnSplit": 3,
		"BtnDefault": 0,
		"BtnEco": 4,
	}
	for child in strategy_buttons.get_children():
		if child is Button and mapping.has(child.name):
			child.pressed.connect(_emit_strategy.bind(child.name, mapping))

func _emit_strategy(button_name: String, mapping: Dictionary) -> void:
	emit_signal("strategy_selected", mapping[button_name])
