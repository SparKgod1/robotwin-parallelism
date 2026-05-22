#!/bin/bash
# Phase 2 完成后的后处理脚本
# 为每个 task 运行 gen_episode_instructions.sh
# 用法: bash multi_proc_scripts/finalize_tasks.sh [--task-config demo_clean]

TASK_CONFIG=${1:-demo_clean}
shift || true
TASK_FILTER=""
TASK_EXCLUDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --task-filter) TASK_FILTER="$2"; shift 2 ;;
        --task-exclude) TASK_EXCLUDE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

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

# 如果指定了 TASK_FILTER，只处理匹配的 task
if [ -n "$TASK_FILTER" ]; then
    IFS=',' read -ra FILTER_LIST <<< "$TASK_FILTER"
    FILTERED=()
    for ft in "${FILTER_LIST[@]}"; do
        ft=$(echo "$ft" | xargs)
        for task in "${TASKS[@]}"; do
            [ "$task" = "$ft" ] && FILTERED+=("$task") && break
        done
    done
    TASKS=("${FILTERED[@]}")
fi

# 如果指定了 TASK_EXCLUDE，排除匹配的 task
if [ -n "$TASK_EXCLUDE" ]; then
    IFS=',' read -ra EXCLUDE_LIST <<< "$TASK_EXCLUDE"
    FILTERED=()
    for task in "${TASKS[@]}"; do
        EXCLUDED=false
        for ex in "${EXCLUDE_LIST[@]}"; do
            ex=$(echo "$ex" | xargs)
            [ "$task" = "$ex" ] && EXCLUDED=true && break
        done
        [ "$EXCLUDED" = false ] && FILTERED+=("$task")
    done
    TASKS=("${FILTERED[@]}")
fi

SAVE_PATH=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")

LANGUAGE_NUM=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f).get('language_num', 10))
")

echo "Merging scene_info and running gen_episode_instructions..."

for task in "${TASKS[@]}"; do
    echo "  Processing: $task"
    TASK_SAVE="${SAVE_PATH}/${task}/${TASK_CONFIG}"
    SCENE_DIR="${TASK_SAVE}/_scene_info"
    SCENE_JSON="${TASK_SAVE}/scene_info.json"

    # 合并 _scene_info/*.json → scene_info.json
    if [ -d "$SCENE_DIR" ]; then
        python3 -c "
import os, json, glob
scene_dir = '${SCENE_DIR}'
out_path = '${SCENE_JSON}'
db = {}
if os.path.exists(out_path):
    with open(out_path) as f:
        db = json.load(f)
for p in glob.glob(os.path.join(scene_dir, 'episode_*.json')):
    key = os.path.basename(p).replace('.json', '')
    with open(p) as f:
        db[key] = json.load(f)
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(db, f, ensure_ascii=False, indent=4)
print(f'    Merged {len(db)} entries into scene_info.json')
"
    fi

    (cd description && bash gen_episode_instructions.sh "$task" "$TASK_CONFIG" "$LANGUAGE_NUM")
    if [ $? -ne 0 ]; then
        echo "  [WARN] $task failed"
    fi
done

echo "Finalization complete."
