"""
Phase 1 Worker: 独立进程采集 seed，输出到 _worker_{id}/ 目录。
每个 worker 从独立的 seed 起点开始递增，避免并发冲突。
"""
import sys
import os
import time
import pickle

sys.path.append("./")

import yaml
import importlib
from copy import deepcopy
from argparse import ArgumentParser
from envs import *


def class_decorator(task_name):
    envs_module = importlib.import_module(f"envs.{task_name}")
    try:
        env_class = getattr(envs_module, task_name)
        env_instance = env_class()
    except Exception:
        raise SystemExit("No such task")
    return env_instance


def get_embodiment_config(robot_file):
    robot_config_file = os.path.join(robot_file, "config.yml")
    with open(robot_config_file, "r", encoding="utf-8") as f:
        embodiment_args = yaml.load(f.read(), Loader=yaml.FullLoader)
    return embodiment_args


def main():
    parser = ArgumentParser()
    parser.add_argument("task_name", type=str)
    parser.add_argument("task_config", type=str)
    parser.add_argument("--worker-id", type=int, required=True)
    parser.add_argument("--num-workers", type=int, required=True)
    parser.add_argument("--episodes", type=int, required=True,
                        help="Number of successful episodes this worker should collect")
    parser.add_argument("--seed-start", type=int, required=True)
    args_cli = parser.parse_args()

    task_name = args_cli.task_name
    task_config = args_cli.task_config
    worker_id = args_cli.worker_id
    target_episodes = args_cli.episodes
    seed_start = args_cli.seed_start

    task = class_decorator(task_name)
    config_path = f"./task_config/{task_config}.yml"

    with open(config_path, "r", encoding="utf-8") as f:
        args = yaml.load(f.read(), Loader=yaml.FullLoader)

    args["task_name"] = task_name
    args["collect_data"] = False

    embodiment_type = args.get("embodiment")
    embodiment_config_path = os.path.join(CONFIGS_PATH, "_embodiment_config.yml")

    with open(embodiment_config_path, "r", encoding="utf-8") as f:
        _embodiment_types = yaml.load(f.read(), Loader=yaml.FullLoader)

    def get_embodiment_file(etype):
        robot_file = _embodiment_types[etype]["file_path"]
        if robot_file is None:
            raise RuntimeError("missing embodiment files")
        return robot_file

    if len(embodiment_type) == 1:
        args["left_robot_file"] = get_embodiment_file(embodiment_type[0])
        args["right_robot_file"] = get_embodiment_file(embodiment_type[0])
        args["dual_arm_embodied"] = True
    elif len(embodiment_type) == 3:
        args["left_robot_file"] = get_embodiment_file(embodiment_type[0])
        args["right_robot_file"] = get_embodiment_file(embodiment_type[1])
        args["embodiment_dis"] = embodiment_type[2]
        args["dual_arm_embodied"] = False
    else:
        raise RuntimeError("number of embodiment config parameters should be 1 or 3")

    args["left_embodiment_config"] = get_embodiment_config(args["left_robot_file"])
    args["right_embodiment_config"] = get_embodiment_config(args["right_robot_file"])

    if len(embodiment_type) == 1:
        embodiment_name = str(embodiment_type[0])
    else:
        embodiment_name = str(embodiment_type[0]) + "+" + str(embodiment_type[1])

    args["embodiment_name"] = embodiment_name
    args["task_config"] = task_config
    args["save_path"] = os.path.join(args["save_path"], str(task_name), task_config)

    worker_dir = os.path.join(args["save_path"], f"_worker_{worker_id}")
    os.makedirs(worker_dir, exist_ok=True)

    seeds_file = os.path.join(worker_dir, "seeds.txt")

    # 断点续传：读取已有进度
    existing_seeds = []
    if os.path.exists(seeds_file):
        with open(seeds_file, "r") as f:
            existing_seeds = [int(s) for s in f.read().split() if s.strip()]

    suc_num = len(existing_seeds)
    seed_list = existing_seeds[:]

    # 从上次最后一个 seed + 1 继续，或从 seed_start 开始
    if existing_seeds:
        epid = max(existing_seeds) + 1
    else:
        epid = seed_start

    remaining = target_episodes - suc_num
    if remaining <= 0:
        print(f"[Worker {worker_id}] Task: {task_name}, already done ({suc_num}/{target_episodes} episodes)")
        return

    print(f"[Worker {worker_id}] Task: {task_name}, target: {target_episodes} episodes, "
          f"resuming from {suc_num}, seed: {epid}")

    args["need_plan"] = True
    fail_num = 0

    while suc_num < target_episodes:
        try:
            task.setup_demo(now_ep_num=suc_num, seed=epid, **args)
            task.play_once()

            if task.plan_success and task.check_success():
                print(f"[Worker {worker_id}] episode {suc_num} success! (seed = {epid})")
                seed_list.append(epid)
                traj_path = os.path.join(worker_dir, f"episode{suc_num}.pkl")
                traj_data = {
                    "left_joint_path": deepcopy(task.left_joint_path),
                    "right_joint_path": deepcopy(task.right_joint_path),
                }
                os.makedirs(os.path.dirname(traj_path), exist_ok=True)
                tmp_path = traj_path + ".tmp"
                with open(tmp_path, "wb") as f:
                    pickle.dump(traj_data, f)
                os.rename(tmp_path, traj_path)
                # 立即追加写入 seeds.txt，确保中途 kill 不丢进度
                with open(seeds_file, "a") as f:
                    f.write(f"{epid} ")
                suc_num += 1
            else:
                print(f"[Worker {worker_id}] episode {suc_num} fail! (seed = {epid})")
                fail_num += 1

            task.close_env()

            if args["render_freq"]:
                task.viewer.close()
        except UnStableError as e:
            print(f"[Worker {worker_id}] episode {suc_num} fail! (seed = {epid}) Error: {e}")
            fail_num += 1
            task.close_env()
            if args["render_freq"]:
                task.viewer.close()
            time.sleep(0.3)
        except Exception as e:
            print(f"[Worker {worker_id}] episode {suc_num} fail! (seed = {epid}) Error: {e}")
            fail_num += 1
            task.close_env()
            if args["render_freq"]:
                task.viewer.close()
            time.sleep(1)

        epid += 1

    print(f"[Worker {worker_id}] Done. {suc_num} success, {fail_num} failures.")


if __name__ == "__main__":
    sys.path.append("./script")
    from test_render import Sapien_TEST
    Sapien_TEST()

    import torch.multiprocessing as mp
    mp.set_start_method("spawn", force=True)

    main()
