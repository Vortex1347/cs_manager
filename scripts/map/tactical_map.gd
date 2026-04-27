# tactical_map.gd
# Строит gameplay-faithful top-down Dust2-карту, callout-граф, authored routes, plant slots, retake lanes и combat metadata.
# Зависимости: bombsite.gd (runtime bombsite zones), bot_team.gd / bot_brain.gd (читают routes, cover slots, plant slots, bomb packages)

extends Node3D
class_name TacticalMap

const DEBUG_START_COLOR: Color = Color(0.18, 0.74, 1.0, 0.95)
const DEBUG_AIM_COLOR: Color = Color(1.0, 0.85, 0.24, 0.95)
const DEBUG_HIGHLIGHT_COLOR: Color = Color(1.0, 0.42, 0.16, 1.0)
const DEBUG_SLOT_COLOR: Color = Color(0.35, 1.0, 0.46, 0.95)
const DEBUG_ARC_COLOR: Color = Color(1.0, 0.22, 0.22, 0.8)

const FLOOR_COLOR: Color = Color(0.76, 0.70, 0.60, 1.0)
const WALL_COLOR: Color = Color(0.58, 0.52, 0.45, 1.0)
const BOX_COLOR: Color = Color(0.53, 0.40, 0.22, 1.0)
const ACCENT_A_COLOR: Color = Color(0.98, 0.81, 0.21, 1.0)
const ACCENT_B_COLOR: Color = Color(0.95, 0.63, 0.13, 1.0)

const WALL_HEIGHT: float = 3.0
const WALL_THICKNESS: float = 1.0
const FLOOR_SIZE: Vector3 = Vector3(188.0, 0.2, 164.0)

@export var layout_scene: PackedScene

var _points: Dictionary = {}
var _routes: Dictionary = {}
var _lineups: Dictionary = {}
var _utility_packages: Dictionary = {}
var _cover_slots: Dictionary = {}
var _hold_profiles: Dictionary = {}
var _peek_profiles: Dictionary = {}
var _fallback_routes: Dictionary = {}
var _sound_zones: Array = []
var _plant_slots: Dictionary = {}
var _retake_lanes: Dictionary = {}
var _bomb_cover_packages: Dictionary = {}
var _graph: Dictionary = {}
var _materials: Dictionary = {}
var _spawn_positions_t: Array = []
var _spawn_positions_ct: Array = []
var _site_positions: Dictionary = {}
var _site_zone_sizes: Dictionary = {}

var _runtime_root: Node3D = null
var _layout_root: Node3D = null
var _lineup_debug_root: Node3D = null
var _combat_debug_root: Node3D = null
var _lineup_debug_visible: bool = false
var _combat_debug_visible: bool = false
var _highlighted_lineups: Array[String] = []
var _highlighted_slots: Array[String] = []

func _ready() -> void:
	_bind_default_layout()
	_build_point_defs()
	_build_graph()
	_build_runtime_scene()
	_build_routes()
	_build_lineups()
	_build_utility_packages()
	_build_combat_metadata()

func bind_map_scene(root: Node3D) -> void:
	if _layout_root and is_instance_valid(_layout_root):
		_layout_root.queue_free()
	_layout_root = root
	if _layout_root == null:
		return
	_layout_root.name = "ImportedMap"
	add_child(_layout_root)
	if _layout_root.has_method("ensure_layout"):
		_layout_root.call("ensure_layout")

func _bind_default_layout() -> void:
	var existing := get_node_or_null("ImportedMap")
	if existing and existing is Node3D:
		_layout_root = existing
		if _layout_root.has_method("ensure_layout"):
			_layout_root.call("ensure_layout")
		return
	if layout_scene == null:
		push_warning("TacticalMap: layout_scene is not assigned; map anchors will be missing.")
		return
	var instance = layout_scene.instantiate()
	if not (instance is Node3D):
		push_warning("TacticalMap: layout_scene root is not Node3D.")
		return
	bind_map_scene(instance as Node3D)

func get_point(point_name: String) -> Vector3:
	return _points.get(point_name.to_lower(), Vector3.ZERO)

func get_route(route_id: String) -> Array[Vector3]:
	return get_dynamic_route(_routes.get(route_id, []))

func get_dynamic_route(point_names: Array) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for point_name in point_names:
		var point = get_point(String(point_name))
		if point != Vector3.ZERO:
			result.append(point)
	return result

func get_route_ids() -> Array:
	return _routes.keys()

func get_site(site_id: String) -> Bombsite:
	for site in get_tree().get_nodes_in_group("bombsites"):
		if site is Bombsite and site.site_id == site_id:
			return site
	return null

func get_site_position(site_id: String) -> Vector3:
	return _site_positions.get(site_id.to_upper(), Vector3.ZERO)

func get_site_id_from_position(pos: Vector3) -> String:
	var best_site := ""
	var best_dist := INF
	for site_id in _site_positions.keys():
		var center = Vector3(_site_positions[site_id])
		var extents = Vector3(_site_zone_sizes.get(site_id, Vector3(18, 2, 16)))
		var local = pos - center
		if absf(local.x) <= extents.x * 0.5 and absf(local.z) <= extents.z * 0.5:
			return String(site_id)
		var dist_sq = center.distance_squared_to(pos)
		if dist_sq < best_dist:
			best_dist = dist_sq
			best_site = String(site_id)
	return best_site

func get_lineup(lineup_id: String) -> Dictionary:
	return _lineups.get(lineup_id, {}).duplicate(true)

func get_utility_package(package_id: String) -> Array:
	var package: Array = _utility_packages.get(package_id, [])
	var result: Array = []
	for entry in package:
		result.append(entry.duplicate(true))
	return result

func get_cover_slot(slot_id: String) -> Dictionary:
	return _cover_slots.get(slot_id, {}).duplicate(true)

func get_cover_slot_ids() -> Array:
	return _cover_slots.keys()

func get_hold_profile(profile_id: String) -> Dictionary:
	return _hold_profiles.get(profile_id, {}).duplicate(true)

func get_peek_profile(profile_id: String) -> Dictionary:
	return _peek_profiles.get(profile_id, {}).duplicate(true)

func get_fallback_route(route_id: String) -> Array[Vector3]:
	return get_dynamic_route(_fallback_routes.get(route_id, []))

func get_plant_slot(site_id: String, slot_id: String = "default") -> Dictionary:
	var site_slots: Dictionary = _plant_slots.get(site_id.to_upper(), {})
	return site_slots.get(slot_id.to_lower(), site_slots.get("default", {})).duplicate(true)

func get_retake_lane(site_id: String, lane_id: String) -> Dictionary:
	var site_lanes: Dictionary = _retake_lanes.get(site_id.to_upper(), {})
	return site_lanes.get(lane_id.to_lower(), {}).duplicate(true)

func get_bomb_cover_package(site_id: String, phase: String) -> Dictionary:
	var site_packages: Dictionary = _bomb_cover_packages.get(site_id.to_upper(), {})
	return site_packages.get(phase.to_lower(), {}).duplicate(true)

