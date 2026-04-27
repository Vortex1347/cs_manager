# combat_directive.gd
# Общий контейнер для боевой директивы бота: hold, peek, trade, fallback и lane context.
# Зависимости: нет (Resource, используется bot_team.gd и bot_brain.gd)

extends Resource
class_name CombatDirective

@export var hold_zone: String = ""
@export var hold_arc: Dictionary = {}
@export var peek_mode: String = "hold_angle"
@export var trade_partner_id: int = -1
@export var fallback_route_id: String = ""
@export var reposition_slot: String = ""
@export var confidence_threshold: float = 0.45
@export var lane_id: String = ""
@export var slot_id: String = ""
@export var hold_position: Vector3 = Vector3.ZERO
@export var look_at_position: Vector3 = Vector3.ZERO
@export var shoulder_position: Vector3 = Vector3.ZERO
@export var wide_position: Vector3 = Vector3.ZERO
@export var fallback_position: Vector3 = Vector3.ZERO
@export var clear_points: Array = []
@export var last_target_position: Vector3 = Vector3.ZERO
@export var engagement_profile_hint: String = ""
@export var preferred_fire_mode: String = ""
@export var stabilize_before_peek: bool = false
@export var stabilize_window: float = 0.1
@export var counter_strafe_window: float = 0.06
@export var commit_window: float = 0.45

func clone():
	var copy = get_script().new()
	copy.hold_zone = hold_zone
	copy.hold_arc = hold_arc.duplicate(true)
	copy.peek_mode = peek_mode
	copy.trade_partner_id = trade_partner_id
	copy.fallback_route_id = fallback_route_id
	copy.reposition_slot = reposition_slot
	copy.confidence_threshold = confidence_threshold
	copy.lane_id = lane_id
	copy.slot_id = slot_id
	copy.hold_position = hold_position
	copy.look_at_position = look_at_position
	copy.shoulder_position = shoulder_position
	copy.wide_position = wide_position
	copy.fallback_position = fallback_position
	copy.clear_points = clear_points.duplicate()
	copy.last_target_position = last_target_position
	copy.engagement_profile_hint = engagement_profile_hint
	copy.preferred_fire_mode = preferred_fire_mode
	copy.stabilize_before_peek = stabilize_before_peek
	copy.stabilize_window = stabilize_window
	copy.counter_strafe_window = counter_strafe_window
	copy.commit_window = commit_window
	return copy

func to_dict() -> Dictionary:
	return {
		"hold_zone": hold_zone,
		"hold_arc": hold_arc.duplicate(true),
		"peek_mode": peek_mode,
		"trade_partner_id": trade_partner_id,
		"fallback_route_id": fallback_route_id,
		"reposition_slot": reposition_slot,
		"confidence_threshold": confidence_threshold,
		"lane_id": lane_id,
		"slot_id": slot_id,
		"hold_position": hold_position,
		"look_at_position": look_at_position,
		"shoulder_position": shoulder_position,
		"wide_position": wide_position,
		"fallback_position": fallback_position,
		"clear_points": clear_points.duplicate(),
		"last_target_position": last_target_position,
		"engagement_profile_hint": engagement_profile_hint,
		"preferred_fire_mode": preferred_fire_mode,
		"stabilize_before_peek": stabilize_before_peek,
		"stabilize_window": stabilize_window,
		"counter_strafe_window": counter_strafe_window,
		"commit_window": commit_window,
	}

func load_from_dict(data: Dictionary) -> void:
	hold_zone = String(data.get("hold_zone", ""))
	hold_arc = data.get("hold_arc", {}).duplicate(true)
	peek_mode = String(data.get("peek_mode", "hold_angle"))
	trade_partner_id = int(data.get("trade_partner_id", -1))
	fallback_route_id = String(data.get("fallback_route_id", ""))
	reposition_slot = String(data.get("reposition_slot", ""))
	confidence_threshold = float(data.get("confidence_threshold", 0.45))
	lane_id = String(data.get("lane_id", ""))
	slot_id = String(data.get("slot_id", ""))
	hold_position = data.get("hold_position", Vector3.ZERO)
	look_at_position = data.get("look_at_position", Vector3.ZERO)
	shoulder_position = data.get("shoulder_position", Vector3.ZERO)
	wide_position = data.get("wide_position", Vector3.ZERO)
	fallback_position = data.get("fallback_position", Vector3.ZERO)
	clear_points = data.get("clear_points", []).duplicate()
	last_target_position = data.get("last_target_position", Vector3.ZERO)
	engagement_profile_hint = String(data.get("engagement_profile_hint", ""))
	preferred_fire_mode = String(data.get("preferred_fire_mode", ""))
	stabilize_before_peek = bool(data.get("stabilize_before_peek", false))
	stabilize_window = float(data.get("stabilize_window", 0.1))
	counter_strafe_window = float(data.get("counter_strafe_window", 0.06))
	commit_window = float(data.get("commit_window", 0.45))

func get_summary() -> String:
	return "%s / %s / lane:%s / tp:%d / fm:%s" % [hold_zone, peek_mode, lane_id, trade_partner_id, preferred_fire_mode]
