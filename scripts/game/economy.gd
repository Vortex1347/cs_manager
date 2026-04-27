# economy.gd
# Экономика: деньги ботов, награды за убийства/победу/поражение, покупки.
# Зависимости: bot_loadout.gd, bot_stats.gd (через словарь), round_manager.gd (сигналы раунда)

extends Node
class_name Economy

const BotLoadoutScript = preload("res://scripts/game/bot_loadout.gd")

signal money_changed(bot_id: int, new_amount: int)
signal purchase_made(bot_id: int, item_name: String, cost: int)

# Награды CS:GO-like
const REWARD_KILL: int = 300
const REWARD_WIN: int = 3250
const REWARD_LOSS_BASE: int = 1400
const REWARD_LOSS_STREAK_BONUS: int = 500
const REWARD_PLANT: int = 300
const REWARD_DEFUSE: int = 300
const MAX_MONEY: int = 16000
const START_MONEY: int = 800
const ARMOR_PRICE: int = 650
const HELMET_PRICE: int = 350

# Стоимости предметов
const WEAPON_PRICES: Dictionary = {
	"pistol": 200,
	"smg": 1200,
	"rifle": 2700,
	"awp": 4750,
	"smoke": 300,
	"flash": 200,
	"frag": 300,
	"defuse_kit": 400,
}

var bot_money: Dictionary = {}     # bot_id → int
var _loss_streak_ct: int = 0
var _loss_streak_t: int = 0

func _ready() -> void:
	pass

func initialize(bot_ids: Array) -> void:
	for id in bot_ids:
		bot_money[id] = START_MONEY

func get_money(bot_id: int) -> int:
	return bot_money.get(bot_id, 0)

func add_money(bot_id: int, amount: int) -> void:
	bot_money[bot_id] = min(MAX_MONEY, bot_money.get(bot_id, 0) + amount)
	emit_signal("money_changed", bot_id, bot_money[bot_id])

func deduct_money(bot_id: int, amount: int) -> void:
	bot_money[bot_id] = max(0, bot_money.get(bot_id, 0) - amount)
	emit_signal("money_changed", bot_id, bot_money[bot_id])

func reward_kill(bot_id: int) -> void:
	add_money(bot_id, REWARD_KILL)

func reward_round_end(winner_team: String, ct_ids: Array, t_ids: Array) -> void:
	if winner_team == "CT":
		_loss_streak_t += 1
		_loss_streak_ct = 0
		for id in ct_ids:
			add_money(id, REWARD_WIN)
		for id in t_ids:
			var bonus = min(_loss_streak_t - 1, 4) * REWARD_LOSS_STREAK_BONUS
			add_money(id, REWARD_LOSS_BASE + bonus)
	elif winner_team == "T":
		_loss_streak_ct += 1
		_loss_streak_t = 0
		for id in t_ids:
			add_money(id, REWARD_WIN)
		for id in ct_ids:
			var bonus = min(_loss_streak_ct - 1, 4) * REWARD_LOSS_STREAK_BONUS
			add_money(id, REWARD_LOSS_BASE + bonus)

func reward_plant(bot_id: int) -> void:
	add_money(bot_id, REWARD_PLANT)

func reward_defuse(bot_id: int) -> void:
	add_money(bot_id, REWARD_DEFUSE)

# Командная автозакупка: профиль решает приоритет оружия и utility.
func auto_buy(
	bot_id: int,
	current_money: int,
	team: String,
	buy_profile: String,
	role_name: String,
	allow_defuse_kit: bool,
	preferred_grenades: Array[String]
) -> Variant:
	var loadout = BotLoadoutScript.new()
	loadout.buy_profile = buy_profile
	var money = current_money

	loadout.weapon_type = _pick_weapon(money, buy_profile, role_name)
	if loadout.weapon_type != "pistol":
		money = _purchase_item(bot_id, loadout.weapon_type, money)

	loadout.armor_value = _pick_armor(money, buy_profile)
	if loadout.armor_value > 0:
		var armor_price = ARMOR_PRICE if loadout.armor_value == 100 else HELMET_PRICE
		money = _purchase_custom(bot_id, "armor", armor_price, money)

	if team == "CT" and allow_defuse_kit and money >= WEAPON_PRICES["defuse_kit"]:
		loadout.has_defuse_kit = true
		money = _purchase_item(bot_id, "defuse_kit", money)

	loadout.grenades = _pick_grenades(money, buy_profile, role_name, preferred_grenades)
	for grenade_name in loadout.grenades:
		money = _purchase_item(bot_id, grenade_name, money)

	return loadout

func can_afford(bot_id: int, item: String) -> bool:
	return bot_money.get(bot_id, 0) >= WEAPON_PRICES.get(item, INF)

func get_team_money(bot_ids: Array) -> Dictionary:
	var snapshot: Dictionary = {}
	for bot_id in bot_ids:
		snapshot[bot_id] = get_money(bot_id)
	return snapshot

func _pick_weapon(current_money: int, buy_profile: String, role_name: String) -> String:
	if buy_profile == "eco":
		return "pistol"
	if buy_profile == "half_buy":
		return "smg" if current_money >= WEAPON_PRICES["smg"] + ARMOR_PRICE else "pistol"
	if role_name == "entry" and current_money >= WEAPON_PRICES["rifle"]:
		return "rifle"
	if role_name == "anchor" and current_money >= WEAPON_PRICES["rifle"]:
		return "rifle"
	if current_money >= WEAPON_PRICES["rifle"] + ARMOR_PRICE:
		return "rifle"
	if current_money >= WEAPON_PRICES["smg"] + HELMET_PRICE:
		return "smg"
	return "pistol"

func _pick_armor(current_money: int, buy_profile: String) -> int:
	if buy_profile == "eco":
		return 0
	if current_money >= ARMOR_PRICE:
		return 100
	if buy_profile == "half_buy" and current_money >= HELMET_PRICE:
		return 50
	return 0

func _pick_grenades(current_money: int, buy_profile: String, role_name: String, preferred_grenades: Array[String]) -> Array[String]:
	var grenades: Array[String] = []
	var money = current_money
	var budget_limit = 2
	if buy_profile.begins_with("full") or buy_profile == "anchor_full" or buy_profile == "rotator_full" or buy_profile == "retake_full":
		budget_limit = 3
	elif buy_profile == "eco":
		budget_limit = 1
	for grenade_name in preferred_grenades:
		if grenades.size() >= budget_limit:
			break
		if not WEAPON_PRICES.has(grenade_name):
			continue
		var price = WEAPON_PRICES[grenade_name]
		if money < price:
			continue
		if buy_profile == "eco" and grenade_name == "frag":
			continue
		grenades.append(grenade_name)
		money -= price
	if grenades.is_empty() and buy_profile != "eco" and role_name in ["entry", "support", "anchor", "rotator"] and money >= WEAPON_PRICES["flash"]:
		grenades.append("flash")
	return grenades

func _purchase_item(bot_id: int, item_name: String, current_money: int) -> int:
	var cost = WEAPON_PRICES.get(item_name, 0)
	return _purchase_custom(bot_id, item_name, cost, current_money)

func _purchase_custom(bot_id: int, item_name: String, cost: int, current_money: int) -> int:
	if cost <= 0 or current_money < cost:
		return current_money
	deduct_money(bot_id, cost)
	emit_signal("purchase_made", bot_id, item_name, cost)
	return current_money - cost