func build_path(from_pos: Vector3, to_pos: Vector3) -> Array[Vector3]:
	if _graph.is_empty():
		return [to_pos]
	var from_key = _get_nearest_graph_point(from_pos)
	var to_key = _get_nearest_graph_point(to_pos)
	if from_key == "" or to_key == "":
		return [to_pos]
	if from_key == to_key:
		return [to_pos]
	var open: Array = [from_key]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {from_key: 0.0}
	var f_score: Dictionary = {from_key: get_point(from_key).distance_to(get_point(to_key))}
	while not open.is_empty():
		var current = _pop_lowest_score(open, f_score)
		if current == to_key:
			break
		for neighbor in _graph.get(current, []):
			var tentative = float(g_score.get(current, INF)) + get_point(current).distance_to(get_point(neighbor))
			if tentative >= float(g_score.get(neighbor, INF)):
				continue
			came_from[neighbor] = current
			g_score[neighbor] = tentative
			f_score[neighbor] = tentative + get_point(neighbor).distance_to(get_point(to_key))
			if not (neighbor in open):
				open.append(neighbor)
	var point_path = _reconstruct_path(came_from, from_key, to_key)
	var world_path: Array[Vector3] = []
	if from_pos.distance_to(get_point(from_key)) > 2.4:
		world_path.append(get_point(from_key))
	for point_name in point_path:
		var point = get_point(String(point_name))
		if point != Vector3.ZERO and (world_path.is_empty() or world_path[world_path.size() - 1].distance_to(point) > 0.15):
			world_path.append(point)
	if world_path.is_empty() or world_path[world_path.size() - 1].distance_to(to_pos) > 0.6:
		world_path.append(to_pos)
	return world_path

func find_free_cover_slot(lane_id: String, reserved_slot_ids: Array) -> String:
	for slot_id in _cover_slots.keys():
		var slot = _cover_slots[slot_id]
		if String(slot.get("lane_id", "")) != lane_id:
			continue
		if slot_id in reserved_slot_ids:
			continue
		return slot_id
	return ""

func get_lane_id_from_position(pos: Vector3) -> String:
	var nearest_lane := "unknown"
	var nearest_dist := INF
	for zone in _sound_zones:
		var center: Vector3 = zone["center"]
		var extents: Vector3 = zone["extents"]
		var local = pos - center
		if absf(local.x) <= extents.x and absf(local.z) <= extents.z:
			return String(zone["lane_id"])
		var dist_sq = center.distance_squared_to(pos)
		if dist_sq < nearest_dist:
			nearest_dist = dist_sq
			nearest_lane = String(zone["lane_id"])
	return nearest_lane

func get_sound_zone(pos: Vector3) -> Dictionary:
	var lane_id = get_lane_id_from_position(pos)
	for zone in _sound_zones:
		if zone["lane_id"] == lane_id:
			return zone.duplicate(true)
	return {}

func get_spawn_positions(side_name: String) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if side_name == "CT":
		for pos in _spawn_positions_ct:
			result.append(Vector3(pos))
	else:
		for pos in _spawn_positions_t:
			result.append(Vector3(pos))
	return result

func set_lineup_debug_visible(value: bool) -> void:
	_lineup_debug_visible = value
	if value and _lineup_debug_root == null:
		_rebuild_debug_markers()
	elif _lineup_debug_root:
		_lineup_debug_root.visible = value

func is_lineup_debug_visible() -> bool:
	return _lineup_debug_visible

func set_combat_debug_visible(value: bool) -> void:
	_combat_debug_visible = value
	if value and _combat_debug_root == null:
		_rebuild_debug_markers()
	elif _combat_debug_root:
		_combat_debug_root.visible = value

func is_combat_debug_visible() -> bool:
	return _combat_debug_visible

func set_highlighted_lineups(lineup_ids: Array) -> void:
	var normalized: Array[String] = []
	for lineup_id in lineup_ids:
		normalized.append(String(lineup_id))
	if normalized == _highlighted_lineups:
		return
	_highlighted_lineups = normalized
	if _lineup_debug_visible:
		_rebuild_debug_markers()

func set_highlighted_slots(slot_ids: Array) -> void:
	var normalized: Array[String] = []
	for slot_id in slot_ids:
		normalized.append(String(slot_id))
	if normalized == _highlighted_slots:
		return
	_highlighted_slots = normalized
	if _combat_debug_visible:
		_rebuild_debug_markers()

func _build_point_defs() -> void:
	_points.clear()
	_spawn_positions_t.clear()
	_spawn_positions_ct.clear()
	_site_positions.clear()
	_site_zone_sizes = {
		"A": Vector3(22, 2, 18),
		"B": Vector3(20, 2, 18),
	}
	if _layout_root == null:
		push_warning("TacticalMap: no imported layout root bound.")
		return
	var anchor_root: Node = _layout_root.get_node_or_null("MapAnchors")
	if anchor_root == null:
		push_warning("TacticalMap: imported layout has no MapAnchors node.")
		return
	for child in anchor_root.get_children():
		if child is Node3D:
			_points[String(child.name).to_lower()] = (child as Node3D).global_position
	var spawn_root: Node = _layout_root.get_node_or_null("SpawnPoints")
	if spawn_root:
		var t_names: Array[String] = []
		var ct_names: Array[String] = []
		var t_markers: Dictionary = {}
		var ct_markers: Dictionary = {}
		for child in spawn_root.get_children():
			if not (child is Node3D):
				continue
			var child_name = String(child.name)
			if child_name.begins_with("T_Spawn_"):
				t_names.append(child_name)
				t_markers[child_name] = (child as Node3D).global_position
			elif child_name.begins_with("CT_Spawn_"):
				ct_names.append(child_name)
				ct_markers[child_name] = (child as Node3D).global_position
		t_names.sort()
		ct_names.sort()
		for name in t_names:
			_spawn_positions_t.append(Vector3(t_markers[name]))
		for name in ct_names:
			_spawn_positions_ct.append(Vector3(ct_markers[name]))
	var site_root: Node = _layout_root.get_node_or_null("MapSites")
	if site_root:
		var site_a = site_root.get_node_or_null("Site_A")
		var site_b = site_root.get_node_or_null("Site_B")
		if site_a and site_a is Node3D:
			_site_positions["A"] = (site_a as Node3D).global_position
		if site_b and site_b is Node3D:
			_site_positions["B"] = (site_b as Node3D).global_position
	if not _site_positions.has("A") and _points.has("a_default"):
		_site_positions["A"] = Vector3(_points["a_default"])
	if not _site_positions.has("B") and _points.has("b_default"):
		_site_positions["B"] = Vector3(_points["b_default"])

