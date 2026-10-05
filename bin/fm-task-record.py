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
import subprocess
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
    for name, field in clean.items():
        if "\n" in field or "\r" in field:
            raise Refusal(f"{name} must be one line")
        if len(field.encode("utf-8")) > 1200:
            raise Refusal(f"{name} exceeds 1200 UTF-8 bytes")
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
                             or not isinstance(hold.get("until"), (str, type(None)))
                             or not isinstance(hold.get("set"), (str, type(None)))):
        raise Refusal("hold is invalid")
    completion = record.get("completion")
    if completion is not None and (not isinstance(completion, dict)
                                   or completion.get("verb") not in ("done", "merged", "reported")
                                   or not isinstance(completion.get("date"), str)):
        raise Refusal("completion is invalid")
    return {
        "schema": "fm-task.v1", "id": task_id,
        "title": text(record.get("title"), "title"),
        "body": text(record.get("body", ""), "body", empty=True),
        "state": state, "kind": text(record.get("kind", "task"), "kind"),
        "repo": text(record.get("repo", ""), "repo", empty=True),
        "priority": text(record.get("priority", ""), "priority", empty=True),
        "created": text(record.get("created"), "created"),
        "closed": record.get("closed") if isinstance(record.get("closed"), str) else None,
        "completion": completion,
        "hold": hold, "deferred_until": record.get("deferred_until") if isinstance(record.get("deferred_until"), str) else None,
        "blocked_by": blocked_by, "links": links, "history": history,
        "progress": clean_progress(record.get("progress")),
        "updated_at": text(record.get("updated_at"), "updated_at"),
    }


def read(data: Path, task_id: str) -> tuple[dict[str, Any], bytes]:
    path = task_path(data, task_id)
    if path.parent.is_symlink() or path.is_symlink():
        raise Refusal(f"unsafe task record: {path}")
    if not path.exists():
        raise FileNotFoundError(task_id)
    if not path.is_file():
        raise Refusal(f"task record is not a regular file: {path}")
    raw = path.read_bytes()
    try:
        return validate(json.loads(raw), task_id), raw
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise Refusal(f"task {task_id} record is invalid JSON") from exc


def write(data: Path, record: dict[str, Any], previous_raw: bytes | None = None, *, create: bool = False) -> None:
    record = validate(record, record.get("id"))
    path = task_path(data, record["id"])
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise Refusal(f"task directory is a symlink: {path.parent}")
    encoded = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    if previous_raw is not None and previous_raw == encoded:
        return
    if not create and previous_raw is None and path.is_file() and not path.is_symlink() and path.read_bytes() == encoded:
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
        if create:
            try:
                os.link(temporary, path)
            except FileExistsError as exc:
                raise Refusal(f"task already exists: {record['id']}") from exc
        else:
            os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
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
        if not path.exists() and not path.is_symlink():
            continue
        try:
            found.append(read(data, entry.name)[0])
        except (json.JSONDecodeError, UnicodeDecodeError, Refusal) as exc:
            raise Refusal(f"cannot list corrupt task record {path}: {exc}") from exc
    return found


def disposition(record: dict[str, Any]) -> str:
    if record["state"] == "in_flight":
        return "active"
    if record["state"] == "queued":
        return "parked" if record["hold"] and record["hold"]["kind"] == "parked" else "queued"
    return "done" if record["state"] == "done" else "archive_done"


def inventory(items: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = {item["id"]: item for item in items}
    ready = [item["id"] for item in items if item["state"] == "queued" and not item["hold"] and
             all(by_id.get(blocker, {}).get("state") in ("done", "archived") for blocker in item["blocked_by"])]
    return {"tasks": items, "dispositions": {item["id"]: disposition(item) for item in items}, "ready_ids": ready}


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
            "task_hold_kind": record["hold"]["kind"] if record["hold"] is not None else "",
            "task_blocked": "no" if not record["blocked_by"] else "yes",
            "recorded": bool(progress["acceptance"]) and bool(progress["current_state"]),
            "context_relation": relation, **progress, "record_token": token}


