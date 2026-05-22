"""
Phase 2 Worker: 从共享队列认领 batch 并渲染。
每个 GPU 运行一个 worker 进程，循环从队列取任务直到队列耗尽。
"""
import sys
import os
import json
import fcntl
import time
import glob
import random
import subprocess
from argparse import ArgumentParser

sys.path.append("./")


STALE_TIMEOUT = 1800  # 30 minutes


def claim_batch(queue_dir, worker_id, allowed_tasks=None, excluded_tasks=None):
    """Returns (task_name, task_config, episodes) or None.
    Sets claim_batch.has_processing = True if there are still processing batches."""
    queue_files = glob.glob(os.path.join(queue_dir, "*.json"))
    queue_files = [f for f in queue_files if not f.endswith(".lock")]

    # 按 task filter/exclude 过滤队列文件
    if allowed_tasks is not None or excluded_tasks:
        filtered = []
        for qf in queue_files:
            task_name = os.path.basename(qf).replace(".json", "")
            if allowed_tasks is not None and task_name not in allowed_tasks:
                continue
            if excluded_tasks and task_name in excluded_tasks:
                continue
            filtered.append(qf)
        queue_files = filtered

    random.shuffle(queue_files)
    has_processing = False
    skipped_due_to_lock = False
    for qf in queue_files:
        lock_path = qf + ".lock"
        lock_fd = open(lock_path, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            lock_fd.close()
            skipped_due_to_lock = True
            continue

        try:
            with open(qf, "r") as f:
                queue = json.load(f)

            claimed = None

            for batch in queue["batches"]:
                if batch["status"] == "pending":
                    batch["status"] = "processing"
                    batch["worker"] = worker_id
                    batch["claimed_at"] = time.time()
                    claimed = (queue["task_name"], queue["task_config"], batch["episodes"])
                    break

            if claimed is None:
                for batch in queue["batches"]:
                    if batch["status"] == "processing":
                        has_processing = True
                        if batch["claimed_at"] and \
                           time.time() - batch["claimed_at"] > STALE_TIMEOUT:
                            print(f"[{worker_id}] Reclaiming stale batch from {batch['worker']}")
                            batch["status"] = "processing"
                            batch["worker"] = worker_id
                            batch["claimed_at"] = time.time()
                            claimed = (queue["task_name"], queue["task_config"], batch["episodes"])
                            break

            if claimed is not None:
                with open(qf, "w") as f:
                    json.dump(queue, f, indent=2)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()

        if claimed is not None:
            return claimed

    claim_batch.has_processing = has_processing or skipped_due_to_lock
    return None


def mark_done(queue_dir, task_name, episodes, worker_id):
    qf = os.path.join(queue_dir, f"{task_name}.json")
    lock_path = qf + ".lock"
    with open(lock_path, "w") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            with open(qf, "r") as f:
                queue = json.load(f)
            for batch in queue["batches"]:
                if batch["episodes"] == episodes and batch["worker"] == worker_id:
                    batch["status"] = "done"
                    break
            with open(qf, "w") as f:
                json.dump(queue, f, indent=2)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)


def render_batch(task_name, task_config, episodes):
    episodes_str = ",".join(str(e) for e in episodes)
    cmd = [
        sys.executable, "script/collect_data.py",
        task_name, task_config,
        "--phase", "2",
        "--episodes", episodes_str,
    ]
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if result.returncode != 0:
        raise RuntimeError(f"collect_data.py failed with code {result.returncode}")


def main():
    parser = ArgumentParser()
    parser.add_argument("--worker-id", type=str, required=True)
    parser.add_argument("--task-config", type=str, default="demo_clean")
    parser.add_argument("--task-filter", type=str, default="",
                        help="Comma-separated task names to process (default: all in queue)")
    parser.add_argument("--task-exclude", type=str, default="",
                        help="Comma-separated task names to exclude")
    args = parser.parse_args()

    import yaml
    config_path = f"./task_config/{args.task_config}.yml"
    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.load(f.read(), Loader=yaml.FullLoader)

    queue_dir = os.path.join(config["save_path"], "_queue")

    allowed_tasks = None
    if args.task_filter:
        allowed_tasks = {t.strip() for t in args.task_filter.split(",") if t.strip()}
    excluded_tasks = set()
    if args.task_exclude:
        excluded_tasks = {t.strip() for t in args.task_exclude.split(",") if t.strip()}

    print(f"[{args.worker_id}] Phase 2 worker started. Queue: {queue_dir}")

    batch_count = 0
    idle_count = 0
    while True:
        result = claim_batch(queue_dir, args.worker_id,
                             allowed_tasks=allowed_tasks, excluded_tasks=excluded_tasks)
        if result is None:
            if getattr(claim_batch, 'has_processing', False):
                idle_count += 1
                if idle_count > 60:
                    print(f"[{args.worker_id}] Still processing batches elsewhere but waited too long. Exiting.")
                    break
                time.sleep(30)
                continue
            print(f"[{args.worker_id}] No more work. Completed {batch_count} batches.")
            break

        idle_count = 0

        task_name, task_config, episodes = result
        print(f"[{args.worker_id}] Claimed: {task_name} episodes {episodes}")

        try:
            t_start = time.time()
            render_batch(task_name, task_config, episodes)
            elapsed = time.time() - t_start
            mark_done(queue_dir, task_name, episodes, args.worker_id)
            batch_count += 1
            print(f"[{args.worker_id}] Done: {task_name} episodes {episodes} ({elapsed:.1f}s)")
        except Exception as e:
            elapsed = time.time() - t_start
            print(f"[{args.worker_id}] ERROR: {task_name} episodes {episodes} ({elapsed:.1f}s): {e}")
            # Leave as processing - stale reclaim will handle retry


if __name__ == "__main__":
    sys.path.append("./script")
    from test_render import Sapien_TEST
    Sapien_TEST()

    main()
