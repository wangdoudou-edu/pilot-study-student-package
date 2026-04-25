#!/usr/bin/env bash
set -euo pipefail

PARTICIPANT_ID="${1:-}"

if [[ -z "$PARTICIPANT_ID" ]]; then
  echo "Usage: bash setup_pilot_project.sh P01"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/学生项目模板"
RUNS_DIR="${PILOT_RUNS_DIR:-$HOME/Desktop/AIMind_Pilot_Runs}"
TARGET_DIR="$RUNS_DIR/${PARTICIPANT_ID}_任务文件夹"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  echo "Template not found: $TEMPLATE_DIR"
  exit 1
fi

if [[ -e "$TARGET_DIR" ]]; then
  echo "Target already exists: $TARGET_DIR"
  echo "Please move or rename it first."
  exit 1
fi

mkdir -p "$RUNS_DIR"
rsync -a --exclude '.DS_Store' "$TEMPLATE_DIR/" "$TARGET_DIR/"

echo "Created: $TARGET_DIR"
echo ""
echo "Next:"
echo "1. Open this folder in Codex: $TARGET_DIR"
echo "2. Start with:"
echo "   你好，我的编号是 ${PARTICIPANT_ID}，现在我要开始今天的任务了。请先阅读当前项目文件夹，告诉我里面有哪些文件。"
echo "3. After the student says the task is finished, finalize the session with:"
echo "   bash \"$SCRIPT_DIR/finalize_pilot_session.sh\" ${PARTICIPANT_ID}"
