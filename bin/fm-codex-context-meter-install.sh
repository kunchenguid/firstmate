#!/usr/bin/env bash
# fm-codex-context-meter-install.sh - install or remove the global Codex meter.
#
# Usage:
#   fm-codex-context-meter-install.sh install
#   fm-codex-context-meter-install.sh uninstall
#
# The installer merges four command hooks into $CODEX_HOME/hooks.json, adds the
# exact Codex footer fields to $CODEX_HOME/config.toml, and adds a $context row
# to Herdr's Codex-specific agent rows. Existing JSON/TOML is parsed before and
# after every edit. A private ownership receipt makes a byte-exact uninstall
# possible while the files are unchanged and limits drifted-file cleanup to
# values this installer actually added.
#
# HERDR_CONFIG_PATH overrides the default Herdr config path. The command never
# installs Herdr's official Codex integration and never reloads a live server.
set -u

case "${1:-}" in
  install|uninstall) ACTION=$1 ;;
  -h|--help)
    sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|uninstall\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-codex-context-meter-install: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-codex-context-meter-install: refused: python3 with tomllib is required.\n' >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="$ROOT/bin/fm-codex-context-meter.sh"
CODEX_DIR=${CODEX_HOME:-$HOME/.codex}
HERDR_CONFIG=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}

python3 - "$ACTION" "$CODEX_DIR" "$HERDR_CONFIG" "$HANDLER" <<'PY'
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import re
import shlex
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print(
        "fm-codex-context-meter-install: refused: python3 with tomllib is required.",
        file=sys.stderr,
    )
    raise SystemExit(1)

ACTION, CODEX_DIR, HERDR_CONFIG, HANDLER = sys.argv[1:]
HOOKS = os.path.join(CODEX_DIR, "hooks.json")
CODEX_CONFIG = os.path.join(CODEX_DIR, "config.toml")
STATE = os.path.join(CODEX_DIR, ".firstmate-codex-context-meter.json")
EVENTS = ("SessionStart", "PostToolUse", "PostCompact", "Stop")
STATUS_ITEMS = ("context-used", "context-window-size", "used-tokens")
CONTEXT_ROW = ["$context"]
DEFAULT_AGENT_ROWS = [["state_icon", "workspace", "tab"], ["agent"]]


class Refusal(Exception):
    pass


def refuse(reason: str) -> None:
    raise Refusal(reason)


def ensure_parent(path: str) -> None:
    parent = os.path.dirname(path)
    if os.path.lexists(parent):
        info = os.lstat(parent)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"config parent is not a regular directory: {parent}")
    else:
        os.makedirs(parent, mode=0o700)


def read_file(path: str) -> tuple[bool, bytes, int]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False, b"", 0o600
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"config path is not a regular non-symlink file: {path}")
    with open(path, "rb") as stream:
        return True, stream.read(), stat.S_IMODE(info.st_mode)


def atomic_write(path: str, data: bytes, mode: int) -> None:
    ensure_parent(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def snapshot(exists: bool, data: bytes, mode: int) -> dict:
    return {
        "exists": exists,
        "mode": mode,
        "data": base64.b64encode(data).decode("ascii"),
    }


def snapshot_bytes(record: dict) -> bytes:
    return base64.b64decode(record["data"], validate=True)


def parse_json(data: bytes, label: str) -> dict:
    if not data:
        return {}
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        refuse(f"{label} is malformed JSON: {error}")
    if not isinstance(value, dict):
        refuse(f"{label} root is not an object")
    return value


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def parse_toml(data: bytes, label: str) -> dict:
    if not data:
        return {}
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}")
    try:
        value = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        refuse(f"{label} is malformed TOML: {error}")
    if not isinstance(value, dict):
        refuse(f"{label} root is not a table")
    return value


def nested(value: dict, path: tuple[str, ...]):
    current = value
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def inline_toml(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(", ", ": "))


HEADER = re.compile(r"(?m)^[ \t]*\[(?!\[)([^\]\n]+)\][ \t]*(?:#.*)?$")


def table_bounds(text: str, table: str):
    matches = [match for match in HEADER.finditer(text) if match.group(1).replace(" ", "") == table]
    if len(matches) > 1:
        refuse(f"TOML repeats [{table}] in an unsupported form")
    if not matches:
        return None
    match = matches[0]
    next_match = HEADER.search(text, match.end())
    return match.start(), match.end(), next_match.start() if next_match else len(text)


