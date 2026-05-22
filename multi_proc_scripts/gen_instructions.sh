#!/bin/bash
# 合并 scene_info 并生成 instruction
# 用法: bash multi_proc_scripts/gen_instructions.sh <task_name> [task_config] [language_num] [--dry-run]

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ] || [ "$arg" = "-n" ]; then
        DRY_RUN=1
    else
        POSITIONAL+=("$arg")
    fi
done

TASK_NAME=${POSITIONAL[0]:?Usage: bash multi_proc_scripts/gen_instructions.sh <task_name> [task_config] [language_num] [--dry-run]}
TASK_CONFIG=${POSITIONAL[1]:-demo_clean}
LANGUAGE_NUM=${POSITIONAL[2]:-10}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$SAVE_PATH" ]; then
    SAVE_PATH=$(python3 -c "
import yaml
with open('${PROJECT_DIR}/task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")
fi

TASK_DIR="${SAVE_PATH}/${TASK_NAME}/${TASK_CONFIG}"
SCENE_DIR="${TASK_DIR}/_scene_info"
SCENE_JSON="${TASK_DIR}/scene_info.json"
VIDEO_DIR="${TASK_DIR}/video"
DATA_DIR="${TASK_DIR}/data"

echo "Task: $TASK_NAME, Config: $TASK_CONFIG"
echo "Path: $TASK_DIR"
if [ $DRY_RUN -eq 1 ]; then
    echo "Mode: DRY RUN (scan only)"
fi

# 合并 _scene_info/*.json → scene_info.json
if [ -d "$SCENE_DIR" ]; then
    if [ $DRY_RUN -eq 0 ]; then
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
print(f'Merged {len(db)} entries into scene_info.json')
"
    else
        echo "Would merge _scene_info/*.json -> scene_info.json"
    fi
else
    echo "No _scene_info directory, using existing scene_info.json"
fi

# 检查 scene_info 与 video/data 的一致性
CHECK_RESULT=$(python3 -c "
import os, json, sys

scene_json = '${SCENE_JSON}'
video_dir = '${VIDEO_DIR}'
data_dir = '${DATA_DIR}'

if not os.path.exists(scene_json):
    print('[ERROR] scene_info.json not found')
    sys.exit(1)

with open(scene_json) as f:
    scene_data = json.load(f)

scene_ids = set()
for key in scene_data:
    scene_ids.add(key.replace('episode_', ''))

# 检查 video
video_ids = set()
if os.path.isdir(video_dir):
    for f in os.listdir(video_dir):
        if f.startswith('episode') and f.endswith('.mp4'):
            video_ids.add(f.replace('episode', '').replace('.mp4', ''))

# 检查 data (hdf5)
data_ids = set()
if os.path.isdir(data_dir):
    for f in os.listdir(data_dir):
        if f.startswith('episode') and f.endswith('.hdf5'):
            data_ids.add(f.replace('episode', '').replace('.hdf5', ''))

errors = 0

# scene_info 有但 video 没有
missing_video = scene_ids - video_ids
if missing_video:
    samples = sorted(missing_video)[:10]
    print(f'[ERROR] {len(missing_video)} scene entries without video: {samples}')
    errors += len(missing_video)

# scene_info 有但 data 没有
missing_data = scene_ids - data_ids
if missing_data:
    samples = sorted(missing_data)[:10]
    print(f'[ERROR] {len(missing_data)} scene entries without hdf5: {samples}')
    errors += len(missing_data)

# video 有但 scene_info 没有
extra_video = video_ids - scene_ids
if extra_video:
    samples = sorted(extra_video)[:10]
    print(f'[WARN] {len(extra_video)} videos without scene_info: {samples}')

# data 有但 scene_info 没有
extra_data = data_ids - scene_ids
if extra_data:
    samples = sorted(extra_data)[:10]
    print(f'[WARN] {len(extra_data)} hdf5 without scene_info: {samples}')

print(f'Scene: {len(scene_ids)}, Videos: {len(video_ids)}, HDF5: {len(data_ids)}')
if errors == 0 and not extra_video and not extra_data:
    print('[OK] All files match.')

sys.exit(1 if errors > 0 else 0)
")
CHECK_EXIT=$?
echo "$CHECK_RESULT"

if [ $DRY_RUN -eq 1 ]; then
    echo ""
    echo "Dry run complete. No files were modified."
    exit $CHECK_EXIT
fi

if [ $CHECK_EXIT -ne 0 ]; then
    echo ""
    echo "[ABORT] File consistency errors detected. Fix missing files before generating instructions."
    exit 1
fi

# 生成 instruction
echo "Generating instructions (language_num=$LANGUAGE_NUM)..."
python3 "${PROJECT_DIR}/description/utils/generate_episode_instructions.py" \
    "$TASK_NAME" "$TASK_CONFIG" "$LANGUAGE_NUM" \
    --save_path "$SAVE_PATH" \
    --project_dir "$PROJECT_DIR"
echo "Done."