func _build_graph() -> void:
	_graph.clear()
	for point_name in _points.keys():
		_graph[point_name] = []
	_link("t_spawn_center", "long_doors")
	_link("t_spawn_center", "suicide")
	_link("t_spawn_center", "lower_tunnels")
	_link("long_doors", "outside_long")
	_link("outside_long", "pit")
	_link("outside_long", "blue")
	_link("pit", "blue")
	_link("blue", "a_long")
	_link("a_long", "a_car")
	_link("a_car", "a_cross")
	_link("a_cross", "a_ramp")
	_link("a_ramp", "a_default")
	_link("a_ramp", "a_boxes")
	_link("a_default", "goose")
	_link("suicide", "top_mid")
	_link("top_mid", "xbox")
	_link("top_mid", "mid")
	_link("top_mid", "catwalk_entry")
	_link("catwalk_entry", "xbox")
	_link("xbox", "mid")
	_link("xbox", "catwalk")
	_link("mid", "mid_doors")
	_link("mid", "lower_tunnels")
	_link("catwalk", "short_stairs")
	_link("short_stairs", "short_a")
	_link("short_a", "short_top")
	_link("short_top", "a_boxes")
	_link("short_top", "a_default")
	_link("lower_tunnels", "upper_tunnels")
	_link("upper_tunnels", "b_entrance")
	_link("b_entrance", "b_platform")
	_link("b_entrance", "b_window")
	_link("b_window", "b_door")
	_link("b_door", "ct_mid")
	_link("b_platform", "b_default")
	_link("b_platform", "b_car")
	_link("b_default", "b_back")
	_link("ct_spawn", "ct_a_ramp")
	_link("ct_spawn", "ct_mid")
	_link("ct_spawn", "ct_b_rot")
	_link("ct_a_ramp", "a_ramp")
	_link("ct_a_ramp", "short_top")
	_link("ct_mid", "mid_doors")
	_link("ct_mid", "short_top")
	_link("ct_mid", "b_window")
	_link("ct_b_rot", "b_window")
	_link("ct_b_rot", "b_platform")
	_link("ct_b_rot", "b_back")

func _build_runtime_scene() -> void:
	if _runtime_root:
		_runtime_root.queue_free()
	var existing = get_node_or_null("RuntimeZones")
	if existing:
		existing.queue_free()
	_runtime_root = Node3D.new()
	_runtime_root.name = "RuntimeZones"
	add_child(_runtime_root)
	if _site_positions.has("A"):
		_add_site_zone(_runtime_root, "A", Vector3(_site_positions["A"]), Vector3(_site_zone_sizes.get("A", Vector3(22, 2, 18))))
	if _site_positions.has("B"):
		_add_site_zone(_runtime_root, "B", Vector3(_site_positions["B"]), Vector3(_site_zone_sizes.get("B", Vector3(20, 2, 18))))

func _build_routes() -> void:
	_routes = {
		"default_a_long_entry": ["t_spawn_center", "long_doors", "outside_long", "pit", "blue", "a_long", "a_cross"],
		"default_a_long_trade": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_car"],
		"default_a_long_support": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top"],
		"default_a_long_carrier": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_ramp", "a_default"],
		"default_a_long_lurk": ["t_spawn_center", "suicide", "top_mid", "mid", "mid_doors"],
		"a_long_commit_entry": ["t_spawn_center", "long_doors", "outside_long", "pit", "blue", "a_long", "a_car", "a_cross", "a_ramp"],
		"a_long_commit_trade": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_cross"],
		"a_long_commit_carrier": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_ramp", "a_default"],
		"a_cat_split_long": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_cross", "a_ramp"],
		"a_cat_split_short": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top", "a_boxes"],
		"a_cat_split_carrier": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top", "a_default"],
		"b_contact_entry": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_platform"],
		"b_contact_trade": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_platform"],
		"b_exec_entry": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_platform"],
		"b_exec_trade": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_default"],
		"b_exec_support": ["t_spawn_center", "suicide", "top_mid", "mid", "mid_doors", "b_window"],
		"b_exec_carrier": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_platform", "b_default"],
		"mid_to_b_split_mid": ["t_spawn_center", "suicide", "top_mid", "mid", "mid_doors", "b_door", "b_window"],
		"mid_to_b_split_tunnels": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_platform"],
		"mid_to_b_split_carrier": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_platform", "b_default"],
		"t_late_rotate_a": ["mid_doors", "mid", "xbox", "catwalk", "short_stairs", "short_top", "a_default"],
		"t_late_rotate_b": ["a_ramp", "a_cross", "mid", "mid_doors", "b_window", "b_default"],
		"t_post_a_long": ["a_default", "a_ramp", "a_long", "blue", "pit"],
		"t_post_a_short": ["a_default", "a_boxes", "short_top", "short_a"],
		"t_post_a_ramp": ["a_default", "a_ramp"],
		"t_post_b_tunnels": ["b_default", "b_platform", "upper_tunnels"],
		"t_post_b_window": ["b_default", "b_window"],
		"ct_a_anchor": ["ct_spawn", "ct_a_ramp", "goose"],
		"ct_long_contest": ["ct_spawn", "ct_a_ramp", "a_ramp", "a_long"],
		"ct_short_hold": ["ct_spawn", "ct_mid", "short_top"],
		"ct_mid_info": ["ct_spawn", "ct_mid", "mid_doors"],
		"ct_b_anchor": ["ct_spawn", "ct_b_rot", "b_platform"],
		"ct_b_window": ["ct_spawn", "ct_b_rot", "b_window"],
		"ct_rotate_a": ["ct_spawn", "ct_mid", "short_top", "a_boxes"],
		"ct_rotate_b": ["ct_spawn", "ct_b_rot", "b_window", "b_default"],
		"ct_retake_a_ct": ["ct_spawn", "ct_a_ramp", "a_ramp", "a_default"],
		"ct_retake_a_short": ["ct_spawn", "ct_mid", "short_top", "a_boxes"],
		"ct_retake_b_window": ["ct_spawn", "ct_b_rot", "b_window", "b_default"],
		"ct_retake_b_platform": ["ct_spawn", "ct_b_rot", "b_platform", "b_default"],
		"ct_retake_b_door": ["ct_spawn", "ct_mid", "b_door", "b_window"],
		"ct_save_a": ["ct_spawn", "ct_a_ramp"],
		"ct_save_b": ["ct_spawn", "ct_b_rot"],
		"recover_a_drop": ["a_cross", "a_long", "blue"],
		"recover_b_drop": ["b_platform", "upper_tunnels", "lower_tunnels"],

		# Compatibility aliases
		"t_default_a_entry": ["t_spawn_center", "long_doors", "outside_long", "pit", "blue", "a_long", "a_cross"],
		"t_default_a_trade": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_car"],
		"t_default_a_support": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top"],
		"t_default_a_carrier": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_ramp", "a_default"],
		"t_default_a_lurk": ["t_spawn_center", "suicide", "top_mid", "mid", "mid_doors"],
		"t_split_long": ["t_spawn_center", "long_doors", "outside_long", "blue", "a_long", "a_cross", "a_ramp"],
		"t_split_cat": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top", "a_boxes"],
		"t_split_carrier": ["t_spawn_center", "suicide", "top_mid", "xbox", "catwalk", "short_stairs", "short_a", "short_top", "a_default"],
		"t_b_entry": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_platform"],
		"t_b_trade": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_entrance", "b_default"],
		"t_b_carrier": ["t_spawn_center", "lower_tunnels", "upper_tunnels", "b_platform", "b_default"],
		"t_b_mid_support": ["t_spawn_center", "suicide", "top_mid", "mid", "mid_doors", "b_window"],
		"t_post_a_cat": ["a_default", "a_boxes", "short_top", "short_a"],
		"t_post_b_car": ["b_default", "b_car"],
		"t_post_b_back": ["b_default", "b_back"],
		"ct_a_long": ["ct_spawn", "ct_a_ramp", "a_ramp", "a_long"],
		"ct_retake_a_ramp": ["ct_spawn", "ct_a_ramp", "a_ramp", "a_default"],
		"ct_retake_b_tunnels": ["ct_spawn", "ct_mid", "b_door", "upper_tunnels"],
	}

