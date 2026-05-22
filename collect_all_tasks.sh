#!/bin/bash

GPUS=${1:-"0"}
NUM_WORKER_PER_GPU=${2:-1}
TASK_CONFIG=${3:-demo_clean}
START_SEED=${4:-1000000}

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

# Read save_path from config
SAVE_PATH=$(python3 -c "
import yaml
with open('./task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f).get('save_path', './data'))
")

CURRENT_SEED=$START_SEED

for task in "${TASKS[@]}"; do
    echo "========== [$task] (start_seed=$CURRENT_SEED) =========="
    bash collect_data.sh "$task" "$TASK_CONFIG" "$GPUS" "$NUM_WORKER_PER_GPU"
    if [ $? -ne 0 ]; then
        echo "[WARN] $task failed, continuing..."
    fi

    LAST_SEED_FILE="${SAVE_PATH}/${task}/${TASK_CONFIG}/.last_seed"
    if [ -f "$LAST_SEED_FILE" ]; then
        CURRENT_SEED=$(cat "$LAST_SEED_FILE")
    fi
    echo ""
done

echo "All tasks done."
