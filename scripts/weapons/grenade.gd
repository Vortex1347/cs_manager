# grenade.gd
# Базовый класс гранаты + три вида: smoke, flash, frag.
# Зависимости: bot_brain.gd (apply_flash), BotStats (нет прямой зависимости)

extends RigidBody3D
class_name Grenade

signal grenade_detonated(grenade_type: String, position: Vector3)

enum GrenadeType { SMOKE, FLASH, FRAG }

const FUSE_TIME: float = 1.5
const SMOKE_DURATION: float = 12.0
const FLASH_DURATION: float = 2.0
const FRAG_RADIUS: float = 3.5
const FRAG_DAMAGE: int = 85
const SMOKE_RADIUS: float = 5.0
const FLASH_RADIUS: float = 15.0

@export var grenade_type: GrenadeType = GrenadeType.FRAG

var _thrower_id: int = -1
var _fuse_timer: float = 0.0
var _active: bool = false
var _smoke_body: StaticBody3D = null  # создаётся при детонации смоука

func throw(from: Vector3, direction: Vector3, thrower_id: int) -> void:
	global_position = from
	linear_velocity = direction * 12.0 + Vector3(0, 4.0, 0)
	_thrower_id = thrower_id
	_active = true
	_fuse_timer = FUSE_TIME

func _process(delta: float) -> void:
	if not _active:
		return
	_fuse_timer -= delta
	if _fuse_timer <= 0.0:
		_detonate()

func _detonate() -> void:
	_active = false
	emit_signal("grenade_detonated", GrenadeType.keys()[grenade_type], global_position)
	match grenade_type:
		GrenadeType.SMOKE:  _detonate_smoke()
		GrenadeType.FLASH:  _detonate_flash()
		GrenadeType.FRAG:   _detonate_frag()
	queue_free()

func _detonate_smoke() -> void:
	# Создаём StaticBody3D в слое smoke (layer 2), блокирует LOS ботов
	_smoke_body = StaticBody3D.new()
	_smoke_body.collision_layer = 2
	_smoke_body.collision_mask = 0
	var shape_node = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = SMOKE_RADIUS
	shape_node.shape = sphere
	_smoke_body.add_child(shape_node)
	_smoke_body.global_position = global_position
	get_tree().current_scene.add_child(_smoke_body)
	# Убираем через SMOKE_DURATION секунд
	await get_tree().create_timer(SMOKE_DURATION).timeout
	if is_instance_valid(_smoke_body):
		_smoke_body.queue_free()

func _detonate_flash() -> void:
	# Слепим всех ботов в радиусе (у которых есть LOS до гранаты)
	var space = get_world_3d().direct_space_state
	var query = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = FLASH_RADIUS
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, global_position)
	query.collision_mask = 8 | 4  # CT + T слои
	var hits = space.intersect_shape(query)
	for hit in hits:
		var body = hit["collider"]
		if body and body.has_method("apply_flash"):
			# Проверяем LOS к гранате
			var ray = PhysicsRayQueryParameters3D.create(
				global_position,
				body.global_position + Vector3(0, 1.4, 0)
			)
			ray.collision_mask = 1  # только стены
			if space.intersect_ray(ray).is_empty():
				body.apply_flash(FLASH_DURATION)

func _detonate_frag() -> void:
	var space = get_world_3d().direct_space_state
	var query = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = FRAG_RADIUS
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, global_position)
	query.collision_mask = 8 | 4
	var hits = space.intersect_shape(query)
	for hit in hits:
		var body = hit["collider"]
		if body and body.has_method("apply_damage"):
			# Урон уменьшается с расстоянием
			var dist = global_position.distance_to(body.global_position)
			var falloff = 1.0 - (dist / FRAG_RADIUS)
			var actual_damage = int(FRAG_DAMAGE * falloff)
			body.apply_damage(actual_damage, _thrower_id)
