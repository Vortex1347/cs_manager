# nav_baker.gd
# Перезапекает NavigationMesh в рантайме после того как CSG вычислит геометрию.
# Зависимости: NavigationRegion3D (родительский узел)

extends NavigationRegion3D

func _ready() -> void:
	# Ждём 2 кадра — CSG-узлы обновляют свою геометрию асинхронно
	await get_tree().process_frame
	await get_tree().process_frame
	bake_navigation_mesh(false)
