#!/bin/bash
# Phase 2 启动脚本
# 用法: bash multi_proc_scripts/run_phase2.sh --machine-id <0-19> [--task-config demo_clean] [--num-worker-per-gpu 4]

set -e

MACHINE_ID=""
TASK_CONFIG="demo_clean"
NUM_GPUS=8
NUM_WORKER_PER_GPU=4
TASK_FILTER=""
TASK_EXCLUDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --machine-id) MACHINE_ID="$2"; shift 2 ;;
        --task-config) TASK_CONFIG="$2"; shift 2 ;;
        --num-gpus) NUM_GPUS="$2"; shift 2 ;;
        --num-worker-per-gpu) NUM_WORKER_PER_GPU="$2"; shift 2 ;;
        --task-filter) TASK_FILTER="$2"; shift 2 ;;
        --task-exclude) TASK_EXCLUDE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MACHINE_ID" ]; then
    echo "Usage: bash multi_proc_scripts/run_phase2.sh --machine-id <0-19>"
    exit 1
fi

TOTAL_WORKERS=$((NUM_GPUS * NUM_WORKER_PER_GPU))

echo "=========================================="
echo "[Machine $MACHINE_ID] Phase 2 - Rendering"
echo "GPUs: $NUM_GPUS, Workers/GPU: $NUM_WORKER_PER_GPU, Total: $TOTAL_WORKERS"
echo "=========================================="

FILTER_ARGS=""
[ -n "$TASK_FILTER" ] && FILTER_ARGS="$FILTER_ARGS --task-filter $TASK_FILTER"
[ -n "$TASK_EXCLUDE" ] && FILTER_ARGS="$FILTER_ARGS --task-exclude $TASK_EXCLUDE"

PIDS=()

for ((gpu=0; gpu<NUM_GPUS; gpu++)); do
    for ((w=0; w<NUM_WORKER_PER_GPU; w++)); do
        WORKER_ID="machine${MACHINE_ID}_gpu${gpu}_w${w}"
        CUDA_VISIBLE_DEVICES=$gpu PYTHONWARNINGS=ignore::UserWarning \
        python multi_proc_scripts/phase2_worker.py \
            --worker-id "$WORKER_ID" \
            --task-config "$TASK_CONFIG" $FILTER_ARGS &
        PIDS+=($!)
    done
done

FAILED=0
for pid in "${PIDS[@]}"; do
    wait $pid || FAILED=$((FAILED + 1))
done

echo ""
echo "=========================================="
echo "[Machine $MACHINE_ID] Phase 2 complete. ($FAILED workers had errors)"
echo "=========================================="
