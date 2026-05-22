#!/bin/bash
# 从第 N 个 episode 往前渲染（跳过已有的）
# 用法: bash multi_proc_scripts/run_reverse.sh <task_name> <task_config> [--start 5999] [--end 0] [--gpu 0]

TASK_NAME=""
TASK_CONFIG="demo_clean"
START=5999
END=0
GPU=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START="$2"; shift 2 ;;
        --end) END="$2"; shift 2 ;;
        --gpu) GPU="$2"; shift 2 ;;
        *)
            if [ -z "$TASK_NAME" ]; then TASK_NAME="$1"
            elif [ "$TASK_CONFIG" = "demo_clean" ]; then TASK_CONFIG="$1"
            fi
            shift ;;
    esac
done

if [ -z "$TASK_NAME" ]; then
    echo "Usage: bash multi_proc_scripts/run_reverse.sh <task_name> [task_config] [--start 5999] [--end 0] [--gpu 0]"
    exit 1
fi

EPISODES=$(python3 -c "print(','.join(str(i) for i in range($START, $END - 1, -1)))")

echo "Task: $TASK_NAME, Config: $TASK_CONFIG"
echo "Episodes: $START -> $END ($(($START - $END + 1)) total)"
echo "GPU: $GPU"

CUDA_VISIBLE_DEVICES=$GPU python script/collect_data.py "$TASK_NAME" "$TASK_CONFIG" --phase 2 --episodes "$EPISODES"
