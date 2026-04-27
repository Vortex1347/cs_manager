# dust2_layout_blockout.gd
# Строит replaceable low-poly Dust2 blockout scene с MapAnchors, SpawnPoints и простыми collision helpers.
# Зависимости: tactical_map.gd (индексирует маркеры), game_manager.gd (использует SpawnPoints совместимо через TacticalMap)

extends Node3D
class_name Dust2LayoutBlockout

const FLOOR_COLOR: Color = Color(0.77, 0.71, 0.61, 1.0)
const ACCENT_A_COLOR: Color = Color(0.89, 0.75, 0.34, 1.0)
const ACCENT_B_COLOR: Color = Color(0.92, 0.61, 0.24, 1.0)
const WALL_COLOR: Color = Color(0.56, 0.50, 0.44, 1.0)
const BOX_COLOR: Color = Color(0.48, 0.36, 0.22, 1.0)
const WALL_HEIGHT: float = 3.0

var _points: Dictionary = {}
var _spawn_positions_t: Array[Vector3] = []
var _spawn_positions_ct: Array[Vector3] = []
var _site_positions: Dictionary = {}

func _ready() -> void:
	ensure_layout()

func ensure_layout() -> void:
	_build_point_defs()
	_clear_layout()
	var visual_root := Node3D.new()
	visual_root.name = "MapVisual"
	add_child(visual_root)
	var collider_root := Node3D.new()
	collider_root.name = "CollisionHelpers"
	add_child(collider_root)
	var anchor_root := Node3D.new()
	anchor_root.name = "MapAnchors"
	add_child(anchor_root)
	var spawn_root := Node3D.new()
	spawn_root.name = "SpawnPoints"
	add_child(spawn_root)
	var site_root := Node3D.new()
	site_root.name = "MapSites"
	add_child(site_root)

	_build_visual_floors(visual_root)
	_build_collision_helpers(collider_root)
	_build_anchor_markers(anchor_root)
	_build_spawn_markers(spawn_root)
	_build_site_markers(site_root)

func _clear_layout() -> void:
	for child_name in ["MapVisual", "CollisionHelpers", "MapAnchors", "SpawnPoints", "MapSites"]:
		var existing = get_node_or_null(child_name)
		if existing:
			existing.free()

func _build_point_defs() -> void:
	_points = {
		"t_spawn_center": Vector3(0, 0, 60),
		"suicide": Vector3(-6, 0, 40),
		"top_mid": Vector3(0, 0, 28),
		"catwalk_entry": Vector3(-10, 0, 24),
		"xbox": Vector3(-8, 0, 12),
		"mid": Vector3(0, 0, 8),
		"mid_doors": Vector3(20, 0, 4),
		"ct_mid": Vector3(18, 0, -18),
		"lower_tunnels": Vector3(24, 0, 34),
		"upper_tunnels": Vector3(40, 0, 18),
		"b_entrance": Vector3(52, 0, 2),
		"b_door": Vector3(42, 0, -18),
		"b_window": Vector3(34, 0, -18),
		"b_platform": Vector3(56, 0, -16),
		"b_default": Vector3(61, 0, -27),
		"b_back": Vector3(70, 0, -30),
		"b_car": Vector3(68, 0, -9),
		"long_doors": Vector3(-32, 0, 44),
		"outside_long": Vector3(-48, 0, 34),
		"pit": Vector3(-66, 0, 18),
		"blue": Vector3(-62, 0, 4),
		"a_long": Vector3(-56, 0, -2),
		"a_car": Vector3(-42, 0, -10),
		"a_cross": Vector3(-46, 0, -12),
		"a_ramp": Vector3(-40, 0, -18),
		"a_boxes": Vector3(-34, 0, -24),
		"a_default": Vector3(-48, 0, -28),
		"goose": Vector3(-60, 0, -27),
		"catwalk": Vector3(-18, 0, 2),
		"short_stairs": Vector3(-24, 0, -6),
		"short_a": Vector3(-28, 0, -13),
		"short_top": Vector3(-34, 0, -19),
		"ct_spawn": Vector3(6, 0, -54),
		"ct_spawn_center": Vector3(6, 0, -54),
		"ct_a_ramp": Vector3(-22, 0, -38),
		"ct_b_rot": Vector3(32, 0, -34),
		"goose_denial": Vector3(-52, 0, -24),
		"b_site_default": Vector3(61, 0, -27),
		"b_site_back": Vector3(70, 0, -30),
		"a_site_default": Vector3(-48, 0, -28),
		"a_site_open": Vector3(-34, 0, -24),
		"t_long_doors": Vector3(-32, 0, 44),
		"t_long_out": Vector3(-48, 0, 34),
	}
	_spawn_positions_t = [
		Vector3(-12, 0, 64),
		Vector3(-6, 0, 62),
		Vector3(0, 0, 64),
		Vector3(6, 0, 62),
		Vector3(12, 0, 64),
	]
	_spawn_positions_ct = [
		Vector3(-8, 0, -58),
		Vector3(-2, 0, -56),
		Vector3(4, 0, -58),
		Vector3(10, 0, -56),
		Vector3(16, 0, -58),
	]
	_site_positions = {
		"A": Vector3(-46, 0, -26),
		"B": Vector3(62, 0, -26),
	}

