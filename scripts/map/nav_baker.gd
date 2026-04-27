# nav_baker.gd
# Совместимость для старых сцен: в обычном матче рантайм-bake отключён, чтобы не фризить загрузку.
# Зависимости: NavigationRegion3D (родительский узел в legacy сценах)

extends NavigationRegion3D

func _ready() -> void:
	set_process(false)
