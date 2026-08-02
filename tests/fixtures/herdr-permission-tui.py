#!/usr/bin/env python3
"""Deterministic permission-modal TUI exposed through a minimal Herdr CLI."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


STATE_PATH = Path(os.environ["FM_PERMISSION_TUI_STATE"])
EXPECTED_SESSION = os.environ.get("FM_PERMISSION_TUI_SESSION", "permission-stub")
PANE_ID = "w1:p1"


def read_state() -> dict[str, Any]:
    return json.loads(STATE_PATH.read_text(encoding="utf-8"))


def write_state(state: dict[str, Any]) -> None:
    candidate = STATE_PATH.with_suffix(".candidate")
    candidate.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(candidate, STATE_PATH)


def initialize(mode: str) -> None:
    if mode not in {"composer", "malformed", "modal", "pending", "unreadable"}:
        raise SystemExit(f"unsupported stub mode: {mode}")
    composer_text = "existing unsent input" if mode == "pending" else ""
    stored_mode = "composer" if mode == "pending" else mode
    write_state(
        {
            "approved": False,
            "composer_text": composer_text,
            "events": [],
            "mode": stored_mode,
            "turn_started": False,
        }
    )


def agent_status(state: dict[str, Any]) -> str:
    if state["mode"] == "modal":
        return "blocked"
    if state["turn_started"]:
        return "working"
    return "idle"


def render(state: dict[str, Any]) -> str:
    if state["mode"] == "modal":
        return "\n".join(
            [
                "Would you like to run the following command?",
                "  1. Yes, proceed",
                "  2. No, continue without running it",
                "Press enter to confirm or esc to cancel",
            ]
        )
    if state["mode"] == "malformed":
        return "corrupted screen without a recognizable composer row"
    text = state["composer_text"]
    return f"› {text}" if text else "›"


def send_text(text: str) -> None:
    state = read_state()
    state["events"].append({"event": "text", "value": text})
    state["composer_text"] += text
    write_state(state)


def send_key(key: str) -> None:
    state = read_state()
    normalized = key.lower()
    state["events"].append({"event": "key", "value": normalized})
    if normalized == "enter" and state["mode"] == "modal":
        state["approved"] = True
        state["events"].append({"event": "modal-approved"})
        state["mode"] = "composer"
    elif normalized == "enter" and state["composer_text"]:
        state["events"].append({"event": "turn-started"})
        state["composer_text"] = ""
        state["turn_started"] = True
    write_state(state)


def strip_session(arguments: list[str]) -> list[str]:
    if len(arguments) < 2 or arguments[-2] != "--session":
        raise SystemExit("stub refused a Herdr call without a trailing --session")
    if arguments[-1] != EXPECTED_SESSION:
        raise SystemExit(f"stub refused foreign Herdr session: {arguments[-1]}")
    return arguments[:-2]


def emit_json(value: dict[str, Any]) -> None:
    print(json.dumps(value, separators=(",", ":")))


def run_herdr(arguments: list[str]) -> None:
    args = strip_session(arguments)
    if args[:2] == ["status", "--json"]:
        emit_json(
            {
                "client": {"protocol": 16, "version": "permission-tui-stub"},
                "server": {"running": True},
            }
        )
        return
    if args[:2] == ["pane", "get"] and args[2:3] == [PANE_ID]:
        emit_json({"result": {"pane": {"pane_id": PANE_ID}}})
        return
    if args[:2] == ["agent", "get"] and args[2:3] == [PANE_ID]:
        emit_json({"result": {"agent": {"agent_status": agent_status(read_state())}}})
        return
    if args[:2] == ["pane", "read"] and args[2:3] == [PANE_ID]:
        state = read_state()
        if state["mode"] == "unreadable":
            raise SystemExit(74)
        print(render(state))
        return
    if args[:2] == ["pane", "send-text"] and args[2:3] == [PANE_ID] and len(args) == 4:
        send_text(args[3])
        emit_json({"result": {"sent": True}})
        return
    if args[:2] == ["pane", "send-keys"] and args[2:3] == [PANE_ID] and len(args) == 4:
        send_key(args[3])
        emit_json({"result": {"sent": True}})
        return
    raise SystemExit(f"unsupported Herdr stub call: {args!r}")


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["stub-init"] and len(args) == 2:
        initialize(args[1])
        return
    if args == ["stub-snapshot"]:
        emit_json(read_state())
        return
    run_herdr(args)


if __name__ == "__main__":
    main()
