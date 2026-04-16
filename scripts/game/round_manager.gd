# round_manager.gd
# FSM раунда: BUY_PHASE → LIVE → ROUND_END.
# Зависимости: game_manager.gd (parent), bot_team.gd (через GameManager)

extends Node

signal phase_changed(phase: int)
signal round_started(round_number: int)
signal round_ended(winner: String, reason: String)
signal time_updated(seconds_remaining: float)

enum RoundPhase { BUY_PHASE, LIVE, ROUND_END }

const BUY_PHASE_DURATION: float = 15.0
const ROUND_DURATION: float = 115.0  # 1:55

var current_phase: RoundPhase = RoundPhase.BUY_PHASE
var round_number: int = 0
var time_remaining: float = 0.0
var _timer: float = 0.0

func _ready() -> void:
	set_process(false)

func start_round() -> void:
	round_number += 1
	emit_signal("round_started", round_number)  # сначала сбрасываем ботов
	_set_phase(RoundPhase.BUY_PHASE)             # потом бай-фаза + автозакупка
	set_process(true)

func _process(delta: float) -> void:
	_timer -= delta
	time_remaining = _timer
	emit_signal("time_updated", _timer)

	if _timer <= 0.0:
		match current_phase:
			RoundPhase.BUY_PHASE:
				_set_phase(RoundPhase.LIVE)
			RoundPhase.LIVE:
				# Время вышло и бомба не заложена → CT победили
				end_round("CT", "time_expired")

func _set_phase(phase: RoundPhase) -> void:
	current_phase = phase
	match phase:
		RoundPhase.BUY_PHASE:
			_timer = BUY_PHASE_DURATION
		RoundPhase.LIVE:
			_timer = ROUND_DURATION
		RoundPhase.ROUND_END:
			_timer = 0.0
			set_process(false)
	emit_signal("phase_changed", phase)

func end_round(winner: String, reason: String) -> void:
	if current_phase == RoundPhase.ROUND_END:
		return
	_set_phase(RoundPhase.ROUND_END)
	emit_signal("round_ended", winner, reason)

func get_time_remaining() -> float:
	return _timer

func is_live() -> bool:
	return current_phase == RoundPhase.LIVE
