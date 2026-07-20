#!/usr/bin/env python3
"""Reusable Telegram relay primitives with bounded retry and safe checkpointing."""

from __future__ import annotations

import json
import random as _random
import time as _time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable
from urllib.error import URLError


TELEGRAM_API_BASE = "https://api.telegram.org/bot"


class TelegramRelayError(RuntimeError):
    """Base error for relay-core failures."""


class TelegramTransientError(TelegramRelayError):
    """Transient error suitable for retry."""


class TelegramPermanentError(TelegramRelayError):
    """Terminal Telegram/API failure."""


class TelegramResponseError(TelegramPermanentError):
    """Telegram response malformed or indicates a rejected request."""


@dataclass(frozen=True)
class RetryConfig:
    max_attempts: int = 5
    base_delay: float = 0.25
    max_delay: float = 4.0
    jitter: float = 0.15

    def __post_init__(self):
        if self.max_attempts < 1:
            raise ValueError("max_attempts must be >= 1")
        if self.base_delay < 0:
            raise ValueError("base_delay must be >= 0")
        if self.max_delay < self.base_delay:
            raise ValueError("max_delay must be >= base_delay")
        if not 0 <= self.jitter < 1:
            raise ValueError("jitter must be in [0, 1)")


def read_offset(path: Path) -> int:
    """Read numeric checkpoint, defaulting to zero on any parse failure."""

    try:
        return int(path.read_text().strip())
    except Exception:
        return 0


def write_offset_atomic(path: Path, offset: int) -> None:
    """Persist an offset atomically.

    Uses a temporary sibling path and replacement so checkpoints do not tear.
    """

    payload = f"{offset}\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(payload)
    tmp.replace(path)


def validate_telegram_ok(payload: dict, method: str) -> dict:
    """Validate Telegram payload and return `result`.

    `payload` must be a dict with ``ok: true`` to be accepted.
    """

    if not isinstance(payload, dict):
        raise TelegramResponseError("telegram response was not a JSON object")

    ok_value = payload.get("ok")
    if ok_value is not True:
        description = payload.get("description")
        if description:
            raise TelegramResponseError(
                f"telegram API {method} rejected request: {description}"
            )
        raise TelegramResponseError(f"telegram API {method} rejected request")

    return payload.get("result", {})


def telegram_api_request(
    token: str,
    method: str,
    params: dict | None = None,
    timeout: float = 35,
) -> dict:
    """Issue a Telegram API request.

    This function is intentionally thin and injectable from callers that want to test
    transport-level behavior with full fakes.
    """

    url = TELEGRAM_API_BASE + token + "/" + method
    data = None
    if params is not None:
        data = urllib.parse.urlencode(params).encode()
    request = urllib.request.Request(
        url,
        data=data,
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def call_with_backoff(
    operation: Callable[[], dict],
    *,
    config: RetryConfig = RetryConfig(),
    retry_exceptions: tuple[type[BaseException], ...] = (URLError, TimeoutError),
    sleep_fn: Callable[[float], None] = _time.sleep,
    random_fn: Callable[[], float] = _random.random,
) -> dict:
    """Run an operation with bounded exponential backoff and bounded jitter.

    Non-retry exceptions are propagated immediately.
    """

    attempts = 0
    while True:
        try:
            return operation()
        except retry_exceptions as exc:
            attempts += 1
            if attempts >= config.max_attempts:
                raise TelegramTransientError(
                    f"telegram request failed after {attempts} attempts"
                ) from exc

            delay = min(config.base_delay * (2 ** (attempts - 1)), config.max_delay)
            if config.jitter:
                span = delay * config.jitter
                delay = max(0.0, delay - span + (2 * span * random_fn()))
            sleep_fn(delay)


def drain_outbox(
    outbox_path: Path,
    offset_path: Path,
    sender: Callable[[str], dict],
    *,
    chunk_size: int = 3900,
    config: RetryConfig = RetryConfig(),
    sleep_fn: Callable[[float], None] = _time.sleep,
    random_fn: Callable[[], float] = _random.random,
) -> int:
    """Drain `outbox_path` from a persisted byte offset with at-least-once send.

    Returns the new offset after a successful full drain.
    """

    outbox_data = outbox_path.read_text(encoding="utf-8", errors="replace")
    size = len(outbox_data)

    # Reset offset if file was truncated between cycles.
    offset = read_offset(offset_path)
    if size < offset:
        offset = 0

    if size <= offset:
        return offset

    remaining = outbox_data[offset:]
    if not remaining.strip():
        write_offset_atomic(offset_path, size)
        return size

    sent_bytes = 0
    end = len(remaining)

    for start in range(0, end, chunk_size):
        chunk = remaining[start : min(start + chunk_size, end)]
        if not chunk:
            continue

        call_with_backoff(
            lambda c=chunk: validate_telegram_ok(sender(c), "sendMessage"),
            config=config,
            sleep_fn=sleep_fn,
            random_fn=random_fn,
        )
        sent_bytes += len(chunk)

    # Write checkpoint only after all chunks are sent.
    new_offset = offset + sent_bytes
    write_offset_atomic(offset_path, new_offset)
    return new_offset


def drain_updates(
    api_request: Callable[[], tuple[int, list[dict]]] | None = None,
    *,
    offset_file: Path,
    api_getter: Callable[[int], object] = lambda _offset: None,
    on_update: Callable[[dict], None] = lambda _update: None,
    initial_offset: int = 0,
) -> int:
    """Minimal helper for polling updates with durable offsets.

    The function is intentionally generic: callers provide their own API getter and
    update handler.
    """

    offset = read_offset(offset_file)
    if offset < 0:
        offset = 0
    if initial_offset > 0:
        offset = max(offset, initial_offset)

    payload = api_getter(offset)
    if not isinstance(payload, dict):
        raise TelegramResponseError("telegram updates API returned non-dict payload")

    if payload.get("ok") is not True:
        raise TelegramResponseError("telegram updates API returned ok=false")

    for update in payload.get("result", []):
        if not isinstance(update, dict):
            continue
        offset = max(offset, int(update.get("update_id", 0)) + 1)
        on_update(update)

    if api_request is not None:
        api_request()
    write_offset_atomic(offset_file, offset)
    return offset