func _build_lineups() -> void:
	_lineups = {
		"t_default_a_long_smoke": _make_lineup("outside_long", "a_cross", "smoke", 17.8, "", "A", "t_default_a"),
		"t_default_a_cat_flash": _make_lineup("xbox", "short_top", "flash", 13.6, "", "A", "t_default_a"),
		"t_default_a_pop_flash": _make_lineup("short_top", "goose", "flash", 12.8, "", "A", "t_default_a"),
		"t_a_commit_long_flash": _make_lineup("blue", "a_ramp", "flash", 12.6, "", "A", "t_a_long_commit"),
		"t_split_long_smoke": _make_lineup("a_long", "a_cross", "smoke", 15.2, "", "A", "t_a_cat_split"),
		"t_split_cat_flash": _make_lineup("short_a", "a_boxes", "flash", 12.4, "", "A", "t_a_cat_split"),
		"t_b_window_smoke": _make_lineup("mid", "b_window", "smoke", 16.8, "", "B", "t_b_exec"),
		"t_b_tunnel_flash": _make_lineup("upper_tunnels", "b_platform", "flash", 13.6, "", "B", "t_b_exec"),
		"t_b_site_frag": _make_lineup("b_entrance", "b_default", "frag", 12.0, "", "B", "t_b_exec"),
		"t_mid_to_b_smoke": _make_lineup("mid", "mid_doors", "smoke", 14.8, "", "B", "t_mid_to_b"),
		"t_mid_to_b_flash": _make_lineup("mid_doors", "b_door", "flash", 12.2, "", "B", "t_mid_to_b"),
		"ct_hold_a_smoke": _make_lineup("goose", "a_long", "smoke", 14.0, "", "A", "ct_hold_a"),
		"ct_hold_a_flash": _make_lineup("ct_a_ramp", "a_cross", "flash", 12.8, "", "A", "ct_hold_a"),
		"ct_hold_b_smoke": _make_lineup("b_platform", "upper_tunnels", "smoke", 13.8, "", "B", "ct_hold_b"),
		"ct_hold_b_flash": _make_lineup("b_window", "b_entrance", "flash", 12.6, "", "B", "ct_hold_b"),
		"ct_retake_a_smoke": _make_lineup("ct_a_ramp", "a_ramp", "smoke", 13.4, "", "A", "ct_retake_a"),
		"ct_retake_a_flash": _make_lineup("ct_mid", "a_boxes", "flash", 13.2, "", "A", "ct_retake_a"),
		"ct_retake_b_smoke": _make_lineup("ct_mid", "b_window", "smoke", 14.4, "", "B", "ct_retake_b"),
		"ct_retake_b_flash": _make_lineup("ct_b_rot", "b_default", "flash", 13.4, "", "B", "ct_retake_b"),
		"t_post_a_frag": _make_lineup("pit", "a_default", "frag", 11.4, "", "A", "t_post_plant_a"),
		"t_post_a_flash": _make_lineup("short_top", "a_default", "flash", 12.2, "", "A", "t_post_plant_a"),
		"t_post_b_frag": _make_lineup("b_window", "b_default", "frag", 11.1, "", "B", "t_post_plant_b"),
		"t_post_b_flash": _make_lineup("upper_tunnels", "b_default", "flash", 12.1, "", "B", "t_post_plant_b"),
	}

func _build_utility_packages() -> void:
	_utility_packages = {
		"t_default_a": [
			_make_utility_step("on_round_start", "t_default_a_long_smoke", "smoke", "take_space"),
			_make_utility_step("on_reach_zone", "t_default_a_cat_flash", "flash", "entry_after_flash"),
			_make_utility_step("on_contact", "t_default_a_pop_flash", "flash", "trade_swing"),
		],
		"t_a_long_commit": [
			_make_utility_step("on_reach_zone", "t_a_commit_long_flash", "flash", "entry_after_flash"),
		],
		"t_a_cat_split": [
			_make_utility_step("on_round_start", "t_split_long_smoke", "smoke", "take_space"),
			_make_utility_step("on_reach_zone", "t_split_cat_flash", "flash", "entry_after_flash"),
		],
		"t_b_exec": [
			_make_utility_step("on_round_start", "t_b_window_smoke", "smoke", "take_space"),
			_make_utility_step("on_reach_zone", "t_b_tunnel_flash", "flash", "entry_after_flash"),
			_make_utility_step("before_plant", "t_b_site_frag", "frag", "cover_planter"),
		],
		"t_mid_to_b": [
			_make_utility_step("on_round_start", "t_mid_to_b_smoke", "smoke", "take_space"),
			_make_utility_step("on_reach_zone", "t_mid_to_b_flash", "flash", "trade_swing"),
		],
		"ct_hold_a": [
			_make_utility_step("on_contact", "ct_hold_a_smoke", "smoke", "hold"),
			_make_utility_step("on_contact", "ct_hold_a_flash", "flash", "trade_swing"),
		],
		"ct_hold_b": [
			_make_utility_step("on_contact", "ct_hold_b_smoke", "smoke", "hold"),
			_make_utility_step("on_contact", "ct_hold_b_flash", "flash", "trade_swing"),
		],
		"ct_retake_a": [
			_make_utility_step("on_retake_start", "ct_retake_a_smoke", "smoke", "retake"),
			_make_utility_step("on_retake_start", "ct_retake_a_flash", "flash", "trade_swing"),
		],
		"ct_retake_b": [
			_make_utility_step("on_retake_start", "ct_retake_b_smoke", "smoke", "retake"),
			_make_utility_step("on_retake_start", "ct_retake_b_flash", "flash", "trade_swing"),
		],
		"t_post_plant_a": [
			_make_utility_step("on_defuse_started", "t_post_a_frag", "frag", "anti_defuse_nade"),
			_make_utility_step("after_plant", "t_post_a_flash", "flash", "guard_bomb"),
		],
		"t_post_plant_b": [
			_make_utility_step("on_defuse_started", "t_post_b_frag", "frag", "anti_defuse_nade"),
			_make_utility_step("after_plant", "t_post_b_flash", "flash", "guard_bomb"),
		],
	}

