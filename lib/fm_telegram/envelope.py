"""Authenticated Telegram update normalization and canonical payload binding."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, Mapping, Optional, Tuple


MAX_TEXT_BYTES = 64 * 1024
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class TelegramEnvelopeError(ValueError):
    """A safe rejection that never interpolates raw Telegram content."""


class EnvelopeDisposition(str, Enum):
    ACCEPTED = "accepted"
    UNAUTHORIZED_CHAT = "unauthorized_chat"
    UNAUTHORIZED_SENDER = "unauthorized_sender"
    SENDER_CHAT_UNSUPPORTED = "sender_chat_unsupported"
    UNSUPPORTED_CONTENT = "unsupported_content"
    CALLBACK_DEFERRED = "callback_deferred"


@dataclass(frozen=True)
class BotBinding:
    bot_fingerprint: str
    home_id: str
    api_root_sha256: str

    def __post_init__(self) -> None:
        if not _SHA256_RE.fullmatch(self.bot_fingerprint):
            raise TelegramEnvelopeError("bot fingerprint is invalid")
        if not self.home_id or len(self.home_id) > 192:
            raise TelegramEnvelopeError("home binding is invalid")
        if not _SHA256_RE.fullmatch(self.api_root_sha256):
            raise TelegramEnvelopeError("API root binding is invalid")


@dataclass(frozen=True, repr=False)
class AuthenticationBinding:
    chat_id: str
    sender_user_id: str

    def __post_init__(self) -> None:
        if not re.fullmatch(r"-?[0-9]+", self.chat_id):
            raise TelegramEnvelopeError("chat identity binding is invalid")
        if not re.fullmatch(r"[0-9]+", self.sender_user_id):
            raise TelegramEnvelopeError("sender identity binding is invalid")

    def __repr__(self) -> str:
        return "AuthenticationBinding(chat_id=<redacted>, sender_user_id=<redacted>)"


@dataclass(frozen=True)
class EnvelopeDiagnostic:
    """The only ordinary diagnostic projection of an envelope."""

    component: str
    event: str
    reason_code: str
    bot_fingerprint_prefix: str
    external_id_sha256: str
    payload_sha256: str
    authenticated: bool
    disposition: str


@dataclass(frozen=True, repr=False)
class TelegramEnvelope:
    schema_version: int
    bot_fingerprint: str
    home_id: str
    api_root_sha256: str
    kind: str
    update_id: str
    message_id: Optional[str]
    chat_id: Optional[str]
    sender_user_id: Optional[str]
    sender_chat_id: Optional[str]
    thread_id: Optional[str]
    reply_to_message_id: Optional[str]
    message_date: Optional[int]
    edit_date: Optional[int]
    callback_query_id: Optional[str]
    normalized_text: Optional[str]
    callback_data: Optional[str]
    callback_data_sha256: Optional[str]
    authenticated: bool
    disposition: EnvelopeDisposition
    unsupported_reason: Optional[str]
    payload_sha256: str

    def __repr__(self) -> str:
        return (
            "TelegramEnvelope(schema_version=1, kind="
            f"{self.kind!r}, authenticated={self.authenticated}, "
            f"disposition={self.disposition.value!r}, payload_sha256="
            f"{self.payload_sha256!r})"
        )

    @property
    def external_id(self) -> str:
        return f"tg:{self.bot_fingerprint}:{self.update_id}"

    def diagnostic(self, event: str, reason_code: str) -> EnvelopeDiagnostic:
        return EnvelopeDiagnostic(
            component="telegram-envelope",
            event=event,
            reason_code=reason_code,
            bot_fingerprint_prefix=self.bot_fingerprint[:12],
            external_id_sha256=hashlib.sha256(
                self.external_id.encode("utf-8")
            ).hexdigest(),
            payload_sha256=self.payload_sha256,
            authenticated=self.authenticated,
            disposition=self.disposition.value,
        )


def _integer_string(
    value: Any,
    field: str,
    *,
    positive: bool = False,
    nonnegative: bool = False,
) -> str:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TelegramEnvelopeError(f"{field} is invalid")
    if positive and value <= 0:
        raise TelegramEnvelopeError(f"{field} is invalid")
    if nonnegative and value < 0:
        raise TelegramEnvelopeError(f"{field} is invalid")
    return str(value)


def _optional_integer_string(
    value: Any,
    field: str,
    *,
    present: bool,
    positive: bool = True,
) -> Optional[str]:
    if not present:
        return None
    return _integer_string(value, field, positive=positive)


def _timestamp(value: Any, field: str, required: bool = False) -> Optional[int]:
    if value is None and not required:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise TelegramEnvelopeError(f"{field} is invalid")
    return value


def _normalized_text(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    text = unicodedata.normalize("NFC", value.replace("\r\n", "\n").replace("\r", "\n"))
    if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
        raise TelegramEnvelopeError("message text is oversized")
    for character in text:
        code = ord(character)
        if (code < 0x20 and character not in ("\n", "\t")) or code == 0x7F:
            raise TelegramEnvelopeError("message text contains unsafe control data")
    return text


def _message_fields(message: Mapping[str, Any]) -> Tuple[
    str,
    str,
    str,
    Optional[str],
    Optional[str],
    Optional[int],
    Optional[int],
    Optional[str],
    Optional[str],
]:
    message_id = _integer_string(message.get("message_id"), "message_id", positive=True)
    chat = message.get("chat")
    sender = message.get("from")
    if not isinstance(chat, Mapping):
        raise TelegramEnvelopeError("message chat identity is missing")
    if not isinstance(sender, Mapping):
        raise TelegramEnvelopeError("message sender identity is missing")
    chat_id = _integer_string(chat.get("id"), "chat_id")
    sender_id = _integer_string(
        sender.get("id"), "sender_user_id", positive=True
    )
    sender_chat_id = None
    sender_chat = message.get("sender_chat")
    if isinstance(sender_chat, Mapping):
        sender_chat_id = _integer_string(sender_chat.get("id"), "sender_chat_id")
    thread_id = _optional_integer_string(
        message.get("message_thread_id"),
        "message_thread_id",
        present="message_thread_id" in message,
    )
    reply_id = None
    reply = message.get("reply_to_message")
    if isinstance(reply, Mapping):
        reply_id = _optional_integer_string(
            reply.get("message_id"),
            "reply_to_message.message_id",
            present=True,
        )
    message_date = _timestamp(message.get("date"), "message date", required=True)
    edit_date = _timestamp(message.get("edit_date"), "edit date")
    text = _normalized_text(message.get("text"))
    return (
        message_id,
        chat_id,
        sender_id,
        sender_chat_id,
        thread_id,
        message_date,
        edit_date,
        reply_id,
        text,
    )


def _canonical_hash(fields: Dict[str, Any]) -> str:
    encoded = json.dumps(
        fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def normalize_update(
    update: Mapping[str, Any],
    bot: BotBinding,
    authentication: AuthenticationBinding,
) -> TelegramEnvelope:
    """Normalize one update and authenticate exact chat, user, bot, and home.

    Unauthorized message bodies are used only to bind the canonical hash and are
    then omitted from the returned envelope.
    """

    if not isinstance(update, Mapping):
        raise TelegramEnvelopeError("Telegram update is not an object")
    update_id = _integer_string(
        update.get("update_id"), "update_id", nonnegative=True
    )
    candidates = [
        name
        for name in ("message", "edited_message", "callback_query")
        if isinstance(update.get(name), Mapping)
    ]
    if len(candidates) != 1:
        raise TelegramEnvelopeError("Telegram update kind is ambiguous or unsupported")
    kind = candidates[0]
    message_id = None
    chat_id = None
    sender_id = None
    sender_chat_id = None
    thread_id = None
    reply_id = None
    message_date = None
    edit_date = None
    callback_query_id = None
    normalized_text = None
    callback_data = None
    callback_data_sha256 = None

    if kind in ("message", "edited_message"):
        message = update[kind]
        (
            message_id,
            chat_id,
            sender_id,
            sender_chat_id,
            thread_id,
            message_date,
            edit_date,
            reply_id,
            normalized_text,
        ) = _message_fields(message)
        if kind == "edited_message" and edit_date is None:
            raise TelegramEnvelopeError("edited message timestamp is missing")
    else:
        query = update["callback_query"]
        callback_query_id = query.get("id")
        if not isinstance(callback_query_id, str) or not callback_query_id:
            raise TelegramEnvelopeError("callback query identity is invalid")
        sender = query.get("from")
        message = query.get("message")
        if not isinstance(sender, Mapping) or not isinstance(message, Mapping):
            raise TelegramEnvelopeError("callback origin is incomplete")
        sender_id = _integer_string(
            sender.get("id"), "sender_user_id", positive=True
        )
        chat = message.get("chat")
        if not isinstance(chat, Mapping):
            raise TelegramEnvelopeError("callback chat identity is missing")
        chat_id = _integer_string(chat.get("id"), "chat_id")
        message_id = _integer_string(
            message.get("message_id"), "message_id", positive=True
        )
        thread_id = _optional_integer_string(
            message.get("message_thread_id"),
            "message_thread_id",
            present="message_thread_id" in message,
        )
        message_date = _timestamp(message.get("date"), "message date", required=True)
        callback_data = query.get("data")
        if not isinstance(callback_data, str) or not callback_data:
            raise TelegramEnvelopeError("callback payload is invalid")
        if len(callback_data.encode("utf-8")) > 64:
            raise TelegramEnvelopeError("callback payload is oversized")
        callback_data_sha256 = hashlib.sha256(
            callback_data.encode("utf-8")
        ).hexdigest()

    if chat_id != authentication.chat_id:
        disposition = EnvelopeDisposition.UNAUTHORIZED_CHAT
    elif sender_id != authentication.sender_user_id:
        disposition = EnvelopeDisposition.UNAUTHORIZED_SENDER
    elif sender_chat_id is not None:
        disposition = EnvelopeDisposition.SENDER_CHAT_UNSUPPORTED
    elif kind == "callback_query":
        disposition = EnvelopeDisposition.CALLBACK_DEFERRED
    elif normalized_text is None:
        disposition = EnvelopeDisposition.UNSUPPORTED_CONTENT
    else:
        disposition = EnvelopeDisposition.ACCEPTED
    authenticated = disposition in (
        EnvelopeDisposition.ACCEPTED,
        EnvelopeDisposition.CALLBACK_DEFERRED,
        EnvelopeDisposition.UNSUPPORTED_CONTENT,
    )
    unsupported_reason = {
        EnvelopeDisposition.SENDER_CHAT_UNSUPPORTED: "sender_chat_not_allowed",
        EnvelopeDisposition.CALLBACK_DEFERRED: "decision_lane_not_enabled",
        EnvelopeDisposition.UNSUPPORTED_CONTENT: "text_required",
    }.get(disposition)

    canonical = {
        "schema_version": 1,
        "bot_fingerprint": bot.bot_fingerprint,
        "home_id": bot.home_id,
        "api_root_sha256": bot.api_root_sha256,
        "kind": kind,
        "update_id": update_id,
        "message_id": message_id,
        "chat_id": chat_id,
        "sender_user_id": sender_id,
        "sender_chat_id": sender_chat_id,
        "thread_id": thread_id,
        "reply_to_message_id": reply_id,
        "message_date": message_date,
        "edit_date": edit_date,
        "callback_query_id": callback_query_id,
        "normalized_text": normalized_text,
        "callback_data_sha256": callback_data_sha256,
        "disposition": disposition.value,
    }
    payload_sha256 = _canonical_hash(canonical)
    if not authenticated:
        normalized_text = None
        callback_data = None

    return TelegramEnvelope(
        schema_version=1,
        bot_fingerprint=bot.bot_fingerprint,
        home_id=bot.home_id,
        api_root_sha256=bot.api_root_sha256,
        kind=kind,
        update_id=update_id,
        message_id=message_id,
        chat_id=chat_id,
        sender_user_id=sender_id,
        sender_chat_id=sender_chat_id,
        thread_id=thread_id,
        reply_to_message_id=reply_id,
        message_date=message_date,
        edit_date=edit_date,
        callback_query_id=callback_query_id,
        normalized_text=normalized_text,
        callback_data=callback_data,
        callback_data_sha256=callback_data_sha256,
        authenticated=authenticated,
        disposition=disposition,
        unsupported_reason=unsupported_reason,
        payload_sha256=payload_sha256,
    )
