# rl_server.gd
# WebSocket сервер (порт 9001). Связывает Godot и Python во время обучения.
# Каждый кадр: отправляет observations → получает actions.
# Зависимости: bot_observer.gd, bot_brain.gd

extends Node
class_name RLServer

const PORT := 9002
# Отправлять observations Python раз в N physics-кадров.
# При 60fps и FRAME_SKIP=3 → 20 решений/сек — Python успевает отвечать.
# Меньше дёрганности: бот применяет одно действие 3 кадра подряд, не ждёт.
const FRAME_SKIP: int = 3

var _ws    := WebSocketMultiplayerPeer.new()
var _obs   := BotObserver.new()
var _pending: Dictionary = {}        # bot_id → {move:int, shoot:bool, interact:bool}
var _rewards: Dictionary = {}        # bot_id → float  (накопленная награда за кадр)
var _dones:   Dictionary = {}        # bot_id → bool
var is_connected: bool = false
var _peer_count: int = 0
var _frame_counter: int = 0

signal python_connected
signal python_disconnected

func _ready() -> void:
	add_child(_obs)
	var err := _ws.create_server(PORT)
	if err != OK:
		push_error("RLServer: не удалось открыть порт %d (err=%d)" % [PORT, err])
		return
	_ws.peer_connected.connect(_on_peer_connected)
	_ws.peer_disconnected.connect(_on_peer_disconnected)
	print("RLServer: слушаю на порту %d" % PORT)

func _on_peer_connected(_id: int) -> void:
	_peer_count += 1
	if _peer_count == 1:
		is_connected = true
		emit_signal("python_connected")
		print("RLServer: Python подключился")

func _on_peer_disconnected(_id: int) -> void:
	_peer_count -= 1
	if _peer_count == 0:
		is_connected = false
		emit_signal("python_disconnected")
		print("RLServer: Python отключился")

func _process(_d: float) -> void:
	_ws.poll()

	# Читаем входящие actions
	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet().get_string_from_utf8()
		var data = JSON.parse_string(raw)
		if data == null: continue
		if data.has("actions"):
			for a in data["actions"]:
				_pending[int(a["id"])] = a

# Вызывается из game_manager каждый physics-кадр.
# Observations отправляются только раз в FRAME_SKIP кадров — даёт Python время ответить.
func send_step(all_bots: Array) -> void:
	if not is_connected:
		return
	_frame_counter += 1
	if _frame_counter % FRAME_SKIP != 0:
		return
	var batch := []
	for bot in all_bots:
		if not bot.has_method("start_round"):
			continue
		var id: int = bot.stats.bot_id
		batch.append({
			"id":     id,
			"obs":    Array(_obs.get_obs(bot)),
			"reward": _rewards.get(id, 0.0),
			"done":   _dones.get(id, false),
		})
	_rewards.clear()
	_dones.clear()
	var msg := JSON.stringify({"step": Engine.get_frames_drawn(), "bots": batch})
	_ws.put_packet(msg.to_utf8_buffer())

# Запросить action для конкретного бота (default: стоять, не стрелять)
func get_action(bot_id: int) -> Dictionary:
	return _pending.get(bot_id, {"move": 0, "shoot": false, "interact": false})

# Добавить награду (вызывается из game_manager по сигналам)
func add_reward(bot_id: int, value: float) -> void:
	_rewards[bot_id] = _rewards.get(bot_id, 0.0) + value

# Пометить эпизод как завершённый (раунд кончился)
func set_done(bot_id: int) -> void:
	_dones[bot_id] = true