func _build_combat_metadata() -> void:
	_cover_slots = {
		"ct_a_anchor_slot": _make_slot("goose", "a_long", "a_site"),
		"ct_long_contest_slot": _make_slot("a_ramp", "blue", "a_long"),
		"ct_short_hold_slot": _make_slot("short_top", "short_a", "short_a"),
		"ct_mid_info_slot": _make_slot("ct_mid", "mid", "mid"),
		"ct_b_anchor_slot": _make_slot("b_platform", "upper_tunnels", "b_site"),
		"ct_b_window_slot": _make_slot("b_window", "mid_doors", "b_window"),
		"t_long_entry_slot": _make_slot("a_long", "a_ramp", "a_long"),
		"t_long_trade_slot": _make_slot("a_car", "a_ramp", "a_long"),
		"t_short_entry_slot": _make_slot("short_top", "a_boxes", "short_a"),
		"t_short_trade_slot": _make_slot("short_a", "a_boxes", "short_a"),
		"t_mid_lurk_slot": _make_slot("mid_doors", "ct_mid", "mid"),
		"t_b_entry_slot": _make_slot("b_entrance", "b_platform", "b_tunnels"),
		"t_b_trade_slot": _make_slot("b_platform", "b_default", "b_site"),
		"post_a_long_slot": _make_slot("pit", "a_default", "a_long"),
		"post_a_short_slot": _make_slot("short_top", "a_default", "short_a"),
		"post_a_ramp_slot": _make_slot("a_ramp", "a_default", "a_site"),
		"post_b_tunnels_slot": _make_slot("upper_tunnels", "b_default", "b_tunnels"),
		"post_b_window_slot": _make_slot("b_window", "b_default", "b_window"),
		"post_b_back_slot": _make_slot("b_back", "b_default", "b_site"),
		"retake_a_defuser_slot": _make_slot("a_boxes", "a_default", "a_site"),
		"retake_a_cover_slot": _make_slot("short_top", "a_default", "short_a"),
		"retake_b_defuser_slot": _make_slot("b_platform", "b_default", "b_site"),
		"retake_b_cover_slot": _make_slot("b_window", "b_default", "b_window"),
		"retake_b_door_slot": _make_slot("b_door", "b_default", "mid_doors"),
	}
	_peek_profiles = {
		"ct_a_anchor": _make_peek_profile("ct_a_anchor_slot", Vector3(2.0, 0, 0.0), Vector3(4.8, 0, 0.0), ["a_long", "a_cross"]),
		"ct_long_contest": _make_peek_profile("ct_long_contest_slot", Vector3(-1.2, 0, 1.1), Vector3(-4.4, 0, 2.0), ["blue", "pit"]),
		"ct_short_hold": _make_peek_profile("ct_short_hold_slot", Vector3(1.2, 0, 1.0), Vector3(3.2, 0, 1.8), ["short_a", "a_boxes"]),
		"ct_b_anchor": _make_peek_profile("ct_b_anchor_slot", Vector3(-1.0, 0, 1.0), Vector3(-3.2, 0, 2.0), ["upper_tunnels", "b_entrance"]),
		"ct_b_window": _make_peek_profile("ct_b_window_slot", Vector3(-0.8, 0, -1.4), Vector3(-2.6, 0, -3.0), ["mid_doors", "b_entrance"]),
		"t_long_entry": _make_peek_profile("t_long_entry_slot", Vector3(1.6, 0, -1.2), Vector3(4.8, 0, -2.0), ["a_ramp", "goose"]),
		"t_long_trade": _make_peek_profile("t_long_trade_slot", Vector3(1.4, 0, -0.8), Vector3(3.6, 0, -1.6), ["a_ramp", "a_boxes"]),
		"t_short_entry": _make_peek_profile("t_short_entry_slot", Vector3(-0.8, 0, -1.0), Vector3(-2.8, 0, -2.4), ["a_boxes", "goose"]),
		"t_b_entry": _make_peek_profile("t_b_entry_slot", Vector3(1.0, 0, -1.0), Vector3(3.8, 0, -2.2), ["b_platform", "b_default"]),
		"t_b_trade": _make_peek_profile("t_b_trade_slot", Vector3(1.0, 0, -1.0), Vector3(3.2, 0, -2.2), ["b_default", "b_car"]),
		"retake_a": _make_peek_profile("retake_a_cover_slot", Vector3(1.0, 0, -0.8), Vector3(3.2, 0, -1.4), ["a_default", "goose"]),
		"retake_b": _make_peek_profile("retake_b_cover_slot", Vector3(1.0, 0, -0.8), Vector3(3.4, 0, -1.4), ["b_default", "b_back"]),
		"retake_b_door": _make_peek_profile("retake_b_door_slot", Vector3(1.0, 0, 0.2), Vector3(3.4, 0, 0.8), ["b_window", "b_default"]),
	}
	_fallback_routes = {
		"fallback_ct_a": ["goose", "ct_a_ramp", "ct_spawn"],
		"fallback_ct_mid": ["ct_mid", "ct_spawn"],
		"fallback_ct_b": ["b_platform", "ct_b_rot", "ct_spawn"],
		"fallback_t_long": ["a_long", "blue", "outside_long", "long_doors"],
		"fallback_t_short": ["short_top", "short_a", "catwalk", "top_mid"],
		"fallback_t_b": ["b_platform", "upper_tunnels", "lower_tunnels"],
		"fallback_post_a": ["a_default", "a_ramp", "a_cross"],
		"fallback_post_b": ["b_default", "b_platform", "upper_tunnels"],
		"fallback_retake_a": ["a_boxes", "short_top", "ct_mid"],
		"fallback_retake_b": ["b_platform", "ct_b_rot", "ct_spawn"],
	}
	_hold_profiles = {
		"ct_a_anchor": _make_hold_profile("ct_a_anchor_slot", "ct_a_anchor", "a_site", "fallback_ct_a", 0.42, "hold_angle"),
		"ct_long_contest": _make_hold_profile("ct_long_contest_slot", "ct_long_contest", "a_long", "fallback_ct_a", 0.32, "shoulder_peek"),
		"ct_short_hold": _make_hold_profile("ct_short_hold_slot", "ct_short_hold", "short_a", "fallback_ct_a", 0.38, "shoulder_peek"),
		"ct_mid_info": _make_hold_profile("ct_mid_info_slot", "", "mid", "fallback_ct_mid", 0.46, "jiggle_info"),
		"ct_b_anchor": _make_hold_profile("ct_b_anchor_slot", "ct_b_anchor", "b_site", "fallback_ct_b", 0.42, "hold_angle"),
		"ct_b_window": _make_hold_profile("ct_b_window_slot", "ct_b_window", "b_window", "fallback_ct_b", 0.36, "shoulder_peek"),
		"t_long_entry": _make_hold_profile("t_long_entry_slot", "t_long_entry", "a_long", "fallback_t_long", 0.30, "wide_swing"),
		"t_long_trade": _make_hold_profile("t_long_trade_slot", "t_long_trade", "a_long", "fallback_t_long", 0.28, "trade_swing"),
		"t_short_entry": _make_hold_profile("t_short_entry_slot", "t_short_entry", "short_a", "fallback_t_short", 0.30, "wide_swing"),
		"t_short_trade": _make_hold_profile("t_short_trade_slot", "t_short_entry", "short_a", "fallback_t_short", 0.28, "trade_swing"),
		"t_mid_lurk": _make_hold_profile("t_mid_lurk_slot", "", "mid", "fallback_t_short", 0.48, "hold_angle"),
		"t_b_entry": _make_hold_profile("t_b_entry_slot", "t_b_entry", "b_tunnels", "fallback_t_b", 0.32, "wide_swing"),
		"t_b_trade": _make_hold_profile("t_b_trade_slot", "t_b_trade", "b_site", "fallback_t_b", 0.28, "trade_swing"),
		"post_a_long": _make_hold_profile("post_a_long_slot", "", "a_long", "fallback_post_a", 0.54, "hold_angle"),
		"post_a_short": _make_hold_profile("post_a_short_slot", "", "short_a", "fallback_post_a", 0.54, "hold_angle"),
		"post_a_ramp": _make_hold_profile("post_a_ramp_slot", "", "a_site", "fallback_post_a", 0.48, "hold_angle"),
		"post_b_tunnels": _make_hold_profile("post_b_tunnels_slot", "", "b_tunnels", "fallback_post_b", 0.54, "hold_angle"),
		"post_b_window": _make_hold_profile("post_b_window_slot", "", "b_window", "fallback_post_b", 0.54, "hold_angle"),
		"post_b_back": _make_hold_profile("post_b_back_slot", "", "b_site", "fallback_post_b", 0.46, "hold_angle"),
		"retake_a_defuser": _make_hold_profile("retake_a_defuser_slot", "retake_a", "a_site", "fallback_retake_a", 0.42, "fallback_hold"),
		"retake_a_cover": _make_hold_profile("retake_a_cover_slot", "retake_a", "short_a", "fallback_retake_a", 0.30, "trade_swing"),
		"retake_b_defuser": _make_hold_profile("retake_b_defuser_slot", "retake_b", "b_site", "fallback_retake_b", 0.42, "fallback_hold"),
		"retake_b_cover": _make_hold_profile("retake_b_cover_slot", "retake_b", "b_window", "fallback_retake_b", 0.30, "trade_swing"),
		"retake_b_door": _make_hold_profile("retake_b_door_slot", "retake_b_door", "mid_doors", "fallback_retake_b", 0.32, "trade_swing"),
	}
	_sound_zones = [
		_make_sound_zone(get_point("outside_long"), Vector3(18, 0, 18), "a_long"),
		_make_sound_zone(get_point("a_default"), Vector3(18, 0, 16), "a_site"),
		_make_sound_zone(get_point("short_top"), Vector3(16, 0, 16), "short_a"),
		_make_sound_zone(get_point("mid"), Vector3(18, 0, 20), "mid"),
		_make_sound_zone(get_point("mid_doors"), Vector3(16, 0, 16), "mid_doors"),
		_make_sound_zone(get_point("upper_tunnels"), Vector3(20, 0, 18), "b_tunnels"),
		_make_sound_zone(get_point("b_window"), Vector3(16, 0, 16), "b_window"),
		_make_sound_zone(get_point("b_default"), Vector3(18, 0, 18), "b_site"),
		_make_sound_zone(get_point("ct_spawn"), Vector3(24, 0, 18), "ct_spawn"),
		_make_sound_zone(get_point("t_spawn_center"), Vector3(24, 0, 20), "t_spawn"),
	]
	_plant_slots = {
		"A": {
			"default": _make_plant_slot("default", "a_default", "a_site", ["post_a_long", "post_a_short", "post_a_ramp"]),
			"safe": _make_plant_slot("safe", "a_boxes", "a_site", ["post_a_short", "post_a_ramp"]),
		},
		"B": {
			"default": _make_plant_slot("default", "b_default", "b_site", ["post_b_window", "post_b_tunnels", "post_b_back"]),
			"back": _make_plant_slot("back", "b_back", "b_site", ["post_b_back", "post_b_window"]),
		},
	}
	_retake_lanes = {
		"A": {
			"ct": {"route_id": "ct_retake_a_ct", "profile_id": "retake_a_defuser", "entry_point": get_point("a_ramp")},
			"short": {"route_id": "ct_retake_a_short", "profile_id": "retake_a_cover", "entry_point": get_point("short_top")},
		},
		"B": {
			"window": {"route_id": "ct_retake_b_window", "profile_id": "retake_b_cover", "entry_point": get_point("b_window")},
			"platform": {"route_id": "ct_retake_b_platform", "profile_id": "retake_b_defuser", "entry_point": get_point("b_platform")},
			"door": {"route_id": "ct_retake_b_door", "profile_id": "retake_b_door", "entry_point": get_point("b_door")},
		},
	}
	_bomb_cover_packages = {
		"A": {
			"plant": {
				"slot_ids": ["t_long_entry_slot", "t_short_entry_slot"],
				"lineup_ids": ["t_default_a_pop_flash"],
				"post_routes": ["t_post_a_long", "t_post_a_short", "t_post_a_ramp"],
			},
			"post_plant": {
				"slot_ids": ["post_a_long_slot", "post_a_short_slot", "post_a_ramp_slot"],
				"lineup_ids": ["t_post_a_frag", "t_post_a_flash"],
				"crossfire_lanes": ["a_long", "short_a"],
			},
			"retake": {
				"lane_ids": ["ct", "short"],
				"lineup_ids": ["ct_retake_a_smoke", "ct_retake_a_flash"],
				"defuser_slot": "retake_a_defuser_slot",
			},
		},
		"B": {
			"plant": {
				"slot_ids": ["t_b_trade_slot", "post_b_window_slot"],
				"lineup_ids": ["t_b_site_frag"],
				"post_routes": ["t_post_b_tunnels", "t_post_b_window", "t_post_b_back"],
			},
			"post_plant": {
				"slot_ids": ["post_b_tunnels_slot", "post_b_window_slot", "post_b_back_slot"],
				"lineup_ids": ["t_post_b_frag", "t_post_b_flash"],
				"crossfire_lanes": ["b_window", "b_tunnels"],
			},
			"retake": {
				"lane_ids": ["window", "platform", "door"],
				"lineup_ids": ["ct_retake_b_smoke", "ct_retake_b_flash"],
				"defuser_slot": "retake_b_defuser_slot",
			},
		},
	}