def new_record(task_id: str, title: str, args: argparse.Namespace) -> dict[str, Any]:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    body = Path(args.body_file).read_text() if args.body_file else args.body or ""
    return {"schema": "fm-task.v1", "id": task_id, "title": title, "body": body.strip(),
            "state": "in_flight" if args.start else "queued", "kind": args.kind or "task",
            "repo": args.repo or "", "priority": args.priority or "", "created": date.today().isoformat(),
            "closed": None, "completion": None, "hold": None, "deferred_until": None, "blocked_by": [], "links": {},
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


# This discovery is used only by explicit one-time migration, never inventory.
def backfill_preview(data: Path, state: Path) -> dict[str, Any]:
    excluded: dict[str, str] = {}
    sources: dict[str, list[dict[str, Any]]] = {}
    ignored: list[dict[str, str]] = []
    reserved = {"skills", "short-agents", "branch-session", "procevent", "procevent-inbox"}
    for path in sorted(state.glob("*.meta")):
        if path.is_symlink() or not path.is_file():
            raise Refusal(f"unsafe migration source: {path}")
        fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        if fields.get("kind") == "secondmate":
            excluded[path.stem] = "persistent secondmate home"

    def candidate(task_id: str, path: Path, kind: str, facts: dict[str, Any] | None = None) -> None:
        if not ID_RE.fullmatch(task_id) or task_id in reserved or task_id in excluded:
            excluded.setdefault(task_id, "non-ordinary namespace")
            return
        if path.is_symlink() or not path.is_file():
            raise Refusal(f"unsafe migration source: {path}")
        sources.setdefault(task_id, []).append({"path": str(path), "type": kind, "facts": facts or {}})

    def load_source(path: Path) -> dict[str, Any]:
        if path.is_symlink() or not path.is_file():
            raise Refusal(f"unsafe migration source: {path}")
        value = json.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise Refusal(f"invalid migration source: {path}")
        return value

    def receipt(path: Path, task_id: str, archived: bool = False) -> None:
        value = load_source(path)
        generation = value.get("spawn_gen")
        if value.get("schema") != "fm-task-cleanup.v1" or value.get("task_id") != task_id or not isinstance(generation, str) or not isinstance(value.get("phases"), dict):
            raise Refusal(f"invalid cleanup identity: {path}")
        if archived and path.name != hashlib.sha256(generation.encode()).hexdigest() + ".json":
            raise Refusal(f"cleanup archive generation mismatch: {path}")
        candidate(task_id, path, "cleanup-receipt")

    existing = {item["id"]: item for item in records(data)}
    for directory in sorted(data.iterdir()):
        if not directory.is_dir() or directory.is_symlink() or not ID_RE.fullmatch(directory.name):
            continue
        task_id = directory.name
        for name in ("task.json", "brief.md", "report.md", "lifecycle.json"):
            path = directory / name
            if not path.exists() and not path.is_symlink():
                continue
            if name == "task.json":
                read(data, task_id)
                candidate(task_id, path, "canonical")
            elif name == "lifecycle.json":
                value = load_source(path)
                if value.get("schema") not in ("fm-task-lifecycle.v1", "fm-task-lifecycle.v2") or value.get("task_id") != task_id:
                    raise Refusal(f"invalid lifecycle identity: {path}")
                candidate(task_id, path, "lifecycle", {key: value[key] for key in ("title", "kind", "repo") if key in value})
            else:
                candidate(task_id, path, name)
        receipt_dir = directory / "cleanup-receipts"
        if receipt_dir.is_symlink():
            raise Refusal(f"unsafe migration source: {receipt_dir}")
        if receipt_dir.is_dir():
            for path in sorted(receipt_dir.glob("*.json")):
                receipt(path, task_id, True)
    for path in sorted(state.glob("*.meta")):
        fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        if fields.get("kind") in ("ship", "scout", "program") or fields.get("executor") in ("local-agent", "remote-agent", "cloud-worker"):
            facts = {key: fields[key] for key in ("title", "kind", "repo") if key in fields}
            if "project" in fields and "repo" not in fields:
                facts["repo"] = fields["project"]
            candidate(path.stem, path, "ordinary-meta", facts)
        else:
            excluded.setdefault(path.stem, "non-ordinary metadata")
    status_event = re.compile(r"^(?:(?:\[?\d{4}-\d\d-\d\d[^ ]*\]?|\d\d:\d\d:\d\d)\s+)?(?:working|needs-decision|blocked|paused|done|failed|resolved|note)(?:\s+\[key=[^\]]+\])?:\s*.+$")
    for path in sorted(state.glob("*.status")):
        if path.is_symlink() or not path.is_file():
            raise Refusal(f"unsafe migration source: {path}")
        lines = [line for line in path.read_text().splitlines() if line.strip()]
        if lines and all(status_event.fullmatch(line) for line in lines):
            candidate(path.stem, path, "ordinary-status")
        else:
            ignored.append({"path": str(path), "reason": "not a worker status event stream"})
    for path in sorted(state.glob("*.cleanup.json")):
        receipt(path, path.name[:-len(".cleanup.json")])
    for name in ("backlog.md", "done-archive.md"):
        path = data / name
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink() or not path.is_file():
            raise Refusal(f"unsafe migration source: {path}")
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"- \[[ xX]\] ([A-Za-z0-9][A-Za-z0-9._-]{0,159}) - (.+)", line)
            if not match:
                continue
            task_id, body = match.groups()
            facts = {}
            for key in ("kind", "repo"):
                field = re.search(r"\(" + key + r": ([^()]+)\)", body)
                if field:
                    facts[key] = field[1]
            title = re.split(r"\s+(?:\(|https?://|blocked-by:)", body, maxsplit=1)[0].strip()
            if title:
                facts["title"] = title
            candidate(task_id, path, "legacy-row", facts)
    for namespace, library, validator in (("remote-tasks", "fm-remote-agent-lib.sh", "fm_remote_state_validate_file"),
                                           ("cloud-tasks", "fm-aime-cloud-lib.sh", "fm_aime_state_validate_file")):
        for path in sorted((state / namespace).glob("*/state.json")):
            if path.parent.is_symlink():
                raise Refusal(f"unsafe migration source: {path}")
            value = load_source(path)
            result = subprocess.run(["bash", "-c", '. "$1"; "$2" "$3"', "migration-validator",
                                     str(Path(__file__).with_name(library)), validator, str(path)], capture_output=True)
            if result.returncode or value.get("task_id") != path.parent.name:
                raise Refusal(f"invalid {namespace} identity: {path}")
            candidate(path.parent.name, path, namespace)
    entries = []
    for task_id in sorted(set(sources) | set(existing)):
        known = sources.get(task_id, [])
        if task_id in existing:
            entries.append({"id": task_id, "disposition": "existing", "sources": known,
                            "sha256": hashlib.sha256(read(data, task_id)[1]).hexdigest()})
            continue
        if task_id in excluded:
            continue
        facts, defaults = {}, {}
        for key, default in (("title", task_id), ("kind", "task"), ("repo", "")):
            values = {source["facts"][key] for source in known if isinstance(source["facts"].get(key), str) and source["facts"][key].strip()}
            facts[key] = next(iter(values)) if len(values) == 1 else default
            if len(values) != 1:
                defaults[key] = "unknown" if not values else "conflicting sources"
        entry = {"id": task_id, "disposition": "absent", "sources": known, "facts": facts, "defaults": defaults}
        entry["proposed_record"] = archived_backfill(entry)
        entries.append(entry)
    return {"schema": "fm-task-backfill.v1", "data": str(data.resolve()), "state": str(state.resolve()),
            "policy": "missing-record-archived.v1", "entries": entries,
            "exclusions": [{"id": task_id, "reason": reason} for task_id, reason in sorted(excluded.items())],
            "ignored_sources": ignored}


