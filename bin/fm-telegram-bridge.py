#!/usr/bin/env python3
"""Secure local Hermes Telegram bridge for Firstmate.

This module owns the signed intake envelope, private request/context artifacts,
idempotent Telegram delivery journal, task correlation, and local installation.
Hermes remains transport-only: nothing here launches an agent or worker.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable

VERSION = 1
PLUGIN_NAME = "firstmate-telegram"
REQUEST_RE = re.compile(r"^tg-[0-9a-f]{32}$")
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
OWNER_RE = re.compile(r"^[1-9][0-9]{0,19}$")
CHAT_RE = re.compile(r"^-?[1-9][0-9]{0,19}$")
MESSAGE_RE = re.compile(r"^[1-9][0-9]{0,19}$")
SIGNATURE_RE = re.compile(r"^[0-9a-f]{64}$")
COMMAND_RE = re.compile(r"^/firstmate(?:@[A-Za-z0-9_]{3,})?\s+(.+)$", re.IGNORECASE | re.DOTALL)
MAX_ENVELOPE_BYTES = 65536
MAX_REQUEST_CHARS = 12000
MAX_REPLY_CHARS = 40000
DEFAULT_REPLY_LIMIT = 3800
DEFAULT_REPLY_CAP = 10
DEFAULT_MAX_AGE = 604800
DEFAULT_FOLLOWUP_CAP = 3

EXIT_USAGE = 2
EXIT_DUPLICATE = 3
EXIT_OFFLINE = 4
EXIT_REJECTED = 5
EXIT_UNRESOLVED = 6


class BridgeError(Exception):
    """Safe operator-facing bridge failure without payload content."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


def _now() -> int:
    raw = os.environ.get("FM_TELEGRAM_NOW_OVERRIDE")
    if raw is not None:
        if not raw.isdigit() or len(raw) > 18:
            raise BridgeError("invalid clock override", EXIT_REJECTED)
        return int(raw)
    return int(time.time())


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() not in {"", "0", "false", "no", "off"}


def _canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)


def _require_private_dir(path: Path, *, create: bool = False) -> Path:
    if create and not path.exists() and not path.is_symlink():
        path.mkdir(parents=True, mode=0o700)
    try:
        info = path.lstat()
    except OSError as exc:
        raise BridgeError("private bridge directory is unavailable") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise BridgeError("private bridge directory is unsafe")
    if info.st_uid != os.getuid():
        raise BridgeError("private bridge directory has the wrong owner")
    if stat.S_IMODE(info.st_mode) != 0o700:
        try:
            path.chmod(0o700)
        except OSError as exc:
            raise BridgeError("private bridge directory is not private") from exc
    return path


def _require_private_file(path: Path, *, max_bytes: int = MAX_ENVELOPE_BYTES) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        raise BridgeError("private bridge file is unavailable") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise BridgeError("private bridge file is unsafe")
    if info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise BridgeError("private bridge file failed identity checks")
    if info.st_size > max_bytes:
        raise BridgeError("private bridge file exceeds its size limit")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise BridgeError("private bridge file cannot be read") from exc


def _safe_destination(path: Path, parent: Path) -> None:
    _require_private_dir(parent, create=True)
    if not path.exists() and not path.is_symlink():
        return
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise BridgeError("private bridge destination is unsafe")
    if info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise BridgeError("private bridge destination failed identity checks")


def _atomic_write(path: Path, data: bytes, *, exclusive: bool = False) -> bool:
    parent = _require_private_dir(path.parent, create=True)
    _safe_destination(path, parent)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.fmt.", dir=str(parent))
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        info = tmp.lstat()
        if info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            raise BridgeError("private bridge temporary file failed identity checks")
        if exclusive:
            try:
                os.link(tmp, path)
            except FileExistsError:
                return False
            linked = path.lstat()
            if linked.st_uid != os.getuid() or linked.st_nlink != 2 or stat.S_IMODE(linked.st_mode) != 0o600:
                try:
                    path.unlink()
                except OSError:
                    pass
                raise BridgeError("private bridge exclusive publication failed")
            return True
        os.replace(tmp, path)
        final = path.lstat()
        if final.st_uid != os.getuid() or final.st_nlink != 1 or stat.S_IMODE(final.st_mode) != 0o600:
            try:
                path.unlink()
            except OSError:
                pass
            raise BridgeError("private bridge publication failed")
        return True
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _json_bytes(value: dict[str, Any]) -> bytes:
    return _canonical(value) + b"\n"


def _read_json_private(path: Path, *, max_bytes: int = MAX_ENVELOPE_BYTES) -> dict[str, Any]:
    raw = _require_private_file(path, max_bytes=max_bytes)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError("private bridge JSON is malformed") from exc
    if not isinstance(value, dict):
        raise BridgeError("private bridge JSON has the wrong shape")
    return value


def _fm_home(explicit: str | None = None) -> Path:
    raw = explicit or os.environ.get("FM_HOME")
    if not raw:
        raw = str(Path(__file__).resolve().parent.parent)
    path = Path(raw).expanduser().resolve()
    if not path.is_dir():
        raise BridgeError("Firstmate home is unavailable")
    return path


def _settings_path(home: Path) -> Path:
    return home / "config" / "telegram-bridge" / "settings.json"


