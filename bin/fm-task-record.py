#!/usr/bin/env python3
"""Per-task business record store and unified on-demand reader.

Each task is one data/<id>/task.json file.  Aggregated reads scan those files
in one process; no aggregate index is persisted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
PROGRESS_FIELDS = ("acceptance", "current_state", "remaining_gap", "next_step")
STATES = {"queued", "in_flight", "done", "archived"}


class Refusal(Exception):
    pass


def text(value: Any, name: str, empty: bool = False) -> str:
    if not isinstance(value, str) or "\x00" in value:
        raise Refusal(f"{name} must be text")
    value = value.strip()
    if not empty and not value:
        raise Refusal(f"{name} must not be empty")
    return value


def task_path(data: Path, task_id: str) -> Path:
    if not ID_RE.fullmatch(task_id):
        raise Refusal(f"invalid task id: {task_id}")
    return data / task_id / "task.json"


def clean_progress(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != set(PROGRESS_FIELDS):
        raise Refusal("progress must contain exactly acceptance, current_state, remaining_gap and next_step")
    clean = {name: text(value[name], name, empty=True) for name in PROGRESS_FIELDS}
    if any(clean.values()) and (not clean["acceptance"] or not clean["current_state"]):
        raise Refusal("acceptance and current_state must be present once progress is recorded")
    if bool(clean["remaining_gap"]) != bool(clean["next_step"]):
        raise Refusal("remaining_gap and next_step must both be empty or both be present")
    return clean


def validate(record: Any, expected_id: str | None = None) -> dict[str, Any]:
    if not isinstance(record, dict) or record.get("schema") != "fm-task.v1":
        raise Refusal("task record has an unsupported schema")
    task_id = text(record.get("id"), "id")
    if not ID_RE.fullmatch(task_id) or expected_id is not None and task_id != expected_id:
        raise Refusal("task record identity does not match its directory")
    state = record.get("state")
    if state not in STATES:
        raise Refusal("task state is invalid")
    blocked_by = record.get("blocked_by")
    links = record.get("links")
    history = record.get("history")
    if not isinstance(blocked_by, list) or not all(isinstance(item, str) and ID_RE.fullmatch(item) for item in blocked_by):
        raise Refusal("blocked_by must be a task id array")
    if not isinstance(links, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in links.items()):
        raise Refusal("links must be a text map")
    if not isinstance(history, list) or not all(isinstance(item, str) for item in history):
        raise Refusal("history must be a text array")
    hold = record.get("hold")
    if hold is not None and (not isinstance(hold, dict) or not isinstance(hold.get("reason"), str)
                             or not isinstance(hold.get("kind"), str)
                             or not isinstance(hold.get("until"), (str, type(None)))):
        raise Refusal("hold is invalid")
    return {
        "schema": "fm-task.v1", "id": task_id,
        "title": text(record.get("title"), "title"),
        "body": text(record.get("body", ""), "body", empty=True),
        "state": state, "kind": text(record.get("kind", "task"), "kind"),
        "repo": text(record.get("repo", ""), "repo", empty=True),
        "priority": text(record.get("priority", ""), "priority", empty=True),
        "created": text(record.get("created"), "created"),
        "closed": record.get("closed") if isinstance(record.get("closed"), str) else None,
        "hold": hold, "deferred_until": record.get("deferred_until") if isinstance(record.get("deferred_until"), str) else None,
        "blocked_by": blocked_by, "links": links, "history": history,
        "progress": clean_progress(record.get("progress")),
        "updated_at": text(record.get("updated_at"), "updated_at"),
    }


def read(data: Path, task_id: str) -> tuple[dict[str, Any], bytes]:
    path = task_path(data, task_id)
    if path.is_symlink() or not path.is_file():
        raise FileNotFoundError(task_id)
    raw = path.read_bytes()
    try:
        return validate(json.loads(raw), task_id), raw
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise Refusal(f"task {task_id} record is invalid JSON") from exc


def write(data: Path, record: dict[str, Any], previous_raw: bytes | None = None) -> None:
    record = validate(record, record.get("id"))
    path = task_path(data, record["id"])
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise Refusal(f"task directory is a symlink: {path.parent}")
    encoded = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    if previous_raw is not None and previous_raw == encoded:
        return
    if previous_raw is None and path.is_file() and not path.is_symlink() and path.read_bytes() == encoded:
        return
    descriptor, temporary = tempfile.mkstemp(prefix=f".{record['id']}.task.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        if os.environ.get("FM_TASK_RECORD_TEST_FAIL_BEFORE_REPLACE") == "1":
            raise OSError("injected failure before atomic replacement")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def records(data: Path) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if not data.is_dir():
        return found
    with os.scandir(data) as entries:
        directories = sorted((entry for entry in entries if entry.is_dir(follow_symlinks=False)), key=lambda item: item.name)
    for entry in directories:
        path = Path(entry.path) / "task.json"
        if not path.is_file() or path.is_symlink():
            continue
        try:
            found.append(validate(json.loads(path.read_bytes()), entry.name))
        except (json.JSONDecodeError, UnicodeDecodeError, Refusal) as exc:
            raise Refusal(f"cannot list corrupt task record {path}: {exc}") from exc
    return found


def shown(value: str | None) -> str:
    if not value:
        return '"-"'
    if "\n" in value or value == "-" or value.startswith('"'):
        return json.dumps(value, ensure_ascii=False)
    return value


def show(record: dict[str, Any]) -> None:
    hold = record["hold"]
    links = ",".join(f"{key}:{value}" for key, value in record["links"].items()) or "none"
    blocked = ",".join(record["blocked_by"]) or "none"
    print("task:")
    for key, value in (
        ("id", record["id"]), ("title", record["title"]), ("state", record["state"]),
        ("blocked", "yes" if record["blocked_by"] else "no"), ("blocked_by", blocked),
        ("held", "yes" if hold else "no"), ("hold_reason", hold["reason"] if hold else None),
        ("hold_kind", hold["kind"] if hold else None), ("hold_until", hold.get("until") if hold else None),
        ("kind", record["kind"]), ("repo", record["repo"]), ("priority", record["priority"]),
        ("created", record["created"]), ("closed", record["closed"]),
        ("deps", blocked), ("links", links), ("body", record["body"]),
    ):
        print(f"  {key}: {shown(value)}")


def list_records(items: list[dict[str, Any]], state: str | None, limit: int,
                 fields: str | None = None, label: str = "tasks") -> None:
    selected = [item for item in items if state is None or item["state"] == state][:limit]
    print(f"count: {len(selected)}")
    extra = [name for name in (fields or "").split(",") if name]
    print(f"{label}[{len(selected)}]{{id,state,kind,repo,title" +
          ("," + ",".join(extra) if extra else "") + "}:")
    for item in selected:
        values = [item["id"], item["state"], item["kind"], item["repo"] or '"-"', item["title"]]
        for name in extra:
            if name == "blocked_by":
                values.append("|".join(item["blocked_by"]) or "none")
            elif name == "hold_kind":
                values.append(item["hold"]["kind"] if item["hold"] else "none")
            elif name == "hold_reason":
                values.append(item["hold"]["reason"] if item["hold"] else "none")
            else:
                raise Refusal(f"unsupported list field: {name}")
        print("  " + ",".join(values))


def progress_projection(record: dict[str, Any]) -> dict[str, Any]:
    basis = {key: record[key] for key in ("id", "title", "state", "hold", "blocked_by", "progress")}
    token = hashlib.sha256(json.dumps(basis, ensure_ascii=False, sort_keys=True,
                                      separators=(",", ":")).encode()).hexdigest()
    relation = "exact" if record["state"] == "in_flight" and record["hold"] is None and not record["blocked_by"] else "disposition_only"
    progress = record["progress"]
    return {"task_id": record["id"], "goal": record["title"], "task_state": record["state"],
            "task_held": "no" if record["hold"] is None else "yes",
            "task_blocked": "no" if not record["blocked_by"] else "yes",
            "recorded": relation == "exact" and bool(progress["acceptance"]) and bool(progress["current_state"]),
            "context_relation": relation, **progress, "record_token": token}


def new_record(task_id: str, title: str, args: argparse.Namespace) -> dict[str, Any]:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    body = Path(args.body_file).read_text() if args.body_file else args.body or ""
    return {"schema": "fm-task.v1", "id": task_id, "title": title, "body": body.strip(),
            "state": "in_flight" if args.start else "queued", "kind": args.kind or "task",
            "repo": args.repo or "", "priority": args.priority or "", "created": date.today().isoformat(),
            "closed": None, "hold": None, "deferred_until": None, "blocked_by": [], "links": {},
            "history": [], "progress": {name: "" for name in PROGRESS_FIELDS}, "updated_at": now}


def update_common(record: dict[str, Any], args: argparse.Namespace) -> bool:
    changed = False
    for source, target in (("title", "title"), ("body", "body"), ("kind", "kind"),
                           ("repo", "repo"), ("priority", "priority")):
        value = getattr(args, source, None)
        if value is not None and record[target] != value:
            record[target] = value
            changed = True
    if getattr(args, "body_file", None):
        value = Path(args.body_file).read_text().strip()
        if record["body"] != value:
            record["body"] = value
            changed = True
    for key in ("pr", "report"):
        value = getattr(args, key, None)
        if value is not None and record["links"].get(key) != value:
            record["links"][key] = value
            changed = True
    if getattr(args, "note", None) and args.note not in record["history"]:
        record["history"].append(args.note)
        changed = True
    return changed


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--data", required=True, type=Path)
    sub = result.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("id"); add.add_argument("title")
    for name in ("kind", "repo", "priority", "body", "body_file"):
        add.add_argument("--" + name.replace("_", "-"))
    add.add_argument("--start", action="store_true")
    add.add_argument("--queue", action="store_true")
    show_parser = sub.add_parser("show"); show_parser.add_argument("id"); show_parser.add_argument("--full", action="store_true")
    listing = sub.add_parser("list"); listing.add_argument("--state"); listing.add_argument("--limit", type=int, default=10000)
    listing.add_argument("--blocked", action="store_true"); listing.add_argument("--fields")
    ready = sub.add_parser("ready"); ready.add_argument("--limit", type=int, default=10000)
    for command in ("start", "done", "reopen", "archive", "unhold"):
        item = sub.add_parser(command); item.add_argument("id")
        item.add_argument("--pr"); item.add_argument("--report"); item.add_argument("--note")
        if command == "done":
            item.add_argument("--keep", type=int)
            item.add_argument("--no-prune", action="store_true")
    update = sub.add_parser("update"); update.add_argument("id")
    for name in ("title", "body", "body_file", "kind", "repo", "priority", "pr", "report", "note"):
        update.add_argument("--" + name.replace("_", "-"))
    update.add_argument("--archive-body", action="store_true")
    hold = sub.add_parser("hold"); hold.add_argument("id"); hold.add_argument("--reason", required=True); hold.add_argument("--kind", required=True); hold.add_argument("--until")
    for command in ("block", "unblock"):
        item = sub.add_parser(command); item.add_argument("id"); item.add_argument("--by", required=True)
    progress = sub.add_parser("progress"); progress.add_argument("id")
    progress_view = sub.add_parser("progress-view"); progress_view.add_argument("id")
    progress_update = sub.add_parser("update-progress"); progress_update.add_argument("id"); progress_update.add_argument("--progress", required=True)
    progress_update_view = sub.add_parser("update-progress-view"); progress_update_view.add_argument("id"); progress_update_view.add_argument("--progress", required=True)
    sub.add_parser("progress-list")
    sub.add_parser("inventory")
    prune = sub.add_parser("prune"); prune.add_argument("--keep", type=int, required=True)
    imported = sub.add_parser("import-snapshot")
    imported.add_argument("--snapshot", required=True, type=Path)
    imported.add_argument("--archive", action="store_true")
    return result


def import_snapshot(data: Path, snapshot_path: Path, archived: bool) -> int:
    snapshot = json.loads(snapshot_path.read_bytes())
    rows = snapshot.get("backlog", {}).get("records") if isinstance(snapshot, dict) else None
    if not isinstance(rows, list):
        raise Refusal("snapshot has no backlog record inventory")
    imported = 0
    for row in rows:
        if not isinstance(row, dict) or not row.get("structured"):
            if isinstance(row, dict) and str(row.get("raw") or "").strip():
                raise Refusal("legacy source contains an unstructured task row")
            continue
        task_id = text(row.get("id"), "legacy task id")
        body_lines = row.get("body_lines") if isinstance(row.get("body_lines"), list) else []
        progress = row.get("compact_progress")
        if not isinstance(progress, dict) or not set(PROGRESS_FIELDS).issubset(progress):
            progress = {name: "" for name in PROGRESS_FIELDS}
        else:
            progress = {name: progress[name] for name in PROGRESS_FIELDS}
        links: dict[str, str] = {}
        if isinstance(row.get("pr_url"), str): links["pr"] = row["pr_url"]
        if isinstance(row.get("report_path"), str): links["report"] = row["report_path"]
        artifact_index = 0
        for value in row.get("links", []) if isinstance(row.get("links"), list) else []:
            if not isinstance(value, str) or value in links.values():
                continue
            artifact_index += 1
            links[f"artifact_{artifact_index}"] = value
        state = "archived" if archived else row.get("state")
        if state not in STATES:
            raise Refusal(f"legacy task {task_id} has unsupported state {state}")
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        hold = None
        if row.get("hold_reason"):
            hold = {"reason": str(row["hold_reason"]), "kind": str(row.get("hold_kind") or "captain"),
                    "until": row.get("hold_until") if isinstance(row.get("hold_until"), str) else None}
        record = {"schema": "fm-task.v1", "id": task_id, "title": text(row.get("title"), "legacy title"),
                  "body": "\n".join(str(item) for item in body_lines), "state": state,
                  "kind": str(row.get("kind") or "task"), "repo": str(row.get("repo") or ""),
                  "priority": str(row.get("priority") or ""), "created": str(row.get("since") or date.today().isoformat()),
                  "closed": str(row.get("done")) if row.get("done") else None, "hold": hold,
                  "deferred_until": row.get("hold_until") if isinstance(row.get("hold_until"), str) else None,
                  "blocked_by": [str(item) for item in row.get("blocked_by_ids", [])],
                  "links": links, "history": [str(item) for item in body_lines],
                  "progress": progress, "updated_at": now}
        path = task_path(data, task_id)
        if path.exists():
            existing, _ = read(data, task_id)
            comparable = dict(record); comparable["updated_at"] = existing["updated_at"]
            if existing != validate(comparable, task_id):
                raise Refusal(f"legacy task {task_id} conflicts with an existing task record")
            continue
        write(data, record); imported += 1
    print(json.dumps({"imported": imported}, separators=(",", ":")))
    return 0


def main() -> int:
    args = parser().parse_args()
    data: Path = args.data
    try:
        if args.command == "import-snapshot":
            return import_snapshot(data, args.snapshot, args.archive)
        if args.command == "add":
            path = task_path(data, args.id)
            if path.exists():
                raise Refusal(f"task already exists: {args.id}")
            write(data, new_record(args.id, args.title, args)); return 0
        if args.command == "prune":
            # Canonical records retain full history; the old retention flag is
            # accepted as a no-op compatibility bridge.
            return 0
        if args.command in ("list", "ready", "inventory", "progress-list"):
            items = records(data)
            if args.command == "inventory":
                print(json.dumps({"tasks": items}, ensure_ascii=False, separators=(",", ":"))); return 0
            if args.command == "progress-list":
                ids = sorted(item["id"] for item in items if item["state"] == "in_flight")
                print(json.dumps({"tasks": ids}, separators=(",", ":"))); return 0
            state = getattr(args, "state", None)
            if args.command == "ready":
                dispositions = {item["id"]: item["state"] for item in items}
                items = [item for item in items if item["state"] == "queued" and not item["hold"] and
                         all(dispositions.get(blocker) in ("done", "archived") for blocker in item["blocked_by"])]
                list_records(items, None, args.limit, label="ready"); return 0
            if args.blocked:
                items = [item for item in items if item["blocked_by"]]
            if state == "held":
                items = [item for item in items if item["hold"] is not None]
                state = None
            list_records(items, state, args.limit, args.fields); return 0
        record, raw = read(data, args.id)
        if args.command == "show": show(record); return 0
        if args.command == "progress":
            print(json.dumps(record, ensure_ascii=False, separators=(",", ":"))); return 0
        if args.command == "progress-view":
            print(json.dumps(progress_projection(record), ensure_ascii=False, separators=(",", ":"))); return 0
        if args.command in ("update-progress", "update-progress-view"):
            if os.environ.get("FM_SUPERVISION_ACTOR", "main") != "main":
                raise Refusal("task progress belongs to MAIN")
            progress = clean_progress(json.loads(args.progress))
            if record["state"] in ("done", "archived"):
                raise Refusal(f"completed task {args.id} cannot receive progress updates")
            if record["progress"] != progress:
                record["progress"] = progress
                record["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                write(data, record, raw)
            result = progress_projection(record) if args.command == "update-progress-view" else record
            print(json.dumps(result, ensure_ascii=False, separators=(",", ":"))); return 0
        old_body = record["body"]
        changed = update_common(record, args) if args.command in ("update", "start", "done", "reopen", "archive") else False
        if args.command == "update" and args.archive_body and record["body"] != old_body and old_body and old_body not in record["history"]:
            record["history"].append(old_body)
            changed = True
        if args.command == "start": record["state"] = "in_flight"; record["closed"] = None; changed = True
        elif args.command == "done": record["state"] = "done"; record["closed"] = date.today().isoformat(); changed = True
        elif args.command == "reopen": record["state"] = "queued"; record["closed"] = None; changed = True
        elif args.command == "archive": record["state"] = "archived"; record["closed"] = date.today().isoformat(); changed = True
        elif args.command == "hold": record["hold"] = {"reason": args.reason, "kind": args.kind, "until": args.until}; changed = True
        elif args.command == "unhold": record["hold"] = None; changed = True
        elif args.command == "block":
            if args.by not in record["blocked_by"]: record["blocked_by"].append(args.by); changed = True
        elif args.command == "unblock":
            if args.by in record["blocked_by"]: record["blocked_by"].remove(args.by); changed = True
        if changed:
            record["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            write(data, record, raw)
        return 0
    except FileNotFoundError:
        print("code: NOT_FOUND", file=sys.stderr); return 1
    except (Refusal, json.JSONDecodeError, OSError) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr); return 6


if __name__ == "__main__":
    raise SystemExit(main())
