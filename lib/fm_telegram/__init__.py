"""Harness-neutral Telegram transport foundations for Firstmate."""

from .envelope import (
    AuthenticationBinding,
    BotBinding,
    EnvelopeDisposition,
    TelegramEnvelope,
    TelegramEnvelopeError,
    normalize_update,
)
from .protocol import (
    PROTOCOL_NAME,
    PROTOCOL_VERSION,
    BridgeResult,
    BridgeStatus,
    BusyPolicy,
    Milestone,
    MilestoneKind,
    SessionRegistration,
    SessionUnavailable,
    TurnFinal,
    TurnOffer,
    TurnReconcile,
    decode_frame,
    encode_frame,
    validate_message,
)
from .render import RenderedChunk, ReplyParameters, render_plain_text
from .telegram_api import BotToken, TelegramBotApiClient

__all__ = [
    "AuthenticationBinding",
    "BotBinding",
    "BotToken",
    "BridgeResult",
    "BridgeStatus",
    "BusyPolicy",
    "EnvelopeDisposition",
    "Milestone",
    "MilestoneKind",
    "PROTOCOL_NAME",
    "PROTOCOL_VERSION",
    "RenderedChunk",
    "ReplyParameters",
    "SessionRegistration",
    "SessionUnavailable",
    "TelegramBotApiClient",
    "TelegramEnvelope",
    "TelegramEnvelopeError",
    "TurnFinal",
    "TurnOffer",
    "TurnReconcile",
    "decode_frame",
    "encode_frame",
    "normalize_update",
    "render_plain_text",
    "validate_message",
]
