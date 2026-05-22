#!/bin/bash
# 全流程统一启动脚本
# 所有节点运行同一条命令，通过 $RANK 环境变量区分节点
# 用法（每个节点执行同一条命令即可）:
#   bash multi_proc_scripts/launch_all.sh
#
# 环境变量:
#   RANK: 节点编号 (0-19)，必须设置
#   NUM_MACHINES: 总节点数 (默认 20)
#   NUM_WORKER_PER_GPU: 每 GPU 进程数 (默认 4)
#   TASK_CONFIG: 任务配置 (默认 demo_clean)
#   NUM_GPUS: GPU 数量 (默认 8)
#   BATCH_SIZE: Phase 2 每个 batch 的 episode 数 (默认 200)
#   TASK_FILTER: 逗号分隔的 task 名，只处理指定 task (默认全部)
#   TASK_EXCLUDE: 逗号分隔的 task 名，排除指定 task (默认无)
#   CLUSTER_ID: 集群标识，多集群共享存储时用于隔离 barrier (默认无)

set -eo pipefail

MACHINE_ID=${RANK:?ERROR: RANK environment variable not set}
NUM_MACHINES=${NUM_MACHINES:-1}
NUM_WORKER_PER_GPU=${NUM_WORKER_PER_GPU:-2}
TASK_CONFIG=${TASK_CONFIG:-demo_clean}
NUM_GPUS=${NUM_GPUS:-1}
BATCH_SIZE=${BATCH_SIZE:-5}
TASK_FILTER=${TASK_FILTER:-}
TASK_EXCLUDE=${TASK_EXCLUDE:-}
CLUSTER_ID=${CLUSTER_ID:-}

SAVE_PATH=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")

LOG_DIR="${SAVE_PATH}/_logs"
if [ -n "$CLUSTER_ID" ]; then
    BARRIER_DIR="${SAVE_PATH}/_barrier_${CLUSTER_ID}"
else
    BARRIER_DIR="${SAVE_PATH}/_barrier"
fi
mkdir -p "$LOG_DIR"
# 用时间戳作为 run ID，区分新旧 barrier
RUN_ID="$$_$(date +%s)"
if [ "$MACHINE_ID" -eq 0 ]; then
    rm -rf "$BARRIER_DIR"
    mkdir -p "$BARRIER_DIR"
    echo "$RUN_ID" > "${BARRIER_DIR}/_run_id"
else
    # 等待 Node 0 创建新的 _run_id（说明清理完成）
    while true; do
        if [ -f "${BARRIER_DIR}/_run_id" ]; then
            # 确认是新文件（创建时间在最近 60 秒内）
            FILE_AGE=$(( $(date +%s) - $(stat -c %Y "${BARRIER_DIR}/_run_id" 2>/dev/null || echo 0) ))
            if [ "$FILE_AGE" -lt 60 ]; then
                break
            fi
        fi
        sleep 2
    done
fi

if [ -n "$CLUSTER_ID" ]; then
    LOG_FILE="${LOG_DIR}/${CLUSTER_ID}_node_${MACHINE_ID}.log"
else
    LOG_FILE="${LOG_DIR}/node_${MACHINE_ID}.log"
fi

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

PHASE1_ARGS="--machine-id $MACHINE_ID --num-worker-per-gpu $NUM_WORKER_PER_GPU --task-config $TASK_CONFIG --num-gpus $NUM_GPUS"
[ -n "$TASK_FILTER" ] && PHASE1_ARGS="$PHASE1_ARGS --task-filter $TASK_FILTER"
[ -n "$TASK_EXCLUDE" ] && PHASE1_ARGS="$PHASE1_ARGS --task-exclude $TASK_EXCLUDE"

bash multi_proc_scripts/run_phase1.sh $PHASE1_ARGS 2>&1 | tee -a "$LOG_FILE"

barrier_signal "phase1"
barrier_wait "phase1"

# ============ Queue Init (Node 0 only) ============
if [ "$MACHINE_ID" -eq 0 ]; then
    log "--- Initializing Phase 2 queue ---"
    QUEUE_ARGS="--task-config $TASK_CONFIG --batch-size $BATCH_SIZE"
    [ -n "$TASK_FILTER" ] && QUEUE_ARGS="$QUEUE_ARGS --task-filter $TASK_FILTER"
    [ -n "$TASK_EXCLUDE" ] && QUEUE_ARGS="$QUEUE_ARGS --task-exclude $TASK_EXCLUDE"
    python multi_proc_scripts/init_queue.py $QUEUE_ARGS 2>&1 | tee -a "$LOG_FILE"
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

PHASE2_ARGS="--machine-id $MACHINE_ID --task-config $TASK_CONFIG --num-gpus $NUM_GPUS --num-worker-per-gpu $NUM_WORKER_PER_GPU"
[ -n "$TASK_FILTER" ] && PHASE2_ARGS="$PHASE2_ARGS --task-filter $TASK_FILTER"
[ -n "$TASK_EXCLUDE" ] && PHASE2_ARGS="$PHASE2_ARGS --task-exclude $TASK_EXCLUDE"

bash multi_proc_scripts/run_phase2.sh $PHASE2_ARGS 2>&1 | tee -a "$LOG_FILE"

barrier_signal "phase2"
barrier_wait "phase2"

# ============ Finalize (Node 0 only) ============
if [ "$MACHINE_ID" -eq 0 ]; then
    log "--- Finalization ---"
    FINALIZE_ARGS="$TASK_CONFIG"
    [ -n "$TASK_FILTER" ] && FINALIZE_ARGS="$FINALIZE_ARGS --task-filter $TASK_FILTER"
    [ -n "$TASK_EXCLUDE" ] && FINALIZE_ARGS="$FINALIZE_ARGS --task-exclude $TASK_EXCLUDE"
    bash multi_proc_scripts/finalize_tasks.sh $FINALIZE_ARGS 2>&1 | tee -a "$LOG_FILE"
    rm -rf "$BARRIER_DIR"
    log "Barrier files cleaned."
fi

log "=== Pipeline complete ==="
