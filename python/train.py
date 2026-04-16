"""
train.py — PPO обучение ботов CS Manager.

Запуск:
  1. Запустить Godot с rl_training_mode=true (headless или с окном)
  2. python train.py

Результат: cs_bot_policy.zip (можно продолжить: python train.py --resume)
"""

import argparse
import os

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback, EvalCallback
from stable_baselines3.common.vec_env import SubprocVecEnv, VecMonitor

from env import GodotCSEnv

# ── Конфиг ────────────────────────────────────────────────────────────────────
BOT_IDS      = list(range(5)) + list(range(10, 15))  # CT: 0-4, T: 10-14
N_BOTS       = len(BOT_IDS)   # 10
TOTAL_STEPS  = 10_000_000
SAVE_FREQ    = 100_000
MODEL_FILE   = "cs_bot_policy"
LOG_DIR      = "./tb_logs/"
GODOT_URL    = "ws://localhost:9002"


def make_env(bot_id: int):
    def _init():
        return GodotCSEnv(bot_id=bot_id, url=GODOT_URL)
    return _init


def main(resume: bool = False):
    os.makedirs(LOG_DIR, exist_ok=True)
    print(f"Подключаем {N_BOTS} ботов к Godot на {GODOT_URL}... IDs: {BOT_IDS}")

    envs = SubprocVecEnv([make_env(i) for i in BOT_IDS])
    envs = VecMonitor(envs)

    if resume and os.path.exists(MODEL_FILE + ".zip"):
        print(f"Продолжаем обучение с {MODEL_FILE}.zip")
        model = PPO.load(MODEL_FILE, env=envs, tensorboard_log=LOG_DIR)
    else:
        model = PPO(
            "MlpPolicy",
            envs,
            verbose=1,
            n_steps=2048,         # шагов на env до обновления
            batch_size=512,
            n_epochs=10,
            gamma=0.99,
            gae_lambda=0.95,
            clip_range=0.2,
            ent_coef=0.01,        # энтропия = исследование
            learning_rate=3e-4,
            tensorboard_log=LOG_DIR,
            policy_kwargs={"net_arch": [256, 256]},  # 27→256→256→18
        )

    checkpoint_cb = CheckpointCallback(
        save_freq=SAVE_FREQ // N_BOTS,
        save_path="./checkpoints/",
        name_prefix="cs_bot",
    )

    print(f"Начинаем обучение: {TOTAL_STEPS:,} шагов")
    print("Прогресс: tensorboard --logdir tb_logs/")
    model.learn(
        total_timesteps=TOTAL_STEPS,
        callback=checkpoint_cb,
        reset_num_timesteps=not resume,
    )
    model.save(MODEL_FILE)
    print(f"Сохранено: {MODEL_FILE}.zip")
    envs.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--resume", action="store_true", help="продолжить с последнего checkpoint")
    args = parser.parse_args()
    main(resume=args.resume)
