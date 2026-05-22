"""
初始化 Phase 2 队列。在 Phase 1 全部完成后由 Machine 0 运行。
为每个 task 创建一个队列 JSON 文件，将 episodes 分成 batch_size=10 的批次。
"""
import sys
import os
import json
import yaml
from argparse import ArgumentParser

TASKS = [
    "adjust_bottle", "beat_block_hammer", "blocks_ranking_rgb", "blocks_ranking_size",
    "click_alarmclock", "click_bell", "dump_bin_bigbin", "grab_roller",
    "handover_block", "handover_mic", "hanging_mug", "lift_pot",
    "move_can_pot", "move_pillbottle_pad", "move_playingcard_away", "move_stapler_pad",
    "open_laptop", "open_microwave", "pick_diverse_bottles", "pick_dual_bottles",
    "place_a2b_left", "place_a2b_right", "place_bread_basket", "place_bread_skillet",
    "place_burger_fries", "place_can_basket", "place_cans_plasticbox", "place_container_plate",
    "place_dual_shoes", "place_empty_cup", "place_fan", "place_mouse_pad",
    "place_object_basket", "place_object_scale", "place_object_stand", "place_phone_stand",
    "place_shoe", "press_stapler", "put_bottles_dustbin", "put_object_cabinet",
    "rotate_qrcode", "scan_object", "shake_bottle", "shake_bottle_horizontally",
    "stack_blocks_three", "stack_blocks_two", "stack_bowls_three", "stack_bowls_two",
    "stamp_seal", "turn_switch",
]


def main():
    parser = ArgumentParser()
    parser.add_argument("--task-config", type=str, default="demo_clean")
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--task-filter", type=str, default="",
                        help="Comma-separated task names to process (default: all)")
    parser.add_argument("--task-exclude", type=str, default="",
                        help="Comma-separated task names to exclude")
    args = parser.parse_args()

    config_path = f"./task_config/{args.task_config}.yml"
    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.load(f.read(), Loader=yaml.FullLoader)

    save_path = config["save_path"]
    episode_num = config["episode_num"]
    batch_size = args.batch_size

    if args.task_filter:
        task_list = [t.strip() for t in args.task_filter.split(",") if t.strip()]
    else:
        task_list = TASKS[:]

    if args.task_exclude:
        exclude_set = {t.strip() for t in args.task_exclude.split(",") if t.strip()}
        task_list = [t for t in task_list if t not in exclude_set]

    queue_dir = os.path.join(save_path, "_queue")
    os.makedirs(queue_dir, exist_ok=True)

    errors = []
    created = 0
    skipped = 0
    for task_name in task_list:
        task_dir = os.path.join(save_path, task_name, args.task_config)
        seed_file = os.path.join(task_dir, "seed.txt")

        if not os.path.exists(seed_file):
            errors.append(f"{task_name}: seed.txt not found")
            continue

        with open(seed_file, "r") as f:
            seeds = [int(s) for s in f.read().split() if s.strip()]

        if len(seeds) < episode_num:
            errors.append(f"{task_name}: only {len(seeds)}/{episode_num} seeds")
            continue

        queue_file = os.path.join(queue_dir, f"{task_name}.json")

        # 如果队列文件已存在，检查是否需要扩容
        if os.path.exists(queue_file):
            with open(queue_file, "r") as f:
                existing_queue = json.load(f)
            old_total = existing_queue["total_episodes"]
            if old_total >= episode_num:
                skipped += 1
                continue
            # 扩容：追加新 batch 覆盖 old_total ~ episode_num
            new_batches = []
            for start in range(old_total, episode_num, batch_size):
                end = min(start + batch_size, episode_num)
                new_batches.append({
                    "episodes": list(range(start, end)),
                    "status": "pending",
                    "worker": None,
                    "claimed_at": None,
                })
            existing_queue["batches"].extend(new_batches)
            existing_queue["total_episodes"] = episode_num
            with open(queue_file, "w") as f:
                json.dump(existing_queue, f, indent=2)
            created += 1
            print(f"[EXPAND] {task_name}: added {len(new_batches)} batches ({old_total}->{episode_num})")
            continue

        batches = []
        for start in range(0, episode_num, batch_size):
            end = min(start + batch_size, episode_num)
            batches.append({
                "episodes": list(range(start, end)),
                "status": "pending",
                "worker": None,
                "claimed_at": None,
            })

        queue_data = {
            "task_name": task_name,
            "task_config": args.task_config,
            "total_episodes": episode_num,
            "batches": batches,
        }

        with open(queue_file, "w") as f:
            json.dump(queue_data, f, indent=2)

        created += 1
        print(f"[OK] {task_name}: {len(batches)} batches")

    if errors:
        print("\n[ERRORS]")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    else:
        print(f"\nQueue: {created} created, {skipped} already existed (preserved). "
              f"{episode_num // batch_size} batches per task.")


if __name__ == "__main__":
    main()
