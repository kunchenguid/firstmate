#!/usr/bin/env python3
"""Guarded Apple Notes channel owner.

Public entrypoint: bin/fm-notes-channel.sh.

This process owns the channel schema, immutable local ledger, strict envelope
parser, fake/production provider boundary, capture-before-offer ordering,
claims, deterministic outbound intents, reconcile-before-create publication,
health, authenticated-check definitions, emergency disable, and local-only
uninstall definitions.

It never sends Apple Events itself.  Production requests are fixed JSON sent on
stdin to the pinned Firstmate Notes Bridge app without a shell.  The fake
provider is deterministic and records a body-free call spy for offline tests.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import dataclasses
import datetime as dt
import fcntl
import hashlib
import html
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import uuid
from typing import Any, Iterable, Iterator, Mapping

CHANNEL_SCHEMA = "firstmate.apple-notes-channel/v1"
CONFIG_SCHEMA = "firstmate.apple-notes-channel-config/v1"
CAPTURE_SCHEMA = "firstmate.apple-notes.capture/v1"
OUTBOUND_SCHEMA = "firstmate.apple-notes.outbound/v1"
FAKE_SCHEMA = "firstmate.apple-notes.fake-provider/v1"
BRIDGE_SCHEMA = "firstmate.apple-notes.bridge/v1"
BUNDLE_ID = "dev.firstmate.notes-bridge"
EXPECTED_NAMES = {
    "root": "Firstmate",
    "guide": "00 Guide",
    "inbox": "10 Inbox",
    "acknowledgments": "20 Acknowledgments",
    "outbox": "30 Outbox",
    "archive": "90 Archive",
    "archive_inbound": "Inbound",
    "archive_acknowledgments": "Acknowledgments",
    "archive_outbound": "Outbound",
}
BINDING_KEYS = ("account", *EXPECTED_NAMES.keys())
OPERATIONAL_FOLDER_KEYS = tuple(EXPECTED_NAMES.keys())
INTENTS = {"status", "summarize", "scout", "plan", "draft"}
KINDS = {"query", "feedback", "command", "ack"}
OUTBOUND_KINDS = {"ACK", "DONE", "DECISION", "INFO", "CONFLICT"}
DESTINATIONS = {"acknowledgments", "outbox"}
MESSAGE_RE = re.compile(r"^ni1_[a-z2-7]{26}$")
OUTBOUND_RE = re.compile(r"^(?:na1|no1)_[a-z0-9._-]{8,80}$")
REPLY_RE = re.compile(
    r"^(?:-|ni1_[a-z2-7]{26}|na1_[a-z0-9._-]{8,80}|no1_[a-z0-9._-]{8,80})$"
)
KEY_RE = re.compile(r"^[a-z][a-z_]*$")
HTTPS_RE = re.compile(r"https://[^\s<>\[\](){}\"']+", re.IGNORECASE)
ANY_SCHEME_RE = re.compile(r"\b([a-zA-Z][a-zA-Z0-9+.-]*):(?://)?")
HIGH_IMPACT_RE = re.compile(
    r"\b(?:merge|land|push|publish|post|send|email|message|deploy|release|restart|"
    r"install|uninstall|load|unload|delete|discard|erase|overwrite|force|revoke|"
    r"rotate|credential|password|token|secret|keychain|mfa|two[- ]factor|payment|"
    r"purchase|refund|transfer|invoice|production|database|customer data|sudo|"
    r"full disk access|accessibility|automation permission|tcc|icloud setting|"
    r"share (?:the )?note|lock (?:the )?note|unlock (?:the )?note)\b",
    re.IGNORECASE,
)
PROHIBITED_DATA_RE = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:password|api[_ -]?key|"
    r"access[_ -]?token|refresh[_ -]?token|session cookie|recovery code)\s*[:=]",
    re.IGNORECASE,
)
OUTBOUND_PRIVATE_PATH_RE = re.compile(
    r"(?:^|[\s(])/(?:Users|private|var|etc|tmp)/[^\s)]*|"
    r"\b[A-Za-z]:\\(?:Users|Windows|ProgramData)\\[^\s]*",
    re.IGNORECASE | re.MULTILINE,
)
BIDI_CODEPOINTS = {
    *range(0x202A, 0x202F),
    *range(0x2066, 0x206A),
    0x061C,
    0x200E,
    0x200F,
}
ALLOWED_HTML_TAGS = {
    "div",
    "p",
    "br",
    "b",
    "strong",
    "i",
    "em",
    "u",
    "ul",
    "ol",
    "li",
    "pre",
    "code",
    "a",
    "span",
}
DEFAULT_LIMITS = {
    "inbox_objects": 200,
    "capture_per_scan": 20,
    "scan_deadline_seconds": 8,
    "title_bytes": 256,
    "title_characters": 120,
    "envelope_bytes": 2048,
    "envelope_lines": 20,
    "body_bytes": 14 * 1024,
    "plaintext_bytes": 16 * 1024,
    "plaintext_lines": 200,
    "url_count": 5,
    "url_bytes": 2048,
    "stability_seconds": 15,
    "max_age_seconds": 24 * 3600,
    "future_skew_seconds": 300,
    "accepted_five_minutes": 3,
    "accepted_day": 20,
    "outbound_hour": 10,
    "outbound_day": 30,
    "reoffer_seconds": 3600,
}


class ChannelError(Exception):
    def __init__(self, code: str, message: str, *, disable: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.disable = disable


class ProviderError(ChannelError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def b32_digest(value: bytes, length: int = 26) -> str:
    return (
        base64.b32encode(hashlib.sha256(value).digest())
        .decode("ascii")
        .lower()
        .rstrip("=")[:length]
    )


def utc_iso(epoch: float) -> str:
    return (
        dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def parse_rfc3339(value: str) -> dt.datetime:
    if not isinstance(value, str) or len(value) > 64:
        raise ChannelError(
            "malformed-created-at", "created_at is not a bounded RFC3339 value"
        )
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ChannelError("malformed-created-at", "created_at is not RFC3339") from exc
    if parsed.tzinfo is None:
        raise ChannelError(
            "malformed-created-at", "created_at requires an explicit offset"
        )
    return parsed.astimezone(dt.timezone.utc)


def safe_component(value: str) -> str:
    return b32_digest(value.encode("utf-8"), 32)


def mode_of(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


def ensure_no_symlink_components(home: Path, path: Path) -> None:
    home_abs = Path(os.path.abspath(home))
    path_abs = Path(os.path.abspath(path))
    try:
        relative = path_abs.relative_to(home_abs)
    except ValueError as exc:
        raise ChannelError(
            "path-escape", "channel path escapes FM_HOME", disable=True
        ) from exc
    try:
        home_info = home_abs.lstat()
    except OSError as exc:
        raise ChannelError(
            "unsafe-home", "FM_HOME is unavailable", disable=True
        ) from exc
    if (
        not stat.S_ISDIR(home_info.st_mode)
        or stat.S_ISLNK(home_info.st_mode)
        or home_info.st_uid != os.getuid()
    ):
        raise ChannelError(
            "unsafe-home", "FM_HOME is not an owned regular directory", disable=True
        )
    current = home_abs
    for component in relative.parts:
        current = current / component
        if current.exists() or current.is_symlink():
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ChannelError(
                    "unsafe-path", "channel path contains a symbolic link", disable=True
                )
            if info.st_uid != os.getuid() or info.st_dev != home_info.st_dev:
                raise ChannelError(
                    "unsafe-path",
                    "channel path owner or device differs from FM_HOME",
                    disable=True,
                )


def ensure_private_dir(home: Path, path: Path) -> Path:
    ensure_no_symlink_components(home, path)
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ChannelError(
                "unsafe-directory", f"unsafe channel directory: {path}", disable=True
            )
        if info.st_nlink < 2:
            raise ChannelError(
                "unsafe-directory", f"invalid channel directory: {path}", disable=True
            )
        os.chmod(path, 0o700)
    else:
        parent = path.parent
        if parent != home and not parent.exists():
            ensure_private_dir(home, parent)
        path.mkdir(mode=0o700)
    return path


def validate_private_file(home: Path, path: Path, expected_mode: int = 0o600) -> None:
    ensure_no_symlink_components(home, path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ChannelError("unsafe-file", f"unsafe channel file: {path}", disable=True)
    if info.st_nlink != 1:
        raise ChannelError("unsafe-file", f"linked channel file: {path}", disable=True)
    if stat.S_IMODE(info.st_mode) != expected_mode:
        raise ChannelError(
            "unsafe-file-mode", f"wrong channel file mode: {path}", disable=True
        )
    if info.st_uid != os.getuid():
        raise ChannelError(
            "unsafe-file-owner", f"wrong channel file owner: {path}", disable=True
        )
    if info.st_dev != home.lstat().st_dev:
        raise ChannelError(
            "unsafe-file-device", f"wrong channel file device: {path}", disable=True
        )


def atomic_write(
    home: Path, path: Path, payload: bytes, mode: int = 0o600, *, replace: bool = True
) -> None:
    parent = ensure_private_dir(home, path.parent)
    if path.exists() or path.is_symlink():
        validate_private_file(home, path, mode)
        if not replace:
            raise FileExistsError(path)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=True) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        validate_private_file(home, tmp, mode)
        if not replace:
            try:
                os.link(tmp, path, follow_symlinks=False)
            except FileExistsError:
                raise
            finally:
                tmp.unlink(missing_ok=True)
        else:
            if path.exists() or path.is_symlink():
                validate_private_file(home, path, mode)
            os.replace(tmp, path)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        tmp.unlink(missing_ok=True)


def write_json(home: Path, path: Path, value: Any, *, replace: bool = True) -> None:
    atomic_write(home, path, canonical_json(value) + b"\n", replace=replace)


def read_json(home: Path, path: Path, *, required: bool = True) -> Any:
    if not path.exists() and not path.is_symlink():
        if required:
            raise ChannelError(
                "missing-file",
                f"required channel file is missing: {path}",
                disable=True,
            )
        return None
    validate_private_file(home, path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ChannelError(
            "corrupt-file", f"channel JSON is unreadable: {path}", disable=True
        ) from exc
    return value


def append_json_line(home: Path, path: Path, value: Any) -> None:
    ensure_private_dir(home, path.parent)
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.getuid()
        ):
            raise ChannelError(
                "unsafe-audit",
                "audit log is not a private single-link regular file",
                disable=True,
            )
        os.write(fd, canonical_json(value) + b"\n")
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_text_controls(
    value: str, label: str, *, allow_tab_newline: bool = True
) -> None:
    for character in value:
        code = ord(character)
        if code in BIDI_CODEPOINTS:
            raise ChannelError("unicode-control", f"{label} contains a bidi control")
        if code == 0 or 0x7F <= code <= 0x9F:
            raise ChannelError(
                "unicode-control", f"{label} contains a forbidden control"
            )
        if code < 0x20 and not (allow_tab_newline and character in "\t\n"):
            raise ChannelError(
                "unicode-control", f"{label} contains a forbidden control"
            )
        if 0xFDD0 <= code <= 0xFDEF or code & 0xFFFF in {0xFFFE, 0xFFFF}:
            raise ChannelError(
                "unicode-noncharacter", f"{label} contains a Unicode noncharacter"
            )


def normalize_newlines(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n")


def validate_https_url(value: str, limits: Mapping[str, int]) -> str:
    if len(value.encode("utf-8")) > limits["url_bytes"]:
        raise ChannelError("url-too-long", "a URL exceeds the byte cap")
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        raise ChannelError(
            "unsafe-url", "only credential-free HTTPS URLs are inertly allowed"
        )
    host = parsed.hostname.lower().rstrip(".")
    if host == "localhost" or host.endswith(".localhost"):
        raise ChannelError("unsafe-url", "local URLs are not accepted")
    try:
        address = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        address = None
    if address and (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
    ):
        raise ChannelError("unsafe-url", "private or local IP URLs are not accepted")
    validate_text_controls(value, "URL", allow_tab_newline=False)
    return value


class StrictNotesHTML(HTMLParser):
    def __init__(self, limits: Mapping[str, int]):
        super().__init__(convert_charrefs=True)
        self.limits = limits
        self.parts: list[str] = []
        self.stack: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag not in ALLOWED_HTML_TAGS:
            raise ChannelError("unsafe-html", f"inbound HTML tag is not allowed: {tag}")
        normalized = {key.lower(): value for key, value in attrs}
        if tag == "a":
            if set(normalized) != {"href"} or normalized["href"] is None:
                raise ChannelError(
                    "unsafe-html", "an inbound link has unexpected attributes"
                )
            validate_https_url(normalized["href"], self.limits)
        elif normalized:
            raise ChannelError(
                "unsafe-html", f"inbound HTML attributes are not allowed on {tag}"
            )
        if tag in {"br", "p", "div", "li"}:
            self.parts.append("\n")
        if tag not in {"br"}:
            self.stack.append(tag)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag.lower() != "br":
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if not self.stack or self.stack[-1] != tag:
            raise ChannelError("unsafe-html", "inbound HTML is not properly nested")
        self.stack.pop()
        if tag in {"p", "div", "li"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        validate_text_controls(data, "inbound HTML text")
        self.parts.append(data)

    def handle_comment(self, data: str) -> None:
        raise ChannelError("unsafe-html", "inbound HTML comments are not allowed")

    def unknown_decl(self, data: str) -> None:
        raise ChannelError("unsafe-html", "inbound HTML declarations are not allowed")

    def visible_text(self) -> str:
        if self.stack:
            raise ChannelError("unsafe-html", "inbound HTML has unclosed tags")
        return "".join(self.parts)


def visible_compare(value: str) -> str:
    normalized = unicodedata.normalize("NFC", normalize_newlines(value))
    return re.sub(r"\s+", " ", normalized).strip()


@dataclasses.dataclass(frozen=True)
class ParsedEnvelope:
    title: str
    kind: str
    intent: str
    client_id: str
    reply_to: str
    created_at: str
    body: str
    links: tuple[str, ...]
    content_digest: str
    confirmation_required: bool

    def public_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "kind": self.kind,
            "intent": self.intent,
            "client_id": self.client_id,
            "reply_to": self.reply_to,
            "created_at": self.created_at,
            "body": self.body,
            "links": list(self.links),
            "content_digest": self.content_digest,
            "confirmation_required": self.confirmation_required,
        }


def parse_envelope(
    plaintext: str,
    returned_title: str,
    html_body: str,
    now: float,
    limits: Mapping[str, int],
) -> ParsedEnvelope:
    try:
        plaintext.encode("utf-8", "strict")
        html_body.encode("utf-8", "strict")
    except UnicodeError as exc:
        raise ChannelError("invalid-utf8", "Notes text is not valid UTF-8") from exc
    text = normalize_newlines(plaintext)
    validate_text_controls(text, "plaintext")
    validate_text_controls(returned_title, "title", allow_tab_newline=False)
    if len(text.encode("utf-8")) > limits["plaintext_bytes"]:
        raise ChannelError(
            "plaintext-too-large", "normalized plaintext exceeds the byte cap"
        )
    lines = text.split("\n")
    if len(lines) > limits["plaintext_lines"]:
        raise ChannelError(
            "plaintext-too-many-lines", "normalized plaintext exceeds the line cap"
        )
    if len(lines) < 5 or lines[1] != "" or lines[2] != "FIRSTMATE-NOTE/1":
        raise ChannelError(
            "malformed-envelope", "missing exact FIRSTMATE-NOTE/1 header"
        )
    title = unicodedata.normalize("NFC", lines[0]).strip()
    if not title or title != unicodedata.normalize("NFC", returned_title).strip():
        raise ChannelError(
            "title-mismatch", "the Notes title does not match the envelope first line"
        )
    if (
        len(title) > limits["title_characters"]
        or len(title.encode("utf-8")) > limits["title_bytes"]
    ):
        raise ChannelError("title-too-large", "title exceeds its cap")
    try:
        delimiter = lines.index("---", 3)
    except ValueError as exc:
        raise ChannelError(
            "malformed-envelope", "missing exact body delimiter"
        ) from exc
    envelope_lines = lines[2:delimiter]
    if (
        len(envelope_lines) > limits["envelope_lines"]
        or len("\n".join(envelope_lines).encode("utf-8")) > limits["envelope_bytes"]
    ):
        raise ChannelError("envelope-too-large", "envelope exceeds its cap")
    fields: dict[str, str] = {}
    for line in lines[3:delimiter]:
        if ": " not in line or line.count(": ") != 1:
            raise ChannelError(
                "malformed-envelope", "envelope lines must use exact key: value syntax"
            )
        key, value = line.split(": ", 1)
        if (
            not KEY_RE.fullmatch(key)
            or unicodedata.normalize("NFKC", key) != key
            or not key.isascii()
        ):
            raise ChannelError(
                "malformed-envelope", "envelope keys must be exact ASCII tokens"
            )
        if key in fields:
            raise ChannelError("duplicate-envelope-key", "envelope keys must be unique")
        validate_text_controls(value, f"envelope field {key}", allow_tab_newline=False)
        if unicodedata.normalize("NFKC", value) != value:
            raise ChannelError(
                "ambiguous-envelope-value", "envelope values must already be NFKC"
            )
        fields[key] = value
    common = {
        "direction",
        "sender",
        "kind",
        "client_id",
        "reply_to",
        "created_at",
        "final",
    }
    kind = fields.get("kind", "")
    required = set(common)
    if kind in {"command", "query"}:
        required.add("command")
    if set(fields) != required:
        raise ChannelError(
            "unknown-or-missing-envelope-key",
            "envelope key set is not exact for its kind",
        )
    if (
        fields["direction"] != "inbound"
        or fields["sender"] != "captain"
        or fields["final"] != "yes"
    ):
        raise ChannelError(
            "invalid-envelope-authority",
            "direction, sender, or final marker is invalid",
        )
    if kind not in KINDS:
        raise ChannelError("unknown-kind", "message kind is not allowlisted")
    command = fields.get("command", "")
    if kind == "command":
        if command not in INTENTS:
            raise ChannelError("unknown-intent", "command intent is not allowlisted")
        intent = command
    elif kind == "query":
        if command not in {"status", "summarize"}:
            raise ChannelError(
                "unknown-intent", "query intent must be status or summarize"
            )
        intent = command
    elif kind == "feedback":
        intent = "feedback"
    else:
        intent = "ack"
    client_id = fields["client_id"]
    if client_id != "auto":
        try:
            parsed_uuid = uuid.UUID(client_id)
        except ValueError as exc:
            raise ChannelError(
                "invalid-client-id", "client_id must be auto or a UUIDv4"
            ) from exc
        if parsed_uuid.version != 4 or str(parsed_uuid) != client_id.lower():
            raise ChannelError(
                "invalid-client-id", "client_id must be a canonical UUIDv4"
            )
        client_id = str(parsed_uuid)
    reply_to = fields["reply_to"]
    if not REPLY_RE.fullmatch(reply_to):
        raise ChannelError(
            "invalid-reply-to", "reply_to is not a valid channel identifier"
        )
    if kind in {"feedback", "ack"} and reply_to == "-":
        raise ChannelError(
            "missing-reply-to", "feedback and ack messages require reply_to"
        )
    created = parse_rfc3339(fields["created_at"])
    created_epoch = created.timestamp()
    if created_epoch > now + limits["future_skew_seconds"]:
        raise ChannelError("future-message", "created_at is too far in the future")
    if now - created_epoch > limits["max_age_seconds"]:
        raise ChannelError(
            "expired-message",
            "the finalized message is older than the acceptance window",
        )
    body = unicodedata.normalize("NFC", "\n".join(lines[delimiter + 1 :]).strip())
    validate_text_controls(body, "message body")
    if len(body.encode("utf-8")) > limits["body_bytes"]:
        raise ChannelError("body-too-large", "message body exceeds the byte cap")
    if PROHIBITED_DATA_RE.search(body):
        raise ChannelError(
            "prohibited-sensitive-content",
            "message resembles prohibited credential material",
        )
    parser = StrictNotesHTML(limits)
    try:
        parser.feed(html_body)
        parser.close()
    except ChannelError:
        raise
    if visible_compare(parser.visible_text()) != visible_compare(text):
        raise ChannelError(
            "html-plaintext-mismatch", "Notes HTML visible text and plaintext differ"
        )
    urls = tuple(HTTPS_RE.findall(body))
    if len(urls) > limits["url_count"]:
        raise ChannelError("too-many-urls", "message exceeds the inert URL cap")
    for candidate in urls:
        validate_https_url(candidate, limits)
    for scheme_match in ANY_SCHEME_RE.finditer(body):
        if scheme_match.group(1).lower() != "https":
            raise ChannelError(
                "unsafe-url-scheme", "message contains a non-HTTPS URL scheme"
            )
    content_record = {
        "schema": CHANNEL_SCHEMA,
        "title": title,
        "kind": kind,
        "intent": intent,
        "client_id": client_id,
        "reply_to": reply_to,
        "created_at": created.isoformat(),
        "body": body,
        "links": list(urls),
    }
    return ParsedEnvelope(
        title=title,
        kind=kind,
        intent=intent,
        client_id=client_id,
        reply_to=reply_to,
        created_at=created.isoformat(),
        body=body,
        links=urls,
        content_digest=sha256_bytes(canonical_json(content_record)),
        confirmation_required=bool(HIGH_IMPACT_RE.search(body)),
    )


class Provider:
    def probe_binding(self, binding: Mapping[str, Any]) -> Mapping[str, Any]:
        raise NotImplementedError

    def list_inbox_metadata(
        self, binding: Mapping[str, Any], limit: int
    ) -> list[dict[str, Any]]:
        raise NotImplementedError

    def read_inbox_note(
        self, binding: Mapping[str, Any], note_id: str, max_bytes: int
    ) -> dict[str, Any]:
        raise NotImplementedError

    def find_owned_note(
        self, binding: Mapping[str, Any], destination: str, logical_id: str
    ) -> list[dict[str, Any]]:
        raise NotImplementedError

    def create_owned_note(
        self, binding: Mapping[str, Any], intent: Mapping[str, Any]
    ) -> dict[str, Any]:
        raise NotImplementedError


class FakeProvider(Provider):
    def __init__(self, channel: "Channel", fixture_path: Path):
        self.channel = channel
        self.fixture_path = fixture_path
        self.listed_ids: set[str] = set()
        self.fixture = self._load()

    def _load(self) -> dict[str, Any]:
        try:
            fixture = json.loads(self.fixture_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ProviderError(
                "fake-provider-unavailable", "fake provider fixture is unreadable"
            ) from exc
        if fixture.get("schema") != FAKE_SCHEMA:
            raise ProviderError(
                "fake-provider-schema", "fake provider fixture schema is invalid"
            )
        return fixture

    def _save(self) -> None:
        payload = canonical_json(self.fixture) + b"\n"
        self.fixture_path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".fake-notes.", dir=self.fixture_path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, self.fixture_path)
        finally:
            Path(name).unlink(missing_ok=True)

    def _record(self, operation: str, **fields: Any) -> None:
        safe = {"operation": operation, "at": utc_iso(self.channel.now), **fields}
        append_json_line(
            self.channel.home, self.channel.state_root / "provider-calls.jsonl", safe
        )
        fault = self.fixture.get("faults", {}).get(operation)
        if fault:
            if fault in {
                "tcc-denied",
                "tcc-not-determined",
                "binding-drift",
                "identity-drift",
            }:
                raise ProviderError(
                    fault, f"fake provider injected {fault}", disable=True
                )
            raise ProviderError(str(fault), f"fake provider injected {fault}")

    def probe_binding(self, binding: Mapping[str, Any]) -> Mapping[str, Any]:
        self._record("probe-binding", binding_hash=binding_hash(binding))
        actual = self.fixture.get("binding")
        validate_binding(actual)
        if binding_hash(actual) != binding_hash(binding):
            raise ProviderError(
                "binding-drift",
                "fake provider binding differs from the pinned binding",
                disable=True,
            )
        return {"binding_hash": binding_hash(actual), "valid": True}

    def list_inbox_metadata(
        self, binding: Mapping[str, Any], limit: int
    ) -> list[dict[str, Any]]:
        self._record(
            "list-inbox-metadata",
            account_id=binding["account"]["id"],
            folder_id=binding["inbox"]["id"],
            limit=limit,
        )
        notes = list(self.fixture.setdefault("notes", {}).setdefault("inbox", []))
        if len(notes) > limit:
            return [{"over_cap": True, "count": len(notes)}]
        metadata: list[dict[str, Any]] = []
        self.listed_ids.clear()
        for note in notes:
            note_id = str(note["id"])
            self.listed_ids.add(note_id)
            plaintext = str(note.get("plaintext", ""))
            metadata.append(
                {
                    "id": note_id,
                    "title": str(note.get("title", "")),
                    "creation_date": str(
                        note.get("creation_date", "1970-01-01T00:00:00Z")
                    ),
                    "modification_date": str(
                        note.get("modification_date", "1970-01-01T00:00:00Z")
                    ),
                    "shared": bool(note.get("shared", False)),
                    "password_protected": bool(note.get("password_protected", False)),
                    "attachment_count": int(note.get("attachment_count", 0)),
                    "plaintext_bytes": len(plaintext.encode("utf-8")),
                    "folder_id": binding["inbox"]["id"],
                    "account_id": binding["account"]["id"],
                }
            )
        return metadata

    def read_inbox_note(
        self, binding: Mapping[str, Any], note_id: str, max_bytes: int
    ) -> dict[str, Any]:
        self._record(
            "read-inbox-note",
            account_id=binding["account"]["id"],
            folder_id=binding["inbox"]["id"],
            note_id_hash=sha256_bytes(note_id.encode("utf-8")),
            max_bytes=max_bytes,
        )
        if note_id not in self.listed_ids:
            raise ProviderError(
                "unlisted-note",
                "fake provider refused a note not in the current Inbox listing",
                disable=True,
            )
        matches = [n for n in self.fixture["notes"]["inbox"] if str(n["id"]) == note_id]
        if len(matches) != 1:
            raise ProviderError(
                "note-identity-conflict",
                "fake provider note ID is missing or ambiguous",
                disable=True,
            )
        note = dict(matches[0])
        plaintext = str(note.get("plaintext", ""))
        if len(plaintext.encode("utf-8")) > max_bytes:
            raise ProviderError(
                "note-too-large", "fake provider refused an oversized body"
            )
        return {
            "id": note_id,
            "title": str(note.get("title", "")),
            "plaintext": plaintext,
            "html": str(note.get("html", html.escape(plaintext).replace("\n", "<br>"))),
            "creation_date": str(note.get("creation_date", "1970-01-01T00:00:00Z")),
            "modification_date": str(
                note.get("modification_date", "1970-01-01T00:00:00Z")
            ),
            "shared": bool(note.get("shared", False)),
            "password_protected": bool(note.get("password_protected", False)),
            "attachment_count": int(note.get("attachment_count", 0)),
            "folder_id": binding["inbox"]["id"],
            "account_id": binding["account"]["id"],
        }

    def find_owned_note(
        self, binding: Mapping[str, Any], destination: str, logical_id: str
    ) -> list[dict[str, Any]]:
        folder = binding[destination]
        self._record(
            "find-owned-note",
            account_id=binding["account"]["id"],
            folder_id=folder["id"],
            destination=destination,
            logical_id=logical_id,
        )
        return [
            {
                "id": str(note["id"]),
                "logical_id": str(note["logical_id"]),
                "content_sha256": str(note["content_sha256"]),
                "folder_id": folder["id"],
            }
            for note in self.fixture.setdefault("notes", {}).setdefault(destination, [])
            if note.get("logical_id") == logical_id
        ]

    def create_owned_note(
        self, binding: Mapping[str, Any], intent: Mapping[str, Any]
    ) -> dict[str, Any]:
        destination = str(intent["destination"])
        folder = binding[destination]
        self._record(
            "create-owned-note",
            account_id=binding["account"]["id"],
            folder_id=folder["id"],
            destination=destination,
            logical_id=intent["logical_id"],
            content_sha256=intent["content_sha256"],
        )
        bucket = self.fixture.setdefault("notes", {}).setdefault(destination, [])
        note_id = "fake-note-" + b32_digest(
            str(intent["logical_id"]).encode("utf-8"), 16
        )
        bucket.append(
            {
                "id": note_id,
                "logical_id": intent["logical_id"],
                "content_sha256": intent["content_sha256"],
                "title": outbound_title(intent),
                "plaintext": render_outbound_plaintext(intent),
                "html": render_outbound_html(intent),
            }
        )
        faults = self.fixture.setdefault("faults", {})
        ambiguous = bool(faults.pop("create-after-commit-once", False))
        self._save()
        if ambiguous:
            raise ProviderError(
                "ambiguous-create",
                "fake provider lost the create response after committing",
            )
        return {
            "id": note_id,
            "logical_id": intent["logical_id"],
            "content_sha256": intent["content_sha256"],
        }


class ProductionProvider(Provider):
    def __init__(self, channel: "Channel", config: Mapping[str, Any]):
        self.channel = channel
        helper = config.get("helper", {})
        self.app = Path(str(helper.get("app_path", "")))
        self.executable = self.app / "Contents" / "MacOS" / "FirstmateNotesBridge"
        self.expected_sha = str(helper.get("executable_sha256", ""))
        self.expected_requirement = str(helper.get("designated_requirement", ""))
        self._verify_identity()

    def _verify_identity(self) -> None:
        default_app = Path.home() / "Applications" / "Firstmate Notes Bridge.app"
        if self.app != default_app:
            raise ProviderError(
                "identity-drift",
                "production bridge is not at the fixed install path",
                disable=True,
            )
        if self.app.is_symlink() or not self.app.is_dir():
            raise ProviderError(
                "identity-drift",
                "production bridge app is missing or linked",
                disable=True,
            )
        if not self.executable.is_file() or self.executable.is_symlink():
            raise ProviderError(
                "identity-drift",
                "production bridge executable is missing or linked",
                disable=True,
            )
        if (
            self.app.lstat().st_uid != os.getuid()
            or self.executable.lstat().st_uid != os.getuid()
        ):
            raise ProviderError(
                "identity-drift",
                "production bridge owner changed",
                disable=True,
            )
        if (
            not re.fullmatch(r"[0-9a-f]{64}", self.expected_sha)
            or sha256_file(self.executable) != self.expected_sha
        ):
            raise ProviderError(
                "identity-drift",
                "production bridge executable hash changed",
                disable=True,
            )
        info_path = self.app / "Contents" / "Info.plist"
        if info_path.is_symlink() or not info_path.is_file():
            raise ProviderError(
                "identity-drift",
                "production bridge Info.plist is missing or linked",
                disable=True,
            )
        try:
            info = plistlib.loads(info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as exc:
            raise ProviderError(
                "identity-drift",
                "production bridge Info.plist is unreadable",
                disable=True,
            ) from exc
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ProviderError(
                "identity-drift", "production bridge bundle ID changed", disable=True
            )
        verify = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
        if verify.returncode != 0:
            raise ProviderError(
                "identity-drift",
                "production bridge signature verification failed",
                disable=True,
            )
        requirement = subprocess.run(
            ["/usr/bin/codesign", "-d", "-r-", str(self.app)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=5,
            text=True,
        )
        actual_lines = [
            line.strip()
            for line in requirement.stdout.splitlines()
            if line.strip().startswith("designated =>")
        ]
        if (
            requirement.returncode != 0
            or len(actual_lines) != 1
            or self.expected_requirement != actual_lines[0]
        ):
            raise ProviderError(
                "identity-drift",
                "production bridge designated requirement changed",
                disable=True,
            )

    def _call(self, operation: str, **fields: Any) -> Any:
        request = {"schema": BRIDGE_SCHEMA, "operation": operation, **fields}
        try:
            result = subprocess.run(
                [str(self.executable), operation],
                input=canonical_json(request),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=8,
            )
        except subprocess.TimeoutExpired as exc:
            raise ProviderError(
                "notes-timeout", "the Notes bridge exceeded its fixed deadline"
            ) from exc
        if len(result.stdout) > 1024 * 1024 or len(result.stderr) > 64 * 1024:
            raise ProviderError(
                "bridge-output-cap",
                "the Notes bridge exceeded its output cap",
                disable=True,
            )
        try:
            response = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ProviderError(
                "bridge-protocol",
                "the Notes bridge returned invalid JSON",
                disable=True,
            ) from exc
        if not isinstance(response, dict) or response.get("schema") != BRIDGE_SCHEMA:
            raise ProviderError(
                "bridge-protocol",
                "the Notes bridge response schema is invalid",
                disable=True,
            )
        if not response.get("ok"):
            error = response.get("error", {})
            code = str(error.get("code", "bridge-error"))
            disabling = code in {
                "tcc-denied",
                "tcc-not-determined",
                "binding-drift",
                "identity-drift",
                "helper-disabled",
            }
            raise ProviderError(
                code,
                "the dedicated Notes bridge refused the operation",
                disable=disabling,
            )
        if result.returncode != 0:
            raise ProviderError(
                "bridge-protocol",
                "the Notes bridge exit status disagrees with its response",
                disable=True,
            )
        return response.get("result")

    def pair_fixed_tree(self, request_automation: bool) -> Mapping[str, Any]:
        return dict(
            self._call("pair-fixed-tree", request_automation=request_automation)
        )

    def probe_binding(self, binding: Mapping[str, Any]) -> Mapping[str, Any]:
        return self._call("probe-binding", binding_hash=binding_hash(binding))

    def list_inbox_metadata(
        self, binding: Mapping[str, Any], limit: int
    ) -> list[dict[str, Any]]:
        return list(self._call("list-inbox-metadata", limit=limit))

    def read_inbox_note(
        self, binding: Mapping[str, Any], note_id: str, max_bytes: int
    ) -> dict[str, Any]:
        return dict(self._call("read-inbox-note", note_id=note_id, max_bytes=max_bytes))

    def find_owned_note(
        self, binding: Mapping[str, Any], destination: str, logical_id: str
    ) -> list[dict[str, Any]]:
        return list(
            self._call(
                "find-owned-note", destination=destination, logical_id=logical_id
            )
        )

    def create_owned_note(
        self, binding: Mapping[str, Any], intent: Mapping[str, Any]
    ) -> dict[str, Any]:
        return dict(self._call("create-owned-note", intent=intent))


def validate_binding(binding: Any) -> None:
    if not isinstance(binding, dict) or set(binding) != set(BINDING_KEYS):
        raise ChannelError(
            "invalid-binding",
            "binding must contain the exact fixed folder tree",
            disable=True,
        )
    account = binding.get("account")
    if not isinstance(account, dict) or set(account) != {"id", "name"}:
        raise ChannelError(
            "invalid-binding", "bound account metadata is invalid", disable=True
        )
    if (
        not isinstance(account["id"], str)
        or not account["id"]
        or account["name"] != "iCloud"
    ):
        raise ChannelError(
            "invalid-binding",
            "bound account must be the exact iCloud account",
            disable=True,
        )
    for key, expected_name in EXPECTED_NAMES.items():
        folder = binding[key]
        if not isinstance(folder, dict) or set(folder) != {
            "id",
            "name",
            "parent_id",
            "shared",
        }:
            raise ChannelError(
                "invalid-binding", f"bound {key} metadata is invalid", disable=True
            )
        if not isinstance(folder["id"], str) or not folder["id"]:
            raise ChannelError(
                "invalid-binding", f"bound {key} ID is missing", disable=True
            )
        if folder["name"] != expected_name or folder["shared"] is not False:
            raise ChannelError(
                "invalid-binding",
                f"bound {key} name/share invariant failed",
                disable=True,
            )
    expected_parents = {
        "root": account["id"],
        "guide": binding["root"]["id"],
        "inbox": binding["root"]["id"],
        "acknowledgments": binding["root"]["id"],
        "outbox": binding["root"]["id"],
        "archive": binding["root"]["id"],
        "archive_inbound": binding["archive"]["id"],
        "archive_acknowledgments": binding["archive"]["id"],
        "archive_outbound": binding["archive"]["id"],
    }
    for key, parent_id in expected_parents.items():
        if binding[key]["parent_id"] != parent_id:
            raise ChannelError(
                "invalid-binding", f"bound {key} parent invariant failed", disable=True
            )
    ids = [binding[key]["id"] for key in BINDING_KEYS]
    if len(set(ids)) != len(ids):
        raise ChannelError(
            "invalid-binding", "bound account/folder IDs must be unique", disable=True
        )


def binding_hash(binding: Mapping[str, Any]) -> str:
    validate_binding(binding)
    return sha256_bytes(canonical_json(binding))


def metadata_revision(metadata: Mapping[str, Any]) -> str:
    fields = {
        "id": metadata.get("id"),
        "title": metadata.get("title"),
        "creation_date": metadata.get("creation_date"),
        "modification_date": metadata.get("modification_date"),
        "shared": metadata.get("shared"),
        "password_protected": metadata.get("password_protected"),
        "attachment_count": metadata.get("attachment_count"),
        "plaintext_bytes": metadata.get("plaintext_bytes"),
        "folder_id": metadata.get("folder_id"),
        "account_id": metadata.get("account_id"),
    }
    return sha256_bytes(canonical_json(fields))


def message_id(binding: Mapping[str, Any], note_id: str) -> str:
    material = "\0".join(
        [
            CHANNEL_SCHEMA,
            str(binding["account"]["id"]),
            str(binding["inbox"]["id"]),
            note_id,
        ]
    ).encode("utf-8")
    return "ni1_" + b32_digest(material)


def deterministic_outbound_id(prefix: str, *parts: str) -> str:
    slug = "_".join(re.sub(r"[^a-z0-9._-]", "-", part.lower()) for part in parts)
    if len(slug) > 72:
        slug = slug[:48] + "_" + b32_digest(slug.encode("utf-8"), 20)
    return f"{prefix}_{slug}"


def outbound_title(intent: Mapping[str, Any]) -> str:
    suffix = str(intent["logical_id"])[-4:].upper()
    return f"{intent['kind']} · {suffix} · {intent['summary']}"


def render_outbound_plaintext(intent: Mapping[str, Any]) -> str:
    lines = [
        outbound_title(intent),
        "",
        "Outcome",
        str(intent["outcome"]),
        "",
        "Evidence",
    ]
    evidence = list(intent.get("evidence", []))
    lines.extend([f"- {item}" for item in evidence] or ["- No additional evidence."])
    lines.extend(
        ["", "Your decision / next action", str(intent["action"]), "", "Links"]
    )
    links = list(intent.get("links", []))
    lines.extend(links or ["None."])
    lines.extend(
        [
            "",
            "Receipt",
            f"in_reply_to: {intent['in_reply_to']}",
            f"message_id: {intent['logical_id']}",
            f"published_on_mac: {intent['created_at']}",
            f"content_sha256: {intent['content_sha256']}",
            "channel_state: published-awaiting-sync",
        ]
    )
    return "\n".join(lines)


def render_outbound_html(intent: Mapping[str, Any]) -> str:
    def esc(value: Any) -> str:
        return html.escape(str(value), quote=True)

    evidence = (
        "".join(f"<li>{esc(item)}</li>" for item in intent.get("evidence", []))
        or "<li>No additional evidence.</li>"
    )
    links = (
        "".join(
            f'<div><a href="{esc(link)}">{esc(link)}</a></div>'
            for link in intent.get("links", [])
        )
        or "<div>None.</div>"
    )
    return (
        f"<div><strong>{esc(outbound_title(intent))}</strong></div>"
        f"<div><strong>Outcome</strong></div><div>{esc(intent['outcome'])}</div>"
        f"<div><strong>Evidence</strong></div><ul>{evidence}</ul>"
        f"<div><strong>Your decision / next action</strong></div><div>{esc(intent['action'])}</div>"
        f"<div><strong>Links</strong></div>{links}"
        f"<div><strong>Receipt</strong></div>"
        f"<div>in_reply_to: {esc(intent['in_reply_to'])}</div>"
        f"<div>message_id: {esc(intent['logical_id'])}</div>"
        f"<div>published_on_mac: {esc(intent['created_at'])}</div>"
        f"<div>content_sha256: {esc(intent['content_sha256'])}</div>"
        "<div>channel_state: published-awaiting-sync</div>"
    )


def validate_outbound_intent(intent: Any, limits: Mapping[str, int]) -> dict[str, Any]:
    required = {
        "schema",
        "logical_id",
        "destination",
        "kind",
        "summary",
        "outcome",
        "evidence",
        "action",
        "links",
        "in_reply_to",
        "created_at",
        "content_sha256",
    }
    if (
        not isinstance(intent, dict)
        or set(intent) != required
        or intent.get("schema") != OUTBOUND_SCHEMA
    ):
        raise ChannelError(
            "invalid-outbound-intent", "outbound intent schema or keys are invalid"
        )
    if not OUTBOUND_RE.fullmatch(str(intent["logical_id"])):
        raise ChannelError("invalid-outbound-id", "outbound logical ID is invalid")
    if (
        intent["destination"] not in DESTINATIONS
        or intent["kind"] not in OUTBOUND_KINDS
    ):
        raise ChannelError(
            "invalid-outbound-target", "outbound destination or kind is invalid"
        )
    if not isinstance(intent["evidence"], list) or len(intent["evidence"]) > 5:
        raise ChannelError(
            "invalid-outbound-evidence",
            "outbound evidence must contain at most five items",
        )
    if (
        not isinstance(intent["links"], list)
        or len(intent["links"]) > limits["url_count"]
    ):
        raise ChannelError("invalid-outbound-links", "outbound links exceed the cap")
    for key, cap in (("summary", 120), ("outcome", 2048), ("action", 1024)):
        value = intent[key]
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > cap:
            raise ChannelError("invalid-outbound-text", f"outbound {key} is invalid")
        validate_text_controls(value, f"outbound {key}")
        if PROHIBITED_DATA_RE.search(value) or OUTBOUND_PRIVATE_PATH_RE.search(value):
            raise ChannelError(
                "prohibited-outbound-content",
                f"outbound {key} resembles credential material or a private path",
            )
    for item in intent["evidence"]:
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > 1024:
            raise ChannelError(
                "invalid-outbound-evidence", "outbound evidence item is invalid"
            )
        validate_text_controls(item, "outbound evidence")
        if PROHIBITED_DATA_RE.search(item) or OUTBOUND_PRIVATE_PATH_RE.search(item):
            raise ChannelError(
                "prohibited-outbound-content",
                "outbound evidence resembles credential material or a private path",
            )
    for link in intent["links"]:
        validate_https_url(str(link), limits)
    if not REPLY_RE.fullmatch(str(intent["in_reply_to"])):
        raise ChannelError("invalid-outbound-reply", "outbound in_reply_to is invalid")
    parse_rfc3339(str(intent["created_at"]))
    digest_fields = dict(intent)
    supplied_digest = str(digest_fields.pop("content_sha256"))
    expected_digest = sha256_bytes(canonical_json(digest_fields))
    if supplied_digest != expected_digest:
        raise ChannelError(
            "outbound-digest-mismatch", "outbound content digest is invalid"
        )
    if len(render_outbound_plaintext(intent).encode("utf-8")) > 12 * 1024:
        raise ChannelError(
            "outbound-too-large", "rendered outbound note exceeds 12 KiB"
        )
    return intent


class Channel:
    def __init__(self, home: Path, now: float | None = None):
        self.home = Path(os.path.abspath(home))
        self.config_dir = self.home / "config"
        self.config_path = self.config_dir / "apple-notes-channel.json"
        self.data_root = self.home / "data" / "apple-notes-channel"
        self.state_root = self.home / "state" / "apple-notes-channel"
        self.captures = self.data_root / "captures"
        self.sources = self.data_root / "sources"
        self.aliases = self.data_root / "aliases"
        self.outbound = self.data_root / "outbound"
        self.receipts = self.data_root / "receipts"
        self.audit_dir = self.data_root / "audit"
        self.audit_log = self.audit_dir / "events.jsonl"
        self.audit_head = self.audit_dir / "head.json"
        self.audit_lock_path = self.state_root / "audit.lock"
        self.stability = self.state_root / "stability"
        self.rejections = self.state_root / "rejections"
        self.conflicts = self.state_root / "conflicts"
        self.claims = self.state_root / "claims"
        self.offers = self.state_root / "offers"
        self.pending_writes = self.state_root / "pending-writes"
        self.health_path = self.state_root / "health.json"
        self.checkpoint = self.state_root / "checkpoint.json"
        self.disabled_path = self.state_root / "DISABLED"
        self.lock_path = self.state_root / "scan.lock"
        self.now = now if now is not None else time.time()
        self.config: dict[str, Any] = {}
        self.limits: dict[str, int] = dict(DEFAULT_LIMITS)

    def prepare_roots(self) -> None:
        for path in (
            self.config_dir,
            self.data_root,
            self.state_root,
            self.captures,
            self.sources,
            self.aliases,
            self.outbound,
            self.receipts,
            self.audit_dir,
            self.stability,
            self.rejections,
            self.conflicts,
            self.claims,
            self.offers,
            self.pending_writes,
        ):
            ensure_private_dir(self.home, path)

    def load_config(self) -> dict[str, Any]:
        config = read_json(self.home, self.config_path)
        if not isinstance(config, dict) or config.get("schema") != CONFIG_SCHEMA:
            raise ChannelError(
                "invalid-config",
                "Apple Notes channel config schema is invalid",
                disable=True,
            )
        allowed = {
            "schema",
            "enabled",
            "provider",
            "mode",
            "binding",
            "helper",
            "limits",
            "fake_fixture",
        }
        if set(config) - allowed:
            raise ChannelError(
                "invalid-config",
                "Apple Notes channel config has unknown keys",
                disable=True,
            )
        if config.get("provider") not in {"fake", "production"}:
            raise ChannelError(
                "invalid-config",
                "Apple Notes channel provider is invalid",
                disable=True,
            )
        if config.get("mode") not in {
            "disabled",
            "synthetic",
            "outbound-test",
            "read-only",
            "bounded-bidirectional",
        }:
            raise ChannelError(
                "invalid-config", "Apple Notes channel mode is invalid", disable=True
            )
        if not isinstance(config.get("enabled"), bool):
            raise ChannelError(
                "invalid-config",
                "Apple Notes channel enabled flag is invalid",
                disable=True,
            )
        limits = dict(DEFAULT_LIMITS)
        configured_limits = config.get("limits", {})
        if not isinstance(configured_limits, dict) or set(configured_limits) - set(
            DEFAULT_LIMITS
        ):
            raise ChannelError(
                "invalid-config", "Apple Notes channel limits are invalid", disable=True
            )
        for key, value in configured_limits.items():
            if not isinstance(value, int) or value <= 0 or value > DEFAULT_LIMITS[key]:
                raise ChannelError(
                    "invalid-config",
                    f"Apple Notes channel limit {key} may only tighten the default",
                    disable=True,
                )
            limits[key] = value
        if config.get("binding") is not None:
            validate_binding(config["binding"])
        helper = config.get("helper")
        if config.get("provider") == "production":
            if not isinstance(helper, dict) or set(helper) != {
                "app_path",
                "bundle_id",
                "executable_sha256",
                "designated_requirement",
            }:
                raise ChannelError(
                    "invalid-config",
                    "production helper identity record is invalid",
                    disable=True,
                )
            if helper.get("bundle_id") != BUNDLE_ID:
                raise ChannelError(
                    "invalid-config",
                    "production helper bundle ID is invalid",
                    disable=True,
                )
        elif helper is not None:
            raise ChannelError(
                "invalid-config", "fake provider cannot carry a helper identity"
            )
        self.config = config
        self.limits = limits
        return config

    def save_config(self, config: Mapping[str, Any]) -> None:
        self.prepare_roots()
        write_json(self.home, self.config_path, dict(config))
        self.config = dict(config)
        self.limits = dict(DEFAULT_LIMITS)
        self.limits.update(config.get("limits", {}))

    @contextlib.contextmanager
    def scan_lock(self, *, blocking: bool = False) -> Iterator[None]:
        self.prepare_roots()
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(self.lock_path, flags, 0o600)
        try:
            os.fchmod(fd, 0o600)
            info = os.fstat(fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != os.getuid()
            ):
                raise ChannelError(
                    "unsafe-lock", "channel scan lock is unsafe", disable=True
                )
            lock_mode = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
            try:
                fcntl.flock(fd, lock_mode)
            except BlockingIOError as exc:
                raise ChannelError(
                    "scan-busy", "another bounded channel operation owns the scan lock"
                ) from exc
            os.ftruncate(fd, 0)
            os.write(
                fd,
                canonical_json({"pid": os.getpid(), "started_at": utc_iso(self.now)})
                + b"\n",
            )
            os.fsync(fd)
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def disabled(self) -> bool:
        if self.disabled_path.exists() or self.disabled_path.is_symlink():
            validate_private_file(self.home, self.disabled_path)
            return True
        return False

    def require_enabled(self, *, outbound: bool = False) -> None:
        if self.disabled():
            raise ChannelError(
                "disabled", "Apple Notes channel emergency disable is active"
            )
        self.load_config()
        if not self.config["enabled"]:
            raise ChannelError("disabled", "Apple Notes channel is disabled")
        if outbound and self.config["mode"] not in {
            "synthetic",
            "outbound-test",
            "bounded-bidirectional",
        }:
            raise ChannelError(
                "mode-refusal",
                "current channel mode does not permit outbound Notes creation",
            )
        if not outbound and self.config["mode"] not in {
            "synthetic",
            "read-only",
            "bounded-bidirectional",
        }:
            raise ChannelError(
                "mode-refusal", "current channel mode does not permit Inbox reads"
            )
        if self.config.get("binding") is None:
            raise ChannelError(
                "missing-binding",
                "Apple Notes channel has no exact binding",
                disable=True,
            )

    def provider(self) -> Provider:
        if self.config["provider"] == "fake":
            fixture = self.config.get("fake_fixture")
            if not isinstance(fixture, str) or not fixture:
                raise ChannelError(
                    "invalid-config",
                    "fake provider fixture path is missing",
                    disable=True,
                )
            return FakeProvider(self, Path(fixture))
        return ProductionProvider(self, self.config)

    def record_health(
        self,
        state: str,
        *,
        error: str | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        self.prepare_roots()
        payload = {
            "schema": "firstmate.apple-notes.health/v1",
            "state": state,
            "at": utc_iso(self.now),
            "error": error,
            "details": dict(details or {}),
            "icloud_freshness": "not-provable",
        }
        write_json(self.home, self.health_path, payload)

    @contextlib.contextmanager
    def audit_lock(self) -> Iterator[None]:
        self.prepare_roots()
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(self.audit_lock_path, flags, 0o600)
        try:
            os.fchmod(fd, 0o600)
            info = os.fstat(fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != os.getuid()
                or info.st_dev != self.home.lstat().st_dev
            ):
                raise ChannelError(
                    "unsafe-audit-lock", "channel audit lock is unsafe", disable=True
                )
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def audit(self, event_type: str, details: Mapping[str, Any]) -> dict[str, Any]:
        with self.audit_lock():
            return self._audit_locked(event_type, details)

    def _audit_locked(
        self, event_type: str, details: Mapping[str, Any]
    ) -> dict[str, Any]:
        self.prepare_roots()
        previous = "0" * 64
        sequence = 1
        if self.audit_head.exists() or self.audit_head.is_symlink():
            head = read_json(self.home, self.audit_head)
            previous = str(head.get("hash", ""))
            sequence = int(head.get("sequence", 0)) + 1
            if not re.fullmatch(r"[0-9a-f]{64}", previous):
                raise ChannelError(
                    "audit-corrupt", "audit head is invalid", disable=True
                )
        event = {
            "schema": "firstmate.apple-notes.audit/v1",
            "sequence": sequence,
            "at": utc_iso(self.now),
            "type": event_type,
            "previous_hash": previous,
            "details": dict(details),
        }
        event_hash = sha256_bytes(canonical_json(event))
        event["hash"] = event_hash
        append_json_line(self.home, self.audit_log, event)
        write_json(
            self.home, self.audit_head, {"sequence": sequence, "hash": event_hash}
        )
        day = utc_iso(self.now)[:10]
        receipt_path = self.receipts / day / f"{sequence:012d}-{event_hash[:16]}.json"
        write_json(self.home, receipt_path, event, replace=False)
        return event

    def verify_audit(self) -> dict[str, Any]:
        if not self.audit_log.exists() and not self.audit_head.exists():
            return {"valid": True, "events": 0, "head": "0" * 64}
        validate_private_file(self.home, self.audit_log)
        previous = "0" * 64
        sequence = 0
        with self.audit_log.open("r", encoding="utf-8") as handle:
            for line in handle:
                sequence += 1
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ChannelError(
                        "audit-corrupt", "audit log contains invalid JSON", disable=True
                    ) from exc
                supplied = event.pop("hash", None)
                if (
                    event.get("sequence") != sequence
                    or event.get("previous_hash") != previous
                ):
                    raise ChannelError(
                        "audit-corrupt",
                        "audit sequence or previous hash is invalid",
                        disable=True,
                    )
                calculated = sha256_bytes(canonical_json(event))
                if supplied != calculated:
                    raise ChannelError(
                        "audit-corrupt", "audit event hash is invalid", disable=True
                    )
                previous = calculated
        head = read_json(self.home, self.audit_head)
        if head != {"sequence": sequence, "hash": previous}:
            raise ChannelError(
                "audit-corrupt",
                "audit head does not match the append-only chain",
                disable=True,
            )
        return {"valid": True, "events": sequence, "head": previous}

    def safe_disable(self, code: str) -> None:
        self.prepare_roots()
        if not self.disabled_path.exists():
            write_json(
                self.home,
                self.disabled_path,
                {
                    "schema": "firstmate.apple-notes.disabled/v1",
                    "at": utc_iso(self.now),
                    "reason": code,
                },
                replace=False,
            )
        if self.config_path.exists() and not self.config_path.is_symlink():
            with contextlib.suppress(ChannelError):
                config = self.load_config()
                config = dict(config)
                config["enabled"] = False
                config["mode"] = "disabled"
                self.save_config(config)
        with contextlib.suppress(ChannelError):
            self.record_health("disabled", error=code)

    def emergency_disable(self, code: str) -> None:
        # Publish the zero-call marker first, then fence any operation that had
        # already passed its entry check.  New entries stop at the marker; when
        # this returns, no earlier scan/publish still owns the operation lock.
        self.safe_disable(code)
        with self.scan_lock(blocking=True):
            pass

    def _metadata_precheck(
        self, metadata: Mapping[str, Any], binding: Mapping[str, Any]
    ) -> None:
        if (
            metadata.get("account_id") != binding["account"]["id"]
            or metadata.get("folder_id") != binding["inbox"]["id"]
        ):
            raise ChannelError(
                "provider-containment",
                "provider returned metadata outside the bound Inbox",
                disable=True,
            )
        if metadata.get("shared") is not False:
            raise ChannelError(
                "shared-note", "a channel note became shared", disable=True
            )
        if metadata.get("password_protected") is not False:
            raise ChannelError(
                "locked-note", "a locked note is rejected before body access"
            )
        if metadata.get("attachment_count") != 0:
            raise ChannelError(
                "attachment-rejected", "an attached note is rejected before body access"
            )
        if (
            not isinstance(metadata.get("plaintext_bytes"), int)
            or metadata["plaintext_bytes"] > self.limits["plaintext_bytes"]
        ):
            raise ChannelError(
                "plaintext-too-large", "note exceeds the body cap before body access"
            )

    def _source_record_path(self, note_id: str) -> Path:
        return self.sources / f"{safe_component(note_id)}.json"

    def _stability_path(self, note_id: str) -> Path:
        return self.stability / f"{safe_component(note_id)}.json"

    def _rejection_path(self, note_id: str) -> Path:
        return self.rejections / f"{safe_component(note_id)}.json"

    def _offer(self, mid: str) -> bool:
        path = self.offers / f"{mid}.json"
        payload = {
            "schema": "firstmate.apple-notes.offer/v1",
            "message_id": mid,
            "offered_at": self.now,
            "surfaced_at": None,
        }
        if path.exists() or path.is_symlink():
            existing = read_json(self.home, path)
            if existing.get("message_id") != mid:
                raise ChannelError(
                    "offer-corrupt", "offer identity is invalid", disable=True
                )
            surfaced_at = existing.get("surfaced_at")
            if surfaced_at is None:
                return True
            if self.now - float(surfaced_at) < self.limits["reoffer_seconds"]:
                return False
        write_json(self.home, path, payload)
        return True

    def mark_offers_surfaced(self, message_ids: Iterable[str]) -> None:
        for mid in message_ids:
            path = self.offers / f"{mid}.json"
            offer = read_json(self.home, path)
            if offer.get("message_id") != mid:
                raise ChannelError(
                    "offer-corrupt", "offer identity is invalid", disable=True
                )
            offer["surfaced_at"] = self.now
            write_json(self.home, path, offer)

    def test_failpoint(self, name: str) -> None:
        if (
            self.config.get("provider") == "fake"
            and os.environ.get("FM_NOTES_TEST_FAILPOINT") == name
        ):
            raise ChannelError("test-crash-seam", f"synthetic crash seam: {name}")

    def _record_rejection(self, note_id: str, revision: str, code: str) -> None:
        path = self._rejection_path(note_id)
        current = read_json(self.home, path, required=False)
        if (
            current
            and current.get("revision") == revision
            and current.get("code") == code
        ):
            return
        write_json(
            self.home,
            path,
            {
                "schema": "firstmate.apple-notes.rejection/v1",
                "revision": revision,
                "code": code,
                "at": utc_iso(self.now),
            },
        )
        self.audit(
            "metadata-rejected",
            {
                "source_id_hash": sha256_bytes(note_id.encode("utf-8")),
                "revision": revision,
                "code": code,
            },
        )

    def _capture_candidate(
        self,
        binding: Mapping[str, Any],
        note: Mapping[str, Any],
        parsed: ParsedEnvelope,
        transport_digest: str,
    ) -> tuple[str, bool]:
        note_id = str(note["id"])
        mid = message_id(binding, note_id)
        source_path = self._source_record_path(note_id)
        source = read_json(self.home, source_path, required=False)
        if source:
            if source.get("transport_digest") != transport_digest:
                conflict = {
                    "schema": "firstmate.apple-notes.conflict/v1",
                    "type": "modified-source",
                    "message_id": source.get("message_id"),
                    "original_transport_digest": source.get("transport_digest"),
                    "changed_transport_digest": transport_digest,
                    "at": utc_iso(self.now),
                }
                write_json(self.home, self.conflicts / f"{mid}.json", conflict)
                self.audit(
                    "source-conflict", {"message_id": mid, "type": "modified-source"}
                )
                return mid, False
            return str(source["message_id"]), False
        if parsed.client_id != "auto":
            alias_path = self.aliases / f"{parsed.client_id}.json"
            alias = read_json(self.home, alias_path, required=False)
            if alias:
                if alias.get("content_digest") != parsed.content_digest:
                    conflict_id = "client-" + safe_component(parsed.client_id)
                    write_json(
                        self.home,
                        self.conflicts / f"{conflict_id}.json",
                        {
                            "schema": "firstmate.apple-notes.conflict/v1",
                            "type": "client-id-collision",
                            "client_id": parsed.client_id,
                            "at": utc_iso(self.now),
                        },
                    )
                    self.audit(
                        "identity-collision",
                        {"client_id": parsed.client_id, "type": "different-content"},
                    )
                    return mid, False
                locators = sorted(
                    set(alias.get("source_note_hashes", []))
                    | {sha256_bytes(note_id.encode("utf-8"))}
                )
                alias["source_note_hashes"] = locators
                write_json(self.home, alias_path, alias)
                write_json(
                    self.home,
                    source_path,
                    {
                        "schema": "firstmate.apple-notes.source/v1",
                        "message_id": alias["message_id"],
                        "transport_digest": transport_digest,
                        "content_digest": parsed.content_digest,
                        "client_id": parsed.client_id,
                        "alias": True,
                    },
                    replace=False,
                )
                return str(alias["message_id"]), False
        capture = {
            "schema": CAPTURE_SCHEMA,
            "message_id": mid,
            "origin": "apple-notes",
            "source_note_id_hash": sha256_bytes(note_id.encode("utf-8")),
            "binding_hash": binding_hash(binding),
            "transport_digest": transport_digest,
            "content_digest": parsed.content_digest,
            "html_sha256": sha256_bytes(str(note["html"]).encode("utf-8")),
            "notes_creation_date": note.get("creation_date"),
            "notes_modification_date": note.get("modification_date"),
            "captured_at": utc_iso(self.now),
            "receive_seq": self._next_receive_seq(),
            "envelope": parsed.public_dict(),
            "authority": {
                "level": "notes-low-authority",
                "confirmation_required": parsed.confirmation_required,
                "permitted_intents": sorted(INTENTS),
                "external_mutation": False,
            },
            "work_key": f"notes-{mid}",
        }
        capture_path = self.captures / f"{mid}.json"
        try:
            write_json(self.home, capture_path, capture, replace=False)
        except FileExistsError:
            existing = read_json(self.home, capture_path)
            if existing.get("transport_digest") != transport_digest:
                raise ChannelError(
                    "capture-collision",
                    "capture ID collides with different content",
                    disable=True,
                )
            return mid, False
        write_json(
            self.home,
            source_path,
            {
                "schema": "firstmate.apple-notes.source/v1",
                "message_id": mid,
                "transport_digest": transport_digest,
                "content_digest": parsed.content_digest,
                "client_id": parsed.client_id,
                "alias": False,
            },
            replace=False,
        )
        if parsed.client_id != "auto":
            write_json(
                self.home,
                self.aliases / f"{parsed.client_id}.json",
                {
                    "schema": "firstmate.apple-notes.alias/v1",
                    "client_id": parsed.client_id,
                    "message_id": mid,
                    "content_digest": parsed.content_digest,
                    "source_note_hashes": [sha256_bytes(note_id.encode("utf-8"))],
                },
                replace=False,
            )
        self.audit(
            "captured",
            {
                "message_id": mid,
                "transport_digest": transport_digest,
                "intent": parsed.intent,
                "confirmation_required": parsed.confirmation_required,
            },
        )
        return mid, True

    def _next_receive_seq(self) -> int:
        checkpoint = read_json(self.home, self.checkpoint, required=False) or {}
        current = int(checkpoint.get("last_receive_seq", 0))
        for capture_path in self.captures.glob("ni1_*.json"):
            capture = read_json(self.home, capture_path)
            current = max(current, int(capture.get("receive_seq", 0)))
        return current + 1

    def scan(self, *, poll: bool = False) -> dict[str, Any]:
        self.require_enabled(outbound=False)
        binding = self.config["binding"]
        started = time.monotonic()
        captured: list[str] = []
        offered: list[str] = []
        rejected = 0
        with self.scan_lock():
            provider = self.provider()
            provider.probe_binding(binding)
            metadata = provider.list_inbox_metadata(
                binding, self.limits["inbox_objects"]
            )
            if metadata and metadata[0].get("over_cap"):
                self.record_health(
                    "over-cap",
                    error="inbox-over-cap",
                    details={"count": metadata[0].get("count")},
                )
                raise ChannelError(
                    "inbox-over-cap", "bound Inbox exceeds the complete-set cap"
                )
            if len(metadata) > self.limits["inbox_objects"]:
                raise ChannelError(
                    "inbox-over-cap",
                    "provider returned more Inbox objects than requested",
                    disable=True,
                )
            ids = [str(item.get("id", "")) for item in metadata]
            if not all(ids) or len(ids) != len(set(ids)):
                raise ChannelError(
                    "metadata-identity-conflict",
                    "Inbox metadata IDs are empty or duplicated",
                    disable=True,
                )
            revisions = {str(item["id"]): metadata_revision(item) for item in metadata}
            ordered = sorted(
                metadata,
                key=lambda item: (str(item.get("creation_date", "")), str(item["id"])),
            )
            budget = self.limits["capture_per_scan"]
            for meta in ordered:
                if len(captured) >= budget:
                    break
                if time.monotonic() - started > self.limits["scan_deadline_seconds"]:
                    raise ChannelError(
                        "scan-deadline",
                        "bounded Notes scan exceeded its internal deadline",
                    )
                note_id = str(meta["id"])
                revision = revisions[note_id]
                rejection = read_json(
                    self.home, self._rejection_path(note_id), required=False
                )
                if rejection and rejection.get("revision") == revision:
                    rejected += 1
                    continue
                try:
                    self._metadata_precheck(meta, binding)
                except ChannelError as exc:
                    self._record_rejection(note_id, revision, exc.code)
                    rejected += 1
                    if exc.disable:
                        raise
                    continue
                try:
                    note = provider.read_inbox_note(
                        binding, note_id, self.limits["plaintext_bytes"]
                    )
                    self._metadata_precheck(
                        {
                            **meta,
                            "shared": note.get("shared"),
                            "password_protected": note.get("password_protected"),
                            "attachment_count": note.get("attachment_count"),
                            "folder_id": note.get("folder_id"),
                            "account_id": note.get("account_id"),
                            "plaintext_bytes": len(
                                str(note.get("plaintext", "")).encode("utf-8")
                            ),
                        },
                        binding,
                    )
                    parsed = parse_envelope(
                        str(note["plaintext"]),
                        str(note["title"]),
                        str(note["html"]),
                        self.now,
                        self.limits,
                    )
                except ChannelError as exc:
                    self._record_rejection(note_id, revision, exc.code)
                    rejected += 1
                    if exc.disable:
                        raise
                    continue
                transport_record = {
                    "schema": CHANNEL_SCHEMA,
                    "account_id": note.get("account_id"),
                    "folder_id": note.get("folder_id"),
                    "source_note_id": note_id,
                    "creation_date": note.get("creation_date"),
                    "modification_date": note.get("modification_date"),
                    "title": note.get("title"),
                    "plaintext": normalize_newlines(str(note.get("plaintext", ""))),
                    "html_sha256": sha256_bytes(
                        str(note.get("html", "")).encode("utf-8")
                    ),
                    "shared": note.get("shared"),
                    "password_protected": note.get("password_protected"),
                    "attachment_count": note.get("attachment_count"),
                }
                transport_digest = sha256_bytes(canonical_json(transport_record))
                stable_path = self._stability_path(note_id)
                stable = read_json(self.home, stable_path, required=False)
                if not stable or stable.get("transport_digest") != transport_digest:
                    write_json(
                        self.home,
                        stable_path,
                        {
                            "schema": "firstmate.apple-notes.stability/v1",
                            "transport_digest": transport_digest,
                            "first_observed_at": self.now,
                        },
                    )
                    continue
                if (
                    self.now - float(stable.get("first_observed_at", self.now))
                    < self.limits["stability_seconds"]
                ):
                    continue
                self.test_failpoint("before-capture")
                mid, is_new = self._capture_candidate(
                    binding, note, parsed, transport_digest
                )
                if is_new:
                    captured.append(mid)
                    self.test_failpoint("after-capture-before-offer")
                if (
                    is_new or not (self.claims / f"{mid}.json").exists()
                ) and self._offer(mid):
                    offered.append(mid)
                    self.test_failpoint("after-offer-before-output")
            last_receive_seq = 0
            for path in self.captures.glob("ni1_*.json"):
                capture = read_json(self.home, path)
                last_receive_seq = max(
                    last_receive_seq, int(capture.get("receive_seq", 0))
                )
            write_json(
                self.home,
                self.checkpoint,
                {
                    "schema": "firstmate.apple-notes.checkpoint/v1",
                    "binding_hash": binding_hash(binding),
                    "scan_generation": int(
                        (
                            read_json(self.home, self.checkpoint, required=False) or {}
                        ).get("scan_generation", 0)
                    )
                    + 1,
                    "observed_id_revisions": revisions,
                    "last_successful_scan": utc_iso(self.now),
                    "last_receive_seq": last_receive_seq,
                },
            )
            self.audit(
                "scan",
                {
                    "binding_hash": binding_hash(binding),
                    "objects_seen": len(metadata),
                    "candidates_captured": len(captured),
                    "metadata_rejected": rejected,
                    "offers_published": len(offered),
                    "duration_ms": int((time.monotonic() - started) * 1000),
                    "icloud_freshness": "not-provable",
                },
            )
            self.record_health(
                "healthy",
                details={"objects_seen": len(metadata), "captured": len(captured)},
            )
        return {
            "captured": captured,
            "offered": offered,
            "rejected": rejected,
            "objects_seen": len(metadata),
        }

    def reconcile_local(self) -> dict[str, Any]:
        self.prepare_roots()
        reoffered: list[str] = []
        for capture_path in sorted(self.captures.glob("ni1_*.json")):
            capture = read_json(self.home, capture_path)
            mid = str(capture.get("message_id", ""))
            if not MESSAGE_RE.fullmatch(mid) or capture_path.name != f"{mid}.json":
                raise ChannelError(
                    "capture-corrupt",
                    "capture filename or message ID is invalid",
                    disable=True,
                )
            if not (self.claims / f"{mid}.json").exists() and self._offer(mid):
                reoffered.append(mid)
        return {"reoffered": reoffered}

    def claim(self, mid: str) -> dict[str, Any]:
        if not MESSAGE_RE.fullmatch(mid):
            raise ChannelError("invalid-message-id", "message ID is invalid")
        self.require_enabled(outbound=False)
        capture = read_json(self.home, self.captures / f"{mid}.json")
        claim_path = self.claims / f"{mid}.json"
        with self.audit_lock():
            existing = read_json(self.home, claim_path, required=False)
            if existing:
                return {**existing, "repeat": True}
            accepted = (
                self._rate_count("claimed", 300) < self.limits["accepted_five_minutes"]
                and self._rate_count("claimed", 86400) < self.limits["accepted_day"]
            )
            confirmation = bool(capture["authority"]["confirmation_required"])
            classification = (
                "rate-limited"
                if not accepted
                else ("decision-required" if confirmation else "accepted")
            )
            claim = {
                "schema": "firstmate.apple-notes.claim/v1",
                "message_id": mid,
                "claimed_at": utc_iso(self.now),
                "classification": classification,
                "work_key": capture["work_key"],
                "intent": capture["envelope"]["intent"],
                "authority": "notes-low-authority",
                "repeat": False,
            }
            try:
                write_json(self.home, claim_path, claim, replace=False)
            except FileExistsError:
                existing = read_json(self.home, claim_path)
                return {**existing, "repeat": True}
            self._audit_locked(
                "claimed",
                {
                    "message_id": mid,
                    "classification": classification,
                    "intent": capture["envelope"]["intent"],
                },
            )
        offer = self.offers / f"{mid}.json"
        if offer.exists() and not offer.is_symlink():
            validate_private_file(self.home, offer)
            offer.unlink()
        return claim

    def show(self, mid: str) -> dict[str, Any]:
        if not MESSAGE_RE.fullmatch(mid):
            raise ChannelError("invalid-message-id", "message ID is invalid")
        claim = read_json(self.home, self.claims / f"{mid}.json")
        capture = read_json(self.home, self.captures / f"{mid}.json")
        return {"claim": claim, "capture": capture}

    def _rate_count(self, event_type: str, seconds: int) -> int:
        if not self.audit_log.exists():
            return 0
        validate_private_file(self.home, self.audit_log)
        cutoff = self.now - seconds
        count = 0
        with self.audit_log.open("r", encoding="utf-8") as handle:
            for line in handle:
                with contextlib.suppress(json.JSONDecodeError, ValueError):
                    event = json.loads(line)
                    timestamp = parse_rfc3339(str(event["at"])).timestamp()
                    if event.get("type") == event_type and timestamp >= cutoff:
                        count += 1
        return count

    def _store_intent(self, intent: dict[str, Any]) -> dict[str, Any]:
        validate_outbound_intent(intent, self.limits)
        path = self.outbound / f"{intent['logical_id']}.json"
        existing = read_json(self.home, path, required=False)
        if existing:
            if existing != intent:
                raise ChannelError(
                    "outbound-id-collision",
                    "outbound ID collides with a different intent",
                )
            return existing
        write_json(self.home, path, intent, replace=False)
        write_json(
            self.home,
            self.pending_writes / f"{intent['logical_id']}.json",
            {
                "schema": "firstmate.apple-notes.pending-write/v1",
                "logical_id": intent["logical_id"],
                "staged_at": utc_iso(self.now),
            },
            replace=False,
        )
        self.audit(
            "outbound-staged",
            {
                "logical_id": intent["logical_id"],
                "destination": intent["destination"],
                "content_sha256": intent["content_sha256"],
            },
        )
        return intent

    def stage_acknowledgment(self, mid: str, classification: str) -> dict[str, Any]:
        if classification not in {
            "accepted",
            "decision-required",
            "rejected",
            "rate-limited",
        }:
            raise ChannelError(
                "invalid-classification", "acknowledgment classification is invalid"
            )
        shown = self.show(mid)
        if shown["claim"]["classification"] != classification:
            raise ChannelError(
                "classification-mismatch",
                "acknowledgment must match the durable claim classification",
            )
        logical_id = deterministic_outbound_id("na1", mid, classification)
        outcome = {
            "accepted": "The message was captured and accepted within the Apple Notes channel's low-authority scope.",
            "decision-required": "The request needs confirmation through the trusted private phone terminal before any high-impact action.",
            "rejected": "The message was captured but rejected by the channel policy.",
            "rate-limited": "The message was captured but not accepted because the Notes-origin rate limit is active.",
        }[classification]
        kind = "DECISION" if classification == "decision-required" else "ACK"
        fields: dict[str, Any] = {
            "schema": OUTBOUND_SCHEMA,
            "logical_id": logical_id,
            "destination": "acknowledgments",
            "kind": kind,
            "summary": classification.replace("-", " "),
            "outcome": outcome,
            "evidence": [
                "The inbound note remains immutable and was not edited or moved."
            ],
            "action": "Use the trusted private phone terminal for any requested high-impact confirmation."
            if classification == "decision-required"
            else "No action needed.",
            "links": [],
            "in_reply_to": mid,
            "created_at": utc_iso(self.now),
        }
        fields["content_sha256"] = sha256_bytes(canonical_json(fields))
        return self._store_intent(fields)

    def prepare_test_intent(self) -> dict[str, Any]:
        if not self.config:
            self.load_config()
        binding = self.config.get("binding")
        if binding is None:
            raise ChannelError(
                "missing-binding", "outbound test intent requires an exact binding"
            )
        logical_id = "no1_" + b32_digest(
            (
                binding_hash(binding)
                + "\0firstmate-apple-notes-single-outbound-test-v1"
            ).encode("utf-8"),
            26,
        )
        fields: dict[str, Any] = {
            "schema": OUTBOUND_SCHEMA,
            "logical_id": logical_id,
            "destination": "outbox",
            "kind": "INFO",
            "summary": "Apple Notes channel test",
            "outcome": "This is a Firstmate Apple Notes channel test. It contains no private data and requests no action.",
            "evidence": [
                "One harmless outbound test note was requested from the exact bound helper."
            ],
            "action": "No action needed.",
            "links": [],
            "in_reply_to": "-",
            "created_at": utc_iso(self.now),
        }
        fields["content_sha256"] = sha256_bytes(canonical_json(fields))
        return self._store_intent(fields)

    def publish(self, logical_id: str) -> dict[str, Any]:
        if not OUTBOUND_RE.fullmatch(logical_id):
            raise ChannelError("invalid-outbound-id", "outbound logical ID is invalid")
        self.require_enabled(outbound=True)
        intent = validate_outbound_intent(
            read_json(self.home, self.outbound / f"{logical_id}.json"), self.limits
        )
        if (
            self._rate_count("outbound-published", 3600) >= self.limits["outbound_hour"]
            or self._rate_count("outbound-published", 86400)
            >= self.limits["outbound_day"]
        ):
            raise ChannelError(
                "outbound-rate-limit", "outbound Notes creation rate limit is active"
            )
        with self.scan_lock():
            provider = self.provider()
            provider.probe_binding(self.config["binding"])
            found = provider.find_owned_note(
                self.config["binding"], intent["destination"], logical_id
            )
            exact = [
                item
                for item in found
                if item.get("content_sha256") == intent["content_sha256"]
            ]
            if len(found) > 1 or (found and len(exact) != 1):
                self.record_health(
                    "conflict",
                    error="outbound-conflict",
                    details={"logical_id": logical_id},
                )
                self.audit(
                    "outbound-conflict",
                    {"logical_id": logical_id, "objects": len(found)},
                )
                raise ChannelError(
                    "outbound-conflict",
                    "outbound logical ID is ambiguous; no note was created",
                )
            if exact:
                note_id = str(exact[0]["id"])
                created = False
            else:
                try:
                    provider.create_owned_note(self.config["binding"], intent)
                except ProviderError as exc:
                    if exc.code != "ambiguous-create":
                        raise
                    self.record_health(
                        "backoff",
                        error="ambiguous-create",
                        details={"logical_id": logical_id},
                    )
                    return {
                        "logical_id": logical_id,
                        "state": "pending-reconcile",
                        "created": "unknown",
                    }
                found = provider.find_owned_note(
                    self.config["binding"], intent["destination"], logical_id
                )
                exact = [
                    item
                    for item in found
                    if item.get("content_sha256") == intent["content_sha256"]
                ]
                if len(found) != 1 or len(exact) != 1:
                    self.record_health(
                        "conflict",
                        error="outbound-post-create-conflict",
                        details={"logical_id": logical_id},
                    )
                    raise ChannelError(
                        "outbound-conflict",
                        "outbound create did not reconcile to one exact note",
                    )
                note_id = str(exact[0]["id"])
                created = True
            receipt = {
                "schema": "firstmate.apple-notes.publication/v1",
                "logical_id": logical_id,
                "notes_id_hash": sha256_bytes(note_id.encode("utf-8")),
                "content_sha256": intent["content_sha256"],
                "published_at": utc_iso(self.now),
                "icloud_state": "published-awaiting-sync",
            }
            write_json(
                self.home, self.outbound / f"{logical_id}.published.json", receipt
            )
            pending = self.pending_writes / f"{logical_id}.json"
            if pending.exists() and not pending.is_symlink():
                validate_private_file(self.home, pending)
                pending.unlink()
            self.audit(
                "outbound-published",
                {
                    "logical_id": logical_id,
                    "content_sha256": intent["content_sha256"],
                    "created": created,
                },
            )
            self.record_health("healthy", details={"outbound": logical_id})
            return {
                "logical_id": logical_id,
                "state": "published-awaiting-sync",
                "created": created,
            }

    def status(self) -> dict[str, Any]:
        config = self.load_config()
        health = read_json(self.home, self.health_path, required=False)
        captures = (
            len(list(self.captures.glob("ni1_*.json"))) if self.captures.exists() else 0
        )
        pending = (
            len(list(self.pending_writes.glob("*.json")))
            if self.pending_writes.exists()
            else 0
        )
        return {
            "schema": "firstmate.apple-notes.status/v1",
            "enabled": config["enabled"],
            "disabled_marker": self.disabled(),
            "provider": config["provider"],
            "mode": config["mode"],
            "binding_hash": binding_hash(config["binding"])
            if config.get("binding")
            else None,
            "captures": captures,
            "pending_writes": pending,
            "health": health,
            "icloud_freshness": "not-provable",
        }

    def doctor(self) -> dict[str, Any]:
        config = self.load_config()
        result = {
            "schema": "firstmate.apple-notes.doctor/v1",
            "provider": config["provider"],
            "enabled": config["enabled"],
            "mode": config["mode"],
            "disabled_marker": self.disabled(),
            "binding": "present" if config.get("binding") else "absent",
            "provider_calls": 0,
            "audit": self.verify_audit(),
        }
        if config["provider"] == "production":
            ProductionProvider(self, config)
            result["helper_identity"] = "verified"
        else:
            result["helper_identity"] = "not-applicable-fake"
        return result

    def install_definitions(self, runtime_root: Path) -> dict[str, Any]:
        self.load_config()
        runtime = Path(os.path.abspath(runtime_root))
        poll = runtime / "bin" / "fm-notes-poll.sh"
        if not poll.is_file() or poll.is_symlink():
            raise ChannelError(
                "missing-runtime-poll", "runtime Notes poll entrypoint is unavailable"
            )
        state_dir = ensure_private_dir(self.home, self.home / "state")
        check = state_dir / "notes-watch.check.sh"
        trust = state_dir / "notes-watch.check-trust"

        def shell_quote(value: str) -> str:
            return "'" + value.replace("'", "'\\''") + "'"

        content = (
            "#!/usr/bin/env bash\n"
            "# Auto-generated by fm-notes-channel.sh - authenticated bounded Apple Notes check.\n"
            f"export FM_HOME={shell_quote(str(self.home))}\n"
            f"exec {shell_quote(str(poll))}\n"
        ).encode("utf-8")
        if check.exists() or check.is_symlink():
            validate_private_file(self.home, check, 0o700)
            if check.read_bytes() != content:
                raise ChannelError(
                    "foreign-check-definition",
                    "existing Notes check definition is not marker-owned",
                )
        atomic_write(self.home, check, content, 0o700)
        digest = sha256_bytes(content)
        atomic_write(
            self.home, trust, f"fm-custom-check-v1\n{digest}\n".encode("ascii"), 0o600
        )
        return {
            "installed": True,
            "check": "state/notes-watch.check.sh",
            "cadence_seconds": 300,
            "enabled": self.config["enabled"],
        }

    def uninstall_definitions(self, runtime_root: Path | None = None) -> dict[str, Any]:
        state_dir = self.home / "state"
        check = state_dir / "notes-watch.check.sh"
        trust = state_dir / "notes-watch.check-trust"
        removed: list[str] = []
        if check.exists() or check.is_symlink():
            validate_private_file(self.home, check, 0o700)
            content = check.read_bytes()
            if (
                b"Auto-generated by fm-notes-channel.sh - authenticated bounded Apple Notes check."
                not in content
            ):
                raise ChannelError(
                    "foreign-check-definition",
                    "Notes check definition is not marker-owned",
                )
            validate_private_file(self.home, trust, 0o600)
            expected = f"fm-custom-check-v1\n{sha256_bytes(content)}\n".encode("ascii")
            if trust.read_bytes() != expected:
                raise ChannelError(
                    "foreign-check-definition",
                    "Notes check trust binding is not marker-owned",
                )
            check.unlink()
            trust.unlink()
            removed.extend(
                ["state/notes-watch.check.sh", "state/notes-watch.check-trust"]
            )
        elif trust.exists() or trust.is_symlink():
            raise ChannelError(
                "foreign-check-definition",
                "orphaned Notes check trust record requires review",
            )
        return {
            "removed": removed,
            "notes_content_deleted": False,
            "evidence_deleted": False,
        }


def fake_config(fixture: Path, binding: Mapping[str, Any]) -> dict[str, Any]:
    validate_binding(binding)
    return {
        "schema": CONFIG_SCHEMA,
        "enabled": True,
        "provider": "fake",
        "mode": "synthetic",
        "binding": binding,
        "helper": None,
        "limits": {},
        "fake_fixture": str(Path(os.path.abspath(fixture))),
    }


def production_config(
    app_path: Path, executable_sha: str, requirement: str
) -> dict[str, Any]:
    default = Path.home() / "Applications" / "Firstmate Notes Bridge.app"
    if Path(os.path.abspath(app_path)) != default:
        raise ChannelError(
            "invalid-helper-path", f"production helper must be installed at {default}"
        )
    if not re.fullmatch(r"[0-9a-f]{64}", executable_sha):
        raise ChannelError(
            "invalid-helper-hash", "production helper executable SHA-256 is invalid"
        )
    if (
        not requirement.startswith("designated =>")
        or "\n" in requirement
        or "\r" in requirement
    ):
        raise ChannelError(
            "invalid-helper-requirement",
            "production helper designated requirement must be one exact designated line",
        )
    return {
        "schema": CONFIG_SCHEMA,
        "enabled": False,
        "provider": "production",
        "mode": "disabled",
        "binding": None,
        "helper": {
            "app_path": str(default),
            "bundle_id": BUNDLE_ID,
            "executable_sha256": executable_sha,
            "designated_requirement": requirement,
        },
        "limits": {},
        "fake_fixture": None,
    }


def read_stdin_json() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(65537)
    if len(raw) > 65536:
        raise ChannelError("input-too-large", "JSON input exceeds 64 KiB")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ChannelError("invalid-json", "stdin is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise ChannelError("invalid-json", "stdin JSON root must be an object")
    return value


def emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Guarded Apple Notes channel owner")
    result.add_argument(
        "--home", type=Path, default=Path(os.environ.get("FM_HOME", Path.cwd()))
    )
    sub = result.add_subparsers(dest="command", required=True)
    init_fake = sub.add_parser(
        "init-fake", help="initialize a synthetic-only fake provider home"
    )
    init_fake.add_argument("--fixture", type=Path, required=True)
    init_prod = sub.add_parser(
        "init-production",
        help="record a disabled pinned production helper; no Apple Event",
    )
    init_prod.add_argument("--app", type=Path, required=True)
    init_prod.add_argument("--executable-sha256", required=True)
    init_prod.add_argument("--designated-requirement", required=True)
    pair = sub.add_parser(
        "pair-production",
        help="captain-present fixed-tree metadata pairing through the dedicated helper",
    )
    pair.add_argument("--request-automation", action="store_true")
    bind = sub.add_parser(
        "record-pairing",
        help="record captain-reviewed fixed-tree bridge output from stdin; leaves disabled",
    )
    bind.add_argument("--binding-hash", required=True)
    enable = sub.add_parser(
        "enable",
        help="enable a paired channel in one explicit bounded mode; no Apple Event",
    )
    enable.add_argument(
        "--mode",
        choices=["outbound-test", "read-only", "bounded-bidirectional"],
        required=True,
    )
    sub.add_parser("doctor", help="static local validation with zero Apple Events")
    sub.add_parser("status", help="local status with zero Apple Events")
    sub.add_parser("scan", help="one bounded Inbox scan")
    sub.add_parser(
        "poll", help="bounded authenticated-check entry; silence or one body-free line"
    )
    sub.add_parser(
        "reconcile", help="local capture/offer reconciliation with zero Apple Events"
    )
    claim = sub.add_parser("claim", help="atomically claim one durable capture")
    claim.add_argument("message_id")
    show = sub.add_parser("show", help="show one claimed capture")
    show.add_argument("message_id")
    ack = sub.add_parser(
        "acknowledge", help="stage one deterministic acknowledgment intent"
    )
    ack.add_argument("message_id")
    ack.add_argument("--classification", required=True)
    sub.add_parser(
        "prepare-outbound-test",
        help="stage the one deterministic harmless outbound test intent",
    )
    publish = sub.add_parser(
        "publish", help="reconcile-before-create one staged outbound intent"
    )
    publish.add_argument("logical_id")
    sub.add_parser("verify-audit", help="verify the append-only hash chain")
    sub.add_parser("provider-log", help="print the fake provider's body-free call spy")
    install = sub.add_parser(
        "install-definitions",
        help="install but do not enable the authenticated bounded check",
    )
    install.add_argument("--runtime-root", type=Path, required=True)
    sub.add_parser(
        "uninstall-definitions",
        help="remove only exact marker-owned local check definitions",
    )
    disable = sub.add_parser(
        "disable",
        help="emergency-disable before any provider call and retire definitions",
    )
    disable.add_argument("--emergency", action="store_true", required=True)
    return result


def run(args: argparse.Namespace) -> int:
    test_now = os.environ.get("FM_NOTES_TEST_NOW")
    now = float(test_now) if test_now is not None else None
    channel = Channel(args.home, now)
    if args.command == "init-fake":
        fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
        if fixture.get("schema") != FAKE_SCHEMA:
            raise ChannelError("fake-provider-schema", "fake fixture schema is invalid")
        channel.save_config(fake_config(args.fixture, fixture.get("binding")))
        emit({"initialized": "synthetic", "enabled": True, "provider": "fake"})
        return 0
    if args.command == "init-production":
        channel.save_config(
            production_config(
                args.app, args.executable_sha256, args.designated_requirement
            )
        )
        emit({"initialized": "production", "enabled": False, "apple_events": 0})
        return 0
    if args.command == "pair-production":
        config = channel.load_config()
        if (
            config["provider"] != "production"
            or config["enabled"]
            or config.get("binding") is not None
        ):
            raise ChannelError(
                "pairing-refusal",
                "pairing requires a disabled unpaired production config",
            )
        provider = ProductionProvider(channel, config)
        result = provider.pair_fixed_tree(bool(args.request_automation))
        validate_binding(result.get("binding"))
        if result.get("binding_hash") != binding_hash(result["binding"]):
            raise ChannelError(
                "pairing-hash-mismatch",
                "dedicated helper pairing hash is invalid",
                disable=True,
            )
        emit(result)
        return 0
    if args.command == "record-pairing":
        config = channel.load_config()
        if config["provider"] != "production" or config["enabled"]:
            raise ChannelError(
                "pairing-refusal",
                "pairing record requires a disabled production config",
            )
        response = read_stdin_json()
        binding = response.get("binding")
        validate_binding(binding)
        if binding_hash(binding) != args.binding_hash:
            raise ChannelError(
                "pairing-hash-mismatch",
                "pairing response does not match the reviewed binding hash",
            )
        config = dict(config)
        config["binding"] = binding
        channel.save_config(config)
        channel.audit(
            "paired", {"binding_hash": binding_hash(binding), "enabled": False}
        )
        emit({"paired": True, "binding_hash": binding_hash(binding), "enabled": False})
        return 0
    if args.command == "enable":
        config = channel.load_config()
        if channel.disabled():
            raise ChannelError(
                "disabled",
                "remove the kill switch only through a separately reviewed re-enrollment",
            )
        if config.get("binding") is None:
            raise ChannelError(
                "missing-binding", "channel cannot be enabled before exact pairing"
            )
        config = dict(config)
        config["enabled"] = True
        config["mode"] = args.mode
        channel.save_config(config)
        channel.audit(
            "enabled",
            {"mode": args.mode, "binding_hash": binding_hash(config["binding"])},
        )
        emit({"enabled": True, "mode": args.mode, "apple_events": 0})
        return 0
    if args.command == "disable":
        channel.emergency_disable("emergency-disable")
        removal = channel.uninstall_definitions()
        emit({"disabled": True, **removal, "provider_calls": 0})
        return 0
    if args.command == "doctor":
        emit(channel.doctor())
        return 0
    if args.command == "status":
        emit(channel.status())
        return 0
    if args.command == "scan":
        emit(channel.scan())
        return 0
    if args.command == "poll":
        local = channel.reconcile_local()
        result = channel.scan(poll=True)
        count = len(set(local["reoffered"] + result["offered"]))
        if count:
            pending = sorted(set(local["reoffered"] + result["offered"]))
            oldest = pending[0]
            print(
                f"apple-notes-channel: {count} captured message(s) ready; oldest={oldest}",
                flush=True,
            )
            channel.mark_offers_surfaced(pending)
        return 0
    if args.command == "reconcile":
        emit(channel.reconcile_local())
        return 0
    if args.command == "claim":
        emit(channel.claim(args.message_id))
        return 0
    if args.command == "show":
        emit(channel.show(args.message_id))
        return 0
    if args.command == "acknowledge":
        emit(channel.stage_acknowledgment(args.message_id, args.classification))
        return 0
    if args.command == "prepare-outbound-test":
        channel.load_config()
        emit(channel.prepare_test_intent())
        return 0
    if args.command == "publish":
        emit(channel.publish(args.logical_id))
        return 0
    if args.command == "verify-audit":
        emit(channel.verify_audit())
        return 0
    if args.command == "provider-log":
        path = channel.state_root / "provider-calls.jsonl"
        if not path.exists():
            emit([])
            return 0
        validate_private_file(channel.home, path)
        emit(
            [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        )
        return 0
    if args.command == "install-definitions":
        emit(channel.install_definitions(args.runtime_root))
        return 0
    if args.command == "uninstall-definitions":
        emit(channel.uninstall_definitions())
        return 0
    raise ChannelError("unknown-command", "unknown channel command")


def main() -> int:
    args = parser().parse_args()
    try:
        return run(args)
    except ChannelError as exc:
        channel = Channel(
            args.home, float(os.environ.get("FM_NOTES_TEST_NOW", time.time()))
        )
        if exc.disable:
            with contextlib.suppress(Exception):
                channel.safe_disable(exc.code)
        print(
            json.dumps(
                {"error": exc.code, "message": exc.message},
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
        )
        return 1
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(
            json.dumps(
                {"error": "internal-refusal", "message": str(exc)},
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
