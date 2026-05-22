#!/bin/bash
# Phase 1 启动脚本（动态认领模式）
# 每个节点循环从 task 池中认领未完成的 task，直到所有 task 完成。
# 用法: bash multi_proc_scripts/run_phase1.sh --machine-id <0-19> [--num-worker-per-gpu 2] [--task-config demo_clean]

set -e

MACHINE_ID=""
NUM_WORKER_PER_GPU=2
TASK_CONFIG="demo_clean"
NUM_GPUS=8
TASK_FILTER=""
TASK_EXCLUDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --machine-id) MACHINE_ID="$2"; shift 2 ;;
        --num-worker-per-gpu) NUM_WORKER_PER_GPU="$2"; shift 2 ;;
        --task-config) TASK_CONFIG="$2"; shift 2 ;;
        --num-gpus) NUM_GPUS="$2"; shift 2 ;;
        --task-filter) TASK_FILTER="$2"; shift 2 ;;
        --task-exclude) TASK_EXCLUDE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MACHINE_ID" ]; then
    echo "Usage: bash multi_proc_scripts/run_phase1.sh --machine-id <0-19>"
    exit 1
fi

TASKS=(
    adjust_bottle
    beat_block_hammer
    blocks_ranking_rgb
    blocks_ranking_size
    click_alarmclock
    click_bell
    dump_bin_bigbin
    grab_roller
    handover_block
    handover_mic
    hanging_mug
    lift_pot
    move_can_pot
    move_pillbottle_pad
    move_playingcard_away
    move_stapler_pad
    open_laptop
    open_microwave
    pick_diverse_bottles
    pick_dual_bottles
    place_a2b_left
    place_a2b_right
    place_bread_basket
    place_bread_skillet
    place_burger_fries
    place_can_basket
    place_cans_plasticbox
    place_container_plate
    place_dual_shoes
    place_empty_cup
    place_fan
    place_mouse_pad
    place_object_basket
    place_object_scale
    place_object_stand
    place_phone_stand
    place_shoe
    press_stapler
    put_bottles_dustbin
    put_object_cabinet
    rotate_qrcode
    scan_object
    shake_bottle
    shake_bottle_horizontally
    stack_blocks_three
    stack_blocks_two
    stack_bowls_three
    stack_bowls_two
    stamp_seal
    turn_switch
)