func _build_spawn_markers(spawn_root: Node3D) -> void:
	for i in range(_spawn_positions_t.size()):
		var marker = Marker3D.new()
		marker.name = "T_Spawn_%d" % (i + 1)
		marker.position = _spawn_positions_t[i]
		spawn_root.add_child(marker)
	for i in range(_spawn_positions_ct.size()):
		var marker = Marker3D.new()
		marker.name = "CT_Spawn_%d" % (i + 1)
		marker.position = _spawn_positions_ct[i]
		spawn_root.add_child(marker)

func _build_tactical_markers(points_root: Node3D) -> void:
	for point_name in _points.keys():
		var marker = Marker3D.new()
		marker.name = point_name
		marker.position = _points[point_name]
		points_root.add_child(marker)

func _add_wall_ring(parent: Node3D) -> void:
	_add_block(parent, "NorthWall", Vector3(0, 1.5, -82), Vector3(188, WALL_HEIGHT, WALL_THICKNESS), _materials["wall"])
	_add_block(parent, "SouthWall", Vector3(0, 1.5, 82), Vector3(188, WALL_HEIGHT, WALL_THICKNESS), _materials["wall"])
	_add_block(parent, "WestWall", Vector3(-94, 1.5, 0), Vector3(WALL_THICKNESS, WALL_HEIGHT, 164), _materials["wall"])
	_add_block(parent, "EastWall", Vector3(94, 1.5, 0), Vector3(WALL_THICKNESS, WALL_HEIGHT, 164), _materials["wall"])

