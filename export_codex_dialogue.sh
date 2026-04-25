#!/usr/bin/env bash
set -euo pipefail

PARTICIPANT_ID="${1:-}"

if [[ -z "$PARTICIPANT_ID" ]]; then
  echo "Usage: bash export_codex_dialogue.sh P01"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="${PILOT_RUNS_DIR:-$HOME/Desktop/AIMind_Pilot_Runs}"
PROJECT_DIR="$RUNS_DIR/${PARTICIPANT_ID}_任务文件夹"
OUT_DIR="$PROJECT_DIR/Codex对话记录"
OUT_FILE="$OUT_DIR/${PARTICIPANT_ID}_codex_dialogue.md"
EXPORTER="$SCRIPT_DIR/researcher_tools/export_codex_session.py"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Project folder not found: $PROJECT_DIR"
  echo "Create it first with: bash \"$SCRIPT_DIR/setup_pilot_project.sh\" $PARTICIPANT_ID"
  exit 1
fi

if [[ ! -f "$EXPORTER" ]]; then
  echo "Exporter script not found: $EXPORTER"
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ "${INCLUDE_CODEX_TOOLS:-0}" == "1" ]]; then
  python3 "$EXPORTER" \
    --project-dir "$PROJECT_DIR" \
    --participant-id "$PARTICIPANT_ID" \
    --out "$OUT_FILE" \
    --include-tools
else
  python3 "$EXPORTER" \
    --project-dir "$PROJECT_DIR" \
    --participant-id "$PARTICIPANT_ID" \
    --out "$OUT_FILE"
fi

echo ""
echo "Dialogue exported to:"
echo "$OUT_FILE"
