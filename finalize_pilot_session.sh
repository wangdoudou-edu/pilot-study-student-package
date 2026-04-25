#!/usr/bin/env bash
set -euo pipefail

PARTICIPANT_ID="${1:-}"

if [[ -z "$PARTICIPANT_ID" ]]; then
  echo "Usage: bash finalize_pilot_session.sh P01"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="${PILOT_RUNS_DIR:-$HOME/Desktop/AIMind_Pilot_Runs}"
PROJECT_DIR="$RUNS_DIR/${PARTICIPANT_ID}_任务文件夹"
DIALOGUE_FILE="$PROJECT_DIR/Codex对话记录/${PARTICIPANT_ID}_codex_dialogue.md"
METADATA_FILE="$PROJECT_DIR/Codex对话记录/${PARTICIPANT_ID}_codex_dialogue.export_metadata.json"
LOG_FILE="$PROJECT_DIR/任务完成检查.log"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Project folder not found: $PROJECT_DIR"
  echo "Create it first with: bash \"$SCRIPT_DIR/setup_pilot_project.sh\" $PARTICIPANT_ID"
  exit 1
fi

echo "Step 1/2: exporting Codex dialogue..."
bash "$SCRIPT_DIR/export_codex_dialogue.sh" "$PARTICIPANT_ID"

echo "Step 2/2: reviewing dialogue and writing completion log..."
python3 - "$PARTICIPANT_ID" "$PROJECT_DIR" "$DIALOGUE_FILE" "$METADATA_FILE" "$LOG_FILE" <<'PY'
from __future__ import annotations

import re
import json
import sys
from datetime import datetime
from pathlib import Path

participant_id = sys.argv[1]
project_dir = Path(sys.argv[2])
dialogue_file = Path(sys.argv[3])
metadata_file = Path(sys.argv[4])
log_file = Path(sys.argv[5])

now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
checks: list[tuple[str, bool, str]] = []

text = ""
if dialogue_file.exists():
    text = dialogue_file.read_text(encoding="utf-8", errors="replace")

metadata = {}
if metadata_file.exists():
    try:
        metadata = json.loads(metadata_file.read_text(encoding="utf-8", errors="replace"))
    except json.JSONDecodeError:
        metadata = {"metadata_parse_error": True}

student_turns = len(re.findall(r"^### Turn \d+ - Student", text, flags=re.MULTILINE))
codex_outputs = len(re.findall(r"^### Turn \d+ - Codex Output", text, flags=re.MULTILINE))

student_sections = re.findall(
    r"^### Turn \d+ - Student\n(?:\*.*?\*\n)?\n(.*?)(?=^### Turn \d+ - |^#### Turn \d+ - |\Z)",
    text,
    flags=re.MULTILINE | re.DOTALL,
)
student_text = "\n".join(student_sections)

process_categories = {
    "needs_analysis": ["用户需求", "访谈", "需求分析", "用户"],
    "planning": ["设计目标", "策划案", "玩法", "规则", "游戏性", "乐趣"],
    "prototype_work": ["原型", "网页", "HTML", "CSS", "JavaScript", "JS", "修改"],
    "playtest_or_revision": ["试玩", "反馈", "修正", "问题", "改进"],
}
covered_categories = [
    name
    for name, keywords in process_categories.items()
    if any(keyword in student_text for keyword in keywords)
]

file_list_keywords = [
    "项目说明.doc",
    "02_学生任务书.doc",
    "03_用户访谈材料.doc",
    "04_阶段输出表.xls",
    "05_Codex项目操作卡.doc",
    "网页原型",
]

checks.append(("dialogue_file_exists", dialogue_file.exists(), str(dialogue_file)))
checks.append(("export_metadata_exists", metadata_file.exists(), str(metadata_file)))
checks.append(("participant_id_present", participant_id in text, f"participant={participant_id}"))
checks.append(("start_marker_present", "现在我要开始今天的任务" in text, "student opening marker"))
checks.append(("end_marker_present", "今天的任务到此为止" in text or "任务到此为止" in text, "student closing marker"))
checks.append(("student_turn_count_at_least_4", student_turns >= 4, f"student_turns={student_turns}"))
checks.append(("codex_output_count_at_least_4", codex_outputs >= 4, f"codex_outputs={codex_outputs}"))
checks.append(("project_files_listed", all(keyword in text for keyword in file_list_keywords), "required project files visible in dialogue"))
checks.append(("task_process_coverage_at_least_3_categories", len(covered_categories) >= 3, f"covered={','.join(covered_categories) or 'none'}"))
checks.append(("dialogue_not_tiny", len(text) >= 3000, f"characters={len(text)}"))

missing_required_files = []
required_paths = [
    project_dir / "任务材料" / "04_阶段输出表.xls",
    project_dir / "网页原型" / "index.html",
]
for path in required_paths:
    if not path.exists():
        missing_required_files.append(str(path))

checks.append(("required_output_files_exist", not missing_required_files, "; ".join(missing_required_files) or "all required output files found"))

if metadata:
    metadata_student_turns = metadata.get("exported_student_turns")
    metadata_codex_outputs = metadata.get("exported_codex_outputs")
    checks.append(("metadata_matches_dialogue_turns", metadata_student_turns == student_turns and metadata_codex_outputs == codex_outputs, f"metadata_student_turns={metadata_student_turns}; dialogue_student_turns={student_turns}; metadata_codex_outputs={metadata_codex_outputs}; dialogue_codex_outputs={codex_outputs}"))

passed = sum(1 for _, ok, _ in checks if ok)
total = len(checks)
critical_names = {
    "dialogue_file_exists",
    "participant_id_present",
    "start_marker_present",
    "end_marker_present",
    "student_turn_count_at_least_4",
    "task_process_coverage_at_least_3_categories",
    "required_output_files_exist",
}
critical_ok = all(ok for name, ok, _ in checks if name in critical_names)
status = "PASS" if critical_ok and passed == total else "NEEDS_REVIEW"

lines = [
    "Pilot Session Completion Log",
    f"participant_id: {participant_id}",
    f"review_time: {now}",
    f"project_dir: {project_dir}",
    f"dialogue_file: {dialogue_file}",
    f"metadata_file: {metadata_file}",
    f"review_status: {status}",
    f"checks_passed: {passed}/{total}",
    f"compaction_detected: {metadata.get('compaction_detected', 'unknown')}",
    f"rollout_line_count: {metadata.get('rollout_line_count', 'unknown')}",
    f"exported_student_turns: {metadata.get('exported_student_turns', 'unknown')}",
    f"exported_codex_outputs: {metadata.get('exported_codex_outputs', 'unknown')}",
    f"summary_values: {metadata.get('summary_values', 'unknown')}",
    f"truncation_modes: {metadata.get('truncation_modes', 'unknown')}",
    "",
    "Checks:",
]

for name, ok, detail in checks:
    marker = "PASS" if ok else "FAIL"
    lines.append(f"- {marker} {name}: {detail}")

lines.extend([
    "",
    "Decision:",
    "任务完成检查 log 已写入。本 log 是任务收尾记录；如果 review_status=NEEDS_REVIEW，研究者应在学生离场前人工检查原因。",
])

log_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"Completion log written: {log_file}")
print(f"Review status: {status} ({passed}/{total})")
PY

echo ""
echo "Pilot session finalization log:"
echo "$LOG_FILE"
