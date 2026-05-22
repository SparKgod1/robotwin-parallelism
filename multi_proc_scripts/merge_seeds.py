"""
合并各 Phase 1 worker 的结果为统一的 seed.txt + _traj_data/
"""
import sys
import os
import shutil
import glob
import yaml
from argparse import ArgumentParser


def main():
    parser = ArgumentParser()
    parser.add_argument("task_name", type=str)
    parser.add_argument("task_config", type=str)
    args = parser.parse_args()

    config_path = f"./task_config/{args.task_config}.yml"
    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.load(f.read(), Loader=yaml.FullLoader)

    save_path = os.path.join(config["save_path"], args.task_name, args.task_config)

    worker_dirs = sorted(glob.glob(os.path.join(save_path, "_worker_*")),
                         key=lambda x: int(x.split("_worker_")[-1]))

    if not worker_dirs:
        print(f"No worker directories found in {save_path}")
        return

    # 读取已有的 seed.txt 和 _traj_data（支持扩容续传）
    existing_seed_file = os.path.join(save_path, "seed.txt")
    traj_dir = os.path.join(save_path, "_traj_data")
    existing_seeds = []
    if os.path.exists(existing_seed_file):
        with open(existing_seed_file, "r") as f:
            existing_seeds = [int(s) for s in f.read().split() if s.strip()]

    all_seeds = []

    for wdir in worker_dirs:
        seeds_file = os.path.join(wdir, "seeds.txt")
        if not os.path.exists(seeds_file):
            continue
        with open(seeds_file, "r") as f:
            seeds = [int(s) for s in f.read().split() if s.strip()]

        episode_files_map = {}
        for ep_file in glob.glob(os.path.join(wdir, "episode*.pkl")):
            idx = int(os.path.basename(ep_file).replace("episode", "").replace(".pkl", ""))
            episode_files_map[idx] = ep_file

        for i, seed in enumerate(seeds):
            if i not in episode_files_map:
                print(f"[WARN] {wdir}: seed at index {i} (seed={seed}) has no episode{i}.pkl, skipping")
                continue
            if seed in existing_seeds:
                continue
            all_seeds.append((seed, episode_files_map[i]))

    all_seeds.sort(key=lambda x: x[0])

    os.makedirs(traj_dir, exist_ok=True)

    base_idx = len(existing_seeds)
    seed_list = existing_seeds[:]
    for i, (seed, src_pkl) in enumerate(all_seeds):
        dst_pkl = os.path.join(traj_dir, f"episode{base_idx + i}.pkl")
        shutil.copy2(src_pkl, dst_pkl)
        seed_list.append(seed)

    with open(existing_seed_file, "w") as f:
        for s in seed_list:
            f.write(f"{s} ")

    print(f"Merged {len(all_seeds)} new + {len(existing_seeds)} existing = {len(seed_list)} total episodes for {args.task_name}")

    for wdir in worker_dirs:
        shutil.rmtree(wdir)
        print(f"Cleaned up {wdir}")


if __name__ == "__main__":
    main()
