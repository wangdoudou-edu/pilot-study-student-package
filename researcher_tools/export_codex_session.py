#!/usr/bin/env python3
"""Export a Codex rollout session for one project directory to Markdown."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path
from typing import Any


def read_text_parts(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if "text" in item:
            parts.append(str(item["text"]))
    return "\n".join(parts).strip()


def is_context_injection(text: str) -> bool:
    stripped = text.lstrip()
    return (
        stripped.startswith("# AGENTS.md instructions for ")
        or stripped.startswith("<environment_context>")
        or stripped.startswith("<INSTRUCTIONS>")
    )


def project_dir_aliases(project_dir: Path) -> list[str]:
    raw = str(project_dir.expanduser())
    resolved = str(project_dir.expanduser().resolve())
    aliases = [raw, resolved]
    for value in list(aliases):
        if value.startswith("/private/tmp/"):
            aliases.append("/tmp/" + value[len("/private/tmp/") :])
        elif value.startswith("/tmp/"):
            aliases.append("/private/tmp/" + value[len("/tmp/") :])
    return list(dict.fromkeys(aliases))


def find_threads(db_path: Path, project_dir: Path) -> list[dict[str, Any]]:
    aliases = project_dir_aliases(project_dir)
    placeholders = ",".join("?" for _ in aliases)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            f"""
            SELECT id, rollout_path, cwd, title, cli_version, first_user_message,
                   created_at, updated_at, created_at_ms, updated_at_ms
            FROM threads
            WHERE cwd IN ({placeholders})
            ORDER BY updated_at_ms DESC, updated_at DESC
            """,
            aliases,
        ).fetchall()
    finally:
        conn.close()
    return [dict(row) for row in rows]


def parse_rollout(path: Path, include_tools: bool = False, skip_context: bool = True) -> list[dict[str, str]]:
    events: list[dict[str, str]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        timestamp = obj.get("timestamp", "")
        payload = obj.get("payload") or {}
        if obj.get("type") != "response_item":
            continue

        item_type = payload.get("type")
        role = payload.get("role")
        if item_type == "message" and role in {"user", "assistant"}:
            text = read_text_parts(payload.get("content"))
            if role == "user" and skip_context and is_context_injection(text):
                continue
            if text:
                events.append({"timestamp": timestamp, "role": role, "text": text})
        elif include_tools and item_type in {"function_call", "function_call_output"}:
            if item_type == "function_call":
                name = payload.get("name", "tool")
                args = payload.get("arguments", "")
                text = f"{name}\n\n```json\n{args}\n```"
                events.append({"timestamp": timestamp, "role": "tool_call", "text": text})
            else:
                output = str(payload.get("output", ""))
                if len(output) > 4000:
                    output = output[:4000] + "\n\n[truncated]"
                events.append({"timestamp": timestamp, "role": "tool_output", "text": output})
    return events


def analyze_rollout(path: Path) -> dict[str, Any]:
    """Collect audit metadata without treating context summaries as dialogue."""
    stats: dict[str, Any] = {
        "rollout_line_count": 0,
        "response_user_messages": 0,
        "response_assistant_messages": 0,
        "response_developer_messages": 0,
        "function_calls": 0,
        "function_call_outputs": 0,
        "turn_context_count": 0,
        "summary_values": [],
        "truncation_modes": [],
        "compaction_markers": [],
    }
    summary_values: set[str] = set()
    truncation_modes: set[str] = set()
    compaction_markers: list[dict[str, str]] = []

    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        if not line.strip():
            continue
        stats["rollout_line_count"] += 1
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        obj_type = str(obj.get("type", ""))
        payload = obj.get("payload") or {}
        payload_type = str(payload.get("type", ""))
        role = payload.get("role")

        marker_source = " ".join([obj_type, payload_type]).lower()
        if "compact" in marker_source or "compaction" in marker_source:
            compaction_markers.append({"line": str(line_no), "type": obj_type, "payload_type": payload_type})

        if obj_type == "turn_context":
            stats["turn_context_count"] += 1
            summary = payload.get("summary")
            if summary not in (None, "", "none"):
                value = str(summary)
                summary_values.add(value)
                compaction_markers.append({"line": str(line_no), "type": obj_type, "payload_type": f"summary={value}"})

            truncation_policy = payload.get("truncation_policy")
            if isinstance(truncation_policy, dict):
                mode = truncation_policy.get("mode")
                if mode:
                    truncation_modes.add(str(mode))

        if obj_type != "response_item":
            continue

        if payload_type == "message":
            if role == "user":
                stats["response_user_messages"] += 1
            elif role == "assistant":
                stats["response_assistant_messages"] += 1
            elif role == "developer":
                stats["response_developer_messages"] += 1
        elif payload_type == "function_call":
            stats["function_calls"] += 1
        elif payload_type == "function_call_output":
            stats["function_call_outputs"] += 1

    stats["summary_values"] = sorted(summary_values)
    stats["truncation_modes"] = sorted(truncation_modes)
    stats["compaction_markers"] = compaction_markers
    stats["compaction_detected"] = bool(compaction_markers)
    return stats


def format_markdown(thread: dict[str, Any], events: list[dict[str, str]], participant_id: str, audit: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append(f"# Codex Dialogue Export - {participant_id}")
    lines.append("")
    lines.append("## Session Metadata")
    lines.append("")
    lines.append(f"- Participant: `{participant_id}`")
    lines.append(f"- Thread ID: `{thread.get('id', '')}`")
    lines.append(f"- Project directory: `{thread.get('cwd', '')}`")
    lines.append(f"- Title: `{thread.get('title', '')}`")
    lines.append(f"- Codex CLI version: `{thread.get('cli_version', '')}`")
    lines.append(f"- Rollout path: `{thread.get('rollout_path', '')}`")
    lines.append(f"- Rollout line count: `{audit.get('rollout_line_count', '')}`")
    lines.append(f"- Exported student turns: `{sum(1 for event in events if event['role'] == 'user')}`")
    lines.append(f"- Exported Codex outputs: `{sum(1 for event in events if event['role'] == 'assistant')}`")
    lines.append(f"- Compaction detected: `{audit.get('compaction_detected', False)}`")
    if audit.get("summary_values"):
        lines.append(f"- Summary values: `{', '.join(audit['summary_values'])}`")
    if audit.get("truncation_modes"):
        lines.append(f"- Truncation modes: `{', '.join(audit['truncation_modes'])}`")
    lines.append("- Export note: `dialogue is reconstructed from persisted rollout events, not from the current model context`")
    lines.append("")
    lines.append("## Dialogue")
    lines.append("")

    turn = 0
    assistant_in_turn = 0
    for event in events:
        role = event["role"]
        if role == "user":
            turn += 1
            assistant_in_turn = 0
            heading = f"### Turn {turn} - Student"
        elif role == "assistant":
            assistant_in_turn += 1
            heading = f"### Turn {turn} - Codex Output {assistant_in_turn}"
        elif role == "tool_call":
            heading = f"#### Turn {turn} - Tool Call"
        else:
            heading = f"#### Turn {turn} - Tool Output"
        lines.append(heading)
        if event.get("timestamp"):
            lines.append(f"*{event['timestamp']}*")
        lines.append("")
        lines.append(event["text"].strip())
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="Export Codex project dialogue to Markdown.")
    parser.add_argument("--project-dir", required=True, help="Absolute path to the participant project directory.")
    parser.add_argument("--participant-id", required=True, help="Participant ID, such as P01.")
    parser.add_argument("--out", required=True, help="Markdown output path.")
    parser.add_argument("--db", default=str(Path.home() / ".codex" / "state_5.sqlite"), help="Codex state sqlite path.")
    parser.add_argument("--include-tools", action="store_true", help="Include tool calls and truncated tool outputs.")
    parser.add_argument("--include-context", action="store_true", help="Include AGENTS/environment context injections.")
    args = parser.parse_args()

    project_dir = Path(args.project_dir).expanduser().resolve()
    db_path = Path(args.db).expanduser()
    out_path = Path(args.out).expanduser()

    if not db_path.exists():
        raise SystemExit(f"Codex state database not found: {db_path}")

    threads = find_threads(db_path, project_dir)
    if not threads:
        raise SystemExit(f"No Codex thread found for cwd: {project_dir}")

    thread = threads[0]
    rollout = Path(os.path.expanduser(thread["rollout_path"]))
    if not rollout.exists():
        raise SystemExit(f"Rollout file not found: {rollout}")

    events = parse_rollout(rollout, include_tools=args.include_tools, skip_context=not args.include_context)
    if not events:
        raise SystemExit(f"No user/assistant messages found in rollout: {rollout}")

    audit = analyze_rollout(rollout)
    audit["exported_student_turns"] = sum(1 for event in events if event["role"] == "user")
    audit["exported_codex_outputs"] = sum(1 for event in events if event["role"] == "assistant")
    audit["rollout_path"] = str(rollout)
    audit["thread_id"] = thread.get("id", "")
    audit["project_dir"] = thread.get("cwd", "")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(format_markdown(thread, events, args.participant_id, audit), encoding="utf-8")

    metadata_path = out_path.with_suffix(".export_metadata.json")
    metadata_path.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    candidates_path = out_path.with_suffix(".thread_candidates.tsv")
    with candidates_path.open("w", encoding="utf-8") as f:
        f.write("id\trollout_path\tcwd\ttitle\tcli_version\tfirst_user_message\n")
        for row in threads:
            f.write(
                "\t".join(
                    str(row.get(key, "")).replace("\n", " ")
                    for key in ["id", "rollout_path", "cwd", "title", "cli_version", "first_user_message"]
                )
                + "\n"
            )

    print(f"Exported dialogue to: {out_path}")
    print(f"Saved export metadata to: {metadata_path}")
    print(f"Saved thread candidates to: {candidates_path}")


if __name__ == "__main__":
    main()
