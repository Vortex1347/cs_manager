# upgrade_controller.gd
# Меню улучшений ботов: показывает статы, позволяет тратить очки.
# Зависимости: bot_stats.gd (Resource)

extends Control
class_name UpgradeController

signal upgrade_applied(bot_id: int, stat_name: String, new_value: Variant)
signal upgrade_points_changed(new_total: int)

const POINTS_PER_ROUND: int = 1

var upgrade_points: int = 0
var _bot_stats: Array[BotStats] = []
var _bot_panels: Dictionary = {}  # bot_id → Dictionary с Label/Button нодами

func _ready() -> void:
	visible = false

func setup(stats_array: Array[BotStats]) -> void:
	_bot_stats = stats_array
	_build_ui()

func show_menu() -> void:
	_refresh_all_panels()
	visible = true

func hide_menu() -> void:
	visible = false

func add_upgrade_points(amount: int) -> void:
	upgrade_points += amount
	emit_signal("upgrade_points_changed", upgrade_points)
	_refresh_points_display()

func _build_ui() -> void:
	var grid = $BotGrid
	if not grid:
		return
	for child in grid.get_children():
		child.queue_free()
	_bot_panels.clear()

	for stats in _bot_stats:
		var panel = _create_bot_panel(stats)
		grid.add_child(panel)

func _create_bot_panel(stats: BotStats) -> PanelContainer:
	var panel = PanelContainer.new()
	var vbox = VBoxContainer.new()
	panel.add_child(vbox)

	var name_label = Label.new()
	name_label.text = stats.display_name
	vbox.add_child(name_label)

	var stats_dict: Dictionary = {}

	for stat_info in [
		{"name": "aim_level", "label": "Aim", "value": stats.aim_level, "max": 10},
		{"name": "reaction_time", "label": "Reaction", "value": stats.reaction_time, "max": null},
		{"name": "game_sense", "label": "Sense", "value": stats.game_sense, "max": 10},
	]:
		var row = HBoxContainer.new()
		var lbl = Label.new()
		lbl.custom_minimum_size = Vector2(100, 0)
		lbl.text = "%s: %s" % [stat_info["label"], stat_info["value"]]
		row.add_child(lbl)

		var btn = Button.new()
		btn.text = "+"
		btn.custom_minimum_size = Vector2(32, 0)
		var stat_name = stat_info["name"]
		btn.pressed.connect(func(): _on_upgrade_pressed(stats.bot_id, stat_name))
		row.add_child(btn)
		vbox.add_child(row)
		stats_dict[stat_info["name"]] = {"label": lbl, "button": btn}

	_bot_panels[stats.bot_id] = stats_dict
	return panel

func _on_upgrade_pressed(bot_id: int, stat_name: String) -> void:
	if upgrade_points <= 0:
		return
	var stats = _find_stats(bot_id)
	if not stats:
		return

	var applied = false
	match stat_name:
		"aim_level":
			if stats.aim_level < BotStats.MAX_AIM_LEVEL:
				stats.aim_level += 1
				applied = true
		"reaction_time":
			if stats.reaction_time > BotStats.MIN_REACTION_TIME + 0.05:
				stats.reaction_time = maxf(BotStats.MIN_REACTION_TIME, stats.reaction_time - 0.1)
				applied = true
		"game_sense":
			if stats.game_sense < 10:
				stats.game_sense += 1
				applied = true

	if applied:
		upgrade_points -= 1
		emit_signal("upgrade_applied", bot_id, stat_name, _get_stat_value(stats, stat_name))
		emit_signal("upgrade_points_changed", upgrade_points)
		_refresh_panel(bot_id)
		_refresh_points_display()

func _refresh_all_panels() -> void:
	for stats in _bot_stats:
		_refresh_panel(stats.bot_id)

func _refresh_panel(bot_id: int) -> void:
	var stats = _find_stats(bot_id)
	if not stats or not _bot_panels.has(bot_id):
		return
	var panel = _bot_panels[bot_id]
	if panel.has("aim_level"):
		panel["aim_level"]["label"].text = "Aim: %d" % stats.aim_level
	if panel.has("reaction_time"):
		panel["reaction_time"]["label"].text = "React: %.1f" % stats.reaction_time
	if panel.has("game_sense"):
		panel["game_sense"]["label"].text = "Sense: %d" % stats.game_sense
	# Скрываем кнопки если нет очков
	var has_points = upgrade_points > 0
	for stat_name in panel:
		panel[stat_name]["button"].disabled = not has_points

func _refresh_points_display() -> void:
	var lbl = get_node_or_null("PointsLabel")
	if lbl:
		lbl.text = "Points: %d" % upgrade_points

func _find_stats(bot_id: int) -> BotStats:
	for s in _bot_stats:
		if s.bot_id == bot_id:
			return s
	return null

func _get_stat_value(stats: BotStats, stat_name: String) -> Variant:
	match stat_name:
		"aim_level": return stats.aim_level
		"reaction_time": return stats.reaction_time
		"game_sense": return stats.game_sense
	return null