func _build_visual_floors(parent: Node3D) -> void:
	var floor_tiles = [
		{"name": "TSpawnFloor", "pos": Vector3(0, -0.12, 58), "size": Vector3(34, 0.22, 26), "color": FLOOR_COLOR},
		{"name": "LongLaneFloor", "pos": Vector3(-49, -0.12, 22), "size": Vector3(42, 0.22, 54), "color": FLOOR_COLOR},
		{"name": "ALinkFloor", "pos": Vector3(-45, -0.12, -12), "size": Vector3(30, 0.22, 28), "color": FLOOR_COLOR},
		{"name": "ASiteFloor", "pos": Vector3(-46, -0.12, -27), "size": Vector3(32, 0.22, 22), "color": ACCENT_A_COLOR},
		{"name": "MidFloor", "pos": Vector3(2, -0.12, 12), "size": Vector3(42, 0.22, 40), "color": FLOOR_COLOR},
		{"name": "CatFloor", "pos": Vector3(-22, -0.12, -6), "size": Vector3(18, 0.22, 28), "color": FLOOR_COLOR},
		{"name": "TunnelFloor", "pos": Vector3(38, -0.12, 20), "size": Vector3(34, 0.22, 28), "color": FLOOR_COLOR},
		{"name": "BConnectorFloor", "pos": Vector3(44, -0.12, -8), "size": Vector3(24, 0.22, 30), "color": FLOOR_COLOR},
		{"name": "BSiteFloor", "pos": Vector3(61, -0.12, -26), "size": Vector3(28, 0.22, 24), "color": ACCENT_B_COLOR},
		{"name": "CTFloor", "pos": Vector3(10, -0.12, -52), "size": Vector3(46, 0.22, 24), "color": FLOOR_COLOR},
	]
	for tile in floor_tiles:
		_add_floor_tile(parent, String(tile["name"]), Vector3(tile["pos"]), Vector3(tile["size"]), Color(tile["color"]))