def _load_settings(home: Path, *, require_enabled: bool = True) -> dict[str, Any]:
    settings = _read_json_private(_settings_path(home), max_bytes=32768)
    required = {
        "version", "enabled", "owner_id", "secret_file", "hermes_home",
        "hermes_bin", "plugin_dir", "fm_home", "fm_root", "reply_max_chars",
    }
    if not required.issubset(settings):
        raise BridgeError("Telegram bridge settings are incomplete")
    if settings.get("version") != VERSION:
        raise BridgeError("Telegram bridge settings version is unsupported")
    if require_enabled and settings.get("enabled") is not True:
        raise BridgeError("Telegram bridge is stopped", EXIT_REJECTED)
    owner = str(settings.get("owner_id", ""))
    if not OWNER_RE.fullmatch(owner):
        raise BridgeError("Telegram owner binding is invalid")
    configured_home = Path(str(settings.get("fm_home", ""))).expanduser().resolve()
    if configured_home != home:
        raise BridgeError("Telegram bridge home binding does not match")
    return settings


def _load_secret(settings: dict[str, Any]) -> bytes:
    path = Path(str(settings["secret_file"])).expanduser()
    raw = _require_private_file(path, max_bytes=256).strip()
    if not re.fullmatch(rb"[0-9a-f]{64}", raw):
        raise BridgeError("Telegram bridge secret is invalid")
    return bytes.fromhex(raw.decode("ascii"))


def _identity_bytes(payload: dict[str, Any]) -> bytes:
    identity = {
        "platform": payload.get("platform"),
        "chat_id": payload.get("chat_id"),
        "message_id": payload.get("message_id"),
        "thread_id": payload.get("thread_id"),
    }
    return _canonical(identity)


def _expected_request_id(payload: dict[str, Any], secret: bytes) -> str:
    return "tg-" + hmac.new(secret, b"request-id\0" + _identity_bytes(payload), hashlib.sha256).hexdigest()[:32]


def _replay_material(payload: dict[str, Any]) -> bytes:
    material = {k: v for k, v in payload.items() if k not in ("issued_at", "signature")}
    return _canonical(material)


def _verify_envelope(payload: dict[str, Any], settings: dict[str, Any], secret: bytes) -> tuple[str, str]:
    expected_keys = {
        "version", "issued_at", "request_id", "platform", "user_id", "chat_id",
        "message_id", "thread_id", "kind", "text", "signature",
    }
    if set(payload) != expected_keys:
        raise BridgeError("Telegram bridge envelope has unexpected fields", EXIT_REJECTED)
    if payload.get("version") != VERSION or payload.get("platform") != "telegram":
        raise BridgeError("Telegram bridge envelope version or platform is invalid", EXIT_REJECTED)
    request_id = payload.get("request_id")
    user_id = payload.get("user_id")
    chat_id = payload.get("chat_id")
    message_id = payload.get("message_id")
    thread_id = payload.get("thread_id")
    kind = payload.get("kind")
    text = payload.get("text")
    issued_at = payload.get("issued_at")
    signature = payload.get("signature")
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
        raise BridgeError("Telegram request id is invalid", EXIT_REJECTED)
    if not isinstance(user_id, str) or not OWNER_RE.fullmatch(user_id):
        raise BridgeError("Telegram user identity is invalid", EXIT_REJECTED)
    if not hmac.compare_digest(user_id, str(settings["owner_id"])):
        raise BridgeError("Telegram user is not the configured captain", EXIT_REJECTED)
    if not isinstance(chat_id, str) or not CHAT_RE.fullmatch(chat_id):
        raise BridgeError("Telegram chat identity is invalid", EXIT_REJECTED)
    if not isinstance(message_id, str) or not MESSAGE_RE.fullmatch(message_id):
        raise BridgeError("Telegram message identity is invalid", EXIT_REJECTED)
    if not isinstance(thread_id, str) or (thread_id and not MESSAGE_RE.fullmatch(thread_id)):
        raise BridgeError("Telegram thread identity is invalid", EXIT_REJECTED)
    if kind not in {"text", "voice"}:
        raise BridgeError("Telegram request kind is invalid", EXIT_REJECTED)
    if not isinstance(text, str) or "\x00" in text or len(text) > MAX_REQUEST_CHARS + 128:
        raise BridgeError("Telegram request text is invalid", EXIT_REJECTED)
    if not isinstance(issued_at, int) or isinstance(issued_at, bool):
        raise BridgeError("Telegram request timestamp is invalid", EXIT_REJECTED)
    if abs(_now() - issued_at) > 120:
        raise BridgeError("Telegram request timestamp is outside the intake window", EXIT_REJECTED)
    if not isinstance(signature, str) or not SIGNATURE_RE.fullmatch(signature):
        raise BridgeError("Telegram request signature is invalid", EXIT_REJECTED)
    unsigned = dict(payload)
    unsigned.pop("signature")
    expected_signature = hmac.new(secret, _canonical(unsigned), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected_signature):
        raise BridgeError("Telegram request signature did not verify", EXIT_REJECTED)
    expected_id = _expected_request_id(payload, secret)
    if not hmac.compare_digest(request_id, expected_id):
        raise BridgeError("Telegram request correlation did not verify", EXIT_REJECTED)
    match = COMMAND_RE.fullmatch(text.strip())
    if not match:
        raise BridgeError("Telegram request is outside the /firstmate command boundary", EXIT_REJECTED)
    request_text = match.group(1).strip()
    if not request_text or len(request_text) > MAX_REQUEST_CHARS:
        raise BridgeError("Telegram /firstmate request is empty or too long", EXIT_REJECTED)
    return request_id, request_text


