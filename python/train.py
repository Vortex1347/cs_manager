"""
train.py — PPO обучение ботов CS Manager.

Запуск:
  1. Запустить Godot с rl_training_mode=true
  2. python train.py --team CT
     python train.py --team T

Результат: cs_ct_policy.zip / cs_t_policy.zip

Продолжить с последнего сохранения:
  python train.py --team CT --resume

Warm start из любого чекпоинта (не с нуля):
  python train.py --team CT --from-checkpoint checkpoints/cs_bot_10000000_steps

ПОЧЕМУ РАЗДЕЛЬНЫЕ МОДЕЛИ:
  CT и T имеют противоположные цели (defend vs plant).
  Один shared PPO получает взаимоисключающие градиенты → веса не сходятся.
  Решение: ct-модель обучается только на ботах 0-4 (T-боты играют на FSM),
           t-модель — только на ботах 10-14 (CT-боты на FSM).
"""

import argparse
import os
from typing import Optional

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback
from stable_baselines3.common.vec_env import SubprocVecEnv, VecMonitor, VecNormalize

from env import GodotCSEnv

# ── Конфиг ────────────────────────────────────────────────────────────────────
CT_IDS      = list(range(5))          # боты 0-4  (CT team)
T_IDS       = list(range(10, 15))     # боты 10-14 (T team)
TOTAL_STEPS = 5_000_000
SAVE_FREQ   = 50_000
LOG_DIR     = "./tb_logs/"
GODOT_URL   = "ws://localhost:9002"


def make_env(bot_id: int):
    def _init():
        return GodotCSEnv(bot_id=bot_id, url=GODOT_URL)
    return _init


def main(team: str, resume: bool, from_checkpoint: Optional[str]) -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    bot_ids    = CT_IDS if team == "CT" else T_IDS
    model_file = f"cs_{team.lower()}_policy"
    n_bots     = len(bot_ids)
    vec_norm_path = f"{model_file}_vecnorm.pkl"

    print(f"Команда: {team} | Боты: {bot_ids} | Модель: {model_file}.zip")
    print(f"Подключаемся к Godot на {GODOT_URL}...")

    envs = SubprocVecEnv([make_env(i) for i in bot_ids])
    envs = VecMonitor(envs)

    if from_checkpoint and os.path.exists(from_checkpoint + ".zip"):
        print(f"Warm start из {from_checkpoint}")
        envs = VecNormalize(envs, norm_obs=False, norm_reward=True, clip_reward=10.0)
        try:
            model = PPO.load(from_checkpoint, env=envs, tensorboard_log=LOG_DIR)
            reset_timesteps = False
        except ValueError as e:
            print(f"  [!] Чекпоинт несовместим ({e})")
            print(f"  [!] Старая модель обучена с другим obs_size — стартуем с нуля")
            model = PPO(
                "MlpPolicy", envs, verbose=1,
                n_steps=2048, batch_size=512, n_epochs=10,
                gamma=0.99, gae_lambda=0.95, clip_range=0.2,
                ent_coef=0.01, learning_rate=3e-4,
                tensorboard_log=LOG_DIR,
                policy_kwargs={"net_arch": [256, 256]},
            )
            reset_timesteps = True

    elif resume and os.path.exists(model_file + ".zip"):
        print(f"Продолжаем с {model_file}.zip")
        if os.path.exists(vec_norm_path):
            envs = VecNormalize.load(vec_norm_path, envs)
            envs.training = True
            print(f"  VecNormalize статистика загружена из {vec_norm_path}")
        else:
            envs = VecNormalize(envs, norm_obs=False, norm_reward=True, clip_reward=10.0)
        model = PPO.load(model_file, env=envs, tensorboard_log=LOG_DIR)
        reset_timesteps = False

    else:
        print("Новая модель с нуля")
        envs = VecNormalize(envs, norm_obs=False, norm_reward=True, clip_reward=10.0)
        model = PPO(
            "MlpPolicy",
            envs,
            verbose=1,
            n_steps=2048,
            batch_size=512,
            n_epochs=10,
            gamma=0.99,
            gae_lambda=0.95,
            clip_range=0.2,
            ent_coef=0.01,
            learning_rate=3e-4,
            tensorboard_log=LOG_DIR,
            policy_kwargs={"net_arch": [256, 256]},
        )
        reset_timesteps = True

    checkpoint_cb = CheckpointCallback(
        save_freq=SAVE_FREQ // n_bots,
        save_path=f"./checkpoints_{team.lower()}/",
        name_prefix=f"cs_{team.lower()}",
    )

    print(f"Начинаем обучение: {TOTAL_STEPS:,} шагов")
    print(f"TensorBoard: tensorboard --logdir {LOG_DIR}")
    model.learn(
        total_timesteps=TOTAL_STEPS,
        callback=checkpoint_cb,
        reset_num_timesteps=reset_timesteps,
    )
    model.save(model_file)
    envs.save(vec_norm_path)
    print(f"Сохранено: {model_file}.zip + {vec_norm_path}")
    envs.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--team", choices=["CT", "T"], default="CT",
        help="Какую команду обучать (CT или T)"
    )
    parser.add_argument(
        "--resume", action="store_true",
        help="Продолжить с последнего сохранения модели"
    )
    parser.add_argument(
        "--from-checkpoint", default=None,
        help="Warm start из конкретного чекпоинта (.zip без расширения), напр. checkpoints/cs_bot_10000000_steps"
    )
    args = parser.parse_args()
    main(team=args.team, resume=args.resume, from_checkpoint=args.from_checkpoint)