func _build_collision_helpers(parent: Node3D) -> void:
	var blocks = [
		{"name": "NorthWall", "pos": Vector3(0, 1.5, -82), "size": Vector3(188, WALL_HEIGHT, 1)},
		{"name": "SouthWall", "pos": Vector3(0, 1.5, 82), "size": Vector3(188, WALL_HEIGHT, 1)},
		{"name": "WestWall", "pos": Vector3(-94, 1.5, 0), "size": Vector3(1, WALL_HEIGHT, 164)},
		{"name": "EastWall", "pos": Vector3(94, 1.5, 0), "size": Vector3(1, WALL_HEIGHT, 164)},
		{"name": "LongDoorsLeft", "pos": Vector3(-36, 1.5, 46), "size": Vector3(10, WALL_HEIGHT, 4)},
		{"name": "LongDoorsRight", "pos": Vector3(-24, 1.5, 46), "size": Vector3(8, WALL_HEIGHT, 4)},
		{"name": "OutsideLongDivider", "pos": Vector3(-30, 1.5, 24), "size": Vector3(2, WALL_HEIGHT, 44)},
		{"name": "PitCover", "pos": Vector3(-68, 1.5, 18), "size": Vector3(8, WALL_HEIGHT, 2)},
		{"name": "BlueBox", "pos": Vector3(-62, 1.5, 6), "size": Vector3(10, WALL_HEIGHT, 6), "box": true},
		{"name": "ALongWallWest", "pos": Vector3(-74, 1.5, -2), "size": Vector3(2, WALL_HEIGHT, 50)},
		{"name": "ALongWallEast", "pos": Vector3(-38, 1.5, -4), "size": Vector3(2, WALL_HEIGHT, 42)},
		{"name": "AHouseBack", "pos": Vector3(-44, 1.5, -40), "size": Vector3(34, WALL_HEIGHT, 2)},
		{"name": "AHouseRight", "pos": Vector3(-24, 1.5, -24), "size": Vector3(2, WALL_HEIGHT, 32)},
		{"name": "ABoxes", "pos": Vector3(-34, 1.5, -24), "size": Vector3(12, WALL_HEIGHT, 10), "box": true},
		{"name": "GooseBox", "pos": Vector3(-58, 1.5, -26), "size": Vector3(10, WALL_HEIGHT, 8), "box": true},
		{"name": "ShortRiseLeft", "pos": Vector3(-20, 1.5, 2), "size": Vector3(18, WALL_HEIGHT, 2)},
		{"name": "ShortRiseRight", "pos": Vector3(-8, 1.5, -2), "size": Vector3(2, WALL_HEIGHT, 28)},
		{"name": "XboxBox", "pos": Vector3(-8, 1.5, 12), "size": Vector3(8, WALL_HEIGHT, 8), "box": true},
		{"name": "MidDoorsFrame", "pos": Vector3(18, 1.5, 4), "size": Vector3(8, WALL_HEIGHT, 4)},
		{"name": "MidLeftWall", "pos": Vector3(-14, 1.5, 20), "size": Vector3(2, WALL_HEIGHT, 42)},
		{"name": "MidRightWall", "pos": Vector3(24, 1.5, 8), "size": Vector3(2, WALL_HEIGHT, 50)},
		{"name": "LowerTunnelSouth", "pos": Vector3(28, 1.5, 42), "size": Vector3(2, WALL_HEIGHT, 24)},
		{"name": "TunnelSpine", "pos": Vector3(30, 1.5, 22), "size": Vector3(2, WALL_HEIGHT, 36)},
		{"name": "UpperTunnelLeft", "pos": Vector3(48, 1.5, 20), "size": Vector3(18, WALL_HEIGHT, 2)},
		{"name": "BWindowCover", "pos": Vector3(34, 1.5, -16), "size": Vector3(6, WALL_HEIGHT, 10), "box": true},
		{"name": "BDoorFrame", "pos": Vector3(42, 1.5, -18), "size": Vector3(6, WALL_HEIGHT, 4)},
		{"name": "BPlatformBoxes", "pos": Vector3(56, 1.5, -18), "size": Vector3(10, WALL_HEIGHT, 10), "box": true},
		{"name": "BBackBox", "pos": Vector3(70, 1.5, -30), "size": Vector3(8, WALL_HEIGHT, 8), "box": true},
		{"name": "BCarBox", "pos": Vector3(68, 1.5, -9), "size": Vector3(6, WALL_HEIGHT, 6), "box": true},
		{"name": "BSiteBackWall", "pos": Vector3(60, 1.5, -42), "size": Vector3(40, WALL_HEIGHT, 2)},
		{"name": "CTBridge", "pos": Vector3(10, 1.5, -42), "size": Vector3(34, WALL_HEIGHT, 2)},
		{"name": "CTAConnector", "pos": Vector3(-18, 1.5, -44), "size": Vector3(2, WALL_HEIGHT, 18)},
		{"name": "CTBConnector", "pos": Vector3(32, 1.5, -44), "size": Vector3(2, WALL_HEIGHT, 20)},
		{"name": "CTSpawnCrate", "pos": Vector3(2, 1.5, -54), "size": Vector3(10, WALL_HEIGHT, 8), "box": true},
	]
	for block in blocks:
		_add_block(parent, String(block["name"]), Vector3(block["pos"]), Vector3(block["size"]), bool(block.get("box", false)))

func _build_anchor_markers(parent: Node3D) -> void:
	for point_name in _points.keys():
		var marker := Marker3D.new()
		marker.name = String(point_name)
		marker.position = Vector3(_points[point_name])
		parent.add_child(marker)

func _build_spawn_markers(parent: Node3D) -> void:
	for i in range(_spawn_positions_t.size()):
		var marker := Marker3D.new()
		marker.name = "T_Spawn_%d" % (i + 1)
		marker.position = _spawn_positions_t[i]
		parent.add_child(marker)
	for i in range(_spawn_positions_ct.size()):
		var marker := Marker3D.new()
		marker.name = "CT_Spawn_%d" % (i + 1)
		marker.position = _spawn_positions_ct[i]
		parent.add_child(marker)

func _build_site_markers(parent: Node3D) -> void:
	for site_id in _site_positions.keys():
		var marker := Marker3D.new()
		marker.name = "Site_%s" % site_id
		marker.position = Vector3(_site_positions[site_id])
		parent.add_child(marker)

func _add_floor_tile(parent: Node3D, node_name: String, position: Vector3, size: Vector3, color: Color) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	mesh_instance.position = position
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_material(color, 0.92)
	parent.add_child(mesh_instance)

func _add_block(parent: Node3D, node_name: String, position: Vector3, size: Vector3, is_box: bool) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)

	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_material(BOX_COLOR if is_box else WALL_COLOR, 0.86 if is_box else 0.9)
	body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)

func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
