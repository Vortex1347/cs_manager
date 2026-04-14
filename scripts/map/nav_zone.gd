# nav_zone.gd
# Навигационная зона карты. Хранит вейпоинты для патруля ботов.
# Зависимости: нет (Resource, не Node)

extends Resource
class_name NavZone

enum ZoneType { SPAWN_CT, SPAWN_T, MID, SITE_A, SITE_B, CORRIDOR }

@export var zone_name: String = ""
@export var zone_type: ZoneType = ZoneType.MID
@export var waypoints: Array[Vector3] = []
@export var angle_hold_positions: Array[Vector3] = []  # позиции для холда углов (game_sense >= 7)
@export var choke_points: Array[Vector3] = []          # точки для броска смоука

func get_random_waypoints(count: int) -> Array[Vector3]:
	if waypoints.is_empty():
		return []
	var result: Array[Vector3] = []
	var available = waypoints.duplicate()
	available.shuffle()
	for i in range(min(count, available.size())):
		result.append(available[i])
	return result

func get_angle_hold_waypoints(count: int) -> Array[Vector3]:
	if angle_hold_positions.is_empty():
		return get_random_waypoints(count)
	var result: Array[Vector3] = []
	var available = angle_hold_positions.duplicate()
	available.shuffle()
	for i in range(min(count, available.size())):
		result.append(available[i])
	return result
