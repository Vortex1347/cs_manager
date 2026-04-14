# nav_baker.gd
# Перезапекает NavigationMesh в рантайме после того как CSG вычислит геометрию.
# Зависимости: NavigationRegion3D (родительский узел)

extends NavigationRegion3D

func _ready() -> void:
	# Ждём 2 кадра — CSG-узлы обновляют свою геометрию асинхронно
	await get_tree().process_frame
	await get_tree().process_frame

	# Настраиваем NavMesh: использовать collision shapes (надёжнее чем GPU-меши CSG)
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()

	navigation_mesh.cell_size = 0.25
	navigation_mesh.cell_height = 0.25
	navigation_mesh.agent_height = 1.8
	navigation_mesh.agent_radius = 0.4
	navigation_mesh.agent_max_climb = 0.25
	navigation_mesh.agent_max_slope = 45.0
	navigation_mesh.border_size = 0.0

	bake_navigation_mesh(false)
