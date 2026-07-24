"""Authenticated Hermes Telegram transport for explicit Firstmate commands."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import time
from pathlib import Path
from typing import Any

VERSION = 1
CONFIG = Path(__file__).with_name("bridge.json")
TEXT_COMMAND = re.compile(r"^/firstmate(?:@[A-Za-z0-9_]{3,})?\s+(.+)$", re.I | re.S)
VOICE_COMMAND = re.compile(r"^(?:/firstmate|first\s*mate|firstmate)\s*[,.:;-]?\s+(.+)$", re.I | re.S)
ID = re.compile(r"^[1-9][0-9]{0,19}$")
MESSAGE_ID = re.compile(r"^[1-9][0-9]{0,19}$")


def _private(path: Path, limit: int) -> bytes:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValueError("unsafe file")
    if info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("unsafe file identity")
    if info.st_size > limit:
        raise ValueError("file too large")
    return path.read_bytes()


def _load() -> tuple[dict[str, Any], bytes]:
    value = json.loads(_private(CONFIG, 32768).decode("utf-8"))
    required = {"version", "enabled", "owner_id", "secret_file", "ingest_command", "fm_home"}
    if not isinstance(value, dict) or not required.issubset(value) or value["version"] != VERSION:
        raise ValueError("invalid config")
    owner = str(value["owner_id"])
    if not ID.fullmatch(owner):
        raise ValueError("invalid owner")
    secret = _private(Path(str(value["secret_file"])), 256).strip()
    if not re.fullmatch(rb"[0-9a-f]{64}", secret):
        raise ValueError("invalid secret")
    command = Path(str(value["ingest_command"]))
    if not command.is_absolute() or not command.is_file() or not os.access(command, os.X_OK):
        raise ValueError("invalid intake")
    return value, bytes.fromhex(secret.decode("ascii"))


def _field(event: Any, name: str, default: Any = None) -> Any:
    value = getattr(event, name, default)
    if value is not None:
        return value
    raw = getattr(event, "raw_message", None)
    if isinstance(raw, dict):
        return raw.get(name, default)
    return default


def _platform(event: Any) -> str:
    value = _field(getattr(event, "source", None), "platform", "")
    return str(getattr(value, "value", value)).lower()


def _kind(event: Any) -> str:
    value = _field(event, "message_type", "")
    return str(getattr(value, "value", value)).lower()


def _text_request(text: str) -> str | None:
    match = TEXT_COMMAND.fullmatch(text.strip())
    return match.group(1).strip() if match and match.group(1).strip() else None


def _voice_request(text: str) -> str | None:
    match = VOICE_COMMAND.fullmatch(text.strip())
    return match.group(1).strip() if match and match.group(1).strip() else None


def _authorized(gateway: Any, event: Any) -> bool:
    checker = getattr(gateway, "_is_user_authorized", None)
    source = getattr(event, "source", None)
    if not callable(checker) or source is None:
        return False
    try:
        return bool(checker(source))
    except Exception:
        return False


def _voice_path(event: Any) -> str | None:
    media_urls = _field(event, "media_urls", [])
    if isinstance(media_urls, list) and media_urls and isinstance(media_urls[0], str):
        return media_urls[0]
    return None


def _transcribe(event: Any) -> str | None:
    existing = _field(event, "text", "")
    if isinstance(existing, str) and existing.strip():
        return existing
    path = _voice_path(event)
    if not path:
        return None
    try:
        from tools.transcription_tools import transcribe_audio
        result = transcribe_audio(path)
        if isinstance(result, dict) and result.get("success") and isinstance(result.get("transcript"), str):
            return result["transcript"]
    except Exception:
        return None
    return None


def _signed(config: dict[str, Any], secret: bytes, event: Any, kind: str, text: str) -> dict[str, Any]:
    source = getattr(event, "source", None)
    user_id = str(_field(source, "user_id", ""))
    chat_id = str(_field(source, "chat_id", ""))
    message_id = str(_field(event, "message_id", "") or _field(source, "message_id", ""))
    thread_raw = _field(source, "thread_id", "")
    thread_id = "" if thread_raw in (None, "") else str(thread_raw)
    if not ID.fullmatch(user_id) or not re.fullmatch(r"^-?[1-9][0-9]{0,19}$", chat_id):
        raise ValueError("invalid sender identity")
    if not MESSAGE_ID.fullmatch(message_id) or (thread_id and not MESSAGE_ID.fullmatch(thread_id)):
        raise ValueError("invalid message identity")
    identity = {"platform": "telegram", "chat_id": chat_id, "message_id": message_id, "thread_id": thread_id}
    request_id = "tg-" + hmac.new(
        secret,
        b"request-id\0" + json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()[:32]
    unsigned = {
        "version": VERSION,
        "issued_at": int(time.time()),
        "request_id": request_id,
        "platform": "telegram",
        "user_id": user_id,
        "chat_id": chat_id,
        "message_id": message_id,
        "thread_id": thread_id,
        "kind": kind,
        "text": f"/firstmate {text}",
    }
    unsigned["signature"] = hmac.new(
        secret,
        json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return unsigned


async def _notice(gateway: Any, event: Any, text: str) -> None:
    source = getattr(event, "source", None)
    adapters = getattr(gateway, "adapters", {})
    adapter = adapters.get(getattr(source, "platform", None)) if isinstance(adapters, dict) else None
    sender = getattr(adapter, "send", None)
    if not callable(sender):
        return
    try:
        await sender(
            str(source.chat_id),
            text,
            reply_to=getattr(event, "message_id", None),
            metadata={"thread_id": getattr(source, "thread_id", None)},
        )
    except Exception:
        return


def _submit(config: dict[str, Any], envelope: dict[str, Any]) -> int:
    env = os.environ.copy()
    env["FM_HOME"] = str(config["fm_home"])
    try:
        result = subprocess.run(
            [str(config["ingest_command"])],
            input=json.dumps(envelope, separators=(",", ":")),
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 4
    return result.returncode


def _schedule(gateway: Any, event: Any, text: str) -> None:
    try:
        asyncio.get_running_loop().create_task(_notice(gateway, event, text))
    except RuntimeError:
        return


def pre_gateway_dispatch(event: Any, gateway: Any, **_kwargs: Any) -> dict[str, Any] | None:
    """Intercept authenticated Telegram /firstmate text or voice requests."""
    if _platform(event) != "telegram":
        return None
    kind = _kind(event)
    raw_text = _field(event, "text", "")
    request = _text_request(raw_text) if isinstance(raw_text, str) else None
    is_voice = kind in {"voice", "audio"}
    if request is None and not is_voice:
        return None
    try:
        config, secret = _load()
    except Exception:
        _schedule(gateway, event, "Firstmate bridge is unavailable. No request was accepted.")
        return {"action": "skip", "reason": "firstmate-unavailable"}
    source = getattr(event, "source", None)
    user_id = str(_field(source, "user_id", ""))
    if config.get("enabled") is not True:
        _schedule(gateway, event, "Firstmate bridge is stopped. No request was accepted.")
        return {"action": "skip", "reason": "firstmate-stopped"}
    authorized = hmac.compare_digest(user_id, str(config["owner_id"])) and _authorized(gateway, event)
    if not authorized:
        if is_voice:
            return None
        return {"action": "skip", "reason": "firstmate-unauthorized"}
    if is_voice:
        request = _voice_request(_transcribe(event) or "")
        kind = "voice"
        if request is None:
            return None
    else:
        kind = "text"
    try:
        envelope = _signed(config, secret, event, kind, request)
    except Exception:
        _schedule(gateway, event, "Firstmate could not authenticate this request. Nothing was queued.")
        return {"action": "skip", "reason": "firstmate-auth-failed"}
    code = _submit(config, envelope)
    if code == 0:
        _schedule(gateway, event, "Firstmate accepted your request.")
    elif code == 4:
        _schedule(gateway, event, "Firstmate is offline. No request was accepted; retry when supervision is active.")
    elif code != 3:
        _schedule(gateway, event, "Firstmate rejected this request. Nothing was queued.")
    return {"action": "skip", "reason": "firstmate-handled"}


def register(context: Any) -> None:
    """Register hook for Hermes plugin loaders that use explicit callbacks."""
    hook = getattr(context, "register_hook", None)
    if callable(hook):
        hook("pre_gateway_dispatch", pre_gateway_dispatch)
