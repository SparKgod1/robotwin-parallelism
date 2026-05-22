#!/usr/bin/env python3
"""
数据生成进度监控脚本（基于磁盘文件计数）。
用法:
  python multi_proc_scripts/monitor_progress.py [--task-config demo_clean] [--watch]
  python multi_proc_scripts/monitor_progress.py --list [--sort asc|desc]
"""
import os
import sys
import glob
import time
import yaml
from argparse import ArgumentParser
from datetime import datetime, timedelta


def get_progress(save_path, task_config, episode_num, task_filter=None):
    task_dirs = sorted(glob.glob(os.path.join(save_path, "*", task_config)))
    tasks = []
    for td in task_dirs:
        task_name = os.path.basename(os.path.dirname(td))
        if task_name.startswith("_"):
            continue
        if task_filter and task_name not in task_filter:
            continue
        data_dir = os.path.join(td, "video")
        if os.path.isdir(data_dir):
            count = len(glob.glob(os.path.join(data_dir, "episode*.mp4")))
        else:
            count = 0
        tasks.append({"name": task_name, "done": count, "total": episode_num})
    return tasks


def list_tasks(tasks, sort_order):
    if sort_order == "asc":
        tasks = sorted(tasks, key=lambda t: t["done"])
    else:
        tasks = sorted(tasks, key=lambda t: t["done"], reverse=True)

    total_done = sum(t["done"] for t in tasks)
    total_all = sum(t["total"] for t in tasks)
    print(f"\n{'Task':<35} {'Done':>6} / {'Total':<6} {'Pct':>6}")
    print("-" * 60)
    for t in tasks:
        pct = t["done"] / t["total"] * 100 if t["total"] > 0 else 0
        print(f"{t['name']:<35} {t['done']:>6} / {t['total']:<6} {pct:>5.1f}%")
    print("-" * 60)
    pct_all = total_done / total_all * 100 if total_all > 0 else 0
    print(f"{'TOTAL':<35} {total_done:>6} / {total_all:<6} {pct_all:>5.1f}%")
    print(f"Tasks: {len(tasks)}\n")


def main():
    parser = ArgumentParser()
    parser.add_argument("--task-config", type=str, default="demo_clean")
    parser.add_argument("--task", type=str, default="", help="Comma-separated task names to monitor")
    parser.add_argument("--watch", action="store_true", help="every 30s refresh")
    parser.add_argument("--list", action="store_true", help="list all tasks with counts")
    parser.add_argument("--sort", type=str, default="asc", choices=["asc", "desc"],
                        help="sort order for --list (default: asc)")
    args = parser.parse_args()

    config_path = f"./task_config/{args.task_config}.yml"
    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f)

    save_path = config["save_path"]
    episode_num = config["episode_num"]
    task_config = args.task_config
    task_filter = {t.strip() for t in args.task.split(",") if t.strip()} or None

    tasks = get_progress(save_path, task_config, episode_num, task_filter)

    if args.list:
        list_tasks(tasks, args.sort)
        return

    start_time = time.time()
    start_done = None

    while True:
        tasks = get_progress(save_path, task_config, episode_num, task_filter)
        done = sum(t["done"] for t in tasks)
        total = sum(t["total"] for t in tasks)
        pct = (done / total * 100) if total > 0 else 0

        fastest = max(tasks, key=lambda t: t["done"]) if tasks else None
        slowest = min(tasks, key=lambda t: t["done"]) if tasks else None

        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}]  "
              f"{done}/{total} ({pct:.1f}%)", end="")

        if start_done is None:
            start_done = done
        elapsed = time.time() - start_time
        completed_since_start = done - start_done
        if completed_since_start > 0 and elapsed > 10:
            rate = completed_since_start / elapsed
            remaining = total - done
            eta_seconds = remaining / rate
            eta_time = datetime.now() + timedelta(seconds=eta_seconds)
            print(f"  |  {rate*3600:.0f} ep/h  ETA {eta_time.strftime('%m-%d %H:%M')}", end="")

        print()
        if fastest:
            print(f"  fastest: {fastest['name']} ({fastest['done']}/{fastest['total']})")
        if slowest:
            print(f"  slowest: {slowest['name']} ({slowest['done']}/{slowest['total']})")

        if done >= total:
            print("All done!")
            break
        if not args.watch:
            break

        try:
            time.sleep(30)
        except KeyboardInterrupt:
            print("\nStopped.")
            break


if __name__ == "__main__":
    main()
