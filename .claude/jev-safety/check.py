#!/usr/bin/env python3
"""Fail-closed local filter for content sent to TypeSafe Jev."""

from __future__ import annotations

import ast
import json
import os
import re
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
    ("data", "learnings.md"),
    ("data", "backlog.md"),
    ("pipelines", "health"),
    ("pipelines", "health-manager"),
    ("pipelines", "health-connect-sync"),
    ("pipelines", "finance"),
)
SENSITIVE_BASENAMES = frozenset(
    part for target in SENSITIVE_PATHS for part in target if "." in part
)
SENSITIVE_PATH_FRAGMENTS = tuple(
    sorted(
        SENSITIVE_BASENAMES
        | {target[0] for target in SENSITIVE_PATHS if len(target) == 1}
        | {"/".join(target) for target in SENSITIVE_PATHS if len(target) > 1},
        key=len,
        reverse=True,
    )
)
SENSITIVE_PATH_PATTERN = re.compile(
    rf"(?<![\w-])(?:{'|'.join(re.escape(fragment) for fragment in SENSITIVE_PATH_FRAGMENTS)})(?![\w-])",
    re.IGNORECASE,
)
HEALTH_DATA = re.compile(
    r"\b(?:diagnos(?:ed|is)|symptoms?|medical history|health condition|"
    r"patient|prescri(?:bed|ption)|medication|insulin|diabetes|asthma|cancer|"
    r"epilepsy|hiv|pregnan(?:t|cy)|hypertension|depression|anxiety|bipolar|"
    r"arthritis|migraine|allerg(?:y|ies)|fever|nausea|chest pain|shortness of breath)\b",
    re.IGNORECASE,
)


def _path_parts(candidate: str) -> tuple[str, ...]:
    """Normalize a path-like token without resolving or accessing the path."""
    cleaned = candidate.strip(" \t\r\n\"'`([{<,;:=")
    cleaned = cleaned.rstrip(" \t\r\n\"'`)]}>.,;:")
    return tuple(part.casefold() for part in PurePosixPath(cleaned.replace("\\", "/")).parts)


def _is_sensitive_path(candidate: str) -> bool:
    parts = _path_parts(candidate)
    normalized = candidate.casefold().replace("\\", "/")
    return (
        any(part.endswith(".env") for part in parts)
        or SENSITIVE_PATH_PATTERN.search(normalized) is not None
    )


def _is_sensitive_basename(candidate: str) -> bool:
    parts = _path_parts(candidate)
    return len(parts) == 1 and parts[0] in SENSITIVE_BASENAMES


def _constant_string(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = _constant_string(node.left)
        right = _constant_string(node.right)
        if left is not None and right is not None:
            return left + right
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "join"
        and len(node.args) == 1
        and isinstance(node.args[0], (ast.List, ast.Tuple))
    ):
        separator = _constant_string(node.func.value)
        parts = [_constant_string(part) for part in node.args[0].elts]
        if separator is not None and all(part is not None for part in parts):
            return separator.join(part for part in parts if part is not None)
    return None


def _python_inline_has_sensitive_path(command: str) -> bool:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return True
    for index, token in enumerate(tokens[:-2]):
        if Path(token).name not in {"python", "python3"} or tokens[index + 1] != "-c":
            continue
        try:
            tree = ast.parse(tokens[index + 2])
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.BinOp, ast.Constant)):
                candidate = _constant_string(node)
                if candidate is not None and _is_sensitive_path(candidate):
                    return True
    return False


def _bash_command_has_sensitive_path(command: JsonValue) -> bool:
    match command:
        case str() as text:
            if _python_inline_has_sensitive_path(text):
                return True
            tokens = (
                text.replace(">", " ")
                .replace("<", " ")
                .replace("&&", " && ")
                .replace("||", " || ")
                .replace(";", " ; ")
                .replace("|", " | ")
                .split()
            )
            separators = {"&&", "||", ";", "|", "&"}
            for index, token in enumerate(tokens):
                command_name = token.strip("\"'`;,()")
                if command_name not in {"cd", "pushd", "popd"}:
                    continue
                if index and tokens[index - 1] not in separators:
                    continue
                if command_name == "popd":
                    return True
                target_index = index + 1
                while target_index < len(tokens) and tokens[target_index] in {"-L", "-P", "--"}:
                    target_index += 1
                if target_index >= len(tokens) or tokens[target_index] in separators:
                    return True
                target = tokens[target_index].strip("\"'`")
                if (
                    any(char in target for char in "$`*?[()")
                    or "~" in target
                    or target == "-"
                    or ".." in PurePosixPath(target.replace("\\", "/")).parts
                ):
                    return True
                if command_name == "pushd" and target[:1] in {"+", "-"}:
                    return True
                if _is_sensitive_path(target):
                    return True
            path_argument_commands = {".", "cat", "head", "less", "ls", "more", "source", "tail"}
            for index, token in enumerate(tokens):
                candidate = token.rsplit("=", 1)[-1]
                if candidate.startswith("-") and "/" not in candidate and "\\" not in candidate:
                    continue
                if "/" in candidate or "\\" in candidate:
                    if _is_sensitive_path(candidate):
                        return True
                elif _is_sensitive_basename(candidate):
                    return True
                elif candidate.casefold() in {"state", "config"}:
                    segment_start = index - 1
                    while segment_start >= 0 and tokens[segment_start] not in separators:
                        segment_start -= 1
                    command_index = segment_start + 1
                    if command_index < len(tokens):
                        command_name = tokens[command_index].strip("\"'`;,()")
                        if command_name in path_argument_commands:
                            return True
        case _:
            return False
    return False


def _contains_health_data(value: JsonValue) -> bool:
    match value:
        case dict() as mapping:
            return any(_contains_health_data(item) for item in mapping.values())
        case list() as items:
            return any(_contains_health_data(item) for item in items)
        case str() as text:
            return HEALTH_DATA.search(text) is not None
        case _:
            return False


def _contains_sensitive_path(
    value: JsonValue, parent_key: str = "", bash_tool: bool = False
) -> bool:
    """Check path metadata and path-shaped text before inspecting payload secrets."""
    match value:
        case dict() as mapping:
            is_bash = (
                bash_tool
                or mapping.get("tool") == "Bash"
                or mapping.get("tool_name") == "Bash"
            )
            return any(
                _bash_command_has_sensitive_path(child)
                if key.casefold() == "command" and is_bash
                else _contains_sensitive_path(child, key.casefold(), is_bash)
                for key, child in mapping.items()
                if key.casefold() != "command" or is_bash
            )
        case list() as items:
            return any(_contains_sensitive_path(item, parent_key, bash_tool) for item in items)
        case str() as text:
            if any(word in parent_key for word in ("path", "file", "cwd", "directory")):
                if _is_sensitive_path(text):
                    return True
            return any(
                _is_sensitive_path(token)
                if "/" in token or "\\" in token
                else _is_sensitive_basename(token)
                for token in text.split()
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
    if _contains_health_data(value):
        return {"allowed": False, "reason": "health_data"}
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
