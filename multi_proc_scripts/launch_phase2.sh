#!/bin/bash
# Phase 2 集群启动入口（含队列初始化）
# 每个节点通过 $RANK 环境变量获取 machine-id
# Node 0 负责初始化队列，其他节点等待队列就绪后开始渲染。
#
# 用法（每个节点执行同一条命令即可）:
#   bash multi_proc_scripts/launch_phase2.sh
#
# 环境变量:
#   RANK: 节点编号 (0-19)
#   NUM_MACHINES: 总节点数 (默认 1)
#   TASK_CONFIG: 任务配置 (默认 demo_clean)
#   NUM_GPUS: GPU 数量 (默认 1)
#   NUM_WORKER_PER_GPU: 每 GPU 进程数 (默认 2)
#   BATCH_SIZE: 每个 batch 的 episode 数 (默认 5)
#   TASK_FILTER: 逗号分隔的 task 名，只处理指定 task (默认全部)
#   TASK_EXCLUDE: 逗号分隔的 task 名，排除指定 task (默认无)

set -eo pipefail

MACHINE_ID=${RANK:?ERROR: RANK environment variable not set}
NUM_MACHINES=${NUM_MACHINES:-1}
TASK_CONFIG=${TASK_CONFIG:-demo_clean}
NUM_GPUS=${NUM_GPUS:-1}
NUM_WORKER_PER_GPU=${NUM_WORKER_PER_GPU:-2}
BATCH_SIZE=${BATCH_SIZE:-5}
TASK_FILTER=${TASK_FILTER:-}
TASK_EXCLUDE=${TASK_EXCLUDE:-}

SAVE_PATH=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")

LOG_DIR="${SAVE_PATH}/_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/phase2_node_${MACHINE_ID}.log"

log() {
    echo "[Node $MACHINE_ID] $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log "=== Phase 2 pipeline started ==="
log "Config: ${TASK_CONFIG}, GPUs: ${NUM_GPUS}, Workers/GPU: ${NUM_WORKER_PER_GPU}, Machines: ${NUM_MACHINES}"

# ============ Queue Init (Node 0 only) ============
QUEUE_DIR="${SAVE_PATH}/_queue"

if [ "$MACHINE_ID" -eq 0 ]; then
    log "Initializing Phase 2 queue..."
    QUEUE_ARGS="--task-config $TASK_CONFIG --batch-size $BATCH_SIZE"
    [ -n "$TASK_FILTER" ] && QUEUE_ARGS="$QUEUE_ARGS --task-filter $TASK_FILTER"
    [ -n "$TASK_EXCLUDE" ] && QUEUE_ARGS="$QUEUE_ARGS --task-exclude $TASK_EXCLUDE"
    python multi_proc_scripts/init_queue.py $QUEUE_ARGS 2>&1 | tee -a "$LOG_FILE"

    # Reset stale/processing batches so they can be reclaimed immediately
    log "Resetting processing batches..."
    python3 -c "
import json, glob, os
queue_dir = '${QUEUE_DIR}'
for qf in glob.glob(os.path.join(queue_dir, '*.json')):
    with open(qf) as f:
        q = json.load(f)
    changed = False
    for b in q['batches']:
        if b['status'] == 'processing':
            b['status'] = 'pending'
            b['worker'] = None
            b['claimed_at'] = None
            changed = True
    if changed:
        with open(qf, 'w') as f:
            json.dump(q, f, indent=2)
        print(f'Reset: {os.path.basename(qf)}')
" 2>&1 | tee -a "$LOG_FILE"

    touch "${QUEUE_DIR}/_ready"
    log "Queue initialized."
else
    log "Waiting for Node 0 to init queue..."
    while [ ! -f "${QUEUE_DIR}/_ready" ]; do
        sleep 3
    done
    log "Queue ready."
fi

# ============ Phase 2: Rendering ============
log "Starting rendering workers..."

PHASE2_ARGS="--machine-id $MACHINE_ID --task-config $TASK_CONFIG --num-gpus $NUM_GPUS --num-worker-per-gpu $NUM_WORKER_PER_GPU"
[ -n "$TASK_FILTER" ] && PHASE2_ARGS="$PHASE2_ARGS --task-filter $TASK_FILTER"
[ -n "$TASK_EXCLUDE" ] && PHASE2_ARGS="$PHASE2_ARGS --task-exclude $TASK_EXCLUDE"

bash multi_proc_scripts/run_phase2.sh $PHASE2_ARGS 2>&1 | tee -a "$LOG_FILE"

log "=== Phase 2 pipeline complete ==="
