#!/bin/bash
# Phase 2 集群启动入口
# 每个节点通过 $RANK 环境变量获取 machine-id
# 用法（每个节点执行同一条命令即可）:
#   bash multi_proc_scripts/launch_phase2.sh
#
# 环境变量:
#   RANK: 节点编号 (0-19)
#   TASK_CONFIG: 任务配置 (默认 demo_clean)
#   NUM_GPUS: GPU 数量 (默认 8)

set -e

MACHINE_ID=${RANK:?ERROR: RANK environment variable not set}
TASK_CONFIG=${TASK_CONFIG:-demo_clean}
NUM_GPUS=${NUM_GPUS:-8}

LOG_DIR="/mnt/60t_data/arena-sim-data1/_logs/phase2"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/node_${MACHINE_ID}.log"

echo "[Node $MACHINE_ID] Phase 2 started at $(date)" | tee "$LOG_FILE"

bash multi_proc_scripts/run_phase2.sh \
    --machine-id "$MACHINE_ID" \
    --task-config "$TASK_CONFIG" \
    --num-gpus "$NUM_GPUS" \
    2>&1 | tee -a "$LOG_FILE"

echo "[Node $MACHINE_ID] Phase 2 finished at $(date)" | tee -a "$LOG_FILE"
