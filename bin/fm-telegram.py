#!/usr/bin/env python3
"""fm-telegram.py - Firstmate's Telegram terminal mirror bot (WSL and macOS).

One private Telegram bot that mirrors the one Firstmate terminal conversation
in both directions. It runs beside Pi as a WSL systemd user service or a macOS
LaunchAgent and talks to the
tracked Pi extension .pi/extensions/fm-telegram-mirror.ts over one local Unix
socket. The bot contains no model, agent loop, or Firstmate reasoning.

Layout (one private directory, owner-only, default ~/.firstmate-telegram,
overridden by FM_TELEGRAM_DIR):

  env          KEY=VALUE file holding TELEGRAM_BOT_TOKEN (never in the unit)
  config.json  pairing and local commands:
                 user_id            paired Telegram account id (integer)
                 chat_id            paired private chat id (integer)
                 transcribe_command local Parakeet command (string; the audio
                                    path replaces {audio} or is appended)
                 confirmations      send "Pi · Sent to Firstmate." or not
                                    (boolean, default true, persisted by the
                                    Telegram commands and Pi's settings)
  bot.sock     Unix socket the Pi extension connects to
  audio/       temporary voice downloads, deleted after send, cancel, failure,
               and at start and stop

Wire protocol (newline-delimited JSON, both directions):

  extension -> bot  {"t":"hello","features":["image"]}
                    {"t":"terminal","text":...,"images":[...]} terminal submission
                    {"t":"reply","text":...}        final visible Firstmate text
                    {"t":"command","id":N,"command":"toggle"|"on"|"off"|"status"}
                    {"t":"set","setting":"confirmations","value":bool}
                    {"t":"accepted","id":"..."}     Pi accepted that message
  bot -> extension  {"t":"deliver","id":"...","text":...,"image":{...}}
                    {"t":"command_result","id":N|null,"text":...}
                    {"t":"state","mirror":bool,"confirmations":bool}

The terminal frame's images and the delivery frame's image are optional.

The hello frame's features decide what the bot may send. A bridge older than
this bot does not announce "image", and an image sent to it would be silently
dropped into a text-only turn, so the bot refuses the image and says so instead.

The bot owns mirror mode and the confirmations setting and pushes a state frame
on connect and after every change from either surface, so Pi's footer and its
settings UI never hold a stale copy.

These commands work from both Telegram and the Pi terminal and never reach
Firstmate as conversation text:

  /telegram on | off | status        Telegram
  /telegram_on | /telegram_off | /telegram_status
  /telegram_confirmations_on | /telegram_confirmations_off
                                     Telegram menu aliases, published to the
                                     paired chat with setMyCommands because
                                     Telegram's menu rejects a space
  /telegram                          Pi, toggles mirror mode
  /telegram-settings                 Pi, native settings UI

Mirror mode starts on at every bot start and lives in memory only, so a
restart always returns to on even when /telegram_off disabled the last run,
and nothing about the previous mode is written to disk. The inbound
queue is an in-memory FIFO with no durable queue, expiry, replay journal, or
retention subsystem: a queued message that has not reached Pi is lost when the
bot or its host service stops.

Reply threading: every transport status the bot itself produces replies to the
exact Telegram message it describes, because the bot knows that message. A
mirrored Firstmate reply is always sent as a normal unthreaded message. Pi
batches back-to-back submissions into one run, so a reply has no single source
message, and a guessed target would attach answers to the wrong one.

Usage:
  fm-telegram.py run                run the bot in the foreground (the service)
  fm-telegram.py pair               record the first private sender as the pair
  fm-telegram.py status             print pairing, service, and socket status
  fm-telegram.py service-unit       print the systemd unit or LaunchAgent plist
  fm-telegram.py install-service    install and start the WSL or macOS user service
  fm-telegram.py uninstall-service  stop and remove that user service

Environment:
  FM_TELEGRAM_DIR        private directory (default ~/.firstmate-telegram)
  FM_TELEGRAM_API_BASE   Telegram API base URL (tests point this at a fake)
  FM_TELEGRAM_ASSUME_WSL 1 or 0 to force the WSL verdict for service commands
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import contextlib
import ctypes
import json
import os
import platform
import plistlib
import secrets
import shlex
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
from typing import Any, Optional

try:  # Debian/Ubuntu: python3-mistune
    import mistune
except ImportError:  # pragma: no cover - exercised by its own regression
    mistune = None

SERVICE_NAME = "firstmate-telegram.service"
MAC_SERVICE_LABEL = "com.firstmate.telegram"
MAC_SERVICE_NAME = f"{MAC_SERVICE_LABEL}.plist"
DEFAULT_API_BASE = "https://api.telegram.org"
DEFAULT_TRANSCRIBE_COMMAND = "parakeet-tdt-0.6b-v3"

MIRROR_OFF_REPLY = "Telegram mirror is off. Send /telegram_on to enable it."
OFFLINE_REPLY = "Firstmate is not running. Your message is queued until it starts."
ACCEPTED_REPLY = "Pi · Sent to Firstmate."
TRANSCRIBING_REPLY = "Transcribing…"
TERMINAL_LABEL = "You · Terminal"
SENT_FOOTER = "Sent to Firstmate"
CANCELLED_FOOTER = "Cancelled"
EDIT_PROMPT = "Reply to this message with the corrected text."
TRANSCRIBE_FAILED_REPLY = "Transcription failed. Nothing was sent to Firstmate."
TRANSCRIPTION_BUSY_REPLY = "Another voice note is already being transcribed. Try again shortly."
TRANSCRIPT_TOO_LONG_REPLY = (
    "That transcript is over 3,800 characters. Nothing was sent to Firstmate."
)
TRANSCRIPT_EDIT_TOO_LONG_REPLY = "Transcript edits must be 3,800 characters or fewer."
STALE_TRANSCRIPT_REPLY = "This transcript is no longer active."
UNSUPPORTED_REPLY = "Only text, voice notes, and images are mirrored."
UNSUPPORTED_IMAGE_REPLY = "That file type is not supported. Send a PNG, JPEG, or WebP image."
OVERSIZED_IMAGE_REPLY = "That image is too large to send to Firstmate."
IMAGE_FAILED_REPLY = "That image could not be downloaded. Nothing was sent to Firstmate."
IMAGE_UNSUPPORTED_SESSION_REPLY = (
    "This Firstmate session cannot receive images yet. "
    "Update the Telegram extension and reload Pi, then send it again."
)
HELP_REPLY = (
    "Firstmate terminal mirror.\n"
    "/telegram_on or /telegram on - start mirroring\n"
    "/telegram_off or /telegram off - stop mirroring\n"
    "/telegram_status or /telegram status - show mirror and Firstmate state"
)

MIRROR_COMMANDS = ("on", "off", "status")
# Telegram's command menu accepts only lowercase letters, digits, and
# underscores, so "/telegram on" cannot appear in it. These single-token
# aliases are the menu entries; both forms do the same thing.
MIRROR_ALIASES = {
    "/telegram_on": "on",
    "/telegram_off": "off",
    "/telegram_status": "status",
    "/telegram_confirmations_on": "confirmations-on",
    "/telegram_confirmations_off": "confirmations-off",
}
MENU_COMMANDS = [
    {"command": "telegram_on", "description": "Start mirroring the Firstmate terminal"},
    {"command": "telegram_off", "description": "Stop mirroring"},
    {"command": "telegram_status", "description": "Show mirror and Firstmate state"},
    {"command": "telegram_confirmations_on",
     "description": "Confirm each message Firstmate accepts"},
    {"command": "telegram_confirmations_off",
     "description": "Stop confirming accepted messages"},
]
# Images the captain can send from the paired chat. Anything else is refused
# before a byte is downloaded.
IMAGE_MIME_TYPES = {"image/png", "image/jpeg", "image/webp"}
MAX_IMAGE_BYTES = 10 * 1024 * 1024
# Queued images live in memory only, like every other queued message, so the
# total is bounded rather than growing while Firstmate is away.
MAX_QUEUED_IMAGE_BYTES = 32 * 1024 * 1024
# Outbound: Telegram's own album and caption limits.
MAX_MEDIA_GROUP = 10
TELEGRAM_CAPTION_LIMIT = 1024
# One frame can carry the aggregate image allowance encoded as base64 plus JSON.
# Keep the wire boundary explicit and bounded while allowing every valid image
# submission through the reader.
MAX_FRAME_BYTES = ((MAX_QUEUED_IMAGE_BYTES + 2) // 3) * 4 + 2 * 1024 * 1024
# Delivery confirmations are switched by their own Telegram commands and by Pi's
# settings; both write the one persistent setting the bot owns.
MIRROR_COMMAND_NAMES = ("on", "off", "status", "confirmations-on", "confirmations-off")
TELEGRAM_TEXT_LIMIT = 3900
TRANSCRIPT_CARD_LIMIT = 3800
COPY_TEXT_LIMIT = 256
TRANSCRIBE_TIMEOUT = 180
POLL_TIMEOUT = 25
MAX_VOICE_BYTES = 20 * 1024 * 1024
# Transcripts nobody acted on are dropped oldest-first, with their audio, so an
# abandoned card cannot retain its text and temporary file for the whole run.
MAX_PENDING_VOICES = 32
# The graceful stop must finish well inside the unit's TimeoutStopSec. Nothing
# durable is buffered at exit: the inbound queue is documented as memory-only,
# and every setting is written when it changes.
STOP_GRACE_SECONDS = 5
TRANSCRIBE_STOP_GRACE = 2


class TelegramError(RuntimeError):
    """A Telegram API or local configuration failure."""

    def __init__(self, message: str, *, status: Optional[int] = None,
                 error_type: Optional[str] = None) -> None:
        super().__init__(message)
        self.status = status
        self.error_type = error_type


def log(message: str) -> None:
    print(f"fm-telegram: {message}", file=sys.stderr, flush=True)


# --- configuration ----------------------------------------------------------


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def home_dir() -> Path:
    value = os.environ.get("FM_TELEGRAM_DIR")
    if value:
        return Path(value).expanduser()
    return Path.home() / ".firstmate-telegram"


def env_file(home: Path) -> Path:
    return home / "env"


def config_file(home: Path) -> Path:
    return home / "config.json"


def socket_path(home: Path) -> Path:
    return home / "bot.sock"


def audio_dir(home: Path) -> Path:
    return home / "audio"


def read_env(home: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        raw = env_file(home).read_text(encoding="utf-8")
    except OSError:
        return values
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def read_config(home: Path) -> dict[str, Any]:
    try:
        data = json.loads(config_file(home).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def write_config(home: Path, data: dict[str, Any]) -> None:
    private_dir(home)
    target = config_file(home)
    target.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    target.chmod(0o600)


@dataclass
class Config:
    home: Path
    firstmate_home: Path
    token: str
    user_id: int
    chat_id: int
    transcribe_command: str
    api_base: str
    confirmations: bool = True


def load_config(home: Path) -> Config:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or read_env(home).get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        raise TelegramError(
            f"no TELEGRAM_BOT_TOKEN in {env_file(home)}; add it as TELEGRAM_BOT_TOKEN=<token>"
        )
    data = read_config(home)
    user_id = data.get("user_id")
    chat_id = data.get("chat_id")
    if not isinstance(user_id, int) or not isinstance(chat_id, int):
        raise TelegramError(
            f"no pairing in {config_file(home)}; run fm-telegram.py pair and message the bot"
        )
    command = data.get("transcribe_command") or DEFAULT_TRANSCRIBE_COMMAND
    api_base = os.environ.get("FM_TELEGRAM_API_BASE") or data.get("api_base") or DEFAULT_API_BASE
    confirmations = data.get("confirmations")
    firstmate_home = Path(
        os.environ.get("FM_HOME") or Path(__file__).resolve().parents[1]
    ).resolve()
    return Config(
        home=home,
        firstmate_home=firstmate_home,
        token=token,
        user_id=user_id,
        chat_id=chat_id,
        transcribe_command=str(command),
        api_base=str(api_base).rstrip("/"),
        confirmations=confirmations if isinstance(confirmations, bool) else True,
    )


# --- Telegram API -----------------------------------------------------------


class TelegramApi:
    def __init__(self, base: str, token: str) -> None:
        self._base = base.rstrip("/")
        self._token = token

    def _multipart_sync(self, method: str, fields: dict[str, str],
                        files: list[tuple[str, str, bytes]], timeout: float) -> Any:
        """Upload real media: the Bot API takes bytes only as multipart."""
        boundary = f"----fm{secrets.token_hex(16)}"
        body = bytearray()
        for name, value in fields.items():
            body += f"--{boundary}\r\n".encode()
            body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
            body += value.encode("utf-8") + b"\r\n"
        for name, filename, blob in files:
            body += f"--{boundary}\r\n".encode()
            body += (f'Content-Disposition: form-data; name="{name}"; '
                     f'filename="{filename}"\r\n').encode()
            body += b"Content-Type: application/octet-stream\r\n\r\n"
            body += blob + b"\r\n"
        body += f"--{boundary}--\r\n".encode()
        request = urllib.request.Request(
            f"{self._base}/bot{self._token}/{method}", data=bytes(body),
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            raise api_rejection(method, exc.code, detail) from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise TelegramError(f"{method} failed: {exc}") from exc
        if not isinstance(payload, dict) or not payload.get("ok"):
            status = payload.get("error_code") if isinstance(payload, dict) else None
            raise TelegramError(
                f"{method} rejected: {str(payload)[:400]}",
                status=status if isinstance(status, int) else None,
                error_type="api_rejection",
            )
        return payload.get("result")

    async def upload(self, method: str, fields: dict[str, str],
                     files: list[tuple[str, str, bytes]], timeout: float = 120) -> Any:
        return await asyncio.to_thread(self._multipart_sync, method, fields, files, timeout)

    def request_sync(self, method: str, params: dict[str, Any], timeout: float = 30) -> Any:
        url = f"{self._base}/bot{self._token}/{method}"
        body = json.dumps(params).encode("utf-8")
        request = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            raise api_rejection(method, exc.code, detail) from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise TelegramError(f"{method} failed: {exc}") from exc
        if not isinstance(payload, dict) or not payload.get("ok"):
            status = payload.get("error_code") if isinstance(payload, dict) else None
            raise TelegramError(
                f"{method} rejected: {str(payload)[:400]}",
                status=status if isinstance(status, int) else None,
                error_type="api_rejection",
            )
        return payload.get("result")

    async def call(self, method: str, params: Optional[dict[str, Any]] = None,
                   timeout: float = 30) -> Any:
        return await asyncio.to_thread(self.request_sync, method, params or {}, timeout)

    def _download(self, file_path: str, target: Path, timeout: float) -> None:
        target.write_bytes(self._fetch(file_path, MAX_VOICE_BYTES, timeout))
        target.chmod(0o600)

    def _fetch(self, file_path: str, limit: int, timeout: float) -> bytes:
        url = f"{self._base}/file/bot{self._token}/{file_path}"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response:
                data = response.read(limit + 1)
        except (OSError, urllib.error.HTTPError) as exc:
            raise TelegramError(f"download failed: {exc}") from exc
        if len(data) > limit:
            raise TelegramError("the file is larger than this bot accepts")
        return data

    async def fetch(self, file_path: str, limit: int, timeout: float = 120) -> bytes:
        return await asyncio.to_thread(self._fetch, file_path, limit, timeout)

    async def download(self, file_path: str, target: Path, timeout: float = 120) -> None:
        await asyncio.to_thread(self._download, file_path, target, timeout)


# --- bot state --------------------------------------------------------------


@dataclass
class Queued:
    id: str
    text: str
    reply_to: int
    image: Optional[dict[str, str]] = None
    image_bytes: int = 0


@dataclass
class Voice:
    voice_id: int
    card_id: int
    text: str
    revision: int = 1
    audio: Optional[Path] = None
    prompt_id: Optional[int] = None


@dataclass
class MirrorBot:
    config: Config
    api: TelegramApi
    # Process memory only, never persisted: every start begins mirroring, and
    # /telegram_off applies to this process alone.
    mirror_on: bool = True
    queue: deque[Queued] = field(default_factory=deque)
    pending: "OrderedDict[str, Queued]" = field(default_factory=OrderedDict)
    voices: dict[int, Voice] = field(default_factory=dict)
    prompts: dict[int, int] = field(default_factory=dict)
    client: Optional[asyncio.StreamWriter] = None
    client_features: set = field(default_factory=set)
    background: set = field(default_factory=set)
    transcribers: set = field(default_factory=set)
    active_transcription: bool = False
    _sequence: int = 0
    _stopping: bool = False

    # --- helpers ---

    @property
    def connected(self) -> bool:
        return self.client is not None

    def next_id(self) -> str:
        self._sequence += 1
        return f"m{self._sequence}"

    async def mirror_terminal(self, text: str, images: Any = None) -> None:
        """Show a terminal submission in Telegram, images included."""
        accepted, refused = accept_outbound_images(images)
        label = f"{TERMINAL_LABEL}\n{text}" if text.strip() else TERMINAL_LABEL
        if not accepted:
            await self.send(label)
        else:
            # A caption rides along when Telegram allows its length; a longer
            # submission is its own message so nothing is truncated away.
            caption = label if utf16_length(label) <= TELEGRAM_CAPTION_LIMIT else ""
            if not caption:
                await self.send(label)
            await self.send_photos(accepted, caption)
        if refused:
            await self.send(f"{TERMINAL_LABEL}\n{refused} image(s) were too large or "
                            "an unsupported type and were not mirrored.")

    async def send_photos(self, images: list[tuple[bytes, str]], caption: str) -> None:
        """One album per batch: a group succeeds or fails whole, never twice."""
        for start in range(0, len(images), MAX_MEDIA_GROUP):
            batch = images[start:start + MAX_MEDIA_GROUP]
            batch_caption = caption if start == 0 else ""
            try:
                if len(batch) == 1:
                    fields = {"chat_id": str(self.config.chat_id)}
                    if batch_caption:
                        fields["caption"] = batch_caption
                    await self.api.upload(
                        "sendPhoto", fields,
                        [("photo", f"terminal{extension_for(batch[0][1])}", batch[0][0])],
                    )
                    continue
                media = []
                files = []
                for index, (blob, mime) in enumerate(batch):
                    name = f"file{index}"
                    entry: dict[str, Any] = {"type": "photo", "media": f"attach://{name}"}
                    if index == 0 and batch_caption:
                        entry["caption"] = batch_caption
                    media.append(entry)
                    files.append((name, f"terminal{index}{extension_for(mime)}", blob))
                await self.api.upload(
                    "sendMediaGroup",
                    {"chat_id": str(self.config.chat_id), "media": json.dumps(media)},
                    files,
                )
            except TelegramError as exc:
                # Never the bytes or the submission: only what failed.
                log(f"could not mirror terminal images: {exc}")
                await self.send(f"{TERMINAL_LABEL}\n{len(batch)} image(s) could not be "
                                "sent to Telegram.")
                return

    async def send(self, text: str, reply_to: Optional[int] = None,
                   markup: Optional[dict[str, Any]] = None,
                   formatted: bool = False) -> Optional[dict[str, Any]]:
        result: Optional[dict[str, Any]] = None
        chunks = (split_markdown(text) if formatted else
                  [(chunk, False, chunk) for chunk in chunk_text(text)])
        for index, (chunk, chunk_formatted, source) in enumerate(chunks):
            params: dict[str, Any] = {"chat_id": self.config.chat_id, "text": chunk}
            if chunk_formatted:
                rendered = telegram_html(chunk)
                if rendered is not None:
                    params["text"] = rendered
                    params["parse_mode"] = "HTML"
            if reply_to is not None:
                params["reply_parameters"] = {
                    "message_id": reply_to,
                    "allow_sending_without_reply": True,
                }
            if markup is not None and index == len(chunks) - 1:
                params["reply_markup"] = markup
            try:
                result = await self.api.call("sendMessage", params)
            except TelegramError as exc:
                if "parse_mode" not in params or not rejected_formatting(exc):
                    log(str(exc))
                    return None
                # Telegram refused the markup, so it sent nothing: the same text
                # goes out plain rather than the captain losing the message.
                log(f"formatting was rejected, sending plain text instead: {exc}")
                params.pop("parse_mode")
                params["text"] = source
                try:
                    result = await self.api.call("sendMessage", params)
                except TelegramError as plain_exc:
                    log(str(plain_exc))
                    return None
        return result

    async def edit_card(self, message_id: int, text: str,
                        markup: Optional[dict[str, Any]]) -> bool:
        params: dict[str, Any] = {
            "chat_id": self.config.chat_id,
            "message_id": message_id,
            "text": utf16_prefix(text, TELEGRAM_TEXT_LIMIT),
        }
        params["reply_markup"] = markup if markup is not None else {"inline_keyboard": []}
        try:
            await self.api.call("editMessageText", params)
        except TelegramError as exc:
            log(str(exc))
            return False
        return True

    async def delete_message(self, message_id: int) -> None:
        params = {"chat_id": self.config.chat_id, "message_id": message_id}
        try:
            await self.api.call("deleteMessage", params)
        except TelegramError as exc:
            log(str(exc))

    async def answer_callback(self, callback_id: str, text: str = "") -> None:
        params: dict[str, Any] = {"callback_query_id": callback_id}
        if text:
            params["text"] = text
        try:
            await self.api.call("answerCallbackQuery", params)
        except TelegramError as exc:
            log(str(exc))

    # --- inbound Telegram -> Pi ---

    def paired_message(self, message: dict[str, Any]) -> bool:
        sender = message.get("from") or {}
        chat = message.get("chat") or {}
        return (
            sender.get("id") == self.config.user_id
            and chat.get("id") == self.config.chat_id
            and chat.get("type") == "private"
        )

    async def handle_update(self, update: dict[str, Any]) -> None:
        message = update.get("message")
        if isinstance(message, dict):
            if not self.paired_message(message):
                return
            await self.handle_message(message)
            return
        callback = update.get("callback_query")
        if isinstance(callback, dict):
            sender = callback.get("from") or {}
            source = callback.get("message") or {}
            chat = source.get("chat") or {}
            if sender.get("id") != self.config.user_id or chat.get("id") != self.config.chat_id:
                return
            await self.handle_callback(callback)

    async def handle_message(self, message: dict[str, Any]) -> None:
        message_id = message.get("message_id")
        text = message.get("text")
        if isinstance(text, str):
            command = mirror_command(text)
            if command:
                await self.send(self.apply_command(command), reply_to=message_id)
                await self.broadcast_state()
                return
            head = text.strip().split(" ", 1)[0].split("@", 1)[0]
            if head in ("/start", "/help", "/telegram"):
                await self.send(HELP_REPLY, reply_to=message_id)
                return
            reply_to = (message.get("reply_to_message") or {}).get("message_id")
            if isinstance(reply_to, int) and reply_to in self.prompts:
                await self.apply_edit(self.prompts[reply_to], text, message_id)
                return
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            await self.accept_text(text, message_id)
            return
        if isinstance(message.get("voice"), dict):
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            if self.active_transcription:
                await self.send(TRANSCRIPTION_BUSY_REPLY, reply_to=message_id)
                return
            self.active_transcription = True
            task = asyncio.create_task(self.handle_voice(message))
            self.background.add(task)
            task.add_done_callback(self.transcription_finished)
            return
        if message.get("photo") or is_image_document(message.get("document")):
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            await self.handle_image(message)
            return
        if isinstance(message.get("document"), dict):
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            await self.send(UNSUPPORTED_IMAGE_REPLY, reply_to=message_id)
            return
        if not self.mirror_on:
            await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
            return
        await self.send(UNSUPPORTED_REPLY, reply_to=message_id)

    def apply_command(self, command: str) -> str:
        if command == "on":
            self.mirror_on = True
        elif command == "off":
            self.mirror_on = False
        elif command == "toggle":
            self.mirror_on = not self.mirror_on
        elif command == "confirmations-on":
            self.set_confirmations(True)
        elif command == "confirmations-off":
            self.set_confirmations(False)
        return self.status_text()

    def status_text(self) -> str:
        mirror = "on" if self.mirror_on else "off"
        firstmate = "connected" if self.connected else "not running"
        confirmations = "on" if self.config.confirmations else "off"
        status = f"Mirror is {mirror}. Firstmate is {firstmate}. Confirmations are {confirmations}."
        queued = len(self.queue) + len(self.pending)
        if queued:
            status += f" {queued} message(s) waiting."
        return status

    def set_confirmations(self, enabled: bool) -> None:
        self.config.confirmations = enabled
        data = read_config(self.config.home)
        data["confirmations"] = enabled
        try:
            write_config(self.config.home, data)
        except OSError as exc:
            # The choice still applies to this run; only its persistence failed.
            log(f"could not persist the confirmations setting: {exc}")

    async def broadcast_state(self) -> None:
        """Push the state Pi's footer and settings render, after every change."""
        await self.write_frame({
            "t": "state",
            "mirror": self.mirror_on,
            "confirmations": self.config.confirmations,
        })

    async def accept_text(self, text: str, reply_to: int,
                          image: Optional[dict[str, str]] = None,
                          image_bytes: int = 0) -> None:
        item = Queued(id=self.next_id(), text=text, reply_to=reply_to,
                      image=image, image_bytes=image_bytes)
        self.queue.append(item)
        if not self.connected:
            await self.send(OFFLINE_REPLY, reply_to=reply_to)
        await self.pump()

    def queued_image_bytes(self) -> int:
        return sum(item.image_bytes for item in (*self.queue, *self.pending.values()))

    async def pump(self) -> None:
        while self.queue and self.client is not None:
            item = self.queue.popleft()
            if item.image and "image" not in self.client_features:
                # The session that turned up cannot render an image, and
                # delivering it anyway would arrive as a text-only or empty
                # turn with nothing to show for it.
                log("dropping a queued image: this Firstmate session has no image support")
                await self.send(IMAGE_UNSUPPORTED_SESSION_REPLY, reply_to=item.reply_to)
                continue
            frame: dict[str, Any] = {"t": "deliver", "id": item.id, "text": item.text}
            if item.image:
                frame["image"] = item.image
            if not await self.write_frame(frame):
                self.queue.appendleft(item)
                return
            self.pending[item.id] = item

    async def on_accepted(self, message_id: str) -> None:
        item = self.pending.pop(message_id, None)
        if item is None:
            return
        # Pending state clears either way: the message reached Pi, so it must
        # never be re-delivered. Only the visible receipt is optional.
        if not self.config.confirmations:
            return
        await self.send(ACCEPTED_REPLY, reply_to=item.reply_to)

    # --- voice ---

    def transcription_finished(self, task: asyncio.Task[Any]) -> None:
        self.background.discard(task)
        self.active_transcription = False

    async def handle_voice(self, message: dict[str, Any]) -> None:
        voice_id = int(message["message_id"])
        # When Telegram accepts edits, one message covers the whole voice note:
        # this placeholder becomes the transcript card or terminal outcome.
        # A failed edit falls back to sending the result rather than losing it.
        placeholder = await self.send(TRANSCRIBING_REPLY, reply_to=voice_id)
        card_id = int(placeholder["message_id"]) if placeholder is not None else None
        audio = audio_dir(self.config.home) / f"{voice_id}.ogg"
        started: list[Any] = []
        try:
            file_id = (message.get("voice") or {}).get("file_id")
            info = await self.api.call("getFile", {"file_id": file_id})
            private_dir(audio_dir(self.config.home))
            await self.api.download(str((info or {}).get("file_path", "")), audio)
            transcript = await transcribe(
                self.config.transcribe_command, audio, self.register_transcriber(started),
            )
        except TelegramError as exc:
            remove_file(audio)
            if self._stopping:
                # Its child was ended by the stop; that is not a captain-facing
                # failure and the chat is going quiet anyway. The placeholder is
                # deliberately left alone: the stop is bounded and the process is
                # already tearing its API access down.
                return
            log(str(exc))
            await self.retire_placeholder(card_id, voice_id, TRANSCRIBE_FAILED_REPLY)
            return
        finally:
            for process in started:
                self.transcribers.discard(process)
        self.active_transcription = False
        if utf16_length(transcript) > TRANSCRIPT_CARD_LIMIT:
            remove_file(audio)
            await self.retire_placeholder(card_id, voice_id, TRANSCRIPT_TOO_LONG_REPLY)
            return
        if card_id is not None and not await self.edit_card(
            card_id, transcript, main_markup(voice_id, 1),
        ):
            # The placeholder is unreachable, so the transcript gets its own card
            # rather than being lost with it.
            card_id = None
        if card_id is None:
            card = await self.send(transcript, reply_to=voice_id, markup=main_markup(voice_id, 1))
            if card is None:
                remove_file(audio)
                return
            card_id = int(card["message_id"])
        self.voices[voice_id] = Voice(
            voice_id=voice_id, card_id=card_id, text=transcript, audio=audio
        )
        await self.retire_stale_voices()

    async def retire_placeholder(self, card_id: Optional[int], voice_id: int,
                                 text: str) -> None:
        """Prefer ending a voice note in its placeholder, with a sent fallback."""
        if card_id is not None and await self.edit_card(card_id, text, None):
            return
        await self.send(text, reply_to=voice_id)

    def register_transcriber(self, started: list) -> Any:
        def register(process: Any) -> None:
            started.append(process)
            self.transcribers.add(process)
            if self._stopping:
                # Raced the stop: end it immediately rather than outliving us.
                self.stop_transcribers()
        return register

    def stop_transcribers(self) -> None:
        for process in list(self.transcribers):
            end_process_group(process)
        self.transcribers.clear()

    async def retire_stale_voices(self) -> None:
        """Keep the newest transcripts only; an untouched card is not durable."""
        while len(self.voices) > MAX_PENDING_VOICES:
            oldest = min(self.voices)
            entry = self.voices.pop(oldest)
            self.clear_prompt(entry)
            remove_file(entry.audio)
            await self.retire_placeholder(
                entry.card_id, entry.voice_id, STALE_TRANSCRIPT_REPLY,
            )

    async def handle_callback(self, callback: dict[str, Any]) -> None:
        callback_id = str(callback.get("id"))
        data = str(callback.get("data") or "")
        parsed = parse_callback(data)
        if parsed is None:
            await self.answer_callback(callback_id, "Unsupported button.")
            return
        voice_id, revision, action = parsed
        entry = self.voices.get(voice_id)
        if entry is None:
            await self.answer_callback(callback_id, STALE_TRANSCRIPT_REPLY)
            return
        if revision != entry.revision:
            await self.answer_callback(callback_id, "This transcript has already moved on.")
            return
        if action == "send" and not self.mirror_on:
            await self.answer_callback(callback_id, "Telegram mirror is off.")
            await self.send(MIRROR_OFF_REPLY, reply_to=entry.voice_id)
            return
        await self.answer_callback(callback_id)
        if action == "send":
            await self.finish_voice(entry, SENT_FOOTER)
            await self.accept_text(entry.text, entry.voice_id)
            return
        if action == "cancel":
            await self.finish_voice(entry, CANCELLED_FOOTER)
            return
        if action == "edit":
            entry.revision += 1
            await self.edit_card(entry.card_id, entry.text, edit_markup(entry))
            prompt = await self.send(EDIT_PROMPT, reply_to=entry.card_id, markup={
                "force_reply": True,
                "input_field_placeholder": "Corrected text",
            })
            if prompt is not None:
                entry.prompt_id = int(prompt["message_id"])
                self.prompts[entry.prompt_id] = entry.voice_id
            return
        if action == "back":
            entry.revision += 1
            await self.retire_prompt(entry)
            await self.edit_card(entry.card_id, entry.text, main_markup(entry.voice_id, entry.revision))

    async def apply_edit(self, voice_id: int, text: str, message_id: int) -> None:
        entry = self.voices.get(voice_id)
        if entry is None:
            await self.send("That transcript is no longer active.", reply_to=message_id)
            return
        if utf16_length(text) > TRANSCRIPT_CARD_LIMIT:
            await self.send(TRANSCRIPT_EDIT_TOO_LONG_REPLY, reply_to=message_id)
            return
        entry.text = text
        entry.revision += 1
        self.clear_prompt(entry)
        await self.edit_card(entry.card_id, entry.text, main_markup(entry.voice_id, entry.revision))

    async def finish_voice(self, entry: Voice, footer: str) -> None:
        self.clear_prompt(entry)
        self.voices.pop(entry.voice_id, None)
        remove_file(entry.audio)
        entry.audio = None
        await self.retire_placeholder(
            entry.card_id, entry.voice_id, f"{entry.text}\n\n{footer}",
        )

    async def retire_prompt(self, entry: Voice) -> None:
        """Back takes the instruction message out of the chat too.

        The binding is dropped first, so even a refused delete cannot leave the
        message acting as a live correction target.
        """
        prompt_id = entry.prompt_id
        self.clear_prompt(entry)
        if prompt_id is not None:
            await self.delete_message(prompt_id)

    def clear_prompt(self, entry: Voice) -> None:
        if entry.prompt_id is not None:
            self.prompts.pop(entry.prompt_id, None)
            entry.prompt_id = None

    # --- images ---

    async def handle_image(self, message: dict[str, Any]) -> None:
        """Send a screenshot to Firstmate exactly as a pasted terminal image."""
        message_id = int(message["message_id"])
        caption = message.get("caption")
        selection = select_image(message)
        if selection is None:
            await self.send(UNSUPPORTED_IMAGE_REPLY, reply_to=message_id)
            return
        # A bridge that does not announce image support would turn this into a
        # text-only turn, or an empty one with no caption, and nothing would say
        # so. Refuse visibly instead of delivering something that vanishes.
        # While no session is connected the capability is simply unknown, so the
        # image queues like any other message and pump() decides on delivery.
        if self.connected and "image" not in self.client_features:
            log("refusing an image: the connected Firstmate session has no image support")
            await self.send(IMAGE_UNSUPPORTED_SESSION_REPLY, reply_to=message_id)
            return
        file_id, mime, declared_size = selection
        if declared_size and declared_size > MAX_IMAGE_BYTES:
            await self.send(OVERSIZED_IMAGE_REPLY, reply_to=message_id)
            return
        if self.queued_image_bytes() >= MAX_QUEUED_IMAGE_BYTES:
            await self.send(OVERSIZED_IMAGE_REPLY, reply_to=message_id)
            return
        try:
            info = await self.api.call("getFile", {"file_id": file_id})
            data = await self.api.fetch(str((info or {}).get("file_path", "")),
                                        MAX_IMAGE_BYTES)
        except TelegramError as exc:
            # Never the bytes, the caption, or the identifiers: only the reason.
            log(f"image download failed: {exc}")
            await self.send(IMAGE_FAILED_REPLY, reply_to=message_id)
            return
        actual_mime = sniff_image_mime(data)
        if actual_mime is None or (mime is not None and mime != actual_mime):
            await self.send(UNSUPPORTED_IMAGE_REPLY, reply_to=message_id)
            return
        if self.queued_image_bytes() + len(data) > MAX_QUEUED_IMAGE_BYTES:
            await self.send(OVERSIZED_IMAGE_REPLY, reply_to=message_id)
            return
        mime = actual_mime
        image = {"data": base64.b64encode(data).decode("ascii"), "mime": mime}
        await self.accept_text(caption if isinstance(caption, str) else "",
                               message_id, image=image, image_bytes=len(data))

    # --- Pi extension socket ---

    async def write_frame(self, frame: dict[str, Any]) -> bool:
        writer = self.client
        if writer is None:
            return False
        try:
            writer.write((json.dumps(frame) + "\n").encode("utf-8"))
            await writer.drain()
            return True
        except (OSError, ConnectionError):
            await self.drop_client(writer)
            return False

    async def drop_client(self, writer: asyncio.StreamWriter) -> None:
        if self.client is not writer:
            return
        self.client = None
        self.client_features = set()
        # Anything delivered but not yet confirmed goes back to the front of the
        # queue in order. A session that vanished between accepting a message
        # and confirming it can therefore see that one message twice, which is
        # the deliberate trade for keeping the queue in memory only.
        for item in reversed(list(self.pending.values())):
            self.queue.appendleft(item)
        self.pending.clear()
        try:
            writer.close()
        except OSError:
            pass

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        if not peer_owns_session_lock(writer, self.config.firstmate_home):
            log(f"refused an unverified Pi connection from {peer_description(writer)}")
            with contextlib.suppress(OSError):
                writer.close()
            return
        # One mirrored session, first come, never displaced. A crewmate or scout
        # that reached this socket must not be able to take the captain's chat
        # away from the live Firstmate session, so a second connection is
        # refused rather than promoted.
        if self.client is not None and not self.client.is_closing():
            log(f"refused a second Pi connection from {peer_description(writer)}; "
                "the connected Firstmate session keeps the mirror")
            with contextlib.suppress(OSError):
                writer.close()
            return
        self.client = writer
        self.client_features = set()
        log(f"mirroring for {peer_description(writer)}")
        await self.broadcast_state()
        # The queue drains once hello names what this session can render.
        try:
            while True:
                try:
                    line = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    # A frame past the bound is refused without tearing the
                    # session down for every later message.
                    log("ignored an oversized frame from the Firstmate session")
                    continue
                if not line:
                    break
                try:
                    frame = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(frame, dict):
                    await self.handle_frame(frame)
        except (OSError, ConnectionError):
            pass
        finally:
            await self.drop_client(writer)

    async def handle_frame(self, frame: dict[str, Any]) -> None:
        kind = frame.get("t")
        if kind == "hello":
            # The bridge declares what it can render; anything it does not claim
            # is never sent to it.
            features = frame.get("features")
            self.client_features = {
                str(name) for name in features if isinstance(name, str)
            } if isinstance(features, list) else set()
            # State already went out when the connection was accepted.
            await self.pump()
            return
        if kind == "accepted":
            await self.on_accepted(str(frame.get("id")))
            return
        if kind == "terminal":
            if self.mirror_on and isinstance(frame.get("text"), str):
                await self.mirror_terminal(frame["text"], frame.get("images"))
            return
        if kind == "reply":
            # Never threaded. Pi batches back-to-back submissions into one run,
            # so a reply cannot be attributed to one source message; guessing a
            # target would attach answers to the wrong message. Transport
            # statuses below still reply to the exact message they describe,
            # because the bot knows those precisely.
            if self.mirror_on and isinstance(frame.get("text"), str):
                await self.send(frame["text"], formatted=True)
            return
        if kind == "command":
            command = str(frame.get("command"))
            if command in MIRROR_COMMAND_NAMES or command == "toggle":
                text = self.apply_command(command)
            else:
                text = f"Unknown command {command!r}."
            await self.write_frame({"t": "command_result", "id": frame.get("id"), "text": text})
            await self.broadcast_state()
            return
        if kind == "set":
            if frame.get("setting") == "confirmations" and isinstance(frame.get("value"), bool):
                self.set_confirmations(bool(frame["value"]))
                text = self.status_text()
            else:
                text = f"Unknown setting {frame.get('setting')!r}."
            await self.write_frame({"t": "command_result", "id": frame.get("id"), "text": text})
            await self.broadcast_state()

    # --- run loop ---

    async def register_menu(self) -> None:
        """Publish the menu aliases, scoped to the paired chat.

        A failure here costs the menu, never the mirror, so it is logged and the
        bot keeps running: both command forms still work by typing them.
        """
        try:
            await self.api.call("setMyCommands", {
                "commands": MENU_COMMANDS,
                "scope": {"type": "chat", "chat_id": self.config.chat_id},
            })
        except TelegramError as exc:
            log(f"could not publish the command menu: {exc}")

    async def poll(self) -> None:
        offset: Optional[int] = None
        while not self._stopping:
            params: dict[str, Any] = {
                "timeout": POLL_TIMEOUT,
                "allowed_updates": ["message", "callback_query"],
            }
            if offset is not None:
                params["offset"] = offset
            try:
                updates = await self.api.call("getUpdates", params, timeout=POLL_TIMEOUT + 15)
            except TelegramError as exc:
                log(str(exc))
                await asyncio.sleep(3)
                continue
            for update in updates or []:
                if not isinstance(update, dict):
                    continue
                offset = int(update.get("update_id", 0)) + 1
                try:
                    await self.handle_update(update)
                except TelegramError as exc:
                    log(str(exc))

    async def run(self) -> None:
        path = socket_path(self.config.home)
        private_dir(self.config.home)
        clear_audio(self.config.home)
        remove_file(path)
        server = await asyncio.start_unix_server(self.handle_client, path=str(path),
                                                 limit=MAX_FRAME_BYTES)
        os.chmod(path, 0o600)
        log(f"listening on {path}")
        loop = asyncio.get_running_loop()
        stopping = asyncio.Event()
        for name in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(NotImplementedError, RuntimeError):
                loop.add_signal_handler(name, stopping.set)
        poller = asyncio.create_task(self.poll())
        waiter = asyncio.create_task(stopping.wait())
        menu = asyncio.create_task(self.register_menu())
        self.background.add(menu)
        menu.add_done_callback(self.background.discard)
        try:
            await asyncio.wait({poller, waiter}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            # Bounded by construction, against three separate waits that each
            # outlast a service manager's stop timeout:
            #  - a connected Pi session parks handle_client in readline, and
            #    Server.wait_closed() waits for every live connection handler,
            #  - a running transcription owns a worker thread that cancelling
            #    its task cannot interrupt, and
            #  - CPython joins leftover worker threads for up to 300s at exit.
            # Nothing durable is buffered: the queue is documented as
            # memory-only and settings are written when they change.
            self._stopping = True
            self.stop_transcribers()
            client = self.client
            self.client = None
            if client is not None:
                with contextlib.suppress(OSError):
                    client.close()
            server.close()
            with contextlib.suppress(asyncio.TimeoutError, OSError):
                await asyncio.wait_for(server.wait_closed(), timeout=STOP_GRACE_SECONDS)
            tasks = [poller, waiter, *list(self.background)]
            for task in tasks:
                task.cancel()
            await asyncio.wait(tasks, timeout=STOP_GRACE_SECONDS)
            remove_file(path)
            clear_audio(self.config.home)
            log("stopped")
            sys.stderr.flush()
            if any(thread is not threading.main_thread() and thread.is_alive()
                   and not thread.daemon for thread in threading.enumerate()):
                os._exit(0)


# --- pure helpers -----------------------------------------------------------


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def utf16_prefix(text: str, limit: int) -> str:
    units = 0
    for index, char in enumerate(text):
        units += 2 if ord(char) > 0xFFFF else 1
        if units > limit:
            return text[:index]
    return text


def chunk_text(text: str, limit: int = TELEGRAM_TEXT_LIMIT) -> list[str]:
    body = text if text.strip() else "(empty message)"
    chunks: list[str] = []
    while body:
        chunk = utf16_prefix(body, limit)
        if not chunk:
            chunk = body[0]
        chunks.append(chunk)
        body = body[len(chunk):]
    return chunks


# --- Telegram HTML ----------------------------------------------------------
#
# Telegram accepts a small documented tag set, and only <, > and & have to be
# escaped. Mistune does the Markdown parsing; this renderer can only emit those
# documented tags, so no sanitizer stands between them and the API, and any
# construct it does not model degrades to its own text.

# A private marker so list() can tell its own items apart from nested content.
LIST_ITEM_MARK = "\x00"

if mistune is not None:

    class TelegramHtmlRenderer(mistune.HTMLRenderer):  # type: ignore[misc]
        def text(self, text: str) -> str:
            return escape(text, quote=False)

        def paragraph(self, text: str) -> str:
            return f"{text}\n\n"

        def heading(self, text: str, level: int, **attrs: Any) -> str:
            return f"<b>{text}</b>\n\n"

        def strong(self, text: str) -> str:
            return f"<b>{text}</b>"

        def emphasis(self, text: str) -> str:
            return f"<i>{text}</i>"

        def strikethrough(self, text: str) -> str:
            return f"<s>{text}</s>"

        def codespan(self, text: str) -> str:
            return f"<code>{escape(text, quote=False)}</code>"

        def linebreak(self) -> str:
            return "\n"

        def softbreak(self) -> str:
            return "\n"

        def blank_line(self) -> str:
            return ""

        def thematic_break(self) -> str:
            return "\n"

        def block_text(self, text: str) -> str:
            # A newline so nested block content starts on its own line rather
            # than running into the item's own text.
            return f"{text}\n"

        def block_code(self, code: str, info: Optional[str] = None) -> str:
            body = escape(code, quote=False)
            if info:
                language = escape(info.split()[0], quote=True)
                return f'<pre><code class="language-{language}">{body}</code></pre>\n'
            return f"<pre>{body}</pre>\n"

        def block_quote(self, text: str) -> str:
            return f"<blockquote>{text.strip()}</blockquote>\n"

        def list(self, text: str, ordered: bool, **attrs: Any) -> str:
            # Telegram has no list markup, so the markers are text. They are
            # applied here because only this call knows whether the list is
            # numbered and where its numbering starts.
            number = int(attrs.get("start") or 1)
            lines: list[str] = []
            for line in text.split("\n"):
                if line.startswith(LIST_ITEM_MARK):
                    body = line[len(LIST_ITEM_MARK):]
                    lines.append(f"{number}. {body}" if ordered else f"- {body}")
                    number += 1
                elif line.strip():
                    # A nested list or a continuation line, kept under its item.
                    lines.append(f"  {line}")
            return "\n".join(lines) + "\n\n"

        def list_item(self, text: str) -> str:
            # One line per item keeps adjacent items compact; the marker is
            # attached by list() above.
            body = "\n".join(part for part in text.strip().split("\n") if part.strip())
            return f"{LIST_ITEM_MARK}{body}\n"

        def link(self, text: str, url: str, title: Optional[str] = None) -> str:
            return f'<a href="{escape(url, quote=True)}">{text or escape(url, quote=False)}</a>'

        def image(self, text: str, url: str, title: Optional[str] = None) -> str:
            return escape(text or url, quote=False)

        def inline_html(self, html: str) -> str:
            return escape(html, quote=False)

        def block_html(self, html: str) -> str:
            return escape(html, quote=False)

    _render_markdown = mistune.create_markdown(
        renderer=TelegramHtmlRenderer(escape=False), plugins=["strikethrough"],
    )
else:
    _render_markdown = None


def telegram_html(text: str) -> Optional[str]:
    """Telegram-safe HTML, or None to send this text plain."""
    if _render_markdown is None:
        return None
    try:
        rendered = str(_render_markdown(text)).strip()
    except Exception as exc:  # a parser fault must never cost the message
        log(f"could not format a message, sending it plain: {exc}")
        return None
    return rendered or None


def inline_boundary_is_safe(text: str) -> bool:
    escaped = False
    ticks = 0
    stars = 0
    underscores = 0
    strikes = 0
    brackets = 0
    index = 0
    while index < len(text):
        char = text[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if char == "`":
            run = 1
            while index + run < len(text) and text[index + run] == "`":
                run += 1
            ticks ^= run
            index += run
            continue
        if ticks:
            index += 1
            continue
        pair = text[index:index + 2]
        if pair == "**":
            stars ^= 1
            index += 2
            continue
        if pair == "__":
            underscores ^= 1
            index += 2
            continue
        if pair == "~~":
            strikes ^= 1
            index += 2
            continue
        if char == "*":
            stars ^= 1
        elif char == "_":
            underscores ^= 1
        elif char == "[":
            brackets += 1
        elif char == "]" and brackets:
            brackets -= 1
        index += 1
    return not any((ticks, stars, underscores, strikes, brackets))


def split_semantic_markdown(text: str, limit: int) -> list[tuple[str, bool, str]]:
    pieces: list[tuple[str, bool, str]] = []
    remaining = text
    while remaining:
        rendered = telegram_html(remaining)
        if (utf16_length(remaining) <= limit and rendered is not None
                and utf16_length(rendered) <= limit):
            pieces.append((remaining, True, remaining))
            break
        prefix_length = len(utf16_prefix(remaining, limit))
        candidates = [
            index for index in range(1, prefix_length + 1)
            if remaining[index - 1].isspace() and inline_boundary_is_safe(remaining[:index])
        ]
        chosen = ""
        for index in reversed(candidates):
            candidate = remaining[:index]
            rendered = telegram_html(candidate)
            if rendered is not None and utf16_length(rendered) <= limit:
                chosen = candidate
                break
        if not chosen:
            pieces.extend((piece, False, piece) for piece in chunk_text(remaining))
            break
        pieces.append((chosen, True, chosen))
        remaining = remaining[len(chosen):]
    return pieces


def split_markdown(text: str, limit: int = TELEGRAM_TEXT_LIMIT) -> list[tuple[str, bool, str]]:
    """Return bounded chunks, formatting safety, and their owned source text."""
    body = text if text.strip() else "(empty message)"
    chunks: list[tuple[str, bool, str]] = []
    current = ""
    owned = ""
    fence = ""
    inside = False
    plain_fence = False

    def flush() -> None:
        nonlocal current, owned
        if not owned:
            current = f"```{fence}\n" if inside else ""
            return
        chunk = current
        if inside:
            chunk = f"{chunk.rstrip(chr(10))}\n```"
        chunk = chunk.strip("\n")
        rendered = telegram_html(chunk)
        if rendered is not None and utf16_length(rendered) <= limit:
            chunks.append((chunk, True, owned))
        else:
            chunks.extend(split_semantic_markdown(owned, limit))
        current = f"```{fence}\n" if inside else ""
        owned = ""

    for line in body.splitlines(keepends=True):
        marker = line.lstrip()
        is_fence = marker.startswith("```")
        if is_fence and not inside:
            if current and utf16_length(current + line) > limit:
                flush()
            current += line
            owned += line
            inside = True
            fence = marker[3:].strip()
            rendered_opener = telegram_html(f"{line.rstrip(chr(10))}\n```")
            plain_fence = (rendered_opener is None
                           or utf16_length(rendered_opener) > limit)
            continue
        if is_fence and inside:
            if plain_fence:
                current += line
                owned += line
                chunks.extend((piece, False, piece) for piece in chunk_text(owned))
                current = ""
                owned = ""
            else:
                if utf16_length(current + line) > limit:
                    flush()
                current += line
                owned += line
            inside = False
            plain_fence = False
            fence = ""
            continue
        if inside:
            if plain_fence:
                current += line
                owned += line
                continue
            piece_limit = max(1, (limit - utf16_length(fence) - 32) // 5)
            while line:
                current_body_units = max(
                    0, utf16_length(current) - utf16_length(fence) - 4,
                )
                available = piece_limit - current_body_units
                if available <= 0:
                    flush()
                    continue
                line_units = utf16_length(line)
                if line_units > available and line_units <= piece_limit:
                    flush()
                    continue
                piece = utf16_prefix(line, available)
                current += piece
                owned += piece
                line = line[len(piece):]
                if line:
                    flush()
            continue
        if current and utf16_length(current + line) > limit:
            flush()
        current += line
        owned += line
    if owned:
        if plain_fence:
            chunks.extend((piece, False, piece) for piece in chunk_text(owned))
        else:
            flush()
    return chunks or [(body, True, body)]


def is_image_document(document: Any) -> bool:
    return isinstance(document, dict) and document.get("mime_type") in IMAGE_MIME_TYPES


def select_image(message: dict[str, Any]) -> Optional[tuple[str, Optional[str], int]]:
    """The best image in a message: (file id, declared mime, declared size)."""
    photos = message.get("photo")
    if isinstance(photos, list) and photos:
        sizes = [p for p in photos if isinstance(p, dict) and p.get("file_id")]
        if not sizes:
            return None
        # Telegram sends every rendition; the captain sent one screenshot, so
        # take the sharpest one it offers.
        best = max(sizes, key=lambda p: (int(p.get("width", 0)) * int(p.get("height", 0)),
                                         int(p.get("file_size", 0))))
        return str(best["file_id"]), None, int(best.get("file_size", 0))
    document = message.get("document")
    if is_image_document(document) and document.get("file_id"):
        return (str(document["file_id"]), str(document["mime_type"]),
                int(document.get("file_size", 0)))
    return None


def sniff_image_mime(data: bytes) -> Optional[str]:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def extension_for(mime: str) -> str:
    return {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}.get(mime, ".png")


def accept_outbound_images(images: Any) -> tuple[list[tuple[bytes, str]], int]:
    """Terminal images fit to mirror, plus how many were refused.

    The same type and size rules as inbound images, applied before anything is
    uploaded, with an aggregate bound so one submission cannot hold the mirror.
    """
    if not isinstance(images, list):
        return [], 0
    accepted: list[tuple[bytes, str]] = []
    refused = 0
    total = 0
    for entry in images:
        if not isinstance(entry, dict):
            refused += 1
            continue
        mime = entry.get("mime")
        raw = entry.get("data")
        if mime not in IMAGE_MIME_TYPES or not isinstance(raw, str):
            refused += 1
            continue
        try:
            blob = base64.b64decode(raw, validate=True)
        except (ValueError, binascii.Error):
            refused += 1
            continue
        if not blob or len(blob) > MAX_IMAGE_BYTES or sniff_image_mime(blob) != mime:
            refused += 1
            continue
        if total + len(blob) > MAX_QUEUED_IMAGE_BYTES:
            refused += 1
            continue
        total += len(blob)
        accepted.append((blob, mime))
    return accepted, refused


def peer_credentials(writer: asyncio.StreamWriter) -> Optional[tuple[int, int]]:
    """Return the kernel-supplied PID and UID of a Unix-socket peer."""
    try:
        sock = writer.get_extra_info("socket")
        if platform.system() == "Darwin":
            # macOS does not implement Linux's SO_PEERCRED. LOCAL_PEERPID is
            # kernel supplied, while getpeereid supplies the peer UID.
            peer_pid = struct.unpack("i", sock.getsockopt(0, 0x002, 4))[0]
            libc = ctypes.CDLL(None, use_errno=True)
            uid = ctypes.c_uint()
            gid = ctypes.c_uint()
            libc.getpeereid.argtypes = [ctypes.c_int,
                                        ctypes.POINTER(ctypes.c_uint),
                                        ctypes.POINTER(ctypes.c_uint)]
            libc.getpeereid.restype = ctypes.c_int
            if libc.getpeereid(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
                return None
            return peer_pid, uid.value
        credentials = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                      struct.calcsize("3i"))
        pid, uid, _gid = struct.unpack("3i", credentials)
    except (OSError, AttributeError, struct.error, ctypes.error):
        return None
    return pid, uid


def session_lock_checker() -> Path:
    if os.environ.get("FM_TELEGRAM_TESTING") == "1":
        override = os.environ.get("FM_TELEGRAM_SESSION_LOCK_CHECK")
        if override:
            return Path(override)
    return Path(__file__).with_name("fm-session-lock-check.sh")


def peer_owns_session_lock(writer: asyncio.StreamWriter, firstmate_home: Path) -> bool:
    credentials = peer_credentials(writer)
    if credentials is None:
        return False
    peer_pid, peer_uid = credentials
    if hasattr(os, "getuid") and peer_uid != os.getuid():
        return False
    try:
        result = subprocess.run(
            [str(session_lock_checker()), str(firstmate_home / "state"), str(peer_pid)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def peer_description(writer: asyncio.StreamWriter) -> str:
    """Kernel-supplied identity of the connected process, never client-supplied."""
    credentials = peer_credentials(writer)
    if credentials is None:
        return "an unidentified process"
    pid, uid = credentials
    try:
        command = Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip()
    except OSError:
        command = "unknown"
    return f"pid {pid} ({command}, uid {uid})"


def api_rejection(method: str, http_status: int, detail: str) -> TelegramError:
    status = http_status
    try:
        payload = json.loads(detail)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, dict) and isinstance(payload.get("error_code"), int):
        status = payload["error_code"]
    return TelegramError(
        f"{method} failed with HTTP {http_status}: {detail}",
        status=status,
        error_type="api_rejection",
    )


def rejected_formatting(error: TelegramError) -> bool:
    """True when Telegram refused the formatted request before sending it."""
    return error.error_type == "api_rejection" and error.status == 400


def mirror_command(text: str) -> Optional[str]:
    parts = text.strip().split()
    if not parts:
        return None
    head = parts[0].split("@", 1)[0]
    if head in MIRROR_ALIASES:
        return MIRROR_ALIASES[head]
    if len(parts) != 2 or head != "/telegram" or parts[1] not in MIRROR_COMMANDS:
        return None
    return parts[1]

def main_markup(voice_id: int, revision: int) -> dict[str, Any]:
    return {
        "inline_keyboard": [
            [{"text": "Send to Firstmate", "callback_data": f"v:{voice_id}:{revision}:send"}],
            [
                {"text": "Edit", "callback_data": f"v:{voice_id}:{revision}:edit"},
                {"text": "Cancel", "callback_data": f"v:{voice_id}:{revision}:cancel"},
            ],
        ]
    }


def edit_markup(entry: Voice) -> dict[str, Any]:
    row: list[dict[str, Any]] = []
    if utf16_length(entry.text) <= COPY_TEXT_LIMIT:
        row.append({"text": "Copy text", "copy_text": {"text": entry.text}})
    row.append({"text": "Back", "callback_data": f"v:{entry.voice_id}:{entry.revision}:back"})
    return {"inline_keyboard": [row]}


def parse_callback(data: str) -> Optional[tuple[int, int, str]]:
    parts = data.split(":")
    if len(parts) != 4 or parts[0] != "v":
        return None
    if parts[3] not in ("send", "edit", "cancel", "back"):
        return None
    try:
        return int(parts[1]), int(parts[2]), parts[3]
    except ValueError:
        return None


def remove_file(path: Optional[Path]) -> None:
    if path is None:
        return
    try:
        path.unlink()
    except OSError:
        pass


def clear_audio(home: Path) -> None:
    directory = audio_dir(home)
    if not directory.is_dir():
        return
    for entry in directory.iterdir():
        if entry.is_file():
            remove_file(entry)


def transcribe_argv(command: str, audio: Path) -> list[str]:
    parts = shlex.split(command)
    if not parts:
        raise TelegramError("transcribe_command is empty")
    if any("{audio}" in part for part in parts):
        return [part.replace("{audio}", str(audio)) for part in parts]
    return [*parts, str(audio)]


def run_transcribe(command: str, audio: Path, register: Optional[Any] = None) -> str:
    argv = transcribe_argv(command, audio)
    try:
        process = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            # Its own process group: a transcriber is usually a wrapper script
            # driving heavier children, and signalling only the wrapper leaves
            # those children alive holding this pipe open.
            start_new_session=True,
        )
    except (OSError, ValueError) as exc:
        raise TelegramError(f"transcription command failed: {exc}") from exc
    # Published before the wait so a stopping bot can end this child instead of
    # blocking on it: a local speech model can hold the CPU for minutes.
    if register is not None:
        register(process)
    try:
        stdout, stderr = process.communicate(timeout=TRANSCRIBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        end_process_group(process)
        process.communicate()
        raise TelegramError("transcription timed out") from None
    if process.returncode != 0:
        detail = (stderr or "").strip()[:200]
        raise TelegramError(f"transcription command exited {process.returncode}: {detail}")
    transcript = (stdout or "").strip()
    if not transcript:
        raise TelegramError("transcription produced no text")
    return transcript


def end_process_group(process: Any) -> None:
    """Stop a transcriber and everything it started, then stop waiting."""
    for signal_name in (signal.SIGTERM, signal.SIGKILL):
        if process.poll() is not None:
            return
        try:
            group = os.getpgid(process.pid)
        except (OSError, ProcessLookupError):
            group = None
        # Only ever signal a group the child leads. A transcriber that failed to
        # get its own session shares ours, and signalling that group would take
        # down this service with it.
        if group is not None and group != os.getpgrp():
            try:
                os.killpg(group, signal_name)
            except (OSError, ProcessLookupError):
                pass
        else:
            try:
                process.send_signal(signal_name)
            except (OSError, ValueError, ProcessLookupError):
                return
        try:
            process.wait(timeout=TRANSCRIBE_STOP_GRACE)
            return
        except subprocess.TimeoutExpired:
            continue


async def transcribe(command: str, audio: Path, register: Optional[Any] = None) -> str:
    return await asyncio.to_thread(run_transcribe, command, audio, register)


# --- service and CLI --------------------------------------------------------


def is_wsl() -> bool:
    assume = os.environ.get("FM_TELEGRAM_ASSUME_WSL")
    if assume in ("0", "1"):
        return assume == "1"
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        return "microsoft" in Path("/proc/sys/kernel/osrelease").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def on_macos() -> bool:
    return platform.system() == "Darwin"


def unit_path() -> Path:
    if on_macos():
        return Path.home() / "Library" / "LaunchAgents" / MAC_SERVICE_NAME
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "systemd" / "user" / SERVICE_NAME


def unit_text(home: Path) -> str:
    script = Path(__file__).resolve()
    firstmate_home = Path(
        os.environ.get("FM_HOME") or Path(__file__).resolve().parents[1]
    ).resolve()
    if on_macos():
        return plistlib.dumps({
            "Label": MAC_SERVICE_LABEL,
            "ProgramArguments": [sys.executable, str(script), "run"],
            "EnvironmentVariables": {
                "FM_TELEGRAM_DIR": str(home),
                "FM_HOME": str(firstmate_home),
            },
            "RunAtLoad": True,
            "KeepAlive": True,
            "ProcessType": "Interactive",
        }, sort_keys=False).decode("utf-8")
    return (
        "[Unit]\n"
        "Description=Firstmate Telegram terminal mirror\n"
        "After=network-online.target\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        f"Environment=FM_TELEGRAM_DIR={shlex.quote(str(home))}\n"
        f"Environment=FM_HOME={shlex.quote(str(firstmate_home))}\n"
        f"ExecStart={sys.executable} {shlex.quote(str(script))} run\n"
        "Restart=always\n"
        "RestartSec=5\n"
        # The bot's own stop is bounded by STOP_GRACE_SECONDS; this leaves room
        # for it without inviting the 90s default when something goes wrong.
        "TimeoutStopSec=20\n"
        "\n"
        "[Install]\n"
        "WantedBy=default.target\n"
    )


def systemctl(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["systemctl", "--user", *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, check=False,
    )


def require_service_platform() -> None:
    if not is_wsl() and not on_macos():
        raise TelegramError("the Telegram mirror service requires WSL or macOS")


def launchctl(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *arguments], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, check=False)


def mac_service_target() -> str:
    return f"gui/{os.getuid()}/{MAC_SERVICE_LABEL}"


def install_service(home: Path) -> int:
    require_service_platform()
    target = unit_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(unit_text(home), encoding="utf-8")
    target.chmod(0o600)
    if on_macos():
        result = launchctl("bootstrap", f"gui/{os.getuid()}", str(target))
        if result.returncode != 0 and not any(
                phrase in result.stdout.lower()
                for phrase in ("already bootstrapped", "service already loaded")):
            raise TelegramError(f"launchctl bootstrap failed: {result.stdout.strip()}")
        result = launchctl("kickstart", "-k", mac_service_target())
        if result.returncode != 0:
            raise TelegramError(f"launchctl kickstart failed: {result.stdout.strip()}")
        print(f"installed {target} and started {MAC_SERVICE_LABEL}")
        return 0
    for arguments in (("daemon-reload",), ("enable", "--now", SERVICE_NAME)):
        result = systemctl(*arguments)
        if result.returncode != 0:
            print(result.stdout, end="")
            raise TelegramError(f"systemctl --user {' '.join(arguments)} failed")
    print(f"installed {target} and started {SERVICE_NAME}")
    return 0


def uninstall_service() -> int:
    require_service_platform()
    target = unit_path()
    if on_macos():
        result = launchctl("bootout", mac_service_target())
        if result.returncode != 0 and not any(
                phrase in result.stdout.lower()
                for phrase in ("could not find service", "service not found", "no such process")
        ):
            raise TelegramError(f"launchctl bootout failed: {result.stdout.strip()}")
        remove_file(target)
        print(f"removed {target}")
        return 0
    systemctl("disable", "--now", SERVICE_NAME)
    remove_file(target)
    systemctl("daemon-reload")
    print(f"removed {target}")
    return 0


def pair(home: Path) -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or read_env(home).get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        raise TelegramError(f"no TELEGRAM_BOT_TOKEN in {env_file(home)}")
    base = os.environ.get("FM_TELEGRAM_API_BASE") or DEFAULT_API_BASE
    api = TelegramApi(base, token)
    print("send any message to the bot from the Telegram account you want paired...")
    offset: Optional[int] = None
    deadline = time.time() + 300
    while time.time() < deadline:
        params: dict[str, Any] = {"timeout": 10, "allowed_updates": ["message"]}
        if offset is not None:
            params["offset"] = offset
        result = api.request_sync("getUpdates", params, 30)
        for update in result or []:
            offset = int(update.get("update_id", 0)) + 1
            message = update.get("message") or {}
            chat = message.get("chat") or {}
            sender = message.get("from") or {}
            if chat.get("type") != "private":
                continue
            data = read_config(home)
            data["user_id"] = int(sender["id"])
            data["chat_id"] = int(chat["id"])
            data.setdefault("transcribe_command", DEFAULT_TRANSCRIBE_COMMAND)
            write_config(home, data)
            print(f"paired user {data['user_id']} in chat {data['chat_id']}")
            return 0
    raise TelegramError("no private message arrived within 5 minutes")


def status(home: Path) -> int:
    data = read_config(home)
    token = "present" if (os.environ.get("TELEGRAM_BOT_TOKEN")
                          or read_env(home).get("TELEGRAM_BOT_TOKEN")) else "missing"
    print(f"home: {home}")
    print(f"token: {token}")
    print(f"paired user: {data.get('user_id', 'none')}")
    print(f"paired chat: {data.get('chat_id', 'none')}")
    print(f"transcribe command: {data.get('transcribe_command', DEFAULT_TRANSCRIBE_COMMAND)}")
    print(f"socket: {'present' if socket_path(home).exists() else 'absent'}")
    if on_macos():
        result = launchctl("print", mac_service_target())
        print(f"service: {'active' if result.returncode == 0 else 'inactive'}")
    else:
        result = systemctl("is-active", SERVICE_NAME)
        print(f"service: {result.stdout.strip() or 'unknown'}")
    return 0


def run(home: Path) -> int:
    config = load_config(home)
    bot = MirrorBot(config=config, api=TelegramApi(config.api_base, config.token))
    try:
        asyncio.run(bot.run())
    except KeyboardInterrupt:
        pass
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-telegram.py",
        description="Firstmate's Telegram terminal mirror bot (WSL and macOS).",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        choices=["run", "pair", "status", "service-unit", "install-service", "uninstall-service"],
    )
    args = parser.parse_args(argv)
    home = private_dir(home_dir())
    if args.command == "run":
        return run(home)
    if args.command == "pair":
        return pair(home)
    if args.command == "status":
        return status(home)
    if args.command == "service-unit":
        print(unit_text(home), end="")
        return 0
    if args.command == "install-service":
        return install_service(home)
    return uninstall_service()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except TelegramError as error:
        log(str(error))
        sys.exit(1)
