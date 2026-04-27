# bot_loadout.gd
# Структурированный результат закупки: оружие, броня, kit, гранаты и профиль закупки.
# Зависимости: нет (Resource, используется economy.gd, bot_brain.gd, game_manager.gd)

extends Resource
class_name BotLoadout

@export var weapon_type: String = "pistol"
@export var armor_value: int = 0
@export var has_defuse_kit: bool = false
@export var grenades: Array[String] = []
@export var buy_profile: String = "eco"

func clone():
	var copy = get_script().new()
	copy.weapon_type = weapon_type
	copy.armor_value = armor_value
	copy.has_defuse_kit = has_defuse_kit
	copy.grenades = grenades.duplicate()
	copy.buy_profile = buy_profile
	return copy

func get_summary() -> String:
	var utility_text = "-".join(grenades) if not grenades.is_empty() else "none"
	return "%s / %s / kit:%s / util:%s" % [
		buy_profile,
		weapon_type,
		"yes" if has_defuse_kit else "no",
		utility_text,
	]
