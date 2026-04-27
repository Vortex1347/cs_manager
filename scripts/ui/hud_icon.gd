# hud_icon.gd
# Рисует минималистичные HUD-иконки без внешних текстур для компактного player-facing UI.
# Зависимости: pause_controller.gd (меняет icon_name и accent), hud.tscn (использует этот Control)

extends Control
class_name HUDIcon

@export var icon_name: String = "hold"
@export var accent: Color = Color(1.0, 1.0, 1.0, 1.0)

func _ready() -> void:
	custom_minimum_size = Vector2(18, 18)

func set_icon_name(value: String) -> void:
	icon_name = value
	queue_redraw()

func set_accent(value: Color) -> void:
	accent = value
	queue_redraw()

func _draw() -> void:
	var rect = Rect2(Vector2.ZERO, size)
	var c = accent
	match icon_name:
		"bomb":
			draw_circle(rect.get_center(), rect.size.x * 0.22, c)
			draw_line(rect.get_center() + Vector2(-1, -6), rect.get_center() + Vector2(5, -10), c, 2.0)
			draw_circle(rect.get_center() + Vector2(7, -11), 1.8, c)
		"plant":
			draw_line(Vector2(6, 4), Vector2(6, 14), c, 2.2)
			draw_colored_polygon(PackedVector2Array([Vector2(6, 4), Vector2(14, 6), Vector2(6, 9)]), c)
		"defuse":
			draw_line(Vector2(5, 13), Vector2(13, 5), c, 2.4)
			draw_line(Vector2(7, 5), Vector2(13, 11), c, 2.0)
			draw_circle(Vector2(5, 13), 2.0, c)
		"smoke":
			draw_circle(Vector2(7, 10), 3.0, c)
			draw_circle(Vector2(11, 9), 3.6, c)
			draw_circle(Vector2(14, 11), 2.4, c)
		"flash":
			var center = rect.get_center()
			draw_circle(center, 2.4, c)
			for i in range(8):
				var angle = TAU * float(i) / 8.0
				var dir = Vector2(cos(angle), sin(angle))
				draw_line(center + dir * 4.0, center + dir * 8.0, c, 1.8)
		"frag":
			draw_circle(rect.get_center() + Vector2(0, 1), 4.6, c)
			draw_line(Vector2(9, 3), Vector2(12, 1), c, 1.8)
			draw_circle(Vector2(13, 1), 1.2, c)
		"site_a":
			draw_colored_polygon(PackedVector2Array([Vector2(9, 3), Vector2(15, 15), Vector2(3, 15)]), c)
			draw_line(Vector2(6, 10), Vector2(12, 10), Color(0.08, 0.08, 0.08, 0.9), 1.6)
		"site_b":
			draw_rect(Rect2(4, 3, 8, 12), c)
			draw_circle(Vector2(10, 6), 3.0, Color(0.08, 0.08, 0.08, 0.9))
			draw_circle(Vector2(10, 12), 3.0, Color(0.08, 0.08, 0.08, 0.9))
		"hold":
			draw_rect(Rect2(4, 4, 10, 10), c, false, 2.0)
		"rush":
			draw_line(Vector2(4, 9), Vector2(14, 9), c, 2.4)
			draw_line(Vector2(10, 5), Vector2(14, 9), c, 2.4)
			draw_line(Vector2(10, 13), Vector2(14, 9), c, 2.4)
		"split":
			draw_line(Vector2(4, 9), Vector2(14, 9), c, 2.2)
			draw_line(Vector2(9, 4), Vector2(4, 9), c, 2.0)
			draw_line(Vector2(9, 14), Vector2(4, 9), c, 2.0)
			draw_line(Vector2(9, 4), Vector2(14, 9), c, 2.0)
			draw_line(Vector2(9, 14), Vector2(14, 9), c, 2.0)
		"rotate":
			draw_arc(rect.get_center(), 5.6, deg_to_rad(-50), deg_to_rad(230), 20, c, 2.0)
			draw_line(Vector2(12, 3), Vector2(15, 7), c, 2.0)
			draw_line(Vector2(12, 3), Vector2(8, 4), c, 2.0)
		"save":
			draw_rect(Rect2(4, 8, 10, 7), c, false, 2.0)
			draw_line(Vector2(4, 8), Vector2(9, 4), c, 2.0)
			draw_line(Vector2(14, 8), Vector2(9, 4), c, 2.0)
		"utility":
			draw_circle(Vector2(6, 12), 2.4, c)
			draw_circle(Vector2(10, 7), 2.4, c)
			draw_circle(Vector2(14, 12), 2.4, c)
		"alive":
			draw_circle(rect.get_center(), 5.0, c)
			draw_circle(rect.get_center(), 2.0, Color(0.08, 0.08, 0.08, 0.95))
		"money":
			draw_rect(Rect2(3, 5, 12, 8), c, false, 2.0)
			draw_line(Vector2(6, 7), Vector2(12, 11), c, 1.6)
		_:
			draw_circle(rect.get_center(), 4.5, c)
