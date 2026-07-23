"""Secret-safe Telegram Bot API client and deterministic response classes."""

from __future__ import annotations

import hashlib
import json
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, Iterable, Mapping, Optional, Protocol

from .render import ensure_safe_outbound_text


MAX_RESPONSE_BYTES = 1024 * 1024
MAX_RETRY_AFTER_SECONDS = 3600
_METHOD_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,63}$")


class WriteState(str, Enum):
    BEFORE_WRITE = "before_write"
    AFTER_WRITE = "after_write"


class DeliveryState(str, Enum):
    NOT_SENT = "not_sent"
    REJECTED = "rejected"
    RETRYABLE = "retryable"
    AMBIGUOUS = "ambiguous"


@dataclass(frozen=True, repr=False)
class BotToken:
    __value: str

    def __post_init__(self) -> None:
        if (
            not isinstance(self.__value, str)
            or not self.__value
            or any(ord(character) < 0x21 or ord(character) == 0x7F for character in self.__value)
        ):
            raise ValueError("Telegram bot credential is missing or malformed")

    def for_transport(self) -> str:
        return self.__value

    def fingerprint(self) -> str:
        return hashlib.sha256(self.__value.encode("utf-8")).hexdigest()

    def __repr__(self) -> str:
        return "BotToken(<redacted>)"

    def __str__(self) -> str:
        return "<redacted>"


@dataclass(frozen=True)
class ApiDiagnostic:
    component: str
    event: str
    method: str
    outcome: str
    reason_code: str
    status_code: Optional[int] = None
    retry_after_seconds: Optional[int] = None


class TelegramApiError(RuntimeError):
    reason_code = "TELEGRAM_API_ERROR"
    delivery_state = DeliveryState.REJECTED

    def __init__(
        self,
        method: str,
        *,
        status_code: Optional[int] = None,
        retry_after_seconds: Optional[int] = None,
    ) -> None:
        self.method = method
        self.status_code = status_code
        self.retry_after_seconds = retry_after_seconds
        super().__init__(self.reason_code)

    @property
    def diagnostic(self) -> ApiDiagnostic:
        return ApiDiagnostic(
            component="telegram-api",
            event="request.failed",
            method=self.method,
            outcome=self.delivery_state.value,
            reason_code=self.reason_code,
            status_code=self.status_code,
            retry_after_seconds=self.retry_after_seconds,
        )


class ConnectionFailure(TelegramApiError):
    reason_code = "CONNECTION_FAILED_BEFORE_WRITE"
    delivery_state = DeliveryState.NOT_SENT


class AmbiguousDelivery(TelegramApiError):
    reason_code = "POST_WRITE_OUTCOME_AMBIGUOUS"
    delivery_state = DeliveryState.AMBIGUOUS


class MalformedResponse(TelegramApiError):
    reason_code = "MALFORMED_RESPONSE"
    delivery_state = DeliveryState.RETRYABLE


class AmbiguousResponse(TelegramApiError):
    reason_code = "MALFORMED_POST_WRITE_RESPONSE"
    delivery_state = DeliveryState.AMBIGUOUS


class DefinitiveRejection(TelegramApiError):
    reason_code = "DEFINITIVE_REJECTION"
    delivery_state = DeliveryState.REJECTED


class OwnershipConflict(TelegramApiError):
    reason_code = "DUPLICATE_POLLER"
    delivery_state = DeliveryState.REJECTED


class RateLimited(TelegramApiError):
    reason_code = "RATE_LIMITED"
    delivery_state = DeliveryState.RETRYABLE


class ServerFailure(TelegramApiError):
    reason_code = "SERVER_FAILURE"
    delivery_state = DeliveryState.RETRYABLE


@dataclass(frozen=True)
class TransportResponse:
    status_code: int
    body: bytes


class TransportFailure(OSError):
    def __init__(self, write_state: WriteState) -> None:
        self.write_state = write_state
        super().__init__("Telegram transport failed")


class TelegramTransport(Protocol):
    def post(
        self,
        api_root: str,
        token: BotToken,
        method: str,
        payload: Mapping[str, Any],
        timeout_seconds: float,
    ) -> TransportResponse:
        ...