TOTAL_TASKS=${#TASKS[@]}

# 如果指定了 TASK_FILTER，只保留匹配的 task
if [ -n "$TASK_FILTER" ]; then
    IFS=',' read -ra FILTER_LIST <<< "$TASK_FILTER"
    FILTERED_TASKS=()
    for ft in "${FILTER_LIST[@]}"; do
        ft=$(echo "$ft" | xargs)  # trim whitespace
        for task in "${TASKS[@]}"; do
            if [ "$task" = "$ft" ]; then
                FILTERED_TASKS+=("$task")
                break
            fi
        done
    done
    TASKS=("${FILTERED_TASKS[@]}")
    TOTAL_TASKS=${#TASKS[@]}
    echo "[Machine $MACHINE_ID] Task filter active: ${TASKS[*]} ($TOTAL_TASKS tasks)"
fi

# 如果指定了 TASK_EXCLUDE，排除匹配的 task
if [ -n "$TASK_EXCLUDE" ]; then
    IFS=',' read -ra EXCLUDE_LIST <<< "$TASK_EXCLUDE"
    FILTERED_TASKS=()
    for task in "${TASKS[@]}"; do
        EXCLUDED=false
        for ex in "${EXCLUDE_LIST[@]}"; do
            ex=$(echo "$ex" | xargs)
            if [ "$task" = "$ex" ]; then
                EXCLUDED=true
                break
            fi
        done
        [ "$EXCLUDED" = false ] && FILTERED_TASKS+=("$task")
    done
    TASKS=("${FILTERED_TASKS[@]}")
    TOTAL_TASKS=${#TASKS[@]}
    echo "[Machine $MACHINE_ID] Task exclude active: excluded ${TASK_EXCLUDE} ($TOTAL_TASKS tasks remaining)"
fi

echo "=========================================="
echo "[Machine $MACHINE_ID] Phase 1 (dynamic mode)"
echo "GPUs: $NUM_GPUS, Workers/GPU: $NUM_WORKER_PER_GPU"
echo "=========================================="

TOTAL_WORKERS=$((NUM_GPUS * NUM_WORKER_PER_GPU))

# Read episode_num, start_seed, save_path from config
read EPISODE_NUM START_SEED SAVE_PATH <<< $(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    c = yaml.safe_load(f)
    print(c['episode_num'], c.get('start_seed', 0), c['save_path'])
")

CLAIM_DIR="${SAVE_PATH}/_phase1_claims"
mkdir -p "$CLAIM_DIR"

# 启动时清理未完成 task 的 stale claim（上次中断残留）
for ((t=0; t<TOTAL_TASKS; t++)); do
    TASK=${TASKS[$t]}
    TASK_DIR="${SAVE_PATH}/${TASK}/${TASK_CONFIG}"
    CLAIM_FILE="${CLAIM_DIR}/${TASK}.lock"
    if [ -d "$CLAIM_FILE" ]; then
        # task 已完成则清理 claim
        if [ -f "${TASK_DIR}/seed.txt" ]; then
            EXISTING_SEEDS=$(wc -w < "${TASK_DIR}/seed.txt")
            if [ "$EXISTING_SEEDS" -ge "$EPISODE_NUM" ]; then
                rm -rf "$CLAIM_FILE"
                continue
            fi
        fi
        # task 未完成且 claim 存在 → 上次中断残留，清理以允许重新认领
        if [ -f "${CLAIM_FILE}/owner" ]; then
            CLAIM_AGE=$(( $(date +%s) - $(stat -c %Y "${CLAIM_FILE}/owner") ))
            if [ "$CLAIM_AGE" -gt 300 ]; then
                echo "[Machine $MACHINE_ID] Cleaning stale claim: $TASK (age: ${CLAIM_AGE}s)"
                rm -rf "$CLAIM_FILE"
            fi
        fi
    fi
done

COMPLETED_COUNT=0

while true; do
    CLAIMED_TASK=""

    for ((t=0; t<TOTAL_TASKS; t++)); do
        TASK=${TASKS[$t]}
        TASK_DIR="${SAVE_PATH}/${TASK}/${TASK_CONFIG}"

        # 已完成：seed.txt 够数
        if [ -f "${TASK_DIR}/seed.txt" ]; then
            EXISTING_SEEDS=$(wc -w < "${TASK_DIR}/seed.txt")
            if [ "$EXISTING_SEEDS" -ge "$EPISODE_NUM" ]; then
                continue
            fi
        fi

        # 尝试认领：mkdir 是原子操作（NFS safe）
        CLAIM_FILE="${CLAIM_DIR}/${TASK}.lock"
        if mkdir "$CLAIM_FILE" 2>/dev/null; then
            # 认领成功，写入机器信息
            echo "machine_${MACHINE_ID} $(date '+%Y-%m-%d %H:%M:%S')" > "${CLAIM_FILE}/owner"
            CLAIMED_TASK="$TASK"
            break
        fi

        # 认领失败，检查是否是 stale claim（超过 2 小时）
        if [ -f "${CLAIM_FILE}/owner" ]; then
            CLAIM_AGE=$(( $(date +%s) - $(stat -c %Y "${CLAIM_FILE}/owner") ))
            if [ "$CLAIM_AGE" -gt 7200 ]; then
                echo "[Machine $MACHINE_ID] Reclaiming stale task: $TASK (age: ${CLAIM_AGE}s)"
                echo "machine_${MACHINE_ID} $(date '+%Y-%m-%d %H:%M:%S') (reclaimed)" > "${CLAIM_FILE}/owner"
                CLAIMED_TASK="$TASK"
                break
            fi
        fi
    done

    # 没有可认领的 task
    if [ -z "$CLAIMED_TASK" ]; then
        # 检查是否所有 task 都已完成
        ALL_DONE=true
        for ((t=0; t<TOTAL_TASKS; t++)); do
            TASK=${TASKS[$t]}
            TASK_DIR="${SAVE_PATH}/${TASK}/${TASK_CONFIG}"
            if [ ! -f "${TASK_DIR}/seed.txt" ]; then
                ALL_DONE=false
                break
            fi
            EXISTING_SEEDS=$(wc -w < "${TASK_DIR}/seed.txt")
            if [ "$EXISTING_SEEDS" -lt "$EPISODE_NUM" ]; then
                ALL_DONE=false
                break
            fi
        done

        if [ "$ALL_DONE" = true ]; then
            echo "[Machine $MACHINE_ID] All tasks complete!"
            break
        fi

        # 还有 task 在被其他节点处理，等待
        echo "[Machine $MACHINE_ID] No available tasks, waiting... (completed $COMPLETED_COUNT so far)"
        sleep 30
        continue
    fi

    # 执行认领到的 task
    TASK="$CLAIMED_TASK"
    TASK_DIR="${SAVE_PATH}/${TASK}/${TASK_CONFIG}"
    echo ""
    echo "========== [Machine $MACHINE_ID] Claimed: $TASK =========="

    # 断点续传：如果有未合并的 _worker_* 目录，检查是否可以直接 merge
    WORKER_DIR_COUNT=$(find "${TASK_DIR}" -maxdepth 1 -name "_worker_*" -type d 2>/dev/null | wc -l)
    if [ "$WORKER_DIR_COUNT" -gt 0 ]; then
        ALL_WORKERS_DONE=true
        for ((wid=0; wid<TOTAL_WORKERS; wid++)); do
            WD="${TASK_DIR}/_worker_${wid}"
            if [ ! -d "$WD" ] || [ ! -f "${WD}/seeds.txt" ]; then
                ALL_WORKERS_DONE=false
                break
            fi
            W_BASE=$((EPISODE_NUM / TOTAL_WORKERS))
            W_REM=$((EPISODE_NUM % TOTAL_WORKERS))
            if [ "$wid" -lt "$W_REM" ]; then
                W_TARGET=$((W_BASE + 1))
            else
                W_TARGET=$W_BASE
            fi
            W_DONE=$(wc -w < "${WD}/seeds.txt")
            if [ "$W_DONE" -lt "$W_TARGET" ]; then
                ALL_WORKERS_DONE=false
                break
            fi
        done

        if [ "$ALL_WORKERS_DONE" = true ]; then
            echo "[Machine $MACHINE_ID] $TASK: all workers already complete, merging..."
            python multi_proc_scripts/merge_seeds.py "$TASK" "$TASK_CONFIG" || {
                echo "[ERROR] $TASK: merge failed"
                rm -rf "${CLAIM_DIR}/${TASK}.lock"
                continue
            }
            echo "[Machine $MACHINE_ID] $TASK merged."
            COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
            continue
        else
            echo "[Machine $MACHINE_ID] $TASK: resuming incomplete workers..."
        fi
    fi

    # 启动 workers
    PIDS=()
    WORKER_ID=0

    for ((gpu=0; gpu<NUM_GPUS; gpu++)); do
        for ((w=0; w<NUM_WORKER_PER_GPU; w++)); do
            BASE_EPISODES=$((EPISODE_NUM / TOTAL_WORKERS))
            REMAINDER=$((EPISODE_NUM % TOTAL_WORKERS))
            if [ "$WORKER_ID" -lt "$REMAINDER" ]; then
                WORKER_EPISODES=$((BASE_EPISODES + 1))
            else
                WORKER_EPISODES=$BASE_EPISODES
            fi

            SEED_START_W=$((START_SEED + WORKER_ID * 100000))

            CUDA_VISIBLE_DEVICES=$gpu PYTHONWARNINGS=ignore::UserWarning \
            python multi_proc_scripts/phase1_worker.py \
                "$TASK" "$TASK_CONFIG" \
                --worker-id $WORKER_ID \
                --num-workers $TOTAL_WORKERS \
                --episodes $WORKER_EPISODES \
                --seed-start $SEED_START_W &
            PIDS+=($!)
            WORKER_ID=$((WORKER_ID + 1))
        done
    done

    # 等待所有 worker 完成
    FAILED=0
    for pid in "${PIDS[@]}"; do
        wait $pid || FAILED=$((FAILED + 1))
    done

    if [ "$FAILED" -gt 0 ]; then
        echo "[WARN] $TASK: $FAILED workers failed"
    fi

    # 合并
    echo "[Machine $MACHINE_ID] Merging results for $TASK..."
    python multi_proc_scripts/merge_seeds.py "$TASK" "$TASK_CONFIG" || {
        echo "[ERROR] $TASK: merge_seeds.py failed"
        rm -rf "${CLAIM_DIR}/${TASK}.lock"
        continue
    }

    COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
    echo "[Machine $MACHINE_ID] $TASK done. (total completed: $COMPLETED_COUNT)"
done

echo ""
echo "=========================================="
echo "[Machine $MACHINE_ID] Phase 1 complete. Completed $COMPLETED_COUNT tasks."
echo "=========================================="
