#!/usr/bin/env python3
"""fm-route-domain.py - route incoming task or message to a secondmate domain using Jev.

Usage:
  fm-route-domain.py [--task <text>] [--brief <file>] [--registry <file>] [--json]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path

TS_BASE = os.environ.get("FM_JEV_TS_BASE", "https://api.typesafe.ai")
TS_MODEL = os.environ.get("FM_JEV_TS_MODEL", "jev-latest")
TS_TIMEOUT = float(os.environ.get("FM_JEV_TS_TIMEOUT", "5.0"))
# One floor for both Jev signals: a route below it (or non-finite) is handled
# direct, never dispatched; a noul at or above it charters a new secondmate.
SIGNAL_FLOOR = 0.7
BUILTIN_ROUTES = ("new_domain", "captain_direct")

# The registry format has one owner, secondmate_registry_parse_line in
# bin/fm-secondmate-registry-lib.sh. Call it rather than re-expressing its
# regexes here, so the two cannot drift apart as they already did once.
REGISTRY_PARSE_SH = (
    'source "$1" || exit 1\n'
    "while IFS= read -r line || [ -n \"$line\" ]; do\n"
    "  secondmate_registry_parse_line \"$line\" || continue\n"
    '  printf \'%s\\t%s\\t%s\\n\' '
    '"$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SCOPE"\n'
    "done\n"
)


def get_api_key(fm_root: Path) -> str | None:
    # 1. Environment
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key

    # 2. The home's .env, read with the same accessor as fm-dispatch-resolve.sh
    env_lib = Path(__file__).resolve().parent / "fm-env-lib.sh"
    try:
        res = subprocess.run(
            ["bash", "-c", 'source "$1" && fmx_env_get TYPESAFE_API_KEY "$2"', "_",
             str(env_lib), str(fm_root / ".env")],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        key = res.stdout.strip() if res.returncode == 0 else ""
        if key:
            return key
    except Exception:
        pass

    return None


class NeverSendUnreadable(Exception):
    pass


def load_never_send(config_dir: Path) -> list[str]:
    path = config_dir / "dispatch-never-send"
    if not path.exists() and not path.is_symlink():
        return []
    if not path.is_file() or not os.access(path, os.R_OK):
        raise NeverSendUnreadable(f"{path} is not a readable regular file")
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise NeverSendUnreadable(f"could not read {path}: {exc}") from exc
    values = []
    for line in lines:
        value = " ".join(line.split())
        if value and not value.startswith("#"):
            values.append(value)
    return values


def withhold(text: str, never_send: list[str]) -> str:
    text = " ".join(text.split())
    spans = []
    for value in sorted(never_send, key=len, reverse=True):
        for m in re.finditer(f"(?=({re.escape(value)}))", text, flags=re.IGNORECASE):
            spans.append((m.start(1), m.end(1)))
    merged: list[list[int]] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    for start, end in reversed(merged):
        text = text[:start] + "[withheld]" + text[end:]
    return text


def live_secondmate(state_dir: Path, sm_id: str) -> bool:
    # fm-send.sh resolves a task id only through its state/<id>.meta record.
    try:
        meta = (state_dir / f"{sm_id}.meta").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return "kind=secondmate" in meta.splitlines()


def parse_registry_lines(reg_path: Path) -> list[tuple[str, str, str]]:
    """Parse the registry through its canonical owner, returning (id, home, scope)."""
    lib = Path(__file__).resolve().parent / "fm-secondmate-registry-lib.sh"
    if not lib.is_file():
        return []
    try:
        proc = subprocess.run(
            ["bash", "-c", REGISTRY_PARSE_SH, "_", str(lib)],
            input=reg_path.read_text(encoding="utf-8", errors="replace"),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    rows = []
    for out_line in proc.stdout.splitlines():
        parts = out_line.split("\t")
        if len(parts) == 3:
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def parse_registry(reg_path: Path, state_dir: Path) -> dict[str, str]:
    if not reg_path.is_file():
        return {}
    criteria = {}
    for sm_id, home, scope in parse_registry_lines(reg_path):
        if home.strip() and scope.strip() and live_secondmate(state_dir, sm_id):
            criteria[sm_id] = " ".join(scope.split())
    if not criteria:
        return {}

    criteria["new_domain"] = (
        "No existing second mate covers this domain; requires creating a new dedicated second mate."
    )
    criteria["captain_direct"] = (
        "A personal note, direct conversation, question, or directive specifically for the Captain."
    )
    return criteria


def shell_word(value: str) -> str:
    if not any(c < " " or c == "\x7f" for c in value):
        return shlex.quote(value)
    body = "".join(
        f"\\x{ord(c):02x}" if c < " " or c == "\x7f" else "\\" + c if c in "\\'" else c
        for c in value
    )
    return f"$'{body}'"


def emit_result(
    action: str,
    route: str,
    confidence: float | None = None,
    noul: float | None = None,
    probabilities: dict[str, float] | None = None,
    reason: str | None = None,
    task_text: str = "",
    fm_root: Path | None = None,
    as_json: bool = False,
    exit_code: int = 0,
) -> None:
    if as_json:
        payload = {
            "action": action,
            "route": route,
            "confidence": confidence,
            "needs_new_noul": noul,
            "probabilities": probabilities or {},
            "reason": reason,
        }
        if action == "dispatch":
            payload["dispatch_message"] = task_text
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    print(f"action={action}")
    print(f"route={route}")
    if confidence is not None:
        print(f"confidence={confidence:.3f}")
    if noul is not None:
        print(f"needs_new_noul={noul:.3f}")
    if reason:
        print(f"reason={reason}")
    if action == "dispatch" and fm_root is not None:
        home = fm_root.resolve()
        argv = [str(home / "bin" / "fm-send.sh"), route, task_text]
        print(f"dispatch_cmd=FM_HOME={shell_word(str(home))} {' '.join(map(shell_word, argv))}")
    sys.exit(exit_code)


def main() -> None:
    parser = argparse.ArgumentParser(description="Route task to secondmate via Jev System One")
    parser.add_argument("--task", type=str, help="Task text to classify")
    parser.add_argument("--brief", type=Path, help="Path to brief file")
    parser.add_argument("--registry", type=Path, help="Path to secondmates.md")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME") or Path(__file__).resolve().parent.parent)
    reg_path = args.registry or (fm_root / "data" / "secondmates.md")
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE") or fm_root / "state")
    config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE") or fm_root / "config")

    task_text = ""
    if args.task is not None:
        task_text = args.task
    elif args.brief is not None:
        if not args.brief.is_file():
            parser.error(f"brief file not found: {args.brief}")
        task_text = args.brief.read_text(encoding="utf-8", errors="replace")
    elif not sys.stdin.isatty():
        task_text = sys.stdin.read()

    task_text = task_text.strip()
    if not task_text:
        emit_result("unavailable", "captain_direct", reason="empty task input", as_json=args.json)

    key = get_api_key(fm_root)
    if not key:
        emit_result(
            "unavailable",
            "captain_direct",
            reason="TYPESAFE_API_KEY unavailable",
            task_text=task_text,
            as_json=args.json,
        )

    criteria = parse_registry(reg_path, state_dir)
    if not criteria:
        emit_result(
            "unavailable",
            "captain_direct",
            reason="no live secondmate in the registry",
            task_text=task_text,
            as_json=args.json,
        )

    try:
        never_send = load_never_send(config_dir)
    except NeverSendUnreadable as exc:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"{exc}; nothing sent",
            task_text=task_text,
            as_json=args.json,
        )

    withheld_ids = [k for k in criteria if k not in BUILTIN_ROUTES and withhold(k, never_send) != k]
    if withheld_ids:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"secondmate id {', '.join(withheld_ids)} matches the never-send list; nothing sent",
            task_text=task_text,
            as_json=args.json,
        )

    clean_task = withhold(task_text, never_send)[:500]
    payload = {
        "model": TS_MODEL,
        "state": {"task": clean_task},
        "questions": {
            "route": {
                "type": "choice",
                "instructions": "Which second mate domain should handle this incoming task or message?",
                "criteria": {k: withhold(v, never_send)[:140] for k, v in criteria.items()},
            },
            "needs_new_secondmate": {
                "type": "noul",
                "instructions": "Is this task clearly outside all existing second mate domains, requiring the creation of a new dedicated second mate?",
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            body = resp.read().decode("utf-8")
            data = json.loads(body)
    except Exception as exc:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"Jev API call failed: {exc}",
            task_text=task_text,
            as_json=args.json,
        )

    try:
        answers = data.get("answers", {})
        route_ans = answers.get("route", {})
        choice = route_ans.get("choice")
        confidence = float(route_ans.get("confidence", 0.0))
        probs = route_ans.get("probabilities", {})

        noul_ans = answers.get("needs_new_secondmate", {})
        noul_val = float(noul_ans.get("noul", 0.0))
    except (AttributeError, TypeError, ValueError) as exc:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"Jev returned a malformed response: {exc}",
            task_text=task_text,
            as_json=args.json,
        )

    if not isinstance(choice, str) or choice not in criteria:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"Jev returned an unknown route: {choice}",
            task_text=task_text,
            as_json=args.json,
        )

    reason = None
    if not (math.isfinite(confidence) and math.isfinite(noul_val)):
        action = "handle_direct"
        reason = f"Jev returned a non-finite signal for {choice}"
        choice = "captain_direct"
        confidence = noul_val = None
    elif choice == "captain_direct":
        action = "handle_direct"
    elif noul_val >= SIGNAL_FLOOR:
        action = "create_secondmate"
        choice = "new_domain"
    elif not confidence >= SIGNAL_FLOOR:
        action = "handle_direct"
        reason = f"route confidence {confidence:.3f} below {SIGNAL_FLOOR} for {choice}"
        choice = "captain_direct"
    elif choice == "new_domain":
        action = "create_secondmate"
    else:
        action = "dispatch"

    emit_result(
        action=action,
        route=choice,
        confidence=confidence,
        noul=noul_val,
        probabilities=probs,
        reason=reason,
        task_text=task_text,
        fm_root=fm_root,
        as_json=args.json,
    )


if __name__ == "__main__":
    main()
