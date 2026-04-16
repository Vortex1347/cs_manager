"""
export_weights.py — экспорт обученной модели PPO в model_weights.json.

После экспорта скопируй model_weights.json в res:// проекта Godot.
Godot загружает его через MLPInference.load_weights("res://model_weights.json").

Запуск:
  python export_weights.py                        # из cs_bot_policy.zip
  python export_weights.py --model checkpoints/cs_bot_1000000_steps
"""

import argparse
import json

import numpy as np
from stable_baselines3 import PPO


def export(model_path: str, out_path: str) -> None:
    print(f"Загружаем модель: {model_path}")
    model = PPO.load(model_path)

    layers = []

    # Скрытые слои (mlp_extractor.policy_net)
    for name, param in model.policy.mlp_extractor.policy_net.named_parameters():
        data = param.detach().cpu().numpy()
        if "weight" in name:
            layers.append({"w": data.tolist(), "b": None})
        elif "bias" in name:
            layers[-1]["b"] = data.tolist()

    # Выходной слой (action_net)
    for name, param in model.policy.action_net.named_parameters():
        data = param.detach().cpu().numpy()
        if "weight" in name:
            layers.append({"w": data.tolist(), "b": None})
        elif "bias" in name:
            layers[-1]["b"] = data.tolist()

    # Проверка
    for i, layer in enumerate(layers):
        w = np.array(layer["w"])
        b = np.array(layer["b"])
        print(f"  Слой {i}: {w.shape[1]} → {w.shape[0]}")

    obs_size = int(np.array(layers[0]["w"]).shape[1])
    result = {"layers": layers, "obs_size": obs_size, "action_size": 18}
    with open(out_path, "w") as f:
        json.dump(result, f)

    size_kb = len(json.dumps(result)) / 1024
    print(f"Экспортировано {len(layers)} слоёв → {out_path} ({size_kb:.1f} KB)")
    print(f"Скопируй {out_path} в папку res:// проекта Godot")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="cs_bot_policy", help="путь к model.zip (без расширения)")
    parser.add_argument("--out", default="../model_weights.json", help="выходной JSON файл")
    args = parser.parse_args()
    export(args.model, args.out)