func _add_layout_blocks(parent: Node3D) -> void:
	var blocks = [
		{"name": "LongDoorsLeft", "pos": Vector3(-36, 1.5, 46), "size": Vector3(10, WALL_HEIGHT, 4), "mat": "wall"},
		{"name": "LongDoorsRight", "pos": Vector3(-24, 1.5, 46), "size": Vector3(8, WALL_HEIGHT, 4), "mat": "wall"},
		{"name": "OutsideLongDivider", "pos": Vector3(-30, 1.5, 24), "size": Vector3(2, WALL_HEIGHT, 44), "mat": "wall"},
		{"name": "PitCover", "pos": Vector3(-68, 1.5, 18), "size": Vector3(8, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "BlueBox", "pos": Vector3(-62, 1.5, 6), "size": Vector3(10, WALL_HEIGHT, 6), "mat": "box"},
		{"name": "ALongWallWest", "pos": Vector3(-74, 1.5, -2), "size": Vector3(2, WALL_HEIGHT, 50), "mat": "wall"},
		{"name": "ALongWallEast", "pos": Vector3(-38, 1.5, -4), "size": Vector3(2, WALL_HEIGHT, 42), "mat": "wall"},
		{"name": "AHouseBack", "pos": Vector3(-44, 1.5, -40), "size": Vector3(34, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "AHouseRight", "pos": Vector3(-24, 1.5, -24), "size": Vector3(2, WALL_HEIGHT, 32), "mat": "wall"},
		{"name": "ABoxes", "pos": Vector3(-34, 1.5, -24), "size": Vector3(12, WALL_HEIGHT, 10), "mat": "box"},
		{"name": "GooseBox", "pos": Vector3(-58, 1.5, -26), "size": Vector3(10, WALL_HEIGHT, 8), "mat": "box"},
		{"name": "ShortRiseLeft", "pos": Vector3(-20, 1.5, 2), "size": Vector3(18, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "ShortRiseRight", "pos": Vector3(-8, 1.5, -2), "size": Vector3(2, WALL_HEIGHT, 28), "mat": "wall"},
		{"name": "XboxBox", "pos": Vector3(-8, 1.5, 12), "size": Vector3(8, WALL_HEIGHT, 8), "mat": "box"},
		{"name": "MidDoorsFrame", "pos": Vector3(18, 1.5, 4), "size": Vector3(8, WALL_HEIGHT, 4), "mat": "wall"},
		{"name": "MidLeftWall", "pos": Vector3(-14, 1.5, 20), "size": Vector3(2, WALL_HEIGHT, 42), "mat": "wall"},
		{"name": "MidRightWall", "pos": Vector3(24, 1.5, 8), "size": Vector3(2, WALL_HEIGHT, 50), "mat": "wall"},
		{"name": "LowerTunnelSouth", "pos": Vector3(28, 1.5, 42), "size": Vector3(2, WALL_HEIGHT, 24), "mat": "wall"},
		{"name": "TunnelSpine", "pos": Vector3(30, 1.5, 22), "size": Vector3(2, WALL_HEIGHT, 36), "mat": "wall"},
		{"name": "UpperTunnelLeft", "pos": Vector3(48, 1.5, 20), "size": Vector3(18, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "BWindowCover", "pos": Vector3(34, 1.5, -16), "size": Vector3(6, WALL_HEIGHT, 10), "mat": "box"},
		{"name": "BDoorFrame", "pos": Vector3(42, 1.5, -18), "size": Vector3(6, WALL_HEIGHT, 4), "mat": "wall"},
		{"name": "BPlatformBoxes", "pos": Vector3(56, 1.5, -18), "size": Vector3(10, WALL_HEIGHT, 10), "mat": "box"},
		{"name": "BBackBox", "pos": Vector3(70, 1.5, -30), "size": Vector3(8, WALL_HEIGHT, 8), "mat": "box"},
		{"name": "BCarBox", "pos": Vector3(68, 1.5, -9), "size": Vector3(6, WALL_HEIGHT, 6), "mat": "box"},
		{"name": "BSiteBackWall", "pos": Vector3(60, 1.5, -42), "size": Vector3(40, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "CTBridge", "pos": Vector3(10, 1.5, -42), "size": Vector3(34, WALL_HEIGHT, 2), "mat": "wall"},
		{"name": "CTAConnector", "pos": Vector3(-18, 1.5, -44), "size": Vector3(2, WALL_HEIGHT, 18), "mat": "wall"},
		{"name": "CTBConnector", "pos": Vector3(32, 1.5, -44), "size": Vector3(2, WALL_HEIGHT, 20), "mat": "wall"},
		{"name": "CTSpawnCrate", "pos": Vector3(2, 1.5, -54), "size": Vector3(10, WALL_HEIGHT, 8), "mat": "box"},
	]
	for block in blocks:
		_add_block(parent, String(block["name"]), Vector3(block["pos"]), Vector3(block["size"]), _materials[String(block["mat"])])

func _add_site_visual(parent: Node3D, node_name: String, position: Vector3, size: Vector3, material: StandardMaterial3D) -> void:
	var visual = MeshInstance3D.new()
	visual.name = node_name
	var mesh = BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.material_override = material
	visual.position = position + Vector3(0, 0.04, 0)
	parent.add_child(visual)

func _add_site_zone(parent: Node3D, site_id: String, position: Vector3, size: Vector3) -> void:
	var site = Bombsite.new()
	site.name = "Site%s" % site_id
	site.site_id = site_id
	site.position = position
	site.collision_layer = 32
	site.collision_mask = 0
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = size
	shape.shape = box
	site.add_child(shape)
	parent.add_child(site)

func _add_block(parent: Node3D, node_name: String, position: Vector3, size: Vector3, material: StandardMaterial3D, use_collision: bool = true) -> void:
	var body = StaticBody3D.new() if use_collision else Node3D.new()
	body.name = node_name
	body.position = position
	if body is CollisionObject3D:
		body.collision_layer = 1
		body.collision_mask = 0
	parent.add_child(body)
	var mesh_instance = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	if use_collision:
		var collision = CollisionShape3D.new()
		var box = BoxShape3D.new()
		box.size = size
		collision.shape = box
		body.add_child(collision)

func _make_material(color: Color, roughness: float, emissive: bool) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.8
	return material

func _make_lineup(start_marker: String, aim_marker: String, grenade_type: String, throw_strength: float, step_out_marker: String, site_id: String, package_id: String) -> Dictionary:
	return {
		"id": "",
		"start_marker": start_marker,
		"start_position": get_point(start_marker),
		"aim_marker": aim_marker,
		"aim_position": get_point(aim_marker),
		"step_out_marker": step_out_marker,
		"step_out_position": get_point(step_out_marker) if step_out_marker != "" else Vector3.ZERO,
		"grenade_type": grenade_type,
		"throw_strength": throw_strength,
		"jump_throw": false,
		"run_throw": step_out_marker != "",
		"trigger_window": 5.0,
		"site_id": site_id,
		"package_id": package_id,
	}

func _make_utility_step(trigger_name: String, lineup_id: String, grenade_type: String, follow_intent: String) -> Dictionary:
	return {
		"trigger": trigger_name,
		"lineup_id": lineup_id,
		"grenade_type": grenade_type,
		"follow_intent": follow_intent,
		"abort_if_site_lost": false,
		"consumed": false,
	}

func _make_slot(marker_name: String, look_at_marker: String, lane_id: String) -> Dictionary:
	return {
		"slot_id": marker_name,
		"position": get_point(marker_name),
		"look_at_position": get_point(look_at_marker),
		"lane_id": lane_id,
		"radius": 1.4,
	}

func _make_peek_profile(slot_id: String, shoulder_offset: Vector3, wide_offset: Vector3, clear_markers: Array) -> Dictionary:
	var slot = _cover_slots.get(slot_id, {})
	var base_pos: Vector3 = slot.get("position", Vector3.ZERO)
	var clear_points: Array[Vector3] = []
	for marker_name in clear_markers:
		var point = get_point(String(marker_name))
		if point != Vector3.ZERO:
			clear_points.append(point)
	return {
		"slot_id": slot_id,
		"shoulder_position": base_pos + shoulder_offset,
		"wide_position": base_pos + wide_offset,
		"clear_points": clear_points,
	}

func _make_hold_profile(slot_id: String, peek_profile_id: String, lane_id: String, fallback_route_id: String, confidence_threshold: float, peek_mode: String = "hold_angle") -> Dictionary:
	var slot = _cover_slots.get(slot_id, {})
	var peek_profile = _peek_profiles.get(peek_profile_id, {})
	return {
		"slot_id": slot_id,
		"hold_position": slot.get("position", Vector3.ZERO),
		"look_at_position": slot.get("look_at_position", Vector3.ZERO),
		"lane_id": lane_id,
		"peek_profile_id": peek_profile_id,
		"peek_mode": peek_mode,
		"shoulder_position": peek_profile.get("shoulder_position", slot.get("position", Vector3.ZERO)),
		"wide_position": peek_profile.get("wide_position", slot.get("position", Vector3.ZERO)),
		"clear_points": peek_profile.get("clear_points", []),
		"fallback_route_id": fallback_route_id,
		"confidence_threshold": confidence_threshold,
	}

func _make_sound_zone(center: Vector3, extents: Vector3, lane_id: String) -> Dictionary:
	return {
		"center": center,
		"extents": extents,
		"lane_id": lane_id,
	}

func _make_plant_slot(slot_id: String, marker_name: String, lane_id: String, post_profiles: Array) -> Dictionary:
	return {
		"slot_id": slot_id,
		"position": get_point(marker_name),
		"lane_id": lane_id,
		"post_profiles": post_profiles.duplicate(),
	}

func _link(a: String, b: String) -> void:
	var key_a = a.to_lower()
	var key_b = b.to_lower()
	if not _graph.has(key_a) or not _graph.has(key_b):
		return
	if not (key_b in _graph[key_a]):
		_graph[key_a].append(key_b)
	if not (key_a in _graph[key_b]):
		_graph[key_b].append(key_a)

func _get_nearest_graph_point(world_pos: Vector3) -> String:
	var best_point := ""
	var best_dist := INF
	for point_name in _graph.keys():
		var dist_sq = get_point(point_name).distance_squared_to(world_pos)
		if dist_sq < best_dist:
			best_dist = dist_sq
			best_point = point_name
	return best_point

func _pop_lowest_score(open: Array, score_map: Dictionary) -> String:
	var best_idx := 0
	var best_score := INF
	for i in range(open.size()):
		var candidate = String(open[i])
		var score = float(score_map.get(candidate, INF))
		if score < best_score:
			best_score = score
			best_idx = i
	var result = String(open[best_idx])
	open.remove_at(best_idx)
	return result

func _reconstruct_path(came_from: Dictionary, start_key: String, end_key: String) -> Array:
	var path: Array = []
	var current = end_key
	path.push_front(current)
	while current != start_key and came_from.has(current):
		current = String(came_from[current])
		path.push_front(current)
	return path

func _rebuild_debug_markers() -> void:
	if _lineup_debug_root:
		_lineup_debug_root.queue_free()
	if _combat_debug_root:
		_combat_debug_root.queue_free()
	_lineup_debug_root = Node3D.new()
	_lineup_debug_root.name = "LineupDebugRoot"
	add_child(_lineup_debug_root)
	_lineup_debug_root.visible = _lineup_debug_visible
	_combat_debug_root = Node3D.new()
	_combat_debug_root.name = "CombatDebugRoot"
	add_child(_combat_debug_root)
	_combat_debug_root.visible = _combat_debug_visible
	if _lineup_debug_visible:
		for lineup_id in _lineups.keys():
			var lineup = _lineups[lineup_id]
			lineup["id"] = lineup_id
			_lineups[lineup_id] = lineup
			var is_highlighted = lineup_id in _highlighted_lineups
			_add_debug_marker(_lineup_debug_root, "%s_start" % lineup_id, lineup["start_position"], DEBUG_HIGHLIGHT_COLOR if is_highlighted else DEBUG_START_COLOR, lineup_id)
			_add_debug_marker(_lineup_debug_root, "%s_aim" % lineup_id, lineup["aim_position"], DEBUG_HIGHLIGHT_COLOR if is_highlighted else DEBUG_AIM_COLOR, "%s aim" % lineup_id)
	if _combat_debug_visible:
		for slot_id in _cover_slots.keys():
			var slot = _cover_slots[slot_id]
			var color = DEBUG_HIGHLIGHT_COLOR if slot_id in _highlighted_slots else DEBUG_SLOT_COLOR
			_add_debug_marker(_combat_debug_root, "%s_slot" % slot_id, slot["position"], color, slot_id)
			_add_debug_arc(_combat_debug_root, "%s_arc" % slot_id, slot["position"], slot["look_at_position"], color)

func _add_debug_marker(parent: Node3D, node_name: String, position: Vector3, color: Color, label_text: String) -> void:
	if position == Vector3.ZERO:
		return
	var root = Node3D.new()
	root.name = node_name
	root.position = position
	parent.add_child(root)
	var marker_mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.24
	sphere.height = 0.48
	marker_mesh.mesh = sphere
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.2
	marker_mesh.material_override = mat
	root.add_child(marker_mesh)
	var label = Label3D.new()
	label.position = Vector3(0, 0.6, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 12
	label.modulate = color
	label.text = label_text
	root.add_child(label)

func _add_debug_arc(parent: Node3D, node_name: String, from: Vector3, to: Vector3, color: Color) -> void:
	if from == Vector3.ZERO or to == Vector3.ZERO:
		return
	var dist = from.distance_to(to)
	if dist < 0.1:
		return
	var tracer = MeshInstance3D.new()
	tracer.name = node_name
	var mesh = BoxMesh.new()
	mesh.size = Vector3(0.08, 0.08, dist)
	tracer.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = DEBUG_ARC_COLOR
	mat.emission_energy_multiplier = 1.6
	tracer.material_override = mat
	parent.add_child(tracer)
	tracer.global_position = (from + to) * 0.5 + Vector3(0, 0.15, 0)
	tracer.look_at(to + Vector3(0, 0.15, 0), Vector3.UP)
