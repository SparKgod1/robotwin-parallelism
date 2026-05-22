#!/bin/bash
# 全流程统一启动脚本
# 所有节点运行同一条命令，通过 $RANK 环境变量区分节点
# 自动完成: Phase 1 → 队列初始化 → Phase 2 → 后处理
#
# 用法（每个节点执行同一条命令即可）:
#   bash multi_proc_scripts/run_all.sh
#
# 环境变量:
#   RANK: 节点编号 (0-19)，必须设置
#   NUM_MACHINES: 总节点数 (默认 20)
#   NUM_WORKER_PER_GPU: 每 GPU 进程数 (默认 4)
#   TASK_CONFIG: 任务配置 (默认 demo_clean)
#   NUM_GPUS: GPU 数量 (默认 8)
#   BATCH_SIZE: Phase 2 每个 batch 的 episode 数 (默认 200)

set -e

MACHINE_ID=${RANK:?ERROR: RANK environment variable not set}
NUM_MACHINES=${NUM_MACHINES:-20}
NUM_WORKER_PER_GPU=${NUM_WORKER_PER_GPU:-4}
TASK_CONFIG=${TASK_CONFIG:-demo_clean}
NUM_GPUS=${NUM_GPUS:-8}
BATCH_SIZE=${BATCH_SIZE:-200}

SAVE_PATH=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")

LOG_DIR="${SAVE_PATH}/_logs"
BARRIER_DIR="${SAVE_PATH}/_barrier"
mkdir -p "$LOG_DIR" "$BARRIER_DIR"

LOG_FILE="${LOG_DIR}/node_${MACHINE_ID}.log"

log() {
    echo "[Node $MACHINE_ID] $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

barrier_signal() {
    touch "${BARRIER_DIR}/${1}_node_${MACHINE_ID}"
}

barrier_wait() {
    local phase=$1
    log "Waiting for all $NUM_MACHINES nodes at barrier: $phase"
    while true; do
        local count=0
        for ((i=0; i<NUM_MACHINES; i++)); do
            [ -f "${BARRIER_DIR}/${phase}_node_${i}" ] && count=$((count + 1))
        done
        if [ "$count" -ge "$NUM_MACHINES" ]; then
            log "All nodes reached barrier: $phase"
            break
        fi
        sleep 10
    done
}

log "=== Full pipeline started ==="
log "Config: ${TASK_CONFIG}, GPUs: ${NUM_GPUS}, Workers/GPU: ${NUM_WORKER_PER_GPU}, Machines: ${NUM_MACHINES}"

# ============ Phase 1: Seed Collection ============
log "--- Phase 1: Seed Collection ---"

bash multi_proc_scripts/run_phase1.sh \
    --machine-id "$MACHINE_ID" \
    --num-worker-per-gpu "$NUM_WORKER_PER_GPU" \
    --task-config "$TASK_CONFIG" \
    --num-gpus "$NUM_GPUS" \
    2>&1 | tee -a "$LOG_FILE"

barrier_signal "phase1"
barrier_wait "phase1"

# ============ Queue Init (Node 0 only) ============
if [ "$MACHINE_ID" -eq 0 ]; then
    log "--- Initializing Phase 2 queue ---"
    python multi_proc_scripts/init_queue.py --task-config "$TASK_CONFIG" --batch-size "$BATCH_SIZE" 2>&1 | tee -a "$LOG_FILE"
    barrier_signal "queue_init"
else
    log "Waiting for Node 0 to init queue..."
    while [ ! -f "${BARRIER_DIR}/queue_init_node_0" ]; do
        sleep 5
    done
    log "Queue ready."
fi

# ============ Phase 2: Rendering ============
log "--- Phase 2: Rendering ---"

bash multi_proc_scripts/run_phase2.sh \
    --machine-id "$MACHINE_ID" \
    --task-config "$TASK_CONFIG" \
    --num-gpus "$NUM_GPUS" \
    --num-worker-per-gpu "$NUM_WORKER_PER_GPU" \
    2>&1 | tee -a "$LOG_FILE"

barrier_signal "phase2"
barrier_wait "phase2"

# ============ Finalize (Node 0 only) ============
if [ "$MACHINE_ID" -eq 0 ]; then
    log "--- Finalization ---"
    bash multi_proc_scripts/finalize_tasks.sh "$TASK_CONFIG" 2>&1 | tee -a "$LOG_FILE"
    rm -rf "$BARRIER_DIR"
    log "Barrier files cleaned."
fi

log "=== Pipeline complete ==="
