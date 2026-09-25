#!/usr/bin/env python3
"""Fail-closed local filter for content sent to TypeSafe Jev."""

from __future__ import annotations

import json
import os
import shlex
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import TypeAlias

JsonScalar: TypeAlias = str | int | float | bool | None
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]

SENSITIVE_PATHS = (
    (".env",),
    ("state",),
    ("config",),
    ("data", "captain.md"),
    ("data", "captain-shared.md"),
    ("pipelines", "health"),
    ("pipelines", "health-manager"),
    ("pipelines", "health-connect-sync"),
    ("pipelines", "finance"),
)


def _path_parts(candidate: str) -> tuple[str, ...]:
    """Normalize a path-like token without resolving or accessing the path."""
    cleaned = candidate.strip(" \t\r\n\"'`([{<,;:=")
    cleaned = cleaned.rstrip(" \t\r\n\"'`)]}>.,;:")
    return tuple(part.casefold() for part in PurePosixPath(cleaned.replace("\\", "/")).parts)


def _is_sensitive_path(candidate: str) -> bool:
    """Match only named private roots and pipelines, not ordinary prose."""
    parts = _path_parts(candidate)
    for target in SENSITIVE_PATHS:
        width = len(target)
        if any(parts[index : index + width] == target for index in range(len(parts) - width + 1)):
            return True
    return any(part.endswith(".env") for part in parts)


def _contains_sensitive_path(value: JsonValue, parent_key: str = "") -> bool:
    """Check path metadata and path-shaped text before inspecting payload secrets."""
    match value:
        case dict() as mapping:
            return any(
                _contains_sensitive_path(child, key.casefold())
                for key, child in mapping.items()
            )
        case list() as items:
            return any(_contains_sensitive_path(item, parent_key) for item in items)
        case str() as text:
            if any(word in parent_key for word in ("path", "file", "cwd", "directory")):
                if _is_sensitive_path(text):
                    return True
            try:
                tokens = shlex.split(text, posix=True)
            except ValueError:
                tokens = text.split()
            return any(
                _is_sensitive_path(token)
                for token in tokens
                if "/" in token or "\\" in token or token.casefold().endswith(".env")
            )
        case _:
            return False


def _has_detected_secret(payload: str, scratch: Path) -> bool:
    """Run Yelp detect-secrets locally and return only a Boolean verdict."""
    from detect_secrets import SecretsCollection
    from detect_secrets.settings import default_settings

    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(scratch, 0o700)
    path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=scratch, prefix="jev-scan-", delete=False
        ) as source:
            os.chmod(source.name, 0o600)
            source.write(payload)
            path = Path(source.name)
        secrets = SecretsCollection()
        with default_settings():
            secrets.scan_file(str(path))
        return bool(secrets.data)
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


def check(raw: str, root: Path) -> dict[str, str | bool]:
    """Return an allow verdict, or a non-sensitive reason for skipping the call."""
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {"allowed": False, "reason": "invalid_payload"}
    if not isinstance(value, (dict, list, str, int, float, bool, type(None))):
        return {"allowed": False, "reason": "invalid_payload"}
    if _contains_sensitive_path(value):
        return {"allowed": False, "reason": "sensitive_path"}
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    try:
        if _has_detected_secret(payload, root / ".claude" / "jev-safety" / ".tmp"):
            return {"allowed": False, "reason": "secret"}
    except (ImportError, OSError, ValueError):
        return {"allowed": False, "reason": "scanner_unavailable"}
    return {"allowed": True, "reason": "clean"}


def main() -> int:
    """Read one JSON payload from stdin and emit a reason-only JSON verdict."""
    root = Path(__file__).resolve().parents[2]
    try:
        verdict = check(sys.stdin.read(), root)
    except (OSError, ValueError):
        verdict = {"allowed": False, "reason": "scanner_unavailable"}
    sys.stdout.write(json.dumps(verdict, separators=(",", ":")) + "\n")
    return 0 if verdict["allowed"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
