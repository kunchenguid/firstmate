"""Relay authorized Telegram DMs into the FirstMate Primary inbox.

Hooks ``pre_gateway_dispatch`` once per inbound MessageEvent, before Hermes
would otherwise build its own agent turn.
For the one authorized chat this first gives the dedicated FirstMate
Hermes/Telegram inbound handler a chance to consume explicit HOME/AWAY
presence commands.
Only a consumed presence command is withheld from the ordinary inbox.
Everything else falls back to ``bin/fm-inbox.sh note`` and then skips Hermes's
own agent turn, preserving Hermes as transport only.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import time
from pathlib import Path

_AUTHORIZED_PLATFORM = "telegram"
_AUTHORIZED_CHAT_ID = "8629896233"

_FM_HOME = "/home/ubuntu/fm-primary"
_FM_INBOX = _FM_HOME + "/bin/fm-inbox.sh"
_FM_NOTIFY = _FM_HOME + "/bin/fm-hermes-notify.sh"

_EVENT_ID_ATTRS = (
    "id",
    "event_id",
    "message_id",
    "telegram_message_id",
    "update_id",
    "request_id",
)


def _platform_str(source) -> str:
    platform = getattr(source, "platform", None)
    value = getattr(platform, "value", None)
    return value if isinstance(value, str) else str(platform or "")


def _stable_value(obj, names: tuple[str, ...]) -> tuple[str, str] | None:
    for name in names:
        value = getattr(obj, name, None)
        if value is None:
            continue
        text = str(value)
        if text:
            return name, text
    return None


def _request_id(event, source) -> str | None:
    event_value = _stable_value(event, _EVENT_ID_ATTRS)
    source_value = _stable_value(source, _EVENT_ID_ATTRS)
    if event_value is None and source_value is None:
        return None
    basis = [
        _AUTHORIZED_PLATFORM,
        _AUTHORIZED_CHAT_ID,
    ]
    if event_value is not None:
        basis.extend(("event." + event_value[0], event_value[1]))
    if source_value is not None:
        basis.extend(("source." + source_value[0], source_value[1]))
    digest = hashlib.sha256("\0".join(basis).encode("utf-8")).hexdigest()
    return "hermes-telegram-" + digest


def _claim_event(request_id: str | None) -> Path | bool | None:
    if request_id is None:
        return None
    directory = Path(_FM_HOME) / "state" / "hermes-notify" / "inbound-events"
    path = directory / request_id
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    except OSError:
        return None
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("status=processing\n")
        handle.write("started_at={}\n".format(int(time.time())))
    return path


def _mark_event(path: Path | bool | None, status: str) -> None:
    if not isinstance(path, Path):
        return
    try:
        with path.open("a", encoding="utf-8") as handle:
            handle.write("status={}\n".format(status))
            handle.write("finished_at={}\n".format(int(time.time())))
    except OSError:
        pass


def _unclaim_event(path: Path | bool | None) -> None:
    if not isinstance(path, Path):
        return
    try:
        path.unlink()
    except OSError:
        pass


def _run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["FM_HOME"] = _FM_HOME
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        env=env,
        timeout=10,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )


def _note_text(event, user_name: str, text: str) -> str:
    return "[Telegram from {} (chat {})] {}".format(
        user_name, _AUTHORIZED_CHAT_ID, text.strip()
    )


def _inbound_note_file(note: str) -> str:
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        delete=False,
        prefix="firstmate-telegram-inbound-",
        suffix=".note",
    )
    with handle:
        handle.write("schema=fm-inbox-note.v1\n")
        handle.write("source=telegram\n")
        handle.write("--\n")
        handle.write(note)
        handle.write("\n")
    return handle.name


def _try_presence_inbound(note: str) -> tuple[bool, str]:
    path = _inbound_note_file(note)
    try:
        result = _run([_FM_NOTIFY, "inbound", path])
    except Exception:
        return False, ""
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    output = result.stdout or ""
    if result.returncode in (0, 3):
        for line in output.splitlines():
            if line in ("mode:AWAY", "mode:HOME"):
                return True, line
    return False, output


def _queue_inbox(note: str, request_id: str | None) -> bool:
    command = [_FM_INBOX, "note"]
    if request_id is not None:
        command.extend(["--request-id", request_id])
    command.append("-")
    try:
        result = _run(command, input_text=note)
    except Exception:
        return False
    return result.returncode in (0, 3)


def _on_pre_gateway_dispatch(**kwargs):
    event = kwargs.get("event")
    source = getattr(event, "source", None)
    if event is None or source is None:
        return None

    if _platform_str(source) != _AUTHORIZED_PLATFORM:
        return None
    if str(getattr(source, "chat_id", "") or "") != _AUTHORIZED_CHAT_ID:
        return None

    text = getattr(event, "text", None)
    if not isinstance(text, str) or not text.strip():
        return None

    user_name = getattr(event, "user_name", None) or "Captain"
    note = _note_text(event, user_name, text)
    request_id = _request_id(event, source)
    claim = _claim_event(request_id)
    if claim is False:
        return {"action": "skip", "reason": "duplicate Telegram event already relayed"}

    consumed, marker = _try_presence_inbound(note)
    if consumed:
        _mark_event(claim, "presence")
        return {
            "action": "skip",
            "reason": "relayed to FirstMate Telegram presence handler",
            "result": marker,
        }

    if _queue_inbox(note, request_id):
        _mark_event(claim, "inbox")
        return {"action": "skip", "reason": "relayed to FirstMate Primary inbox"}

    _unclaim_event(claim)
    return None


def register(ctx):
    ctx.register_hook("pre_gateway_dispatch", _on_pre_gateway_dispatch)
