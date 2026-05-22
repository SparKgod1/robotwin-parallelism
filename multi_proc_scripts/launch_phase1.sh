#!/bin/bash
# Phase 1 集群启动入口
# 每个节点通过 $RANK 环境变量获取 machine-id
# 用法（每个节点执行同一条命令即可）:
#   bash multi_proc_scripts/launch_phase1.sh
#
# 环境变量:
#   RANK: 节点编号 (0-19)
#   NUM_WORKER_PER_GPU: 每 GPU 进程数 (默认 2)
#   TASK_CONFIG: 任务配置 (默认 demo_clean)
#   NUM_GPUS: GPU 数量 (默认 8)

set -e

MACHINE_ID=${RANK:?ERROR: RANK environment variable not set}
NUM_WORKER_PER_GPU=${NUM_WORKER_PER_GPU:-4}
TASK_CONFIG=${TASK_CONFIG:-demo_clean}
NUM_GPUS=${NUM_GPUS:-8}

LOG_DIR="/mnt/workspace/wfm_data/code/robotwin/data/clean2000/_logs/phase1"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/node_${MACHINE_ID}.log"

echo "[Node $MACHINE_ID] Phase 1 started at $(date)" | tee "$LOG_FILE"
echo "[Node $MACHINE_ID] Config: ${TASK_CONFIG}, GPUs: ${NUM_GPUS}, Workers/GPU: ${NUM_WORKER_PER_GPU}" | tee -a "$LOG_FILE"

bash multi_proc_scripts/run_phase1.sh \
    --machine-id "$MACHINE_ID" \
    --num-worker-per-gpu "$NUM_WORKER_PER_GPU" \
    --task-config "$TASK_CONFIG" \
    --num-gpus "$NUM_GPUS" \
    2>&1 | tee -a "$LOG_FILE"

echo "[Node $MACHINE_ID] Phase 1 finished at $(date)" | tee -a "$LOG_FILE"
