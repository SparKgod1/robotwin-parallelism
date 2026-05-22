"""
Benchmark Phase 2 (data collection / replay) speed.
Reads phase1 seeds and trajectory data, then replays episodes and reports timing.

Usage:
    python script/benchmark_phase2.py <task_name> <task_config> [--episodes N] [--gpu GPU_ID]

Example:
    python script/benchmark_phase2.py adjust_bottle demo_clean --episodes 5 --gpu 0
"""

import sys
sys.path.append("./")

import os
import time
import json
import yaml
import importlib
from argparse import ArgumentParser

from script.test_render import Sapien_TEST


def class_decorator(task_name):
    envs_module = importlib.import_module(f"envs.{task_name}")
    env_class = getattr(envs_module, task_name)
    return env_class()


def get_embodiment_config(robot_file):
    robot_config_file = os.path.join(robot_file, "config.yml")
    with open(robot_config_file, "r", encoding="utf-8") as f:
        return yaml.load(f.read(), Loader=yaml.FullLoader)


def main():
    Sapien_TEST()

    import torch.multiprocessing as mp
    mp.set_start_method("spawn", force=True)

    parser = ArgumentParser(description="Benchmark Phase 2 replay speed")
    parser.add_argument("task_name", type=str)
    parser.add_argument("task_config", type=str)
    parser.add_argument("--episodes", type=int, default=None,
                        help="Number of episodes to benchmark (default: all available)")
    parser.add_argument("--gpu", type=int, default=0)
    parser.add_argument("--save-data", action="store_true",
                        help="Actually save hdf5/video (slower, tests full pipeline)")
    args = parser.parse_args()

    os.environ["CUDA_VISIBLE_DEVICES"] = str(args.gpu)

    from envs import CONFIGS_PATH

    config_path = f"./task_config/{args.task_config}.yml"
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = yaml.load(f.read(), Loader=yaml.FullLoader)

    cfg["task_name"] = args.task_name
    cfg["task_config"] = args.task_config
    cfg["need_plan"] = False
    cfg["render_freq"] = 0
    cfg["save_data"] = args.save_data

    # Embodiment setup
    embodiment_type = cfg.get("embodiment")
    embodiment_config_path = os.path.join(CONFIGS_PATH, "_embodiment_config.yml")
    with open(embodiment_config_path, "r", encoding="utf-8") as f:
        _embodiment_types = yaml.load(f.read(), Loader=yaml.FullLoader)

    def get_embodiment_file(etype):
        return _embodiment_types[etype]["file_path"]

    if len(embodiment_type) == 1:
        cfg["left_robot_file"] = get_embodiment_file(embodiment_type[0])
        cfg["right_robot_file"] = get_embodiment_file(embodiment_type[0])
        cfg["dual_arm_embodied"] = True
    elif len(embodiment_type) == 3:
        cfg["left_robot_file"] = get_embodiment_file(embodiment_type[0])
        cfg["right_robot_file"] = get_embodiment_file(embodiment_type[1])
        cfg["embodiment_dis"] = embodiment_type[2]
        cfg["dual_arm_embodied"] = False

    cfg["left_embodiment_config"] = get_embodiment_config(cfg["left_robot_file"])
    cfg["right_embodiment_config"] = get_embodiment_config(cfg["right_robot_file"])

    if len(embodiment_type) == 1:
        cfg["embodiment_name"] = str(embodiment_type[0])
    else:
        cfg["embodiment_name"] = str(embodiment_type[0]) + "+" + str(embodiment_type[1])

    cfg["save_path"] = os.path.join(cfg["save_path"], cfg["task_name"], cfg["task_config"])

    # Load seeds
    seed_file = os.path.join(cfg["save_path"], "seed.txt")
    if not os.path.exists(seed_file):
        print(f"Error: No seed.txt found at {seed_file}")
        print("Phase 1 must be completed first.")
        sys.exit(1)

    with open(seed_file, "r") as f:
        seed_list = [int(s) for s in f.read().split()]

    # Determine episode count
    traj_dir = os.path.join(cfg["save_path"], "_traj_data")
    available = len([f for f in os.listdir(traj_dir) if f.endswith(".pkl")])
    num_episodes = min(args.episodes or available, available, len(seed_list))

    print("=" * 50)
    print(f"  Phase 2 Benchmark: {args.task_name}")
    print(f"  Config: {args.task_config}")
    print(f"  Episodes: {num_episodes} (of {available} available)")
    print(f"  Save data: {args.save_data}")
    print(f"  GPU: {args.gpu}")
    print("=" * 50)

    TASK_ENV = class_decorator(args.task_name)

    episode_times = []
    setup_times = []
    replay_times = []
    merge_times = []

    for i in range(num_episodes):
        print(f"\n--- Episode {i}/{num_episodes} (seed={seed_list[i]}) ---")
        ep_start = time.time()

        # Setup
        t0 = time.time()
        TASK_ENV.setup_demo(now_ep_num=i, seed=seed_list[i], **cfg)
        traj_data = TASK_ENV.load_tran_data(i)
        cfg["left_joint_path"] = traj_data["left_joint_path"]
        cfg["right_joint_path"] = traj_data["right_joint_path"]
        TASK_ENV.set_path_lst(cfg)
        setup_time = time.time() - t0

        # Replay
        t0 = time.time()
        TASK_ENV.play_once()
        replay_time = time.time() - t0

        # Merge (if saving)
        merge_time = 0
        if args.save_data:
            t0 = time.time()
            TASK_ENV.merge_pkl_to_hdf5_video()
            TASK_ENV.remove_data_cache()
            merge_time = time.time() - t0

        success = TASK_ENV.check_success()
        TASK_ENV.close_env()

        ep_total = time.time() - ep_start
        episode_times.append(ep_total)
        setup_times.append(setup_time)
        replay_times.append(replay_time)
        merge_times.append(merge_time)

        print(f"  setup: {setup_time:.2f}s | replay: {replay_time:.2f}s | "
              f"merge: {merge_time:.2f}s | total: {ep_total:.2f}s | "
              f"success: {success}")

    # Summary
    print("\n" + "=" * 50)
    print("  BENCHMARK RESULTS")
    print("=" * 50)
    print(f"  Episodes:       {num_episodes}")
    print(f"  Total time:     {sum(episode_times):.2f}s")
    print(f"  Avg per episode: {sum(episode_times)/num_episodes:.2f}s")
    print(f"  Avg setup:      {sum(setup_times)/num_episodes:.2f}s")
    print(f"  Avg replay:     {sum(replay_times)/num_episodes:.2f}s")
    if args.save_data:
        print(f"  Avg merge:      {sum(merge_times)/num_episodes:.2f}s")
    print(f"  Min episode:    {min(episode_times):.2f}s")
    print(f"  Max episode:    {max(episode_times):.2f}s")
    print("=" * 50)


if __name__ == "__main__":
    main()
