#!/usr/bin/env python3
"""Durable state owner for the opt-in autonomous Pavel operations loop.

The shell entrypoint header owns the operator-facing command contract.
This module keeps Telegram intake, backlog linkage, authority routing, delivery
transitions, and outbound receipts transactional under one home-local lock.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

SCHEMA = "fm-pavel-ops.v1"
EVENT_SCHEMA = "fm-pavel-ops-event.v1"
OUTBOUND_SCHEMA = "fm-pavel-ops-outbound.v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
PR_URL = re.compile(r"^https://[^\s]+$")
LIFECYCLE_NEXT = {
    "ready": "dispatched",
    "dispatched": "validating",
    "validating": "delivery_ready",
    "delivery_ready": "merge_queued",
    "merge_queued": "landed",
    "landed": "live",
}
TERMINAL_EVENT_STATES = {"conversation", "reply", "notified"}
HARD_SAFETY = {
    "credentials",
    "irreversible",
    "legal",
    "security-authority",
    "unbudgeted-spend",
}


class OpsError(RuntimeError):
    pass


class UnknownSendError(OpsError):
    pass


class RetryableSendError(OpsError):
    pass


def epoch() -> int:
    return int(time.time())


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def atomic_json(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise OpsError(f"missing record: {path}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise OpsError(f"unreadable record {path}: {exc}") from exc


def regular_private_file(path: Path, label: str) -> None:
    try:
        stat = path.lstat()
    except OSError as exc:
        raise OpsError(f"{label} is unavailable: {path}: {exc}") from exc
    if path.is_symlink() or not path.is_file() or stat.st_nlink != 1:
        raise OpsError(f"{label} must be a single-linked regular file: {path}")


class Home:
    def __init__(self) -> None:
        root = Path(__file__).resolve().parent.parent
        self.root = Path(os.environ.get("FM_ROOT_OVERRIDE", root)).resolve()
        self.home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", self.root))).resolve()
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", self.home / "state")).resolve()
        self.config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE", self.home / "config")).resolve()
        config_input = os.environ.get("FM_PAVEL_OPS_CONFIG", str(self.config_dir / "pavel-ops.json"))
        self.config_path = Path(os.path.abspath(os.path.expanduser(config_input)))
        self.ops = self.state / "pavel-ops"
        self.events = self.ops / "events"
        self.outbox = self.ops / "outbox"
        self.lock_path = self.ops / ".lock"
        self.audit_path = self.ops / "audit.jsonl"
        for directory in (self.ops, self.events, self.outbox):
            if directory.exists() or directory.is_symlink():
                if directory.is_symlink() or not directory.is_dir():
                    raise OpsError(f"Pavel operations state directory is unsafe: {directory}")
            else:
                directory.mkdir(parents=True, mode=0o700)
            os.chmod(directory, 0o700)
        self.config = self._load_config()

    def _load_config(self) -> dict[str, Any]:
        regular_private_file(self.config_path, "Pavel operations config")
        cfg = read_json(self.config_path)
        if not isinstance(cfg, dict) or cfg.get("version") != 1:
            raise OpsError("pavel-ops config must be a version 1 JSON object")
        if cfg.get("enabled") is not True:
            raise OpsError("pavel-ops config is present but enabled is not true")
        for key in ("project", "principal"):
            if not isinstance(cfg.get(key), str) or not cfg[key].strip():
                raise OpsError(f"pavel-ops config requires a non-empty {key}")
        for key in ("sender_ids", "chat_ids"):
            values = cfg.get(key)
            if not isinstance(values, list) or not values or any(not str(v).strip() for v in values):
                raise OpsError(f"pavel-ops config requires a non-empty {key} array")
            cfg[key] = [str(v) for v in values]
        worker = cfg.get("worker")
        if not isinstance(worker, dict):
            raise OpsError("pavel-ops config requires worker settings")
        if worker.get("harness") != "pi":
            raise OpsError("the Pavel operations worker harness must be pi")
        if worker.get("mode") != "no-mistakes" or worker.get("yolo") != "on":
            raise OpsError("the Pavel operations worker must use mode=no-mistakes and yolo=on")
        telegram = cfg.get("telegram")
        if not isinstance(telegram, dict):
            raise OpsError("pavel-ops config requires telegram settings")
        env_file = Path(str(telegram.get("env_file", ""))).expanduser()
        if not env_file.is_absolute():
            raise OpsError("telegram.env_file must be absolute")
        regular_private_file(env_file, "Telegram credential file")
        telegram["env_file"] = str(env_file)
        token_key = telegram.get("token_key", "TERENTYEV_BOT_TOKEN")
        if not isinstance(token_key, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", token_key):
            raise OpsError("telegram.token_key must be an uppercase environment-style name")
        telegram["token_key"] = token_key
        outbound_chat = telegram.get("outbound_chat_id")
        if outbound_chat is not None and str(outbound_chat) not in cfg["chat_ids"]:
            raise OpsError("telegram.outbound_chat_id must be one of chat_ids")
        if outbound_chat is not None:
            telegram["outbound_chat_id"] = str(outbound_chat)
        api_base = telegram.get("api_base", "https://api.telegram.org")
        if api_base != "https://api.telegram.org" and os.environ.get("FM_PAVEL_OPS_TESTING") != "1":
            raise OpsError("telegram.api_base may be overridden only under FM_PAVEL_OPS_TESTING=1")
        telegram["api_base"] = str(api_base).rstrip("/")
        budget = cfg.get("budget", {})
        if not isinstance(budget, dict):
            raise OpsError("budget must be an object when present")
        for key, value in budget.items():
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
                raise OpsError(f"budget.{key} must be a non-negative number")
        return cfg

    def lock(self):
        flags = os.O_RDWR | os.O_CREAT
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(self.lock_path, flags, 0o600)
        except OSError as exc:
            raise OpsError(f"Pavel operations lock is unavailable: {exc}") from exc
        lock_stat = os.fstat(fd)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
            os.close(fd)
            raise OpsError("Pavel operations lock must be a single-linked regular file")
        os.fchmod(fd, 0o600)
        handle = os.fdopen(fd, "a+")
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle

    def audit(self, action: str, **fields: Any) -> None:
        row = {"schema": SCHEMA, "at": epoch(), "action": action, **fields}
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(self.audit_path, flags, 0o600)
        audit_stat = os.fstat(fd)
        if not stat.S_ISREG(audit_stat.st_mode) or audit_stat.st_nlink != 1:
            os.close(fd)
            raise OpsError("Pavel operations audit must be a single-linked regular file")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as handle:
            handle.write(canonical(row) + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def event_path(self, event_id: str) -> Path:
        if not SAFE_ID.fullmatch(event_id):
            raise OpsError("invalid Pavel event id")
        return self.events / f"{event_id}.json"

    def load_event(self, event_id: str) -> dict[str, Any]:
        event = read_json(self.event_path(event_id))
        if not isinstance(event, dict) or event.get("schema") != EVENT_SCHEMA:
            raise OpsError(f"invalid Pavel event record: {event_id}")
        return event

    def save_event(self, event: dict[str, Any]) -> None:
        event["updated_at"] = epoch()
        atomic_json(self.event_path(event["id"]), event)

    def append_transition(self, event: dict[str, Any], state: str, evidence: str) -> None:
        event.setdefault("transitions", []).append(
            {"at": epoch(), "from": event.get("state"), "to": state, "evidence": evidence}
        )
        event["state"] = state
        event["last_error"] = ""


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    return values


def run_checked(home: Home, args: list[str], timeout: int = 60) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=home.home,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "FM_HOME": str(home.home)},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise OpsError(f"command failed to run: {args[0]}: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()[:500]
        raise OpsError(f"command failed ({result.returncode}): {' '.join(args[:3])}: {detail}")
    return result.stdout


def ensure_wake(home: Home, event: dict[str, Any], reason: str) -> bool:
    wake_key = event["wake_key"]
    command = (
        'set -eu; . "$1"; '
        'if fm_wake_queued_keys check | grep -Fqx -- "$2"; then exit 0; fi; '
        'fm_wake_append check "$2" "$3"'
    )
    lib = home.root / "bin" / "fm-wake-lib.sh"
    try:
        subprocess.run(
            ["bash", "-c", command, "fm-pavel-ops", str(lib), wake_key, reason],
            cwd=home.home,
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "FM_HOME": str(home.home), "FM_STATE_OVERRIDE": str(home.state)},
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def event_identity(raw: dict[str, Any]) -> tuple[str, str]:
    transport = str(raw.get("transport", "telegram"))
    chat_id = str(raw.get("chat_id", ""))
    source_id = str(raw.get("update_id") or raw.get("event_id") or "")
    if transport != "telegram" or not chat_id or not source_id:
        raise OpsError("intake requires transport=telegram, chat_id, and update_id")
    digest = sha(f"{transport}\0{chat_id}\0{source_id}")[:10]
    safe_source = re.sub(r"[^A-Za-z0-9._-]", "-", source_id)[-32:] or "event"
    return f"tg-{safe_source}-{digest}", f"pavel-ops-{digest}"


def validate_intake(home: Home, raw: dict[str, Any]) -> None:
    sender = str(raw.get("sender_id", ""))
    chat = str(raw.get("chat_id", ""))
    if sender not in home.config["sender_ids"]:
        raise OpsError("Telegram event sender is not the configured Pavel principal")
    if chat not in home.config["chat_ids"]:
        raise OpsError("Telegram event chat is not an allowed Pavel operations chat")
    text = raw.get("text", "")
    if not isinstance(text, str):
        raise OpsError("Telegram event text must be a string")
    if not text.strip() and not raw.get("attachments"):
        raise OpsError("Telegram event has neither text nor attachment metadata")


def ingest_one(home: Home, raw: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    validate_intake(home, raw)
    event_id, wake_key = event_identity(raw)
    source = {
        "transport": "telegram",
        "chat_id": str(raw["chat_id"]),
        "update_id": str(raw.get("update_id") or raw.get("event_id")),
        "message_id": str(raw.get("message_id", "")),
        "sender_id": str(raw["sender_id"]),
        "date": raw.get("date"),
        "text": raw.get("text", ""),
        "attachments": raw.get("attachments") or [],
        "reply_to_message_id": str(raw.get("reply_to_message_id", "")),
    }
    source_digest = sha(canonical(source))
    path = home.event_path(event_id)
    duplicate = path.exists()
    if duplicate:
        event = home.load_event(event_id)
        if event.get("source_digest") != source_digest:
            home.audit("intake-conflict", event=event_id, source_digest=source_digest)
            raise OpsError(f"Telegram identity collision for {event_id}; original record preserved")
    else:
        event = {
            "schema": EVENT_SCHEMA,
            "id": event_id,
            "wake_key": wake_key,
            "source": source,
            "source_digest": source_digest,
            "state": "captured",
            "classification": None,
            "authority": None,
            "task_id": None,
            "related_task": None,
            "wake_pending": True,
            "attempts": 0,
            "last_error": "",
            "created_at": epoch(),
            "updated_at": epoch(),
            "transitions": [],
        }
        home.save_event(event)
        home.audit("intake", event=event_id, duplicate=False)
    if event.get("wake_pending") or event.get("state") == "captured":
        woke = ensure_wake(home, event, f"Pavel Telegram event {event_id} requires triage")
        if woke:
            event["wake_pending"] = False
            home.save_event(event)
            home.audit("wake-published", event=event_id, wake_key=wake_key)
    return event, duplicate


def task_exists(home: Home, task_id: str) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["tasks-axi", "show", task_id, "--full"],
            cwd=home.home,
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, "FM_HOME": str(home.home)},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise OpsError(f"tasks-axi unavailable: {exc}") from exc
    if result.returncode == 0:
        return True, result.stdout
    return False, result.stderr or result.stdout


def default_task_id(event: dict[str, Any]) -> str:
    message_id = event["source"].get("message_id") or event["source"].get("update_id")
    base = re.sub(r"[^A-Za-z0-9]+", "-", str(message_id)).strip("-")[-24:] or "event"
    return f"pavel-{base}-{sha(event['id'])[:6]}"


def ensure_task(home: Home, event: dict[str, Any], task_id: str, title: str, intent: str, explicit: bool) -> None:
    if not SAFE_ID.fullmatch(task_id):
        raise OpsError("task id is not path-safe")
    marker = f"Pavel event: {event['id']}"
    exists, detail = task_exists(home, task_id)
    if exists:
        if marker in detail:
            return
        if explicit and "Pavel event:" in detail:
            return
        raise OpsError(f"task id {task_id} exists without a Pavel event marker")
    source_text = event["source"].get("text", "").strip()
    body = (
        f"{marker}\n"
        f"Telegram chat/message: {event['source'].get('chat_id')}/{event['source'].get('message_id')}\n"
        f"Accepted Pavel intent: {intent.strip()}\n"
        f"Source text: {source_text}"
    )
    run_checked(
        home,
        [
            "tasks-axi", "add", task_id, title,
            "--kind", "ship", "--repo", home.config["project"], "--body", body,
        ],
    )
    exists, detail = task_exists(home, task_id)
    if not exists or marker not in detail:
        raise OpsError(f"task id {task_id} was not durably linked to this Pavel event")


def safe_hold_reason(reason: str) -> str:
    cleaned = " ".join(reason.replace("(", "[").replace(")", "]").split())
    return cleaned[:500]


def hold_external(home: Home, task_id: str, reason: str) -> None:
    run_checked(home, ["tasks-axi", "hold", task_id, "--kind", "external", "--reason", safe_hold_reason(reason)])


def hold_captain(home: Home, task_id: str, reason: str) -> None:
    owner = os.environ.get("FM_PAVEL_CAPTAIN_HOLD", str(home.root / "bin" / "fm-captain-hold.sh"))
    run_checked(home, [owner, "hold", task_id, "--reason", safe_hold_reason(reason)])


def validate_existing_task_link(home: Home, event: dict[str, Any], task_id: str, explicit: bool) -> None:
    if not SAFE_ID.fullmatch(task_id):
        raise OpsError("task id is not path-safe")
    exists, detail = task_exists(home, task_id)
    if not exists:
        return
    marker = f"Pavel event: {event['id']}"
    if marker in detail:
        return
    if explicit and "Pavel event:" in detail:
        return
    raise OpsError(f"task id {task_id} exists without a Pavel event marker")


def classification_contract(event: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    if args.as_kind in ("conversation", "reply"):
        return {
            "as": args.as_kind,
            "authority": args.authority,
            "related_task": args.related_task,
            "reason": args.reason,
            "title": args.title or "",
            "intent": args.intent or "",
            "question": args.question or "",
            "safety": args.safety or "",
        }
    task_id = args.task_id or default_task_id(event)
    return {
        "as": "task",
        "authority": args.authority,
        "related_task": args.related_task,
        "reason": args.reason,
        "task_id": task_id,
        "title": args.title or "",
        "intent": args.intent or "",
        "question": args.question or "",
        "safety": args.safety or "",
    }


def classify(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    event = home.load_event(args.event)
    if not args.reason.strip():
        raise OpsError("classification requires a non-empty reason")
    if event["state"] != "captured":
        wanted = classification_contract(event, args)
        existing = event.get("classification") or {}
        if existing == wanted and event.get("task_id") == wanted.get("task_id"):
            return event
        if existing == wanted and args.as_kind in ("conversation", "reply"):
            return event
        raise OpsError(f"event {event['id']} is already classified as {event['state']}")

    if args.as_kind in ("conversation", "reply"):
        if args.authority:
            raise OpsError("conversation and reply classifications do not take an authority route")
        if args.title or args.intent or args.question or args.safety:
            raise OpsError("conversation and reply classifications do not take task-only fields")
        if args.as_kind == "reply" and not args.related_task:
            raise OpsError("a conversational reply requires --related-task for auditability")
        event["classification"] = {
            "as": args.as_kind,
            "authority": None,
            "related_task": args.related_task,
            "reason": args.reason,
            "title": "",
            "intent": "",
            "question": "",
            "safety": "",
        }
        event["related_task"] = args.related_task
        home.append_transition(event, args.as_kind, args.reason)
        home.save_event(event)
        home.audit("classified", event=event["id"], classification=args.as_kind, task=args.related_task)
        return event

    if not args.title or not args.title.strip() or not args.intent or not args.intent.strip() or not args.authority:
        raise OpsError("task classification requires non-empty --title, --intent, and --authority")
    if args.related_task:
        raise OpsError("task classification uses --task-id, not --related-task")
    if args.authority == "business-ambiguity" and not args.question:
        raise OpsError("business ambiguity requires one batched --question")
    if args.authority == "hard-safety":
        if args.safety not in HARD_SAFETY:
            raise OpsError("hard safety requires --safety credentials|irreversible|legal|security-authority|unbudgeted-spend")
    elif args.safety:
        raise OpsError("--safety is accepted only with --authority hard-safety")

    task_id = args.task_id or default_task_id(event)
    explicit = bool(args.task_id)
    wanted = classification_contract(event, args)
    pending = event.get("pending_classification")
    if pending is not None and pending != wanted:
        raise OpsError(f"event {event['id']} has a pending classification with different details")
    validate_existing_task_link(home, event, task_id, explicit)
    if pending is None:
        event["pending_classification"] = wanted
        event["task_id"] = task_id
        event["authority"] = args.authority
        home.save_event(event)
    ensure_task(home, event, task_id, args.title, args.intent, explicit)
    event["task_id"] = task_id
    event["authority"] = args.authority
    event["classification"] = wanted
    event.pop("pending_classification", None)
    if args.authority == "ordinary":
        target = "ready"
        evidence = "ordinary reversible work inside accepted Pavel intent"
    elif args.authority == "business-ambiguity":
        hold_external(home, task_id, f"Pavel clarification pending: {args.question}")
        target = "awaiting_pavel"
        evidence = args.question
    else:
        hold_captain(home, task_id, f"Pavel request crosses hard safety boundary {args.safety}: {args.reason}")
        target = "awaiting_nikita"
        evidence = f"hard safety: {args.safety}"
    home.append_transition(event, target, evidence)
    home.save_event(event)
    home.audit("classified", event=event["id"], classification="task", authority=args.authority, task=task_id)
    return event


def resolve_pavel(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    event = home.load_event(args.event)
    reply = home.load_event(args.reply_event)
    task_id = event.get("task_id")
    if not task_id:
        raise OpsError("clarification event has no backlog task")
    contract = {"reply_event": reply["id"], "related_task": task_id, "answer": args.answer}
    existing_contract = event.get("pavel_resolution")
    if existing_contract is not None and existing_contract != contract:
        raise OpsError("Pavel clarification resolution already exists with different details")
    if event["state"] == "ready":
        if existing_contract == contract and reply.get("related_task") == task_id:
            return event
        raise OpsError("Pavel clarification was already resolved with different details")
    if event["state"] != "awaiting_pavel":
        raise OpsError("only an event awaiting Pavel can be resolved by Pavel")
    if reply["state"] not in {"captured", "reply", "conversation"}:
        raise OpsError("the Pavel answer event is not available for clarification resolution")
    if reply["state"] != "captured" and reply.get("related_task") != task_id:
        raise OpsError("the classified Pavel answer belongs to another task")
    if reply["state"] != "captured" and last_transition_evidence(reply, "reply") not in {"", args.answer}:
        raise OpsError("Pavel clarification answer event already has different evidence")
    if existing_contract is None:
        event["pavel_resolution"] = contract
        home.save_event(event)
    if reply["state"] == "captured":
        reply["classification"] = {
            "as": "reply", "authority": None, "related_task": task_id,
            "reason": "Pavel clarification answer",
        }
        reply["related_task"] = task_id
        home.append_transition(reply, "reply", args.answer)
        home.save_event(reply)
    run_checked(home, ["tasks-axi", "unhold", task_id])
    event.setdefault("clarifications", []).append(
        {"at": epoch(), "reply_event": reply["id"], "answer": args.answer}
    )
    home.append_transition(event, "ready", f"Pavel answered: {args.answer}")
    home.save_event(event)
    home.audit("pavel-answer", event=event["id"], reply_event=reply["id"], task=task_id)
    return event


def last_transition_evidence(event: dict[str, Any], state: str) -> str:
    for transition_record in reversed(event.get("transitions", [])):
        if transition_record.get("to") == state:
            return str(transition_record.get("evidence", ""))
    return ""


def validate_transition_replay(event: dict[str, Any], args: argparse.Namespace) -> None:
    if not args.evidence.strip():
        raise OpsError("every lifecycle transition requires non-empty --evidence")
    if last_transition_evidence(event, args.state) != args.evidence:
        raise OpsError(f"event {event['id']} is already {args.state} with different evidence")
    if args.state == "merge_queued":
        if not args.pr_url or not PR_URL.fullmatch(args.pr_url):
            raise OpsError("merge_queued requires a full HTTPS --pr-url")
        if event.get("pr_url") != args.pr_url:
            raise OpsError(f"event {event['id']} is already merge_queued with another PR URL")
    elif args.pr_url:
        raise OpsError("--pr-url is accepted only with merge_queued")
    if args.state == "live":
        if not args.live_url or not PR_URL.fullmatch(args.live_url):
            raise OpsError("live requires a full HTTPS --live-url")
        if event.get("live_url") != args.live_url:
            raise OpsError(f"event {event['id']} is already live with another live URL")
    elif args.live_url:
        raise OpsError("--live-url is accepted only with live")


def transition(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    event = home.load_event(args.event)
    current = event["state"]
    expected = LIFECYCLE_NEXT.get(current)
    if current == args.state:
        validate_transition_replay(event, args)
        return event
    if expected != args.state:
        raise OpsError(f"invalid Pavel lifecycle transition: {current} -> {args.state}")
    if not args.evidence.strip():
        raise OpsError("every lifecycle transition requires non-empty --evidence")
    if args.state == "merge_queued":
        if not args.pr_url or not PR_URL.fullmatch(args.pr_url):
            raise OpsError("merge_queued requires a full HTTPS --pr-url")
        if home.config["worker"].get("yolo") != "on":
            raise OpsError("Pavel autonomous merge authority is not enabled")
        event["pr_url"] = args.pr_url
    elif args.pr_url:
        raise OpsError("--pr-url is accepted only with merge_queued")
    if args.state == "live":
        if not args.live_url or not PR_URL.fullmatch(args.live_url):
            raise OpsError("live requires a full HTTPS --live-url")
        event["live_url"] = args.live_url
    elif args.live_url:
        raise OpsError("--live-url is accepted only with live")
    home.append_transition(event, args.state, args.evidence)
    home.save_event(event)
    home.audit("transition", event=event["id"], state=args.state, task=event.get("task_id"))
    return event


def record_failure(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    event = home.load_event(args.event)
    event["attempts"] = int(event.get("attempts", 0)) + 1
    event["last_error"] = args.error
    event.setdefault("failures", []).append({"at": epoch(), "stage": args.stage, "error": args.error})
    event["wake_pending"] = True
    home.save_event(event)
    home.audit("retryable-failure", event=event["id"], stage=args.stage, attempt=event["attempts"])
    if ensure_wake(home, event, f"Pavel task {event.get('task_id') or event['id']} needs retry at {args.stage}"):
        event["wake_pending"] = False
        home.save_event(event)
    return event


def outbound_path(home: Home, outbound_id: str) -> Path:
    if not SAFE_ID.fullmatch(outbound_id):
        raise OpsError("invalid outbound id")
    return home.outbox / f"{outbound_id}.json"


def telegram_send(home: Home, chat_id: str, text: str) -> str:
    telegram = home.config["telegram"]
    env_values = parse_env_file(Path(telegram["env_file"]))
    token = env_values.get(telegram["token_key"])
    if not token:
        raise OpsError(f"Telegram credential file lacks {telegram['token_key']}")
    body = urllib.parse.urlencode(
        {"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"}
    ).encode()
    request = urllib.request.Request(
        f"{telegram['api_base']}/bot{token}/sendMessage",
        data=body,
        headers={"User-Agent": "firstmate-pavel-ops/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError) as exc:
        raise UnknownSendError(f"Telegram send has no confirmed receipt: {exc}") from exc
    if not isinstance(result, dict):
        raise UnknownSendError("Telegram returned an unreadable send receipt")
    if result.get("ok") is not True:
        raise RetryableSendError(f"Telegram rejected send: {str(result)[:300]}")
    message_id = (result.get("result") or {}).get("message_id")
    if message_id is None:
        raise UnknownSendError("Telegram accepted send without a message_id receipt")
    return str(message_id)


def expected_outbound_contract(home: Home, event: dict[str, Any], purpose: str, text: str, outbound_id: str) -> dict[str, str]:
    return {
        "schema": OUTBOUND_SCHEMA,
        "id": outbound_id,
        "event_id": event["id"],
        "purpose": purpose,
        "chat_id": str(home.config["telegram"].get("outbound_chat_id") or event["source"]["chat_id"]),
        "text_digest": sha(text),
    }


def validate_outbound_contract(outbound_id: str, outbound: dict[str, Any], expected: dict[str, str]) -> None:
    for key, value in expected.items():
        if str(outbound.get(key, "")) != value:
            raise OpsError(f"outbound {outbound_id} already exists with different {key}")


def send_message(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    event = home.load_event(args.event)
    purpose = args.purpose
    allowed = {
        "qa": {"conversation", "reply"},
        "ack": {"ready", "awaiting_pavel", "awaiting_nikita", "dispatched", "validating"},
        "clarification": {"awaiting_pavel"},
        "live-completion": {"live", "notified"},
    }
    if event["state"] not in allowed[purpose]:
        raise OpsError(f"cannot send {purpose} while event is {event['state']}")
    outbound_id = f"{event['id']}-{purpose}"
    path = outbound_path(home, outbound_id)
    expected = expected_outbound_contract(home, event, purpose, args.text, outbound_id)
    if path.exists():
        outbound = read_json(path)
        validate_outbound_contract(outbound_id, outbound, expected)
        status = outbound.get("status")
        if status == "delivered":
            if purpose == "live-completion" and event["state"] != "notified":
                message_id = outbound.get("telegram_message_id")
                if message_id is None:
                    raise OpsError(f"delivered outbound {outbound_id} lacks a Telegram receipt")
                home.append_transition(event, "notified", f"Telegram message {message_id} reconciled")
                home.save_event(event)
                home.audit(
                    "outbound-delivered-reconciled",
                    event=event["id"],
                    outbound=outbound_id,
                    telegram_message_id=str(message_id),
                )
            return outbound
        if status in {"sending", "unknown"}:
            raise OpsError(
                f"outbound {outbound_id} has unknown delivery after an interrupted or unconfirmed send; "
                "reconcile it before retrying"
            )
    else:
        outbound = {
            "schema": OUTBOUND_SCHEMA,
            "id": outbound_id,
            "event_id": event["id"],
            "purpose": purpose,
            "chat_id": expected["chat_id"],
            "text": args.text,
            "text_digest": expected["text_digest"],
            "status": "pending",
            "attempts": 0,
            "created_at": epoch(),
            "updated_at": epoch(),
        }
    if outbound.get("text_digest") != sha(args.text):
        raise OpsError(f"outbound {outbound_id} already exists with different text")
    outbound["status"] = "sending"
    outbound["attempts"] = int(outbound.get("attempts", 0)) + 1
    outbound["updated_at"] = epoch()
    atomic_json(path, outbound)
    home.audit("outbound-sending", event=event["id"], outbound=outbound_id, attempt=outbound["attempts"])

    try:
        message_id = telegram_send(home, outbound["chat_id"], outbound["text"])
    except UnknownSendError as exc:
        outbound["status"] = "unknown"
        outbound["last_error"] = str(exc)
        outbound["updated_at"] = epoch()
        atomic_json(path, outbound)
        home.audit("outbound-unknown", event=event["id"], outbound=outbound_id, error=str(exc))
        raise
    except RetryableSendError as exc:
        outbound["status"] = "retryable"
        outbound["last_error"] = str(exc)
        outbound["updated_at"] = epoch()
        atomic_json(path, outbound)
        home.audit("outbound-failed", event=event["id"], outbound=outbound_id, error=str(exc))
        raise

    outbound["status"] = "delivered"
    outbound["telegram_message_id"] = message_id
    outbound["delivered_at"] = epoch()
    outbound["updated_at"] = epoch()
    atomic_json(path, outbound)
    if purpose == "live-completion" and event["state"] != "notified":
        home.append_transition(event, "notified", f"Telegram message {message_id} confirmed")
        home.save_event(event)
    home.audit("outbound-delivered", event=event["id"], outbound=outbound_id, telegram_message_id=message_id)
    return outbound


def reconcile_outbound(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    if bool(args.sent_message_id) == bool(args.confirm_not_sent):
        raise OpsError("choose exactly one of --sent-message-id or --confirm-not-sent")
    path = outbound_path(home, args.outbound)
    outbound = read_json(path)
    if outbound.get("status") not in {"sending", "unknown"}:
        raise OpsError("only an interrupted or delivery-unknown send requires reconciliation")
    event = home.load_event(outbound["event_id"])
    if args.sent_message_id:
        outbound["status"] = "delivered"
        outbound["telegram_message_id"] = args.sent_message_id
        outbound["delivered_at"] = epoch()
        if outbound["purpose"] == "live-completion" and event["state"] != "notified":
            home.append_transition(event, "notified", f"Telegram message {args.sent_message_id} reconciled")
            home.save_event(event)
    elif args.confirm_not_sent:
        outbound["status"] = "retryable"
        outbound["last_error"] = "operator confirmed interrupted attempt did not send"
    else:
        raise OpsError("choose --sent-message-id or --confirm-not-sent")
    outbound["updated_at"] = epoch()
    atomic_json(path, outbound)
    home.audit("outbound-reconciled", outbound=args.outbound, status=outbound["status"])
    return outbound


def recover(home: Home, startup: bool = False) -> list[str]:
    actions: list[str] = []
    for path in sorted(home.events.glob("*.json")):
        try:
            event = read_json(path)
        except OpsError as exc:
            actions.append(str(exc))
            continue
        needs_wake = bool(event.get("wake_pending"))
        if event.get("state") == "captured":
            needs_wake = True
        active_states = {"ready", "dispatched", "validating", "delivery_ready", "merge_queued"}
        if event.get("state") in active_states and event.get("task_id"):
            meta = home.state / f"{event['task_id']}.meta"
            if not meta.exists():
                needs_wake = True
            if event.get("last_error") or event.get("failures"):
                needs_wake = True
        if event.get("state") in {"landed", "live"}:
            needs_wake = True
        if needs_wake:
            if ensure_wake(home, event, f"Pavel operations recovery for {event['id']} at {event.get('state')}"):
                event["wake_pending"] = False
                atomic_json(path, event)
                actions.append(f"re-woke {event['id']} at {event.get('state')}")
            else:
                actions.append(f"wake retry failed for {event['id']}")
    for path in sorted(home.outbox.glob("*.json")):
        try:
            outbound = read_json(path)
        except OpsError as exc:
            actions.append(str(exc))
            continue
        if outbound.get("status") in {"sending", "unknown"}:
            event = home.load_event(outbound["event_id"])
            if ensure_wake(home, event, f"Pavel outbound {outbound['id']} has unknown delivery and needs reconciliation"):
                actions.append(f"unknown outbound {outbound['id']} surfaced")
        elif outbound.get("status") == "retryable":
            event = home.load_event(outbound["event_id"])
            if ensure_wake(home, event, f"Pavel outbound {outbound['id']} is retryable"):
                actions.append(f"retryable outbound {outbound['id']} surfaced")
    if actions:
        home.audit("startup-recovery" if startup else "recovery", actions=actions)
    return actions


def adopt(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    exists, _ = task_exists(home, args.task_id)
    if not exists:
        raise OpsError(f"cannot adopt missing backlog task {args.task_id}")
    event_id = f"legacy-task-{args.task_id}"
    path = home.event_path(event_id)
    state = args.state
    authority = "business-ambiguity" if state == "awaiting_pavel" else "ordinary"
    if path.exists():
        event = home.load_event(event_id)
        if (
            event.get("state") != state
            or event.get("task_id") != args.task_id
            or event.get("authority") != authority
            or event.get("classification", {}).get("reason") != args.note
            or event.get("source", {}).get("text") != args.note
            or last_transition_evidence(event, state) != args.note
        ):
            raise OpsError(f"legacy task {args.task_id} was already adopted with different details")
        return event
    event = {
        "schema": EVENT_SCHEMA,
        "id": event_id,
        "wake_key": f"pavel-ops-{sha(event_id)[:10]}",
        "source": {"transport": "legacy", "chat_id": "", "update_id": event_id, "message_id": "", "sender_id": "", "text": args.note, "attachments": [], "reply_to_message_id": ""},
        "source_digest": sha(args.note),
        "state": state,
        "classification": {"as": "task", "authority": authority, "reason": args.note},
        "authority": authority,
        "task_id": args.task_id,
        "related_task": None,
        "wake_pending": state == "ready",
        "attempts": 0,
        "last_error": "",
        "created_at": epoch(),
        "updated_at": epoch(),
        "transitions": [{"at": epoch(), "from": "legacy", "to": state, "evidence": args.note}],
    }
    home.save_event(event)
    home.audit("legacy-task-adopted", event=event_id, task=args.task_id, state=state)
    return event


def migration_audit(home: Home, args: argparse.Namespace) -> dict[str, Any]:
    result: dict[str, Any] = {"schema": SCHEMA, "legacy_pending": [], "held_pavel_tasks": [], "clone": None}
    if args.legacy_pending:
        pending = Path(args.legacy_pending).expanduser().resolve()
        regular_private_file(pending, "legacy Pavel pending queue")
        with pending.open(encoding="utf-8") as handle:
            for line_no, raw in enumerate(handle, 1):
                if not raw.strip():
                    continue
                try:
                    row = json.loads(raw)
                    result["legacy_pending"].append(str(row.get("id") or f"line-{line_no}"))
                except json.JSONDecodeError:
                    result["legacy_pending"].append(f"corrupt-line-{line_no}")
    try:
        output = run_checked(home, ["tasks-axi", "list", "--state", "held", "--limit", "500"])
        result["held_pavel_tasks"] = sorted(set(re.findall(r"\b(pavel-[A-Za-z0-9._-]+)\b", output)))
    except OpsError as exc:
        result["backlog_error"] = str(exc)
    if args.clone:
        clone = Path(args.clone).expanduser().resolve()
        if not (clone / ".git").exists():
            raise OpsError(f"migration clone is not a git checkout: {clone}")
        head = run_checked(home, ["git", "-C", str(clone), "rev-parse", "HEAD"]).strip()
        status = run_checked(home, ["git", "-C", str(clone), "status", "--porcelain"])
        counts = run_checked(home, ["git", "-C", str(clone), "rev-list", "--left-right", "--count", "origin/main...HEAD"]).strip().split()
        behind, ahead = (int(counts[0]), int(counts[1])) if len(counts) == 2 else (-1, -1)
        result["clone"] = {
            "path": str(clone), "head": head, "expected_head_matches": not args.expected_head or head == args.expected_head,
            "dirty": bool(status.strip()), "behind_origin_main": behind, "ahead_origin_main": ahead,
            "recovery": "preserve HEAD on a dedicated branch and ship it independently before guarded fleet sync; never reset, force-push, merge, or clean it as migration",
        }
    return result


def print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2))


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    sub = p.add_subparsers(dest="command", required=True)

    ingest = sub.add_parser("ingest")
    ingest.add_argument("--file")

    inspect = sub.add_parser("inspect")
    inspect.add_argument("event")

    sub.add_parser("list")

    classify_p = sub.add_parser("classify")
    classify_p.add_argument("event")
    classify_p.add_argument("--as", dest="as_kind", choices=("task", "conversation", "reply"), required=True)
    classify_p.add_argument("--title")
    classify_p.add_argument("--intent")
    classify_p.add_argument("--reason", required=True)
    classify_p.add_argument("--authority", choices=("ordinary", "business-ambiguity", "hard-safety"))
    classify_p.add_argument("--question")
    classify_p.add_argument("--safety")
    classify_p.add_argument("--task-id")
    classify_p.add_argument("--related-task")

    resolve = sub.add_parser("resolve-pavel")
    resolve.add_argument("event")
    resolve.add_argument("--reply-event", required=True)
    resolve.add_argument("--answer", required=True)

    trans = sub.add_parser("transition")
    trans.add_argument("event")
    trans.add_argument("state", choices=tuple(LIFECYCLE_NEXT.values()))
    trans.add_argument("--evidence", required=True)
    trans.add_argument("--pr-url")
    trans.add_argument("--live-url")

    failure = sub.add_parser("failure")
    failure.add_argument("event")
    failure.add_argument("--stage", required=True)
    failure.add_argument("--error", required=True)

    send = sub.add_parser("send")
    send.add_argument("event")
    send.add_argument("--purpose", choices=("qa", "ack", "clarification", "live-completion"), required=True)
    send.add_argument("--text", required=True)

    reconcile = sub.add_parser("reconcile-outbound")
    reconcile.add_argument("outbound")
    reconcile.add_argument("--sent-message-id")
    reconcile.add_argument("--confirm-not-sent", action="store_true")

    recover_p = sub.add_parser("recover")
    recover_p.add_argument("--startup", action="store_true")

    adopt_p = sub.add_parser("adopt-task")
    adopt_p.add_argument("task_id")
    adopt_p.add_argument("--state", choices=("ready", "awaiting_pavel", "dispatched", "validating", "delivery_ready", "merge_queued", "landed", "live"), required=True)
    adopt_p.add_argument("--note", required=True)

    audit = sub.add_parser("migration-audit")
    audit.add_argument("--legacy-pending")
    audit.add_argument("--clone")
    audit.add_argument("--expected-head")
    return p


def main() -> int:
    args = parser().parse_args()
    try:
        home = Home()
        with home.lock():
            if args.command == "ingest":
                if args.file:
                    raw = read_json(Path(args.file))
                else:
                    raw = json.load(sys.stdin)
                if not isinstance(raw, dict):
                    raise OpsError("intake payload must be one JSON object")
                event, duplicate = ingest_one(home, raw)
                print_json({"event": event["id"], "duplicate": duplicate, "state": event["state"], "wake_pending": event["wake_pending"]})
            elif args.command == "inspect":
                print_json(home.load_event(args.event))
            elif args.command == "list":
                rows = [read_json(path) for path in sorted(home.events.glob("*.json"))]
                print_json(rows)
            elif args.command == "classify":
                print_json(classify(home, args))
            elif args.command == "resolve-pavel":
                print_json(resolve_pavel(home, args))
            elif args.command == "transition":
                print_json(transition(home, args))
            elif args.command == "failure":
                print_json(record_failure(home, args))
            elif args.command == "send":
                print_json(send_message(home, args))
            elif args.command == "reconcile-outbound":
                print_json(reconcile_outbound(home, args))
            elif args.command == "recover":
                actions = recover(home, startup=args.startup)
                for action in actions:
                    print(f"pavel-ops: {action}")
            elif args.command == "adopt-task":
                print_json(adopt(home, args))
            elif args.command == "migration-audit":
                print_json(migration_audit(home, args))
            else:
                raise OpsError(f"unknown command: {args.command}")
    except (OpsError, OSError, json.JSONDecodeError) as exc:
        print(f"fm-pavel-ops: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
