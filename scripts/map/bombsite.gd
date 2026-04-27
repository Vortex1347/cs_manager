# bombsite.gd
# Валидирует plant/defuse зону сайта и даёт семантический site_id.
# Зависимости: bomb_controller.gd (использует contains_point), tactical_map.gd (читает позиции сайтов)

extends Area3D
class_name Bombsite

@export var site_id: String = "A"

func _ready() -> void:
	add_to_group("bombsites")

func contains_point(pos: Vector3) -> bool:
	var shape_node: CollisionShape3D = get_node_or_null("CollisionShape3D")
	if shape_node == null or shape_node.shape == null:
		return false
	var box := shape_node.shape as BoxShape3D
	if box == null:
		return false
	var local: Vector3 = to_local(pos)
	var ext: Vector3 = box.size * 0.5
	return abs(local.x) <= ext.x and abs(local.z) <= ext.z
