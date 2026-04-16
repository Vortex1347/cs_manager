"""
inference.py — тест: загружаем обученную модель и играем против FSM-ботов.

Запускает агентов для ВСЕХ ботов (CT + T) или только для одной команды.
Используется для визуальной проверки поведения ПЕРЕД экспортом в GDScript.

Запуск:
  python inference.py                    # все 10 ботов управляются моделью
  python inference.py --team T           # только T-боты управляются моделью
"""

import argparse
import json
import threading
import time

import numpy as np
from stable_baselines3 import PPO


def run_inference(model_path: str, bot_ids: list, url: str = "ws://localhost:9002"):
    import websocket

    model = PPO.load(model_path)
    obs_store: dict = {}
    lock = threading.Lock()

    def on_message(ws, raw):
        data = json.loads(raw)
        for b in data.get("bots", []):
            if int(b["id"]) in bot_ids:
                with lock:
                    obs_store[int(b["id"])] = np.array(b["obs"], dtype=np.float32)
        # Сформировать batch actions
        actions = []
        with lock:
            for bot_id in bot_ids:
                if bot_id not in obs_store:
                    continue
                obs = obs_store[bot_id].reshape(1, -1)
                action, _ = model.predict(obs, deterministic=True)
                move = int(action[0]) % 9
                shoot = int(action[0]) >= 9
                actions.append({"id": bot_id, "move": move, "shoot": shoot, "interact": False})
        if actions:
            ws.send(json.dumps({"actions": actions}))

    def on_open(ws):
        print(f"Подключено. Управляю ботами: {bot_ids}")

    ws_app = websocket.WebSocketApp(url, on_open=on_open, on_message=on_message)
    ws_app.run_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="cs_bot_policy")
    parser.add_argument("--team", choices=["CT", "T", "all"], default="all")
    parser.add_argument("--url", default="ws://localhost:9002")
    args = parser.parse_args()

    if args.team == "CT":
        ids = list(range(5))       # CT: bot_id 0-4
    elif args.team == "T":
        ids = list(range(10, 15))  # T: bot_id 10-14
    else:
        ids = list(range(5)) + list(range(10, 15))

    run_inference(args.model, ids, args.url)
