"""
env.py — Gymnasium environment обёртка над Godot CS Manager.

Godot должен быть запущен с rl_training_mode=true и слушать на ws://localhost:9002.
Один GodotCSEnv управляет одним ботом (bot_id).
Для параллельного обучения SubprocVecEnv создаёт несколько таких сред.
"""

import json
import threading
import time

import gymnasium as gym
import numpy as np
import websocket


class GodotCSEnv(gym.Env):
    """
    Observation: 27 float [0..1]
      [hp, armor, has_bomb, bomb_planted, bomb_timer,
       ray_0..ray_7, enemy_vis, enemy_angle, enemy_dist,
       site_angle, site_dist, vel_x, vel_z,
       teammate_has_bomb,
       mate1_angle, mate1_dist, mate1_hp,
       mate2_angle, mate2_dist, mate2_hp]

    Action: Discrete(18)
      0-8  = направления (0=стоять, 1=N, ..., 8=NW), без стрельбы
      9-17 = те же направления + стрельба
    """

    metadata = {"render_modes": []}
    observation_space = gym.spaces.Box(0.0, 1.0, shape=(27,), dtype=np.float32)
    action_space = gym.spaces.Discrete(18)

    def __init__(self, bot_id: int = 0, url: str = "ws://localhost:9002"):
        super().__init__()
        self.bot_id = bot_id
        self._url = url

        self._obs = np.zeros(27, dtype=np.float32)
        self._reward = 0.0
        self._done = False
        self._lock = threading.Lock()
        self._step_event = threading.Event()
        self._connected = threading.Event()

        self.ws = websocket.WebSocketApp(
            url,
            on_open=self._on_open,
            on_message=self._on_message,
            on_error=self._on_error,
            on_close=self._on_close,
        )
        self._thread = threading.Thread(target=self.ws.run_forever, daemon=True)
        self._thread.start()
        if not self._connected.wait(timeout=15):
            raise TimeoutError(f"Не удалось подключиться к Godot на {url} за 15 секунд")

    # ── WebSocket callbacks ──────────────────────────────────────────────────

    def _on_open(self, ws):
        self._connected.set()

    def _on_message(self, ws, raw: str):
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return
        for bot in data.get("bots", []):
            if int(bot["id"]) == self.bot_id:
                with self._lock:
                    self._obs = np.array(bot["obs"], dtype=np.float32)
                    self._reward = float(bot["reward"])
                    self._done = bool(bot["done"])
                self._step_event.set()

    def _on_error(self, ws, error):
        print(f"[GodotCSEnv bot={self.bot_id}] WS error: {error}")

    def _on_close(self, ws, code, msg):
        print(f"[GodotCSEnv bot={self.bot_id}] WS closed: {code}")

    # ── gym API ──────────────────────────────────────────────────────────────

    def step(self, action: int):
        move = int(action) % 9
        shoot = int(action) >= 9
        self._step_event.clear()
        self.ws.send(json.dumps({
            "actions": [{"id": self.bot_id, "move": move, "shoot": shoot, "interact": False}]
        }))
        # Ждём следующий кадр от Godot (max 200ms)
        self._step_event.wait(timeout=0.2)
        with self._lock:
            obs = self._obs.copy()
            reward = self._reward
            done = self._done
        return obs, reward, done, False, {}

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        # Godot сам сбрасывает раунд; просто ждём новое observation
        self._step_event.wait(timeout=5.0)
        with self._lock:
            obs = self._obs.copy()
        return obs, {}

    def close(self):
        self.ws.close()