def _context_path(home: Path, request_id: str) -> Path:
    return home / "state" / "telegram-context" / f"{request_id}.json"


def _inbox_path(home: Path, request_id: str) -> Path:
    return home / "state" / "telegram-inbox" / f"{request_id}.json"


def _verify_context(home: Path, request_id: str, settings: dict[str, Any], secret: bytes) -> dict[str, Any]:
    if not REQUEST_RE.fullmatch(request_id):
        raise BridgeError("unsafe Telegram request id", EXIT_USAGE)
    payload = _read_json_private(_context_path(home, request_id))
    verified_id, _ = _verify_envelope_for_context(payload, settings, secret)
    if not hmac.compare_digest(verified_id, request_id):
        raise BridgeError("Telegram reply context correlation is unresolved", EXIT_UNRESOLVED)
    return payload


def _verify_envelope_for_context(payload: dict[str, Any], settings: dict[str, Any], secret: bytes) -> tuple[str, str]:
    """Verify persisted context without applying the short inbound timestamp window."""
    issued = payload.get("issued_at")
    if not isinstance(issued, int) or isinstance(issued, bool):
        raise BridgeError("Telegram reply context timestamp is invalid", EXIT_UNRESOLVED)
    now = _now()
    if issued > now + 120 or now - issued > DEFAULT_MAX_AGE:
        raise BridgeError("Telegram reply context is outside its retention window", EXIT_UNRESOLVED)
    adjusted = dict(payload)
    adjusted["issued_at"] = now
    unsigned = dict(payload)
    signature = unsigned.pop("signature", None)
    if not isinstance(signature, str) or not SIGNATURE_RE.fullmatch(signature):
        raise BridgeError("Telegram reply context signature is invalid", EXIT_UNRESOLVED)
    expected = hmac.new(secret, _canonical(unsigned), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise BridgeError("Telegram reply context signature did not verify", EXIT_UNRESOLVED)
    # Run structural checks with a temporary timestamp and a matching temporary signature.
    adjusted_unsigned = dict(adjusted)
    adjusted_unsigned.pop("signature", None)
    adjusted["signature"] = hmac.new(secret, _canonical(adjusted_unsigned), hashlib.sha256).hexdigest()
    request_id, request_text = _verify_envelope(adjusted, settings, secret)
    return request_id, request_text


def command_ingest(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    settings = _load_settings(home)
    secret = _load_secret(settings)
    raw = sys.stdin.buffer.read(MAX_ENVELOPE_BYTES + 1)
    if len(raw) > MAX_ENVELOPE_BYTES:
        raise BridgeError("Telegram bridge envelope exceeds its size limit", EXIT_REJECTED)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError("Telegram bridge envelope is malformed", EXIT_REJECTED) from exc
    if not isinstance(payload, dict):
        raise BridgeError("Telegram bridge envelope has the wrong shape", EXIT_REJECTED)
    request_id, request_text = _verify_envelope(payload, settings, secret)
    inbox_path = _inbox_path(home, request_id)
    context_path = _context_path(home, request_id)

    if context_path.exists() or context_path.is_symlink():
        existing = _verify_context(home, request_id, settings, secret)
        if not hmac.compare_digest(_replay_material(existing), _replay_material(payload)):
            raise BridgeError("Telegram request id collided with another context", EXIT_REJECTED)
        print(request_id)
        return EXIT_DUPLICATE

    if inbox_path.exists() or inbox_path.is_symlink():
        existing_inbox = _read_json_private(inbox_path)
        if existing_inbox.get("request_id") != request_id:
            raise BridgeError("Telegram inbox correlation is unresolved", EXIT_REJECTED)
        _atomic_write(context_path, _json_bytes(payload), exclusive=True)
        print(request_id)
        return EXIT_DUPLICATE

    accepted = {
        "version": VERSION,
        "request_id": request_id,
        "platform": "telegram",
        "transport": "hermes",
        "kind": payload["kind"],
        "text": request_text,
        "received_at": _now(),
    }
    if not _atomic_write(inbox_path, _json_bytes(accepted), exclusive=True):
        print(request_id)
        return EXIT_DUPLICATE
    try:
        if not _atomic_write(context_path, _json_bytes(payload), exclusive=True):
            raise BridgeError("Telegram reply context already exists", EXIT_REJECTED)
    except Exception:
        try:
            inbox_path.unlink()
        except OSError:
            pass
        raise

    # Make the registered custom check due on the watcher's next ordinary loop.
    last_check = home / "state" / ".last-check"
    if last_check.is_symlink():
        try:
            last_check.unlink()
        except OSError:
            pass
    elif last_check.exists() and last_check.is_file():
        try:
            last_check.unlink()
        except OSError:
            pass
    print(request_id)
    return 0


def _iter_private_json(directory: Path) -> Iterable[Path]:
    try:
        _require_private_dir(directory)
    except BridgeError:
        return []
    result: list[Path] = []
    for path in sorted(directory.glob("*.json")):
        try:
            _require_private_file(path)
        except BridgeError:
            continue
        result.append(path)
    return result


def command_poll(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    try:
        settings = _load_settings(home)
        secret = _load_secret(settings)
    except BridgeError:
        return 0
    offered_dir = home / "state" / "telegram-offers"
    newly_offered: list[str] = []
    for path in _iter_private_json(home / "state" / "telegram-inbox"):
        try:
            record = _read_json_private(path)
            request_id = str(record.get("request_id", ""))
            if not REQUEST_RE.fullmatch(request_id) or path.name != f"{request_id}.json":
                continue
            _verify_context(home, request_id, settings, secret)
            marker = offered_dir / f"{request_id}.json"
            marker_record = {"version": VERSION, "request_id": request_id, "offered_at": _now()}
            if _atomic_write(marker, _json_bytes(marker_record), exclusive=True):
                newly_offered.append(request_id)
        except BridgeError:
            continue
    if newly_offered:
        print(f"telegram-request {newly_offered[0]}")
    return 0


def command_ack(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    settings = _load_settings(home)
    secret = _load_secret(settings)
    _verify_context(home, args.request_id, settings, secret)
    path = _inbox_path(home, args.request_id)
    if path.exists() or path.is_symlink():
        _require_private_file(path)
        path.unlink()
    print(args.request_id)
    return 0


def _protected_reply(text: str) -> str:
    patterns = [
        re.compile(r"\b\d{6,12}:[A-Za-z0-9_-]{25,}\b"),
        re.compile(r"(?i)authorization\s*:\s*bearer\s+\S+"),
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        re.compile(r"(?i)\b(?:token|secret|password|api[_-]?key|pairing[_-]?data)\s*=\s*[^\s]{8,}"),
    ]
    if any(pattern.search(text) for pattern in patterns):
        raise BridgeError("Telegram reply contains protected credential material", EXIT_REJECTED)
    redacted = text
    hostnames = {socket.gethostname(), socket.getfqdn()}
    for hostname in sorted(hostnames, key=len, reverse=True):
        if hostname and hostname not in {"localhost", "localhost.localdomain"} and len(hostname) >= 3:
            redacted = re.sub(rf"(?<![A-Za-z0-9_.-]){re.escape(hostname)}(?![A-Za-z0-9_.-])", "[local host]", redacted)
    return redacted


def _split_reply(text: str, limit: int, cap: int) -> list[str]:
    normalized = text.strip()
    if not normalized:
        raise BridgeError("Telegram reply text is empty", EXIT_USAGE)
    if len(normalized) <= limit:
        return [normalized]
    suffix_budget = 12
    budget = max(1, limit - suffix_budget)
    units = [unit.strip() for unit in re.split(r"\n\s*\n", normalized) if unit.strip()]
    raw_chunks: list[str] = []
    current = ""
    for unit in units:
        candidates = [unit]
        if len(unit) > budget:
            words = unit.split()
            candidates = []
            piece = ""
            for word in words:
                while len(word) > budget:
                    if piece:
                        candidates.append(piece)
                        piece = ""
                    candidates.append(word[:budget])
                    word = word[budget:]
                trial = word if not piece else f"{piece} {word}"
                if len(trial) <= budget:
                    piece = trial
                else:
                    candidates.append(piece)
                    piece = word
            if piece:
                candidates.append(piece)
        for candidate in candidates:
            trial = candidate if not current else f"{current}\n\n{candidate}"
            if len(trial) <= budget:
                current = trial
            else:
                if current:
                    raw_chunks.append(current)
                current = candidate
    if current:
        raw_chunks.append(current)
    if len(raw_chunks) > cap:
        raw_chunks = raw_chunks[:cap]
        raw_chunks[-1] = raw_chunks[-1][: max(1, budget - 1)].rstrip() + "…"
    count = len(raw_chunks)
    return [f"{chunk} ({index}/{count})" for index, chunk in enumerate(raw_chunks, start=1)]


def _delivery_path(home: Path, request_id: str, delivery_id: str) -> Path:
    return home / "state" / "telegram-deliveries" / request_id / f"{delivery_id}.json"


def _final_path(home: Path, request_id: str) -> Path:
    return home / "state" / "telegram-final" / f"{request_id}.json"


def _publish_final(home: Path, request_id: str, delivery_id: str, event: str) -> None:
    path = _final_path(home, request_id)
    marker = {
        "version": VERSION,
        "request_id": request_id,
        "delivery_id": delivery_id,
        "event": event,
        "finalized_at": _now(),
    }
    if not _atomic_write(path, _json_bytes(marker), exclusive=True):
        existing = _read_json_private(path)
        if existing.get("delivery_id") != delivery_id:
            raise BridgeError("Telegram final-result correlation is unresolved", EXIT_UNRESOLVED)


def _send_chunk(settings: dict[str, Any], target: str, chunk: str) -> bool:
    hermes_bin = Path(str(settings["hermes_bin"])).expanduser()
    if not hermes_bin.is_absolute() or not hermes_bin.exists() or not os.access(hermes_bin, os.X_OK):
        raise BridgeError("Hermes transport executable is unavailable")
    env = os.environ.copy()
    env["HERMES_HOME"] = str(settings["hermes_home"])
    try:
        result = subprocess.run(
            [str(hermes_bin), "send", "--quiet", "--to", target, "--file", "-"],
            input=chunk,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BridgeError("Hermes Telegram delivery did not complete") from exc
    return result.returncode == 0


def reply_request(
    home: Path,
    request_id: str,
    text: str,
    *,
    event: str,
    final: bool,
) -> int:
    settings = _load_settings(home)
    secret = _load_secret(settings)
    context = _verify_context(home, request_id, settings, secret)
    if not isinstance(text, str) or "\x00" in text or len(text) > MAX_REPLY_CHARS:
        raise BridgeError("Telegram reply text is invalid", EXIT_USAGE)
    text = _protected_reply(text)
    if event not in {"acknowledgement", "milestone", "decision", "failure", "final"}:
        raise BridgeError("Telegram reply event is invalid", EXIT_USAGE)
    if final:
        event = "final" if event not in {"failure"} else event
    limit = settings.get("reply_max_chars", DEFAULT_REPLY_LIMIT)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 256 <= limit <= 4096:
        raise BridgeError("Telegram reply split budget is invalid")
    chunks = _split_reply(text, limit, DEFAULT_REPLY_CAP)
    digest = hashlib.sha256((event + "\0" + text).encode("utf-8")).hexdigest()
    delivery_id = digest[:24]
    _require_private_dir(home / "state" / "telegram-deliveries", create=True)
    delivery_path = _delivery_path(home, request_id, delivery_id)

    if delivery_path.exists() or delivery_path.is_symlink():
        journal = _read_json_private(delivery_path, max_bytes=32768)
        if journal.get("digest") != digest:
            raise BridgeError("Telegram delivery id collision is unresolved", EXIT_UNRESOLVED)
        if journal.get("state") == "delivered":
            if final:
                _publish_final(home, request_id, delivery_id, event)
            print(request_id)
            return 0
        raise BridgeError("Telegram delivery outcome is unresolved; automatic retry refused", EXIT_UNRESOLVED)

    final_path = _final_path(home, request_id)
    if final_path.exists() or final_path.is_symlink():
        raise BridgeError("Telegram request already has a final result", EXIT_UNRESOLVED)

    journal = {
        "version": VERSION,
        "request_id": request_id,
        "delivery_id": delivery_id,
        "digest": digest,
        "event": event,
        "state": "pending",
        "chunks": len(chunks),
        "sent": 0,
        "created_at": _now(),
    }
    if not _atomic_write(delivery_path, _json_bytes(journal), exclusive=True):
        raise BridgeError("Telegram delivery was claimed concurrently", EXIT_UNRESOLVED)

    if _truthy(os.environ.get("FMT_DRY_RUN")):
        preview = {
            "version": VERSION,
            "request_id": request_id,
            "delivery_id": delivery_id,
            "event": event,
            "texts": chunks,
        }
        _atomic_write(home / "state" / "telegram-outbox" / f"{request_id}-{delivery_id}.json", _json_bytes(preview))
        journal["state"] = "delivered"
        journal["sent"] = len(chunks)
        journal["delivered_at"] = _now()
        _atomic_write(delivery_path, _json_bytes(journal))
    else:
        target = f"telegram:{context['chat_id']}"
        if context.get("thread_id"):
            target += f":{context['thread_id']}"
        for index, chunk in enumerate(chunks, start=1):
            if not _send_chunk(settings, target, chunk):
                journal["state"] = "unresolved"
                journal["sent"] = index - 1
                journal["failed_at"] = _now()
                _atomic_write(delivery_path, _json_bytes(journal))
                raise BridgeError("Hermes Telegram delivery failed; automatic retry refused", EXIT_UNRESOLVED)
            journal["sent"] = index
            _atomic_write(delivery_path, _json_bytes(journal))
        journal["state"] = "delivered"
        journal["delivered_at"] = _now()
        _atomic_write(delivery_path, _json_bytes(journal))

    if final:
        _publish_final(home, request_id, delivery_id, event)
    print(request_id)
    return 0


def _read_text_source(args: argparse.Namespace) -> str:
    if getattr(args, "text_file", None):
        path = Path(args.text_file)
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise BridgeError("Telegram reply text file cannot be read", EXIT_USAGE) from exc
    if getattr(args, "stdin", False):
        return sys.stdin.read(MAX_REPLY_CHARS + 1)
    value = getattr(args, "text", None)
    if value is None:
        raise BridgeError("Telegram reply text is required", EXIT_USAGE)
    return value


def command_reply(args: argparse.Namespace) -> int:
    return reply_request(
        _fm_home(args.fm_home),
        args.request_id,
        _read_text_source(args),
        event=args.event,
        final=args.final,
    )


def _meta_get(path: Path, key: str) -> str:
    if not path.is_file() or path.is_symlink():
        return ""
    value = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            value = line.split("=", 1)[1]
    return value


def _meta_rewrite(path: Path, updates: dict[str, str | None]) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_nlink != 1:
        raise BridgeError("task metadata is unavailable or unsafe")
    existing = path.read_text(encoding="utf-8").splitlines()
    keys = set(updates)
    kept = [line for line in existing if line.split("=", 1)[0] not in keys]
    for key, value in updates.items():
        if value is not None:
            kept.append(f"{key}={value}")
    data = ("\n".join(kept) + "\n").encode("utf-8")
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.fmt.", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def command_link(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    if not TASK_RE.fullmatch(args.task_id):
        raise BridgeError("unsafe task id", EXIT_USAGE)
    settings = _load_settings(home)
    secret = _load_secret(settings)
    _verify_context(home, args.request_id, settings, secret)
    meta = home / "state" / f"{args.task_id}.meta"
    if args.carry_count is None and args.carry_ts is None:
        count = 0
        timestamp = _now()
    elif args.carry_count is not None and args.carry_ts is not None:
        if args.carry_count < 0 or args.carry_ts < 0:
            raise BridgeError("carried Telegram link values must be non-negative", EXIT_USAGE)
        count = args.carry_count
        timestamp = args.carry_ts
    else:
        raise BridgeError("--carry-count and --carry-ts are required together", EXIT_USAGE)
    _meta_rewrite(meta, {
        "telegram_request": args.request_id,
        "telegram_request_ts": str(timestamp),
        "telegram_followups": str(count),
    })
    print(f"linked {args.task_id} to Telegram request {args.request_id}")
    return 0


def _clear_link(meta: Path) -> None:
    _meta_rewrite(meta, {
        "telegram_request": None,
        "telegram_request_ts": None,
        "telegram_followups": None,
    })


def command_followup(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    if not TASK_RE.fullmatch(args.task_id):
        raise BridgeError("unsafe task id", EXIT_USAGE)
    meta = home / "state" / f"{args.task_id}.meta"
    request_id = _meta_get(meta, "telegram_request")
    if not request_id:
        return 1 if args.check else 0
    timestamp_raw = _meta_get(meta, "telegram_request_ts")
    count_raw = _meta_get(meta, "telegram_followups") or "0"
    if not timestamp_raw.isdigit() or not count_raw.isdigit():
        _clear_link(meta)
        return 1 if args.check else 0
    timestamp = int(timestamp_raw)
    count = int(count_raw)
    if _now() - timestamp > DEFAULT_MAX_AGE or count >= DEFAULT_FOLLOWUP_CAP:
        _clear_link(meta)
        return 1 if args.check else 0
    if _final_path(home, request_id).exists():
        _clear_link(meta)
        return 1 if args.check else 0
    if args.check:
        print(request_id)
        return 0
    result = reply_request(
        home,
        request_id,
        _read_text_source(args),
        event=args.event,
        final=args.final,
    )
    if result != 0:
        return result
    new_count = count + 1
    if args.final or new_count >= DEFAULT_FOLLOWUP_CAP:
        _clear_link(meta)
    else:
        _meta_rewrite(meta, {"telegram_followups": str(new_count)})
    return 0


def _plugin_source(root: Path) -> Path:
    return root / "integrations" / "hermes" / PLUGIN_NAME


def _write_private_json(path: Path, value: dict[str, Any]) -> None:
    _atomic_write(path, _json_bytes(value))


def _resolve_executable(raw: str | None, name: str) -> Path:
    candidate = raw or shutil.which(name)
    if not candidate:
        raise BridgeError(f"{name} executable was not found")
    path = Path(candidate).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise BridgeError(f"{name} executable is not usable")
    return path


def _copy_plugin(source: Path, destination: Path) -> None:
    if destination.is_symlink():
        raise BridgeError("Hermes plugin destination is a symlink")
    if destination.exists():
        manifest = destination / "plugin.yaml"
        try:
            existing = manifest.read_text(encoding="utf-8")
        except OSError as exc:
            raise BridgeError("existing Hermes plugin destination is not owned by this bridge") from exc
        if "name: firstmate-telegram" not in existing:
            raise BridgeError("existing Hermes plugin destination is not owned by this bridge")
    destination.mkdir(parents=True, exist_ok=True)
    destination.chmod(0o700)
    for name in ("plugin.yaml", "__init__.py"):
        data = (source / name).read_bytes()
        path = destination / name
        if path.is_symlink():
            raise BridgeError("Hermes plugin file destination is a symlink")
        path.write_bytes(data)
        path.chmod(0o600)


def _run_hermes_plugin_action(settings: dict[str, Any], action: str) -> None:
    env = os.environ.copy()
    env["HERMES_HOME"] = str(settings["hermes_home"])
    try:
        result = subprocess.run(
            [str(settings["hermes_bin"]), "plugins", action, PLUGIN_NAME],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BridgeError(f"Hermes could not {action} the Firstmate bridge plugin") from exc
    if result.returncode != 0:
        raise BridgeError(f"Hermes could not {action} the Firstmate bridge plugin")


def _check_script_content(home: Path, root: Path) -> bytes:
    return (
        "#!/usr/bin/env bash\n"
        "# Generated by fm-telegram-bridge.py; hash-bound by fm-check-register.sh.\n"
        f"export FM_HOME={shlex.quote(str(home))}\n"
        f"exec {shlex.quote(str(root / 'bin' / 'fm-telegram-poll.sh'))}\n"
    ).encode("utf-8")


def _install_check(home: Path, root: Path) -> None:
    state = home / "state"
    state.mkdir(parents=True, exist_ok=True)
    check = state / "telegram-bridge.check.sh"
    if check.is_symlink():
        raise BridgeError("Telegram watcher check destination is unsafe")
    check.write_bytes(_check_script_content(home, root))
    check.chmod(0o700)
    env = os.environ.copy()
    env.update({"FM_HOME": str(home), "FM_ROOT_OVERRIDE": str(root)})
    result = subprocess.run(
        [str(root / "bin" / "fm-check-register.sh"), "telegram-bridge"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise BridgeError("Telegram watcher check could not be registered")


def _remove_check(home: Path) -> None:
    state = home / "state"
    for name in ("telegram-bridge.check.sh", "telegram-bridge.check-trust"):
        path = state / name
        if path.is_symlink():
            raise BridgeError("Telegram watcher check path is unsafe")
        if path.exists():
            if not path.is_file() or path.stat().st_nlink != 1:
                raise BridgeError("Telegram watcher check path is unsafe")
            path.unlink()


def _bridge_config_for_plugin(settings: dict[str, Any]) -> dict[str, Any]:
    return {
        "version": VERSION,
        "enabled": settings["enabled"],
        "owner_id": settings["owner_id"],
        "secret_file": settings["secret_file"],
        "ingest_command": str(Path(settings["fm_root"]) / "bin" / "fm-telegram-ingest.sh"),
        "fm_home": settings["fm_home"],
    }


def _save_settings(home: Path, settings: dict[str, Any]) -> None:
    _write_private_json(_settings_path(home), settings)
    plugin_dir = Path(str(settings["plugin_dir"]))
    _write_private_json(plugin_dir / "bridge.json", _bridge_config_for_plugin(settings))


def command_install(args: argparse.Namespace) -> int:
    if not args.enable:
        raise BridgeError("installation requires explicit --enable opt-in", EXIT_USAGE)
    if not OWNER_RE.fullmatch(args.owner_id):
        raise BridgeError("--owner-id must be a Telegram numeric user id", EXIT_USAGE)
    root = Path(__file__).resolve().parent.parent
    home = _fm_home(args.fm_home)
    hermes_home = Path(args.hermes_home or os.environ.get("HERMES_HOME") or "~/.hermes").expanduser().resolve()
    hermes_home.mkdir(parents=True, exist_ok=True)
    hermes_bin = _resolve_executable(args.hermes_bin, "hermes")
    source = _plugin_source(root)
    if not source.is_dir():
        raise BridgeError("repo-owned Hermes bridge plugin source is missing")
    plugin_dir = hermes_home / "plugins" / PLUGIN_NAME
    plugin_dir.parent.mkdir(parents=True, exist_ok=True)
    _copy_plugin(source, plugin_dir)

    config_dir = home / "config" / "telegram-bridge"
    _require_private_dir(config_dir, create=True)
    secret_file = config_dir / "secret"
    if secret_file.exists() or secret_file.is_symlink():
        secret_raw = _require_private_file(secret_file, max_bytes=256).strip()
        if not re.fullmatch(rb"[0-9a-f]{64}", secret_raw):
            raise BridgeError("existing Telegram bridge secret is invalid")
    else:
        _atomic_write(secret_file, (secrets.token_hex(32) + "\n").encode("ascii"), exclusive=True)

    settings_path = _settings_path(home)
    if settings_path.exists() or settings_path.is_symlink():
        previous = _load_settings(home, require_enabled=False)
        if str(previous["owner_id"]) != args.owner_id:
            raise BridgeError("existing owner binding differs; use configure")
    settings = {
        "version": VERSION,
        "enabled": True,
        "owner_id": args.owner_id,
        "secret_file": str(secret_file),
        "hermes_home": str(hermes_home),
        "hermes_bin": str(hermes_bin),
        "plugin_dir": str(plugin_dir),
        "fm_home": str(home),
        "fm_root": str(root),
        "reply_max_chars": DEFAULT_REPLY_LIMIT,
        "installed_at": _now(),
    }
    _save_settings(home, settings)
    _install_check(home, root)
    _run_hermes_plugin_action(settings, "enable")
    print("Telegram bridge installed and enabled; restart the Hermes gateway once to load the plugin.")
    return 0


def command_start(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    settings = _load_settings(home, require_enabled=False)
    settings["enabled"] = True
    _copy_plugin(_plugin_source(Path(settings["fm_root"])), Path(settings["plugin_dir"]))
    _save_settings(home, settings)
    _install_check(home, Path(settings["fm_root"]))
    _run_hermes_plugin_action(settings, "enable")
    print("Telegram bridge started.")
    return 0


def command_stop(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    settings = _load_settings(home, require_enabled=False)
    settings["enabled"] = False
    _save_settings(home, settings)
    _remove_check(home)
    print("Telegram bridge stopped; pending private records were preserved.")
    return 0


def command_configure(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    if not OWNER_RE.fullmatch(args.owner_id):
        raise BridgeError("--owner-id must be a Telegram numeric user id", EXIT_USAGE)
    settings = _load_settings(home, require_enabled=False)
    if str(settings["owner_id"]) != args.owner_id:
        context_dir = home / "state" / "telegram-context"
        if any(_iter_private_json(context_dir)):
            raise BridgeError("owner binding cannot change while correlated requests remain")
        settings["owner_id"] = args.owner_id
    _save_settings(home, settings)
    print("Telegram bridge owner binding configured.")
    return 0


def _pending_or_unresolved(home: Path) -> bool:
    if any(_iter_private_json(home / "state" / "telegram-inbox")):
        return True
    for path in _iter_private_json(home / "state" / "telegram-deliveries"):
        try:
            if _read_json_private(path).get("state") != "delivered":
                return True
        except BridgeError:
            return True
    delivery_root = home / "state" / "telegram-deliveries"
    if delivery_root.exists() and delivery_root.is_dir() and not delivery_root.is_symlink():
        for child in delivery_root.iterdir():
            if child.is_dir() and not child.is_symlink():
                for record in _iter_private_json(child):
                    try:
                        if _read_json_private(record).get("state") != "delivered":
                            return True
                    except BridgeError:
                        return True
    return False


def _safe_rmtree(path: Path, parent: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_symlink() or not path.is_dir() or path.parent.resolve() != parent.resolve():
        raise BridgeError("Telegram bridge cleanup path is unsafe")
    shutil.rmtree(path)


def command_uninstall(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    if not _settings_path(home).exists() and not _settings_path(home).is_symlink():
        print("Telegram bridge is already uninstalled.")
        return 0
    settings = _load_settings(home, require_enabled=False)
    if _pending_or_unresolved(home) and not args.purge:
        raise BridgeError("pending or unresolved Telegram records remain; inspect them or pass --purge")
    settings["enabled"] = False
    _save_settings(home, settings)
    _remove_check(home)
    _run_hermes_plugin_action(settings, "disable")
    plugin_dir = Path(settings["plugin_dir"])
    _safe_rmtree(plugin_dir, plugin_dir.parent)
    for name in (
        "telegram-inbox", "telegram-context", "telegram-offers", "telegram-deliveries",
        "telegram-final", "telegram-outbox",
    ):
        _safe_rmtree(home / "state" / name, home / "state")
    _safe_rmtree(home / "config" / "telegram-bridge", home / "config")
    print("Telegram bridge uninstalled; restart the Hermes gateway once to unload the plugin.")
    return 0


def command_status(args: argparse.Namespace) -> int:
    home = _fm_home(args.fm_home)
    try:
        settings = _load_settings(home, require_enabled=False)
        secret_ok = bool(_load_secret(settings))
        plugin_ok = Path(settings["plugin_dir"]).joinpath("plugin.yaml").is_file()
        check_ok = (home / "state" / "telegram-bridge.check.sh").is_file()
        enabled = settings.get("enabled") is True
        pending = len(list(_iter_private_json(home / "state" / "telegram-inbox")))
        print(f"installed: yes\nenabled: {'yes' if enabled else 'no'}\nplugin: {'ready' if plugin_ok else 'missing'}")
        print(f"private-auth: {'ready' if secret_ok else 'invalid'}\nwatch-intake: {'ready' if check_ok else 'stopped'}\npending: {pending}")
        return 0 if plugin_ok and secret_ok else 1
    except BridgeError:
        print("installed: no\nenabled: no\nplugin: missing\nprivate-auth: unavailable\nwatch-intake: stopped\npending: 0")
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-telegram-bridge.py")
    sub = parser.add_subparsers(dest="command", required=True)

    ingest = sub.add_parser("ingest")
    ingest.add_argument("--fm-home")
    ingest.set_defaults(func=command_ingest)

    poll = sub.add_parser("poll")
    poll.add_argument("--fm-home")
    poll.set_defaults(func=command_poll)

    ack = sub.add_parser("ack")
    ack.add_argument("request_id")
    ack.add_argument("--fm-home")
    ack.set_defaults(func=command_ack)

    reply = sub.add_parser("reply")
    reply.add_argument("request_id")
    reply.add_argument("text", nargs="?")
    reply.add_argument("--text-file")
    reply.add_argument("--stdin", action="store_true")
    reply.add_argument("--event", default="milestone", choices=["acknowledgement", "milestone", "decision", "failure", "final"])
    reply.add_argument("--final", action="store_true")
    reply.add_argument("--fm-home")
    reply.set_defaults(func=command_reply)

    link = sub.add_parser("link")
    link.add_argument("task_id")
    link.add_argument("request_id")
    link.add_argument("--carry-count", type=int)
    link.add_argument("--carry-ts", type=int)
    link.add_argument("--fm-home")
    link.set_defaults(func=command_link)

    followup = sub.add_parser("followup")
    followup.add_argument("task_id")
    followup.add_argument("text", nargs="?")
    followup.add_argument("--text-file")
    followup.add_argument("--stdin", action="store_true")
    followup.add_argument("--check", action="store_true")
    followup.add_argument("--event", default="milestone", choices=["milestone", "decision", "failure", "final"])
    followup.add_argument("--final", action="store_true")
    followup.add_argument("--fm-home")
    followup.set_defaults(func=command_followup)

    install = sub.add_parser("install")
    install.add_argument("--enable", action="store_true")
    install.add_argument("--owner-id", required=True)
    install.add_argument("--fm-home")
    install.add_argument("--hermes-home")
    install.add_argument("--hermes-bin")
    install.set_defaults(func=command_install)

    start = sub.add_parser("start")
    start.add_argument("--fm-home")
    start.set_defaults(func=command_start)

    stop = sub.add_parser("stop")
    stop.add_argument("--fm-home")
    stop.set_defaults(func=command_stop)

    configure = sub.add_parser("configure")
    configure.add_argument("--owner-id", required=True)
    configure.add_argument("--fm-home")
    configure.set_defaults(func=command_configure)

    uninstall = sub.add_parser("uninstall")
    uninstall.add_argument("--purge", action="store_true")
    uninstall.add_argument("--fm-home")
    uninstall.set_defaults(func=command_uninstall)

    status_cmd = sub.add_parser("status")
    status_cmd.add_argument("--fm-home")
    status_cmd.set_defaults(func=command_status)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "check", False) and any(
        [getattr(args, "text", None), getattr(args, "text_file", None), getattr(args, "stdin", False), getattr(args, "final", False)]
    ):
        raise BridgeError("--check does not accept reply text or --final", EXIT_USAGE)
    if getattr(args, "text_file", None) and (getattr(args, "stdin", False) or getattr(args, "text", None) is not None):
        raise BridgeError("choose exactly one Telegram reply text source", EXIT_USAGE)
    if getattr(args, "stdin", False) and getattr(args, "text", None) is not None:
        raise BridgeError("choose exactly one Telegram reply text source", EXIT_USAGE)
    return int(args.func(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BridgeError as exc:
        print(f"fm-telegram-bridge: {exc}", file=sys.stderr)
        raise SystemExit(exc.code)
