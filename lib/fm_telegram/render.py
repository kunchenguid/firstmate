"""Canonical Telegram escaping, plain-text rendering, and bounded chunking."""

from __future__ import annotations

import hashlib
import html
import re
import unicodedata
from dataclasses import dataclass
from typing import List, Optional


TELEGRAM_MESSAGE_BYTES = 4096
MAX_CHUNKS = 64
_CREDENTIAL_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(
        r"(?i)\b(?:api[_-]?key|access[_-]?token|auth(?:orization)?|"
        r"bot[_-]?token|client[_-]?secret|password|private[_-]?key|secret)"
        r"\b\s*[:=]\s*[\"']?[A-Za-z0-9_./+=:@-]{8,}"
    ),
    re.compile(r"\b[0-9]{6,}:[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(
        r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
        r"[A-Za-z0-9_-]{8,}\b"
    ),
    re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"),
)


class RenderError(ValueError):
    pass


@dataclass(frozen=True, repr=False)
class ReplyParameters:
    message_id: str
    allow_sending_without_reply: bool = False

    def __post_init__(self) -> None:
        if (
            not isinstance(self.message_id, str)
            or not self.message_id.isdigit()
            or self.message_id == "0"
        ):
            raise RenderError("reply message identity is invalid")
        if self.allow_sending_without_reply is not False:
            raise RenderError("unbound Telegram replies are forbidden")

    def as_payload(self) -> dict:
        return {
            "message_id": int(self.message_id),
            "allow_sending_without_reply": False,
        }

    def __repr__(self) -> str:
        return "ReplyParameters(message_id=<redacted>, allow_sending_without_reply=False)"


@dataclass(frozen=True, repr=False)
class RenderedChunk:
    delivery_id: str
    content_sha256: str
    chunk_sha256: str
    sequence_no: int
    total_chunks: int
    text: str
    reply_parameters: Optional[ReplyParameters]
    thread_id: Optional[str]

    def __repr__(self) -> str:
        return (
            f"RenderedChunk(delivery_id={self.delivery_id!r}, "
            f"sequence_no={self.sequence_no}, total_chunks={self.total_chunks}, "
            f"content_sha256={self.content_sha256!r})"
        )

    def send_payload(self, chat_id: str) -> dict:
        if not isinstance(chat_id, str) or not chat_id.lstrip("-").isdigit():
            raise RenderError("destination chat identity is invalid")
        payload = {"chat_id": chat_id, "text": self.text}
        if self.reply_parameters is not None:
            payload["reply_parameters"] = self.reply_parameters.as_payload()
        if self.thread_id is not None:
            payload["message_thread_id"] = int(self.thread_id)
        return payload


def escape_html(value: str) -> str:
    """Canonical Telegram HTML escaping for later opt-in rich renderers."""

    if not isinstance(value, str):
        raise RenderError("rendered content must be text")
    return html.escape(
        unicodedata.normalize("NFC", value.replace("\r\n", "\n").replace("\r", "\n")),
        quote=False,
    )


def ensure_safe_outbound_text(value: str) -> None:
    """Reject credential-shaped outbound content without returning the match."""

    if not isinstance(value, str):
        raise RenderError("rendered content must be text")
    if any(pattern.search(value) for pattern in _CREDENTIAL_PATTERNS):
        raise RenderError("rendered content contains credential-like material")


def _take_prefix(value: str, limit: int) -> tuple[str, str]:
    low = 0
    high = len(value)
    while low < high:
        middle = (low + high + 1) // 2
        if len(value[:middle].encode("utf-8")) <= limit:
            low = middle
        else:
            high = middle - 1
    return value[:low], value[low:]


def _split_text(value: str, limit: int) -> List[str]:
    if not value:
        return [""]
    chunks: List[str] = []
    remaining = value
    while remaining:
        if len(remaining.encode("utf-8")) <= limit:
            chunks.append(remaining)
            break
        prefix, suffix = _take_prefix(remaining, limit)
        if not prefix:
            raise RenderError("one character exceeds the Telegram message limit")
        boundary = prefix.rfind("\n")
        if boundary > 0:
            prefix = prefix[: boundary + 1]
            suffix = remaining[len(prefix) :]
        chunks.append(prefix)
        remaining = suffix
        if len(chunks) >= MAX_CHUNKS and remaining:
            raise RenderError("rendered content exceeds the Telegram chunk limit")
    return chunks


def render_plain_text(
    text: str,
    *,
    reply_to_message_id: Optional[str] = None,
    thread_id: Optional[str] = None,
    message_bytes: int = TELEGRAM_MESSAGE_BYTES,
) -> List[RenderedChunk]:
    """Render exact normalized plain text with stable content-bound identities."""

    if not isinstance(text, str):
        raise RenderError("rendered content must be text")
    if isinstance(message_bytes, bool) or not isinstance(message_bytes, int):
        raise RenderError("message size limit is invalid")
    if message_bytes < 32 or message_bytes > TELEGRAM_MESSAGE_BYTES:
        raise RenderError("message size limit is invalid")
    normalized = unicodedata.normalize(
        "NFC", text.replace("\r\n", "\n").replace("\r", "\n")
    )
    if not normalized:
        raise RenderError("rendered content must not be empty")
    ensure_safe_outbound_text(normalized)
    for character in normalized:
        code = ord(character)
        if (code < 0x20 and character not in ("\n", "\t")) or code == 0x7F:
            raise RenderError("rendered content contains unsafe control data")
    reply = (
        ReplyParameters(reply_to_message_id)
        if reply_to_message_id is not None
        else None
    )
    if thread_id is not None and (
        not isinstance(thread_id, str)
        or not thread_id.isdigit()
        or thread_id == "0"
    ):
        raise RenderError("message thread identity is invalid")
    content_sha256 = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    parts = _split_text(normalized, message_bytes)
    total = len(parts)
    rendered = []
    for sequence_no, part in enumerate(parts):
        chunk_sha256 = hashlib.sha256(part.encode("utf-8")).hexdigest()
        identity = (
            f"fm.telegram.delivery.v1\0{content_sha256}\0{sequence_no}\0"
            f"{total}\0{chunk_sha256}"
        )
        rendered.append(
            RenderedChunk(
                delivery_id=hashlib.sha256(identity.encode("utf-8")).hexdigest(),
                content_sha256=content_sha256,
                chunk_sha256=chunk_sha256,
                sequence_no=sequence_no,
                total_chunks=total,
                text=part,
                reply_parameters=reply,
                thread_id=thread_id,
            )
        )
    return rendered
