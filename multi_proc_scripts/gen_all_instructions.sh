#!/bin/bash
# 批量处理 SAVE_PATH 下所有任务的 scene_info 合并 + instruction 生成
# 用法: SAVE_PATH=/media/ubuntu/T9/lx/robotwin_data bash multi_proc_scripts/gen_all_instructions.sh [task_config] [language_num]
# 也可以: bash multi_proc_scripts/gen_all_instructions.sh [task_config] [language_num] (从 config 读 save_path)

TASK_CONFIG=${1:-demo_clean}
LANGUAGE_NUM=${2:-10}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$SAVE_PATH" ]; then
    SAVE_PATH=$(python3 -c "
import yaml
with open('${PROJECT_DIR}/task_config/${TASK_CONFIG}.yml') as f:
    print(yaml.safe_load(f)['save_path'])
")
fi

echo "=== Batch processing all tasks ==="
echo "SAVE_PATH: $SAVE_PATH"
echo "Config: $TASK_CONFIG, language_num: $LANGUAGE_NUM"
echo ""

TOTAL=0
SUCCESS=0
SKIP=0

for TASK_DIR in "$SAVE_PATH"/*/; do
    TASK_NAME=$(basename "$TASK_DIR")

    # 跳过不含 config 子目录的
    if [ ! -d "$TASK_DIR/$TASK_CONFIG" ]; then
        continue
    fi

    CONFIG_DIR="$TASK_DIR/$TASK_CONFIG"

    # 必须有 _scene_info/ 或 scene_info.json
    if [ ! -d "$CONFIG_DIR/_scene_info" ] && [ ! -f "$CONFIG_DIR/scene_info.json" ]; then
        echo "[$TASK_NAME] SKIP: no _scene_info/ or scene_info.json"
        SKIP=$((SKIP + 1))
        continue
    fi

    # 必须有对应的 task_instruction 模板
    if [ ! -f "$PROJECT_DIR/description/task_instruction/${TASK_NAME}.json" ]; then
        echo "[$TASK_NAME] SKIP: no task_instruction template"
        SKIP=$((SKIP + 1))
        continue
    fi

    TOTAL=$((TOTAL + 1))
    echo "--- [$TASK_NAME] ---"
    SAVE_PATH="$SAVE_PATH" bash "$SCRIPT_DIR/gen_instructions.sh" "$TASK_NAME" "$TASK_CONFIG" "$LANGUAGE_NUM"

    if [ $? -eq 0 ]; then
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  [ERROR] Failed for $TASK_NAME"
    fi
    echo ""
done

echo "=== Summary ==="
echo "Processed: $TOTAL, Success: $SUCCESS, Skipped: $SKIP"
