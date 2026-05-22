#!/bin/bash

task_name=${1}
task_config=${2}
gpu_id=${3}
start_seed=${4}

./script/.update_path.sh > /dev/null 2>&1

export CUDA_VISIBLE_DEVICES=${gpu_id}

SEED_ARG=""
if [ -n "$start_seed" ]; then
    SEED_ARG="--start-seed $start_seed"
fi

PYTHONWARNINGS=ignore::UserWarning \
python script/collect_data.py $task_name $task_config $SEED_ARG
rm -rf data/${task_name}/${task_config}/.cache
