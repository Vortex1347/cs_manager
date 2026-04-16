# mlp_inference.gd
# Forward pass обученной нейросети в GDScript.
# Загружает model_weights.json (экспорт из Python export_weights.py).
# Архитектура: 20 → 64 → 64 → 18 (ReLU активации, argmax на выходе).
# Зависимости: нет (standalone)

class_name MLPInference

var _layers: Array = []   # [{w: [[float]], b: [float]}, ...]
var is_loaded: bool = false

func load_weights(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("MLPInference: файл не найден: %s" % path)
		return false
	var data = JSON.parse_string(text)
	if data == null or not data.has("layers"):
		push_error("MLPInference: неверный формат JSON")
		return false
	_layers = data["layers"]
	is_loaded = true
	print("MLPInference: загружено %d слоёв" % _layers.size())
	return true

# Возвращает action id (0-17)
func forward(obs: PackedFloat32Array) -> int:
	if not is_loaded:
		push_error("MLPInference: веса не загружены")
		return 0
	var x: Array = Array(obs)
	# Все слои кроме последнего — с ReLU
	for i in range(_layers.size() - 1):
		x = _relu(_linear(x, _layers[i]))
	# Последний слой без активации
	x = _linear(x, _layers[-1])
	# argmax
	var best_i := 0
	var best_v: float = x[0]
	for i in range(1, x.size()):
		if x[i] > best_v:
			best_v = x[i]
			best_i = i
	return best_i

func _linear(x: Array, layer: Dictionary) -> Array:
	var w: Array = layer["w"]   # shape: [out, in]
	var b: Array = layer["b"]   # shape: [out]
	var out := []
	out.resize(w.size())
	for i in range(w.size()):
		var s: float = b[i]
		var row: Array = w[i]
		for j in range(x.size()):
			s += row[j] * float(x[j])
		out[i] = s
	return out

func _relu(x: Array) -> Array:
	var out := x.duplicate()
	for i in range(out.size()):
		if out[i] < 0.0:
			out[i] = 0.0
	return out