def archived_backfill(entry: dict[str, Any]) -> dict[str, Any]:
    task_id, facts = entry["id"], entry["facts"]
    record = new_record(task_id, facts["title"], argparse.Namespace(body_file=None, body=None, start=False,
                         kind=facts["kind"], repo=facts["repo"], priority=None))
    record["state"] = "archived"
    record["closed"] = record["created"]
    record["history"] = ["backfill:missing-record-archived.v1; missing canonical archived by explicit policy; "
                         "created is registration date; sources=" + ",".join(source["path"] for source in entry["sources"]) +
                         "; defaults=" + json.dumps(entry["defaults"], ensure_ascii=False, sort_keys=True)]
    if any(source["type"] == "report.md" for source in entry["sources"]):
        record["links"]["report"] = f"data/{task_id}/report.md"
    return validate(record, task_id)


def backfill_apply(data: Path, state: Path, manifest: Path) -> int:
    value = json.loads(manifest.read_bytes())
    if value.get("schema") != "fm-task-backfill.v1" or value.get("policy") != "missing-record-archived.v1" or value.get("data") != str(data.resolve()) or value.get("state") != str(state.resolve()):
        raise Refusal("backfill manifest does not address the selected home/policy")
    entries = value.get("entries")
    if not isinstance(entries, list) or any(not isinstance(entry, dict) or not isinstance(entry.get("id"), str)
                                          or entry.get("disposition") not in ("existing", "absent") for entry in entries):
        raise Refusal("invalid backfill entries")
    results = []
    task_id = None
    try:
        for entry in entries:
            task_id = entry["id"]
            path = task_path(data, task_id)
            if path.exists() or path.is_symlink():
                read(data, task_id)
                results.append({"id": task_id, "result": "skipped-existing"})
                continue
            if entry["disposition"] != "absent":
                raise Refusal(f"existing task disappeared since preview: {task_id}")
            try:
                write(data, archived_backfill(entry), create=True)
            except Refusal:
                if not path.exists() and not path.is_symlink():
                    raise
                read(data, task_id)
                results.append({"id": task_id, "result": "skipped-existing"})
            else:
                results.append({"id": task_id, "result": "created"})
    except (Refusal, OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({"results": results, "failed_id": task_id, "error": str(exc)}, ensure_ascii=False))
        raise
    print(json.dumps({"results": results}, ensure_ascii=False))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--data", required=True, type=Path)
    sub = result.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("id"); add.add_argument("title")
    for name in ("kind", "repo", "priority", "body", "body_file"):
        add.add_argument("--" + name.replace("_", "-"))
    add.add_argument("--start", action="store_true")
    show_parser = sub.add_parser("show"); show_parser.add_argument("id"); show_parser.add_argument("--full", action="store_true")
    listing = sub.add_parser("list"); listing.add_argument("--state"); listing.add_argument("--limit", type=int, default=10000)
    listing.add_argument("--blocked", action="store_true"); listing.add_argument("--fields")
    ready = sub.add_parser("ready"); ready.add_argument("--limit", type=int, default=10000)
    for command in ("start", "done", "reopen", "archive", "unhold"):
        item = sub.add_parser(command); item.add_argument("id")
        item.add_argument("--pr"); item.add_argument("--report"); item.add_argument("--note")
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
    backfill = sub.add_parser("backfill-archived", help="one-time explicit ordinary identity import; ordinary queries never use it")
    backfill.add_argument("--state-dir", required=True, type=Path)
    mode = backfill.add_mutually_exclusive_group(required=True)
    mode.add_argument("--preview", action="store_true")
    mode.add_argument("--apply-file", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    data: Path = args.data
    try:
        if args.command == "backfill-archived":
            if args.preview:
                print(json.dumps(backfill_preview(data, args.state_dir), ensure_ascii=False))
                return 0
            return backfill_apply(data, args.state_dir, args.apply_file)
        if args.command == "add":
            write(data, new_record(args.id, args.title, args), create=True); return 0
        if args.command in ("list", "ready", "inventory", "progress-list"):
            items = records(data)
            if args.command == "inventory":
                print(json.dumps(inventory(items), ensure_ascii=False, separators=(",", ":"))); return 0
            if args.command == "progress-list":
                ids = sorted(item["id"] for item in items if item["state"] == "in_flight")
                print(json.dumps({"tasks": ids}, separators=(",", ":"))); return 0
            state = getattr(args, "state", None)
            if args.command == "ready":
                ready_ids = set(inventory(items)["ready_ids"])
                items = [item for item in items if item["id"] in ready_ids]
                list_records(items, None, args.limit, label="ready"); return 0
            if args.blocked:
                items = [item for item in items if item["blocked_by"] and item["state"] not in ("done", "archived")]
            if state == "held":
                items = [item for item in items if item["hold"] is not None and item["state"] not in ("done", "archived")]
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
        if record["state"] in ("done", "archived") and args.command in ("start", "hold", "unhold", "block", "unblock"):
            raise Refusal(f"terminal task {args.id} requires explicit reopen before {args.command}")
        old_body = record["body"]
        changed = update_common(record, args) if args.command in ("update", "start", "done", "reopen", "archive") else False
        if args.command == "update" and args.archive_body and record["body"] != old_body and old_body and old_body not in record["history"]:
            record["history"].append(old_body)
            changed = True
        if args.command == "start":
            if record["state"] != "in_flight" or record["closed"] is not None or record["completion"] is not None:
                record["state"] = "in_flight"; record["closed"] = None; record["completion"] = None; changed = True
        elif args.command == "done":
            if record["state"] not in ("done", "archived"):
                closed = date.today().isoformat()
                verb = "merged" if getattr(args, "pr", None) else "reported" if getattr(args, "report", None) else "done"
                record["state"] = "done"; record["closed"] = closed
                record["completion"] = {"verb": verb, "date": closed}; changed = True
        elif args.command == "reopen":
            if record["state"] != "queued" or record["closed"] is not None or record["completion"] is not None:
                record["state"] = "queued"; record["closed"] = None; record["completion"] = None; changed = True
        elif args.command == "archive":
            if record["state"] != "archived":
                record["state"] = "archived"; record["closed"] = record["closed"] or date.today().isoformat(); changed = True
        elif args.command == "hold":
            new_hold = {"reason": args.reason, "kind": args.kind, "until": args.until,
                        "set": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")}
            if record["hold"] is None or any(record["hold"].get(key) != new_hold[key] for key in ("reason", "kind", "until")):
                record["hold"] = new_hold; changed = True
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