class UrllibTelegramTransport:
    """A production HTTP transport with conservative write-state classification."""

    def post(
        self,
        api_root: str,
        token: BotToken,
        method: str,
        payload: Mapping[str, Any],
        timeout_seconds: float,
    ) -> TransportResponse:
        endpoint = _endpoint(api_root, token, method)
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
        request = urllib.request.Request(
            endpoint,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                return TransportResponse(
                    status_code=response.status,
                    body=_read_bounded(response),
                )
        except urllib.error.HTTPError as error:
            try:
                body = _read_bounded(error)
            except OSError as exc:
                raise TransportFailure(WriteState.AFTER_WRITE) from exc
            finally:
                error.close()
            return TransportResponse(status_code=error.code, body=body)
        except urllib.error.URLError as error:
            reason = error.reason
            if isinstance(reason, (ConnectionRefusedError, socket.gaierror)):
                raise TransportFailure(WriteState.BEFORE_WRITE) from None
            raise TransportFailure(WriteState.AFTER_WRITE) from None
        except (TimeoutError, socket.timeout):
            raise TransportFailure(WriteState.AFTER_WRITE) from None
        except OSError:
            raise TransportFailure(WriteState.AFTER_WRITE) from None


def _read_bounded(response: Any) -> bytes:
    body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise OSError("response exceeds safe bound")
    return body


def _endpoint(api_root: str, token: BotToken, method: str) -> str:
    if not isinstance(api_root, str):
        raise ValueError("Telegram API root is invalid")
    root = api_root.rstrip("/")
    parsed = urllib.parse.urlsplit(root)
    loopback = parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")
    if parsed.scheme != "https" and not loopback:
        raise ValueError("Telegram API root must use HTTPS except for loopback tests")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Telegram API root must not contain credentials or query data")
    if not _METHOD_RE.fullmatch(method):
        raise ValueError("Telegram method is invalid")
    encoded_token = urllib.parse.quote(token.for_transport(), safe=":")
    return f"{root}/bot{encoded_token}/{method}"


class TelegramBotApiClient:
    """Typed Bot API operations with safe failures and positive postconditions."""

    def __init__(
        self,
        token: BotToken,
        *,
        api_root: str = "https://api.telegram.org",
        transport: Optional[TelegramTransport] = None,
        timeout_seconds: float = 20.0,
    ) -> None:
        if timeout_seconds <= 0 or timeout_seconds > 60:
            raise ValueError("Telegram timeout is invalid")
        self._token = token
        self._api_root = api_root
        self._transport = transport or UrllibTelegramTransport()
        self._timeout_seconds = timeout_seconds
        _endpoint(api_root, token, "getMe")

    def get_updates(
        self,
        *,
        offset: int,
        timeout_seconds: int,
        allowed_updates: Iterable[str] = (
            "message",
            "edited_message",
            "callback_query",
        ),
    ) -> list:
        if (
            isinstance(offset, bool)
            or not isinstance(offset, int)
            or offset < 0
            or isinstance(timeout_seconds, bool)
            or not isinstance(timeout_seconds, int)
            or timeout_seconds < 0
            or timeout_seconds > 50
        ):
            raise ValueError("Telegram poll parameters are invalid")
        result = self._call(
            "getUpdates",
            {
                "offset": offset,
                "timeout": timeout_seconds,
                "allowed_updates": list(allowed_updates),
            },
            mutation=False,
        )
        if not isinstance(result, list) or any(
            not isinstance(item, dict) for item in result
        ):
            raise MalformedResponse("getUpdates")
        return result

    def get_webhook_info(self) -> dict:
        result = self._call("getWebhookInfo", {}, mutation=False)
        if not isinstance(result, dict) or not isinstance(result.get("url"), str):
            raise MalformedResponse("getWebhookInfo")
        return result

    def send_message(
        self,
        *,
        chat_id: str,
        text: str,
        reply_parameters: Optional[Mapping[str, Any]] = None,
        message_thread_id: Optional[str] = None,
    ) -> dict:
        _chat_id(chat_id)
        if not isinstance(text, str) or not text:
            raise ValueError("Telegram message text is invalid")
        ensure_safe_outbound_text(text)
        payload: Dict[str, Any] = {"chat_id": chat_id, "text": text}
        if reply_parameters is not None:
            payload["reply_parameters"] = _reply_parameters(reply_parameters)
        if message_thread_id is not None:
            payload["message_thread_id"] = int(_positive_id(message_thread_id))
        result = self._call("sendMessage", payload, mutation=True)
        return _positive_message(result, chat_id, "sendMessage")

    def edit_message_text(
        self, *, chat_id: str, message_id: str, text: str
    ) -> dict:
        _chat_id(chat_id)
        message_id = _positive_id(message_id)
        if not isinstance(text, str) or not text:
            raise ValueError("Telegram message text is invalid")
        ensure_safe_outbound_text(text)
        result = self._call(
            "editMessageText",
            {"chat_id": chat_id, "message_id": int(message_id), "text": text},
            mutation=True,
        )
        return _positive_message(result, chat_id, "editMessageText")

    def delete_message(self, *, chat_id: str, message_id: str) -> bool:
        _chat_id(chat_id)
        message_id = _positive_id(message_id)
        result = self._call(
            "deleteMessage",
            {"chat_id": chat_id, "message_id": int(message_id)},
            mutation=True,
        )
        if result is not True:
            raise AmbiguousResponse("deleteMessage")
        return True

    def answer_callback_query(
        self,
        *,
        callback_query_id: str,
        text: Optional[str] = None,
        show_alert: bool = False,
    ) -> bool:
        if not isinstance(callback_query_id, str) or not callback_query_id:
            raise ValueError("Telegram callback identity is invalid")
        if text is not None and (
            not isinstance(text, str) or not text or len(text) > 200
        ):
            raise ValueError("Telegram callback acknowledgment text is invalid")
        if not isinstance(show_alert, bool):
            raise ValueError("Telegram callback alert policy is invalid")
        payload: Dict[str, Any] = {
            "callback_query_id": callback_query_id,
            "show_alert": show_alert,
        }
        if text is not None:
            ensure_safe_outbound_text(text)
            payload["text"] = text
        result = self._call(
            "answerCallbackQuery",
            payload,
            mutation=True,
        )
        if result is not True:
            raise AmbiguousResponse("answerCallbackQuery")
        return True

    def _call(
        self, method: str, payload: Mapping[str, Any], *, mutation: bool
    ) -> Any:
        try:
            response = self._transport.post(
                self._api_root,
                self._token,
                method,
                payload,
                self._timeout_seconds,
            )
        except TransportFailure as failure:
            if failure.write_state == WriteState.BEFORE_WRITE:
                raise ConnectionFailure(method) from None
            if mutation:
                raise AmbiguousDelivery(method) from None
            raise ConnectionFailure(method) from None
        if response.status_code == 409:
            if method == "getUpdates":
                raise OwnershipConflict(method, status_code=409)
            raise DefinitiveRejection(method, status_code=409)
        if response.status_code >= 500:
            raise ServerFailure(method, status_code=response.status_code)
        if response.status_code >= 400 and response.status_code != 429:
            raise DefinitiveRejection(method, status_code=response.status_code)
        decoded = _decode_json(response.body, method, mutation=mutation)
        error_code = decoded.get("error_code")
        if error_code == 409:
            if method == "getUpdates":
                raise OwnershipConflict(method, status_code=409)
            raise DefinitiveRejection(method, status_code=409)
        if response.status_code == 429 or error_code == 429:
            retry_after = _retry_after(decoded)
            raise RateLimited(
                method,
                status_code=429,
                retry_after_seconds=retry_after,
            )
        if response.status_code >= 400 or decoded.get("ok") is False:
            status = error_code if isinstance(error_code, int) else response.status_code
            raise DefinitiveRejection(method, status_code=status)
        if response.status_code != 200 or decoded.get("ok") is not True:
            error_type = AmbiguousResponse if mutation else MalformedResponse
            raise error_type(method, status_code=response.status_code)
        if "result" not in decoded:
            error_type = AmbiguousResponse if mutation else MalformedResponse
            raise error_type(method, status_code=response.status_code)
        return decoded["result"]


def _decode_json(body: bytes, method: str, *, mutation: bool) -> dict:
    try:
        decoded = json.loads(body.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        error_type = AmbiguousResponse if mutation else MalformedResponse
        raise error_type(method) from None
    if not isinstance(decoded, dict):
        error_type = AmbiguousResponse if mutation else MalformedResponse
        raise error_type(method)
    return decoded


def _retry_after(decoded: Mapping[str, Any]) -> int:
    parameters = decoded.get("parameters")
    if not isinstance(parameters, Mapping):
        raise MalformedResponse("rate-limit")
    value = parameters.get("retry_after")
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise MalformedResponse("rate-limit")
    return min(value, MAX_RETRY_AFTER_SECONDS)


def _positive_message(result: Any, expected_chat_id: str, method: str) -> dict:
    if not isinstance(result, dict):
        raise AmbiguousResponse(method)
    message_id = result.get("message_id")
    chat = result.get("chat")
    if (
        isinstance(message_id, bool)
        or not isinstance(message_id, int)
        or message_id <= 0
        or not isinstance(chat, dict)
        or str(chat.get("id")) != expected_chat_id
    ):
        raise AmbiguousResponse(method)
    return result


def _positive_id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value.isdigit()
        or value == "0"
    ):
        raise ValueError("Telegram message identity is invalid")
    return value


def _chat_id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or re.fullmatch(r"-?[0-9]+", value) is None
    ):
        raise ValueError("Telegram chat identity is invalid")
    return value


def _reply_parameters(value: Mapping[str, Any]) -> Dict[str, Any]:
    if set(value) != {"message_id", "allow_sending_without_reply"}:
        raise ValueError("Telegram reply parameters are invalid")
    raw_message_id = value.get("message_id")
    if isinstance(raw_message_id, bool):
        raise ValueError("Telegram reply parameters are invalid")
    message_id = _positive_id(str(raw_message_id))
    if value.get("allow_sending_without_reply") is not False:
        raise ValueError("Telegram reply parameters are invalid")
    return {
        "message_id": int(message_id),
        "allow_sending_without_reply": False,
    }
