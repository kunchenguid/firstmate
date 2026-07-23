"""The single code owner of the private ``fm.telegram.v1`` wire contract.

The protocol is harness-neutral.  Adapters register an explicit active session,
accept or reconcile durable external turns, emit allowlisted milestones, and
correlate one final response to one accepted adapter entry.
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, ClassVar, Dict, Mapping, Optional, Set, Type, TypeVar


PROTOCOL_NAME = "fm.telegram.v1"
PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 256 * 1024

_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$")
_REASON_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_EXTERNAL_ID_RE = re.compile(r"^tg:[0-9a-f]{64}:[0-9]+$")
_HARNESS_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")


class ProtocolValidationError(ValueError):
    """A safe protocol rejection that never includes input values."""


class BridgeStatus(str, Enum):
    ACCEPTED = "ACCEPTED"
    DUPLICATE = "DUPLICATE"
    NOT_FOUND = "NOT_FOUND"
    BUSY = "BUSY"
    UNAVAILABLE = "UNAVAILABLE"
    AMBIGUOUS = "AMBIGUOUS"


class BusyPolicy(str, Enum):
    FOLLOW_UP = "followUp"
    STEER = "steer"


class TurnKind(str, Enum):
    MESSAGE = "message"
    EDIT = "edit"
    REPLY = "reply"


class FinalOutcome(str, Enum):
    ANSWERED = "answered"
    FAILED = "failed"
    CANCELLED = "cancelled"


class MilestoneKind(str, Enum):
    TURN_ACCEPTED = "turn.accepted"
    TURN_STARTED = "turn.started"
    TOOL_PHASE_STARTED = "tool_phase.started"
    EXTERNAL_GATE_WAIT = "external_gate.wait"
    RETRY_STARTED = "retry.started"
    COMPACTION_STARTED = "compaction.started"
    TURN_SETTLED = "turn.settled"


def _exact_fields(
    value: Mapping[str, Any], required: Set[str], optional: Optional[Set[str]] = None
) -> None:
    optional = optional or set()
    keys = set(value)
    if not required.issubset(keys):
        raise ProtocolValidationError("protocol message is missing required fields")
    if keys - required - optional:
        raise ProtocolValidationError("protocol message has unknown fields")


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not _ID_RE.fullmatch(value):
        raise ProtocolValidationError(f"{field} is invalid")
    return value


def _harness(value: Any) -> str:
    if not isinstance(value, str) or not _HARNESS_RE.fullmatch(value):
        raise ProtocolValidationError("harness is invalid")
    return value


def _sha256(value: Any, field: str) -> str:
    if not isinstance(value, str) or not _SHA256_RE.fullmatch(value):
        raise ProtocolValidationError(f"{field} is invalid")
    return value


def _external_id(value: Any) -> str:
    if not isinstance(value, str) or not _EXTERNAL_ID_RE.fullmatch(value):
        raise ProtocolValidationError("external_id is invalid")
    return value


def _positive_int(value: Any, field: str, allow_zero: bool = False) -> int:
    floor = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < floor:
        raise ProtocolValidationError(f"{field} is invalid")
    return value


def _reason(value: Any) -> str:
    if not isinstance(value, str) or not _REASON_RE.fullmatch(value):
        raise ProtocolValidationError("reason_code is invalid")
    return value


def _type_and_version(value: Mapping[str, Any], expected_type: str) -> None:
    if value.get("type") != expected_type:
        raise ProtocolValidationError("protocol message type is invalid")
    if value.get("protocol") != PROTOCOL_NAME:
        raise ProtocolValidationError("protocol name is unsupported")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolValidationError("protocol version is unsupported")


def _enum(enum_type: Type[Any], value: Any, field: str) -> Any:
    try:
        return enum_type(value)
    except (TypeError, ValueError):
        raise ProtocolValidationError(f"{field} is invalid") from None


def _wire_dict(value: Any) -> Dict[str, Any]:
    result = asdict(value)
    for key, item in list(result.items()):
        if isinstance(item, Enum):
            result[key] = item.value
        elif item is None:
            result.pop(key)
    result["type"] = value.TYPE
    result["protocol"] = PROTOCOL_NAME
    result["protocol_version"] = PROTOCOL_VERSION
    return result


def _bridge_result_field_is_required(field: str) -> None:
    raise ProtocolValidationError(f"{field} is invalid")


def _validate_bridge_result(result: "BridgeResult") -> None:
    _string(result.request_id, "request_id")
    _external_id(result.external_id)
    _sha256(result.payload_sha256, "payload_sha256")
    if result.status in (BridgeStatus.ACCEPTED, BridgeStatus.DUPLICATE):
        _positive_int(result.session_epoch, "session_epoch")
        _string(result.session_id, "session_id")
        _string(result.adapter_entry_id, "adapter_entry_id")
        if result.retry_after_ms is not None:
            _bridge_result_field_is_required("retry_after_ms")
        if result.reason_code is not None:
            _bridge_result_field_is_required("reason_code")
    elif result.status == BridgeStatus.NOT_FOUND:
        _positive_int(result.session_epoch, "session_epoch")
        _string(result.session_id, "session_id")
        if result.adapter_entry_id is not None:
            _bridge_result_field_is_required("adapter_entry_id")
        if result.retry_after_ms is not None:
            _bridge_result_field_is_required("retry_after_ms")
        if result.reason_code is not None:
            _bridge_result_field_is_required("reason_code")
    elif result.status == BridgeStatus.BUSY:
        _positive_int(result.session_epoch, "session_epoch")
        _positive_int(result.retry_after_ms, "retry_after_ms")
        if result.session_id is not None:
            _bridge_result_field_is_required("session_id")
        if result.adapter_entry_id is not None:
            _bridge_result_field_is_required("adapter_entry_id")
        if result.reason_code is not None:
            _bridge_result_field_is_required("reason_code")
    elif result.status in (BridgeStatus.UNAVAILABLE, BridgeStatus.AMBIGUOUS):
        _reason(result.reason_code)
        if result.session_epoch is not None:
            _bridge_result_field_is_required("session_epoch")
        if result.session_id is not None:
            _bridge_result_field_is_required("session_id")
        if result.adapter_entry_id is not None:
            _bridge_result_field_is_required("adapter_entry_id")
        if result.retry_after_ms is not None:
            _bridge_result_field_is_required("retry_after_ms")
    else:
        raise ProtocolValidationError("status is invalid")


@dataclass(frozen=True)
class SessionRegistration:
    """An explicit claim by one adapter for one active Firstmate session."""

    TYPE: ClassVar[str] = "session.register"
    request_id: str
    idempotency_key: str
    home_id: str
    daemon_instance_id: str
    bot_fingerprint: str
    bridge_build: str
    harness: str
    harness_version: str
    session_id: str
    route_id: str
    session_epoch: int
    project_root_sha256: str

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "SessionRegistration":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "request_id",
            "idempotency_key",
            "home_id",
            "daemon_instance_id",
            "bot_fingerprint",
            "bridge_build",
            "harness",
            "harness_version",
            "session_id",
            "route_id",
            "session_epoch",
            "project_root_sha256",
        }
        _exact_fields(value, required)
        _type_and_version(value, cls.TYPE)
        return cls(
            request_id=_string(value["request_id"], "request_id"),
            idempotency_key=_string(
                value["idempotency_key"], "idempotency_key"
            ),
            home_id=_string(value["home_id"], "home_id"),
            daemon_instance_id=_string(
                value["daemon_instance_id"], "daemon_instance_id"
            ),
            bot_fingerprint=_sha256(value["bot_fingerprint"], "bot_fingerprint"),
            bridge_build=_string(value["bridge_build"], "bridge_build"),
            harness=_harness(value["harness"]),
            harness_version=_string(value["harness_version"], "harness_version"),
            session_id=_string(value["session_id"], "session_id"),
            route_id=_string(value["route_id"], "route_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
            project_root_sha256=_sha256(
                value["project_root_sha256"], "project_root_sha256"
            ),
        )


@dataclass(frozen=True)
class SessionUnavailable:
    TYPE: ClassVar[str] = "session.unavailable"
    request_id: str
    route_id: str
    session_id: str
    session_epoch: int
    reason_code: str

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "SessionUnavailable":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "request_id",
            "route_id",
            "session_id",
            "session_epoch",
            "reason_code",
        }
        _exact_fields(value, required)
        _type_and_version(value, cls.TYPE)
        return cls(
            request_id=_string(value["request_id"], "request_id"),
            route_id=_string(value["route_id"], "route_id"),
            session_id=_string(value["session_id"], "session_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
            reason_code=_reason(value["reason_code"]),
        )


@dataclass(frozen=True)
class TurnOffer:
    TYPE: ClassVar[str] = "turn.offer"
    request_id: str
    idempotency_key: str
    external_id: str
    payload_sha256: str
    route_id: str
    session_epoch: int
    kind: TurnKind
    text: str
    busy_policy: BusyPolicy
    supersedes_external_id: Optional[str] = None
    telegram_reply_to_message_id: Optional[str] = None
    known_reply_external_id: Optional[str] = None

    def __repr__(self) -> str:
        return (
            "TurnOffer(request_id=<redacted>, external_id=<redacted>, "
            f"kind={self.kind.value!r}, session_epoch={self.session_epoch})"
        )

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "TurnOffer":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "request_id",
            "idempotency_key",
            "external_id",
            "payload_sha256",
            "route_id",
            "session_epoch",
            "kind",
            "text",
            "busy_policy",
        }
        optional = {
            "supersedes_external_id",
            "telegram_reply_to_message_id",
            "known_reply_external_id",
        }
        _exact_fields(value, required, optional)
        _type_and_version(value, cls.TYPE)
        text = value["text"]
        if not isinstance(text, str) or not text or len(text.encode("utf-8")) > 65536:
            raise ProtocolValidationError("turn text is invalid")
        reply_id = value.get("telegram_reply_to_message_id")
        if reply_id is not None and (
            not isinstance(reply_id, str) or not reply_id.isdigit() or reply_id == "0"
        ):
            raise ProtocolValidationError(
                "telegram_reply_to_message_id is invalid"
            )
        supersedes = value.get("supersedes_external_id")
        known_reply = value.get("known_reply_external_id")
        return cls(
            request_id=_string(value["request_id"], "request_id"),
            idempotency_key=_string(value["idempotency_key"], "idempotency_key"),
            external_id=_external_id(value["external_id"]),
            payload_sha256=_sha256(value["payload_sha256"], "payload_sha256"),
            route_id=_string(value["route_id"], "route_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
            kind=_enum(TurnKind, value["kind"], "kind"),
            text=text,
            busy_policy=_enum(BusyPolicy, value["busy_policy"], "busy_policy"),
            supersedes_external_id=(
                _external_id(supersedes) if supersedes is not None else None
            ),
            telegram_reply_to_message_id=reply_id,
            known_reply_external_id=(
                _external_id(known_reply) if known_reply is not None else None
            ),
        )


@dataclass(frozen=True)
class TurnReconcile:
    TYPE: ClassVar[str] = "turn.reconcile"
    request_id: str
    external_id: str
    payload_sha256: str
    route_id: str
    session_epoch: int

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "TurnReconcile":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "request_id",
            "external_id",
            "payload_sha256",
            "route_id",
            "session_epoch",
        }
        _exact_fields(value, required)
        _type_and_version(value, cls.TYPE)
        return cls(
            request_id=_string(value["request_id"], "request_id"),
            external_id=_external_id(value["external_id"]),
            payload_sha256=_sha256(value["payload_sha256"], "payload_sha256"),
            route_id=_string(value["route_id"], "route_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
        )


@dataclass(frozen=True)
class BridgeResult:
    TYPE: ClassVar[str] = "turn.result"
    request_id: str
    external_id: str
    payload_sha256: str
    status: BridgeStatus
    session_epoch: Optional[int] = None
    session_id: Optional[str] = None
    adapter_entry_id: Optional[str] = None
    retry_after_ms: Optional[int] = None
    reason_code: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_bridge_result(self)

    def to_wire(self) -> Dict[str, Any]:
        _validate_bridge_result(self)
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "BridgeResult":
        common = {
            "type",
            "protocol",
            "protocol_version",
            "request_id",
            "external_id",
            "payload_sha256",
            "status",
        }
        status = _enum(BridgeStatus, value.get("status"), "status")
        extra_by_status = {
            BridgeStatus.ACCEPTED: {
                "session_epoch",
                "session_id",
                "adapter_entry_id",
            },
            BridgeStatus.DUPLICATE: {
                "session_epoch",
                "session_id",
                "adapter_entry_id",
            },
            BridgeStatus.NOT_FOUND: {"session_epoch", "session_id"},
            BridgeStatus.BUSY: {"session_epoch", "retry_after_ms"},
            BridgeStatus.UNAVAILABLE: {"reason_code"},
            BridgeStatus.AMBIGUOUS: {"reason_code"},
        }
        _exact_fields(value, common | extra_by_status[status])
        _type_and_version(value, cls.TYPE)
        result = cls(
            request_id=_string(value["request_id"], "request_id"),
            external_id=_external_id(value["external_id"]),
            payload_sha256=_sha256(value["payload_sha256"], "payload_sha256"),
            status=status,
            session_epoch=(
                _positive_int(value["session_epoch"], "session_epoch")
                if "session_epoch" in value
                else None
            ),
            session_id=(
                _string(value["session_id"], "session_id")
                if "session_id" in value
                else None
            ),
            adapter_entry_id=(
                _string(value["adapter_entry_id"], "adapter_entry_id")
                if "adapter_entry_id" in value
                else None
            ),
            retry_after_ms=(
                _positive_int(value["retry_after_ms"], "retry_after_ms")
                if "retry_after_ms" in value
                else None
            ),
            reason_code=(
                _reason(value["reason_code"]) if "reason_code" in value else None
            ),
        )
        return result


@dataclass(frozen=True)
class Milestone:
    TYPE: ClassVar[str] = "turn.milestone"
    event_id: str
    external_id: str
    route_id: str
    session_id: str
    session_epoch: int
    sequence_no: int
    kind: MilestoneKind
    occurred_at: int

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "Milestone":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "event_id",
            "external_id",
            "route_id",
            "session_id",
            "session_epoch",
            "sequence_no",
            "kind",
            "occurred_at",
        }
        _exact_fields(value, required)
        _type_and_version(value, cls.TYPE)
        return cls(
            event_id=_string(value["event_id"], "event_id"),
            external_id=_external_id(value["external_id"]),
            route_id=_string(value["route_id"], "route_id"),
            session_id=_string(value["session_id"], "session_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
            sequence_no=_positive_int(
                value["sequence_no"], "sequence_no", allow_zero=True
            ),
            kind=_enum(MilestoneKind, value["kind"], "kind"),
            occurred_at=_positive_int(value["occurred_at"], "occurred_at"),
        )


@dataclass(frozen=True)
class TurnFinal:
    TYPE: ClassVar[str] = "turn.final"
    event_id: str
    external_id: str
    route_id: str
    session_id: str
    session_epoch: int
    adapter_entry_id: str
    outcome: FinalOutcome
    text: str
    content_sha256: str

    def __repr__(self) -> str:
        return (
            "TurnFinal(event_id=<redacted>, external_id=<redacted>, "
            f"outcome={self.outcome.value!r}, session_epoch={self.session_epoch})"
        )

    def to_wire(self) -> Dict[str, Any]:
        return _wire_dict(self)

    @classmethod
    def from_wire(cls, value: Mapping[str, Any]) -> "TurnFinal":
        required = {
            "type",
            "protocol",
            "protocol_version",
            "event_id",
            "external_id",
            "route_id",
            "session_id",
            "session_epoch",
            "adapter_entry_id",
            "outcome",
            "text",
            "content_sha256",
        }
        _exact_fields(value, required)
        _type_and_version(value, cls.TYPE)
        text = value["text"]
        if not isinstance(text, str) or len(text.encode("utf-8")) > 256 * 1024:
            raise ProtocolValidationError("final text is invalid")
        content_hash = _sha256(value["content_sha256"], "content_sha256")
        if hashlib.sha256(text.encode("utf-8")).hexdigest() != content_hash:
            raise ProtocolValidationError("final content hash does not match text")
        return cls(
            event_id=_string(value["event_id"], "event_id"),
            external_id=_external_id(value["external_id"]),
            route_id=_string(value["route_id"], "route_id"),
            session_id=_string(value["session_id"], "session_id"),
            session_epoch=_positive_int(value["session_epoch"], "session_epoch"),
            adapter_entry_id=_string(
                value["adapter_entry_id"], "adapter_entry_id"
            ),
            outcome=_enum(FinalOutcome, value["outcome"], "outcome"),
            text=text,
            content_sha256=content_hash,
        )


_Message = TypeVar("_Message")
_MESSAGE_TYPES: Dict[str, Type[Any]] = {
    SessionRegistration.TYPE: SessionRegistration,
    SessionUnavailable.TYPE: SessionUnavailable,
    TurnOffer.TYPE: TurnOffer,
    TurnReconcile.TYPE: TurnReconcile,
    BridgeResult.TYPE: BridgeResult,
    Milestone.TYPE: Milestone,
    TurnFinal.TYPE: TurnFinal,
}


def validate_message(value: Mapping[str, Any]) -> Any:
    """Validate one decoded frame and return its immutable typed message."""

    if not isinstance(value, Mapping):
        raise ProtocolValidationError("protocol frame is not an object")
    message_type = value.get("type")
    message_class = _MESSAGE_TYPES.get(message_type)
    if message_class is None:
        raise ProtocolValidationError("protocol message type is unsupported")
    return message_class.from_wire(value)


def encode_frame(message: Any) -> bytes:
    """Encode one validated message as a bounded length-prefixed JSON frame."""

    if not hasattr(message, "to_wire"):
        raise ProtocolValidationError("protocol message is not encodable")
    wire = message.to_wire()
    validate_message(wire)
    payload = json.dumps(
        wire, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    if len(payload) > MAX_FRAME_BYTES:
        raise ProtocolValidationError("protocol frame exceeds maximum size")
    return struct.pack(">I", len(payload)) + payload


def decode_frame(frame: bytes) -> Any:
    """Decode one complete bounded frame and validate all required fields."""

    if not isinstance(frame, bytes) or len(frame) < 4:
        raise ProtocolValidationError("protocol frame is truncated")
    length = struct.unpack(">I", frame[:4])[0]
    if length > MAX_FRAME_BYTES:
        raise ProtocolValidationError("protocol frame exceeds maximum size")
    if len(frame) != length + 4:
        raise ProtocolValidationError("protocol frame length does not match payload")
    try:
        value = json.loads(frame[4:].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise ProtocolValidationError("protocol frame is not valid JSON") from None
    return validate_message(value)
