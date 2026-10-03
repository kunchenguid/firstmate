#!/usr/bin/env python3
"""Project current progress into the existing tasks-axi task body.

This helper owns only the small embedded progress block.  The tasks-axi
adapter remains the task-record owner and the shell boundary owns locking and
publication.  Reads never create a block and replacements emit the complete
new body on stdout for that owner's ordinary publication path.
"""

import argparse
import hashlib
import json
import re
import sys


START = "<!-- firstmate-progress:v1"
END = "<!-- /firstmate-progress -->"
FIELDS = ("acceptance", "current_state", "remaining_gap", "next_step")
MAX_FIELD_BYTES = 1200
BLOCK_RE = re.compile(
    rf"(?:^|\n){re.escape(START)}(?: context=(?P<context>[a-f0-9]{{64}})(?: identity=(?P<identity>[a-f0-9]{{64}}))?)? -->\n"
    r"acceptance: (?P<acceptance>[^\n]*)\n"
    r"current_state: (?P<current>[^\n]*)\n"
    r"remaining_gap: (?P<gap>[^\n]*)\n"
    r"next_step: (?P<next>[^\n]*)\n"
    rf"{re.escape(END)}(?=\n|$)"
)


class Refusal(Exception):
    pass


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def text(value: object, name: str, *, empty: bool = False) -> str:
    if not isinstance(value, str):
        raise Refusal(f"{name} must be text")
    if "\n" in value or "\r" in value or "\x00" in value:
        raise Refusal(f"{name} must be one line")
    value = value.strip()
    if not empty and not value:
        raise Refusal(f"{name} must not be empty")
    if len(value.encode()) > MAX_FIELD_BYTES:
        raise Refusal(f"{name} exceeds {MAX_FIELD_BYTES} bytes")
    return value


def parse(body: str) -> tuple[dict[str, str] | None, re.Match[str] | None, str | None, str | None]:
    matches = list(BLOCK_RE.finditer(body))
    if len(matches) > 1:
        raise Refusal("task body has duplicate Firstmate progress blocks")
    if not matches:
        if START in body or END in body:
            raise Refusal("task body has a malformed Firstmate progress block")
        return None, None, None, None
    match = matches[0]
    try:
        values = {
            "acceptance": json.loads(match.group("acceptance")),
            "current_state": json.loads(match.group("current")),
            "remaining_gap": json.loads(match.group("gap")),
            "next_step": json.loads(match.group("next")),
        }
    except json.JSONDecodeError as exc:
        raise Refusal("task body has an invalid Firstmate progress block") from exc
    values = {name: text(values[name], name, empty=name not in ("acceptance", "current_state")) for name in FIELDS}
    if bool(values["remaining_gap"]) != bool(values["next_step"]):
        raise Refusal("remaining_gap and next_step must both be empty or both be present")
    return values, match, match.group("context"), match.group("identity")


def identity_digest(context: str) -> str | None:
    try:
        value = json.loads(context)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, dict):
        return None
    stable = {name: value.get(name, "") for name in ("goal", "brief_sha256", "execution_generation")}
    return digest(json.dumps(stable, ensure_ascii=False, separators=(",", ":")).encode())


def context_relation(stored: str | None, stored_identity: str | None, current: str) -> str:
    if stored == digest(current.encode()):
        return "exact"
    if stored_identity is not None and stored_identity == identity_digest(current):
        return "disposition_only"
    try:
        value = json.loads(current)
    except json.JSONDecodeError:
        return "mismatch"
    if not isinstance(value, dict):
        return "mismatch"
    # Goal, brief digest and executor generation are the authenticated intent
    # identity. Only backlog disposition/hold/block changes may explain a stale
    # compact context without authorizing new work.
    for state in {str(value.get("task_state", "")), "in_flight", "queued", "done"}:
        for held in ("yes", "no"):
            for blocked in ("yes", "no"):
                candidate = dict(value)
                candidate.update(task_state=state, held=held, blocked=blocked)
                encoded = json.dumps(candidate, ensure_ascii=False, separators=(",", ":"))
                if stored == digest(encoded.encode()):
                    return "disposition_only"
    return "mismatch"