def array_end(text: str, start: int) -> int:
    if start >= len(text) or text[start] != "[":
        refuse("owned TOML value is not an array")
    depth = 0
    quote = None
    escaped = False
    comment = False
    for index in range(start, len(text)):
        char = text[index]
        if comment:
            if char == "\n":
                comment = False
            continue
        if quote is not None:
            if quote == '"' and escaped:
                escaped = False
            elif quote == '"' and char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "#":
            comment = True
        elif char in ('"', "'"):
            quote = char
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return index + 1
    refuse("owned TOML array is unterminated")


def find_assignment(text: str, table: str, key: str, dotted: str | None = None):
    candidates = []
    bounds = table_bounds(text, table)
    if bounds:
        _, body_start, body_end = bounds
        pattern = re.compile(rf"(?m)^[ \t]*{re.escape(key)}[ \t]*=")
        candidates.extend(pattern.finditer(text, body_start, body_end))
    if dotted:
        first_table = HEADER.search(text)
        root_end = first_table.start() if first_table else len(text)
        pattern = re.compile(rf"(?m)^[ \t]*{re.escape(dotted)}[ \t]*=")
        candidates.extend(pattern.finditer(text, 0, root_end))
    if len(candidates) > 1:
        refuse(f"TOML has multiple assignments for {dotted or table + '.' + key}")
    if not candidates:
        return None
    match = candidates[0]
    equals = text.find("=", match.start(), match.end())
    value_start = equals + 1
    while value_start < len(text) and text[value_start] in " \t":
        value_start += 1
    value_end = array_end(text, value_start)
    line_start = text.rfind("\n", 0, match.start()) + 1
    line_end = text.find("\n", value_end)
    if line_end < 0:
        line_end = len(text)
    else:
        line_end += 1
    trailing = text[value_end:line_end].strip()
    if trailing and not trailing.startswith("#"):
        refuse(f"TOML has unsupported content after {dotted or key}")
    return line_start, line_end, value_start, value_end


def set_array(text: str, table: str, key: str, dotted: str | None, value) -> tuple[str, bool]:
    location = find_assignment(text, table, key, dotted)
    encoded = inline_toml(value)
    if location:
        return text[: location[2]] + encoded + text[location[3] :], False
    bounds = table_bounds(text, table)
    assignment = f"{key} = {encoded}\n"
    if bounds:
        insert = bounds[1]
        if insert < len(text) and text[insert] == "\n":
            insert += 1
        return text[:insert] + assignment + text[insert:], True
    prefix = text
    if prefix and not prefix.endswith("\n"):
        prefix += "\n"
    if prefix and not prefix.endswith("\n\n"):
        prefix += "\n"
    return prefix + f"[{table}]\n{assignment}", True


def remove_array(text: str, table: str, key: str, dotted: str | None) -> str:
    location = find_assignment(text, table, key, dotted)
    if not location:
        return text
    return text[: location[0]] + text[location[1] :]


def owned_handler(value) -> bool:
    return (
        isinstance(value, dict)
        and value.get("type") == "command"
        and "fm-codex-context-meter.sh" in str(value.get("command", ""))
    )


def clean_owned_hooks(document: dict) -> dict:
    result = copy.deepcopy(document)
    hooks = result.get("hooks")
    if hooks is None:
        return result
    if not isinstance(hooks, dict):
        refuse("hooks.json has a non-object hooks value")
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            refuse(f"hooks.json event {event} is not an array")
        cleaned = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                refuse(f"hooks.json event {event} has an invalid matcher group")
            candidate = copy.deepcopy(group)
            candidate["hooks"] = [entry for entry in candidate["hooks"] if not owned_handler(entry)]
            if candidate["hooks"] or set(candidate) != {"hooks"}:
                cleaned.append(candidate)
        if cleaned:
            hooks[event] = cleaned
        else:
            del hooks[event]
    if not hooks:
        result.pop("hooks", None)
    return result


def install_hooks(document: dict) -> dict:
    result = clean_owned_hooks(document)
    hooks = result.setdefault("hooks", {})
    command = shlex.quote(os.path.realpath(HANDLER))
    handler = {
        "type": "command",
        "command": command,
        "timeout": 2,
    }
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            refuse(f"hooks.json event {event} is not an array")
        groups.append({"hooks": [copy.deepcopy(handler)]})
    return result


def restore_or_write(path: str, candidate: bytes | None, mode: int) -> None:
    if candidate is None:
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            refuse(f"refusing to remove unexpected path: {path}")
        os.unlink(path)
    else:
        atomic_write(path, candidate, mode)


