#!/bin/bash
# 反序多进程渲染
# 用法: bash multi_proc_scripts/run_reverse_multi.sh <task_name> <task_config> --start 5999 --end 4000 --num-gpus 1 [--num-worker-per-gpu 1]

TASK_NAME=""
TASK_CONFIG="demo_clean"
START=5999
END=4000
NUM_GPUS=1
NUM_WORKER_PER_GPU=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START="$2"; shift 2 ;;
        --end) END="$2"; shift 2 ;;
        --num-gpus) NUM_GPUS="$2"; shift 2 ;;
        --num-worker-per-gpu) NUM_WORKER_PER_GPU="$2"; shift 2 ;;
        *)
            if [ -z "$TASK_NAME" ]; then TASK_NAME="$1"
            else TASK_CONFIG="$1"
            fi
            shift ;;
    esac
done

if [ -z "$TASK_NAME" ]; then
    echo "Usage: bash multi_proc_scripts/run_reverse_multi.sh <task_name> [task_config] --start 5999 --end 4000 --num-gpus 8"
    exit 1
fi

TOTAL_WORKERS=$((NUM_GPUS * NUM_WORKER_PER_GPU))
TOTAL_EPISODES=$((START - END + 1))

echo "Task: $TASK_NAME, Config: $TASK_CONFIG"
echo "Episodes: $START -> $END ($TOTAL_EPISODES total, reverse)"
echo "GPUs: $NUM_GPUS, Workers/GPU: $NUM_WORKER_PER_GPU, Total workers: $TOTAL_WORKERS"

PIDS=()
WORKER_ID=0

for ((gpu=0; gpu<NUM_GPUS; gpu++)); do
    for ((w=0; w<NUM_WORKER_PER_GPU; w++)); do
        CHUNK=$((TOTAL_EPISODES / TOTAL_WORKERS))
        REMAINDER=$((TOTAL_EPISODES % TOTAL_WORKERS))
        if [ "$WORKER_ID" -lt "$REMAINDER" ]; then
            CHUNK=$((CHUNK + 1))
            W_START=$((START - WORKER_ID * CHUNK))
        else
            W_START=$((START - REMAINDER * (CHUNK + 1) - (WORKER_ID - REMAINDER) * CHUNK))
        fi
        W_END=$((W_START - CHUNK + 1))

        EPISODES=$(python3 -c "print(','.join(str(i) for i in range($W_START, $W_END - 1, -1)))")

        echo "  Worker $WORKER_ID (GPU $gpu): episodes $W_START -> $W_END ($CHUNK eps)"
        CUDA_VISIBLE_DEVICES=$gpu python script/collect_data.py "$TASK_NAME" "$TASK_CONFIG" --phase 2 --episodes "$EPISODES" &
        PIDS+=($!)
        WORKER_ID=$((WORKER_ID + 1))
    done
done

echo ""
echo "All $TOTAL_WORKERS workers launched. Waiting..."

FAILED=0
for pid in "${PIDS[@]}"; do
    wait $pid || FAILED=$((FAILED + 1))
done

echo "Done. ($FAILED workers had errors)"