def projection(task: str, goal: str, state: str, held: str, blocked: str,
               body: str, context: str) -> dict[str, object]:
    values, _, stored_context, stored_identity = parse(body)
    relation = context_relation(stored_context, stored_identity, context) if values is not None else "absent"
    active = values is not None and relation == "exact"
    return {
        "task_id": task,
        "goal": goal,
        "task_state": state,
        "task_held": held,
        "task_blocked": blocked,
        "recorded": active,
        "context_relation": relation,
        # Values remain visible when context is stale so MAIN and viewers can
        # reconcile the sole ordinary progress record. `recorded` remains the
        # authority bit for Branch execution.
        "acceptance": values["acceptance"] if values is not None else "",
        "current_state": values["current_state"] if values is not None else "",
        "remaining_gap": values["remaining_gap"] if values is not None else "",
        "next_step": values["next_step"] if values is not None else "",
        # Context is an opaque read-time concurrency salt supplied by the
        # task owner (currently goal, brief bytes, task state, execution
        # generation, and the backlog hold/block flags). It is
        # neither persisted progress nor an evidence reference.
        "record_token": digest(task.encode() + b"\0" + goal.encode() + b"\0" + body.encode() + b"\0" + context.encode()),
    }


def render(values: dict[str, object], context: str) -> str:
    clean = {name: text(values.get(name), name, empty=name not in ("acceptance", "current_state")) for name in FIELDS}
    if bool(clean["remaining_gap"]) != bool(clean["next_step"]):
        raise Refusal("remaining_gap and next_step must both be empty or both be present")
    return "\n".join([
        START + " context=" + digest(context.encode()) + " identity=" + str(identity_digest(context)) + " -->",
        "acceptance: " + json.dumps(clean["acceptance"], ensure_ascii=False),
        "current_state: " + json.dumps(clean["current_state"], ensure_ascii=False),
        "remaining_gap: " + json.dumps(clean["remaining_gap"], ensure_ascii=False),
        "next_step: " + json.dumps(clean["next_step"], ensure_ascii=False),
        END,
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description="Read or replace the compact progress block in an existing task body.")
    parser.add_argument("action", choices=("read", "values", "replace"))
    parser.add_argument("--task", required=True)
    parser.add_argument("--goal", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--held", required=True, choices=("yes", "no"))
    parser.add_argument("--blocked", required=True, choices=("yes", "no"))
    parser.add_argument("--context", default="")
    parser.add_argument("--expected-token")
    parser.add_argument("--progress-json")
    args = parser.parse_args()
    raw = sys.stdin.buffer.read()
    try:
        body = raw.decode("utf-8")
        goal = text(args.goal, "goal")
        current = projection(args.task, goal, args.state, args.held, args.blocked, body, args.context)
        if args.action == "read":
            print(json.dumps(current, ensure_ascii=False, separators=(",", ":")))
            return 0
        if args.action == "values":
            values, _, _, _ = parse(body)
            print(json.dumps(values, ensure_ascii=False, separators=(",", ":")))
            return 0
        if not args.expected_token or args.expected_token != current["record_token"]:
            raise Refusal("task record changed; read current progress before updating")
        if not args.progress_json:
            raise Refusal("progress-json is required")
        values = json.loads(args.progress_json)
        if not isinstance(values, dict) or set(values) != set(FIELDS):
            raise Refusal("progress update must contain only acceptance, current_state, remaining_gap and next_step")
        block = render(values, args.context)
        _, match, _, _ = parse(body)
        if match:
            prefix = body[:match.start()].rstrip("\n")
            suffix = body[match.end():].lstrip("\n")
            updated = "\n\n".join(part for part in (prefix, block, suffix) if part)
        else:
            updated = body.rstrip("\n")
            updated = (updated + "\n\n" if updated else "") + block
        sys.stdout.write(updated + "\n")
        return 0
    except (Refusal, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 6


if __name__ == "__main__":
    raise SystemExit(main())