def exact_restore(current: bytes, record: dict):
    if digest(current) != record.get("after_sha256"):
        return None, False
    if record["before"]["exists"]:
        return snapshot_bytes(record["before"]), True
    return None, True


try:
    if ACTION == "install" and (not os.path.isfile(HANDLER) or not os.access(HANDLER, os.X_OK)):
        refuse(f"hook handler is missing or not executable: {HANDLER}")

    hooks_exists, hooks_original, hooks_mode = read_file(HOOKS)
    codex_exists, codex_original, codex_mode = read_file(CODEX_CONFIG)
    herdr_exists, herdr_original, herdr_mode = read_file(HERDR_CONFIG)
    state_exists, state_original, state_mode = read_file(STATE)

    hooks_doc = parse_json(hooks_original, "Codex hooks.json")
    codex_doc = parse_toml(codex_original, "Codex config.toml")
    herdr_doc = parse_toml(herdr_original, "Herdr config.toml")

    if state_exists:
        state_doc = parse_json(state_original, "Firstmate ownership receipt")
        if state_doc.get("version") != 1:
            refuse("Firstmate ownership receipt has an unsupported version")
    else:
        state_doc = None

    if ACTION == "install":
        if state_doc is None:
            for event_groups in hooks_doc.get("hooks", {}).values():
                if isinstance(event_groups, list) and any(
                    owned_handler(entry)
                    for group in event_groups
                    if isinstance(group, dict)
                    for entry in group.get("hooks", [])
                ):
                    refuse("owned hooks exist without a Firstmate ownership receipt")

        updated_hooks_doc = install_hooks(hooks_doc)
        hooks_candidate = json_bytes(updated_hooks_doc)

        tui = codex_doc.get("tui", {})
        if tui is not None and not isinstance(tui, dict):
            refuse("Codex config.toml has a non-table tui value")
        current_status = tui.get("status_line") if isinstance(tui, dict) else None
        if current_status is not None and (
            not isinstance(current_status, list) or not all(isinstance(item, str) for item in current_status)
        ):
            refuse("Codex tui.status_line is not a string array")
        current_status = list(current_status or [])
        added_status = [item for item in STATUS_ITEMS if item not in current_status]
        installed_status = current_status + added_status
        codex_text = codex_original.decode("utf-8") if codex_original else ""
        codex_text, codex_created = set_array(
            codex_text, "tui", "status_line", "tui.status_line", installed_status
        )
        codex_candidate = codex_text.encode()
        parse_toml(codex_candidate, "updated Codex config.toml")

        global_rows = nested(herdr_doc, ("ui", "sidebar", "agents", "rows"))
        if global_rows is None:
            global_rows = copy.deepcopy(DEFAULT_AGENT_ROWS)
        if not isinstance(global_rows, list) or not all(isinstance(row, list) for row in global_rows):
            refuse("Herdr ui.sidebar.agents.rows is not an array of rows")
        codex_rows = nested(
            herdr_doc, ("ui", "sidebar", "agents", "rows_by_agent", "codex")
        )
        if codex_rows is not None and (
            not isinstance(codex_rows, list) or not all(isinstance(row, list) for row in codex_rows)
        ):
            refuse("Herdr rows_by_agent.codex is not an array of rows")
        herdr_created_codex = codex_rows is None
        installed_rows = copy.deepcopy(global_rows if codex_rows is None else codex_rows)
        context_present = any("$context" in row for row in installed_rows)
        herdr_added = not context_present
        if herdr_added:
            installed_rows.append(copy.deepcopy(CONTEXT_ROW))
        herdr_text = herdr_original.decode("utf-8") if herdr_original else ""
        herdr_text, _ = set_array(
            herdr_text,
            "ui.sidebar.agents.rows_by_agent",
            "codex",
            "ui.sidebar.agents.rows_by_agent.codex",
            installed_rows,
        )
        herdr_candidate = herdr_text.encode()
        parse_toml(herdr_candidate, "updated Herdr config.toml")

        if state_doc is None:
            state_doc = {
                "version": 1,
                "files": {
                    "hooks": {"before": snapshot(hooks_exists, hooks_original, hooks_mode)},
                    "codex": {"before": snapshot(codex_exists, codex_original, codex_mode)},
                    "herdr": {"before": snapshot(herdr_exists, herdr_original, herdr_mode)},
                },
                "codex_added": added_status,
                "codex_created": codex_created,
                "herdr_added": herdr_added,
                "herdr_created_codex": herdr_created_codex,
                "herdr_installed_base": copy.deepcopy(global_rows if herdr_created_codex else codex_rows),
            }
        else:
            state_doc["codex_added"] = list(dict.fromkeys(state_doc.get("codex_added", []) + added_status))
            state_doc["herdr_added"] = bool(state_doc.get("herdr_added")) or herdr_added

        state_doc["files"]["hooks"]["after_sha256"] = digest(hooks_candidate)
        state_doc["files"]["codex"]["after_sha256"] = digest(codex_candidate)
        state_doc["files"]["herdr"]["after_sha256"] = digest(herdr_candidate)
        state_candidate = json_bytes(state_doc)

        if hooks_candidate != hooks_original:
            atomic_write(HOOKS, hooks_candidate, hooks_mode)
        if codex_candidate != codex_original:
            atomic_write(CODEX_CONFIG, codex_candidate, codex_mode)
        if herdr_candidate != herdr_original:
            atomic_write(HERDR_CONFIG, herdr_candidate, herdr_mode)
        if state_candidate != state_original:
            atomic_write(STATE, state_candidate, 0o600)
        print("Codex context meter installed; restart Codex and reload or restart Herdr.")
    else:
        if state_doc is None:
            refuse("Firstmate ownership receipt is missing; nothing was removed")

        hooks_candidate, hooks_exact = exact_restore(hooks_original, state_doc["files"]["hooks"])
        if not hooks_exact:
            hooks_candidate = json_bytes(clean_owned_hooks(hooks_doc))

        codex_candidate, codex_exact = exact_restore(codex_original, state_doc["files"]["codex"])
        if not codex_exact:
            current_status = nested(codex_doc, ("tui", "status_line"))
            if isinstance(current_status, list) and all(isinstance(item, str) for item in current_status):
                remaining = list(current_status)
                for item in state_doc.get("codex_added", []):
                    if item in remaining:
                        remaining.remove(item)
                text = codex_original.decode("utf-8")
                if state_doc.get("codex_created") and not remaining:
                    text = remove_array(text, "tui", "status_line", "tui.status_line")
                else:
                    text, _ = set_array(text, "tui", "status_line", "tui.status_line", remaining)
                codex_candidate = text.encode()
                parse_toml(codex_candidate, "Codex config.toml after uninstall")
            else:
                codex_candidate = codex_original

        herdr_candidate, herdr_exact = exact_restore(herdr_original, state_doc["files"]["herdr"])
        if not herdr_exact:
            current_rows = nested(
                herdr_doc, ("ui", "sidebar", "agents", "rows_by_agent", "codex")
            )
            if isinstance(current_rows, list):
                remaining_rows = copy.deepcopy(current_rows)
                if state_doc.get("herdr_added") and CONTEXT_ROW in remaining_rows:
                    remaining_rows.remove(CONTEXT_ROW)
                text = herdr_original.decode("utf-8")
                if (
                    state_doc.get("herdr_created_codex")
                    and remaining_rows == state_doc.get("herdr_installed_base")
                ):
                    text = remove_array(
                        text,
                        "ui.sidebar.agents.rows_by_agent",
                        "codex",
                        "ui.sidebar.agents.rows_by_agent.codex",
                    )
                else:
                    text, _ = set_array(
                        text,
                        "ui.sidebar.agents.rows_by_agent",
                        "codex",
                        "ui.sidebar.agents.rows_by_agent.codex",
                        remaining_rows,
                    )
                herdr_candidate = text.encode()
                parse_toml(herdr_candidate, "Herdr config.toml after uninstall")
            else:
                herdr_candidate = herdr_original

        restore_or_write(
            HOOKS,
            hooks_candidate,
            state_doc["files"]["hooks"]["before"]["mode"] if hooks_exact else hooks_mode,
        )
        restore_or_write(
            CODEX_CONFIG,
            codex_candidate,
            state_doc["files"]["codex"]["before"]["mode"] if codex_exact else codex_mode,
        )
        restore_or_write(
            HERDR_CONFIG,
            herdr_candidate,
            state_doc["files"]["herdr"]["before"]["mode"] if herdr_exact else herdr_mode,
        )
        os.unlink(STATE)
        print("Codex context meter uninstalled; restart Codex and reload or restart Herdr.")
except (OSError, KeyError, ValueError, Refusal) as error:
    print(f"fm-codex-context-meter-install: refused: {error}.", file=sys.stderr)
    raise SystemExit(1)
PY
