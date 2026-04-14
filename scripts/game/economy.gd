# economy.gd
# Экономика: деньги ботов, награды за убийства/победу/поражение, покупки.
# Зависимости: bot_stats.gd (через словарь), round_manager.gd (сигналы раунда)

extends Node
class_name Economy

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

# Авто-покупка для бота по приоритету
func auto_buy(bot_id: int, current_money: int) -> Array:
	var bought = []
	var money = current_money
	# Приоритет: rifle > smg > pistol
	if money >= WEAPON_PRICES["rifle"]:
		bought.append("rifle")
		money -= WEAPON_PRICES["rifle"]
		deduct_money(bot_id, WEAPON_PRICES["rifle"])
		emit_signal("purchase_made", bot_id, "rifle", WEAPON_PRICES["rifle"])
	elif money >= WEAPON_PRICES["smg"]:
		bought.append("smg")
		money -= WEAPON_PRICES["smg"]
		deduct_money(bot_id, WEAPON_PRICES["smg"])
		emit_signal("purchase_made", bot_id, "smg", WEAPON_PRICES["smg"])
	# Добавить гранаты если остались деньги
	if money >= WEAPON_PRICES["smoke"]:
		bought.append("smoke")
		money -= WEAPON_PRICES["smoke"]
		deduct_money(bot_id, WEAPON_PRICES["smoke"])
		emit_signal("purchase_made", bot_id, "smoke", WEAPON_PRICES["smoke"])
	return bought

func can_afford(bot_id: int, item: String) -> bool:
	return bot_money.get(bot_id, 0) >= WEAPON_PRICES.get(item, INF)
