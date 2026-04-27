# intel_event_data.gd
# Общий контейнер для audio/visual intel: позиция, lane, confidence, ttl и происхождение события.
# Зависимости: нет (Resource, используется game_manager.gd, bot_team.gd, bot_brain.gd)

extends Resource
class_name IntelEventData

@export var event_type: String = ""
@export var world_pos: Vector3 = Vector3.ZERO
@export var lane_id: String = ""
@export var confidence: float = 0.5
@export var ttl: float = 2.0
@export var source_team: int = -1
@export var source_bot_id: int = -1
@export var volume: float = 1.0
@export var detail: String = ""

func clone():
	var copy = get_script().new()
	copy.event_type = event_type
	copy.world_pos = world_pos
	copy.lane_id = lane_id
	copy.confidence = confidence
	copy.ttl = ttl
	copy.source_team = source_team
	copy.source_bot_id = source_bot_id
	copy.volume = volume
	copy.detail = detail
	return copy

func to_dict() -> Dictionary:
	return {
		"event_type": event_type,
		"world_pos": world_pos,
		"lane_id": lane_id,
		"confidence": confidence,
		"ttl": ttl,
		"source_team": source_team,
		"source_bot_id": source_bot_id,
		"volume": volume,
		"detail": detail,
	}

func load_from_dict(data: Dictionary) -> void:
	event_type = String(data.get("event_type", ""))
	world_pos = data.get("world_pos", Vector3.ZERO)
	lane_id = String(data.get("lane_id", ""))
	confidence = float(data.get("confidence", 0.5))
	ttl = float(data.get("ttl", 2.0))
	source_team = int(data.get("source_team", -1))
	source_bot_id = int(data.get("source_bot_id", -1))
	volume = float(data.get("volume", 1.0))
	detail = String(data.get("detail", ""))
