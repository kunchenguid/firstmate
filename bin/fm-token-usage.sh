#!/usr/bin/env bash
# Attribute a worker's token burn to one task from the harness's OWN durable
# per-session records.
#
# Usage: fm-token-usage.sh <harness> <worktree> <since> <until>
#   <harness>   the worker harness recorded in state/<id>.meta
#   <worktree>  the task's isolated worktree path
#   <since>     dispatch timestamp, YYYY-MM-DDTHH:MM:SSZ
#   <until>     window end, YYYY-MM-DDTHH:MM:SSZ
#
# Prints one JSON object on stdout and exits 0 whether or not a figure was
# found. A figure is reported ONLY when the harness writes a durable
# per-session record that states both its working directory and its token
# counts; otherwise "tokens" is null and "note" states why for that harness.
#
#   {"tokens":232033,"source":"codex-rollout","sessions":1,
#    "input":52912,"cached_input":170240,"output":8881,"note":null}
#   {"tokens":null,"source":null,"sessions":null,
#    "input":null,"cached_input":null,"output":null,"note":"<why>"}
#
# Attribution rule, identical for every supported harness: a session counts
# when its recorded working directory is the task worktree or a path inside it,
# AND its first record's timestamp falls within [since, until]. Task worktrees
# are isolated per task, so directory containment attributes a session to at
# most one task, and the dispatch window separates tasks that reuse a pooled
# worktree path. A session that started before the window belongs to the
# previous holder of that path and is never counted.
#
# Component semantics are uniform so providers stay comparable:
#   input         uncached input tokens, including cache-write tokens
#   cached_input  input tokens served from a provider cache
#   output        all output tokens, including reasoning tokens
#   tokens        input + cached_input + output
# Vendors count differently underneath; the components are recorded so a
# comparison can normalize rather than trust one total.
#
# Per-harness sources (verified 2026-08-14; docs/task-metrics.md carries the
# operator-facing summary):
#   claude  ~/.claude/projects/<encoded-cwd>/<session>.jsonl, per-assistant
#           message.usage. CLAUDE_CONFIG_DIR relocates the store.
#   codex   ~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl, session_meta.cwd plus
#           cumulative token_count.info.total_token_usage.
#   pi      ~/.pi/agent/sessions/<encoded-cwd>/<session>.jsonl, session record
#           cwd plus per-message message.usage.
# Every other verified harness reports null: cursor's own chat store
# (~/.cursor/chats/<hash>/<uuid>/) records cwd and timestamps but no token
# counts, and opencode, grok, kimi, muse, and pi-signed have no durable
# per-session token record this repo has verified. Roots are overridable with
# FM_CLAUDE_PROJECTS_ROOT, FM_CODEX_SESSIONS_ROOT, and FM_PI_SESSIONS_ROOT; this
# script reads only inside the resolved root and never writes.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -ne 4 ]; then
  echo "error: usage: fm-token-usage.sh <harness> <worktree> <since> <until>" >&2
  exit 2
fi
HARNESS=$1
WORKTREE=$2
SINCE=$3
UNTIL=$4

token_usage_null() {  # <note>
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps({
    "tokens": None,
    "source": None,
    "sessions": None,
    "input": None,
    "cached_input": None,
    "output": None,
    "note": sys.argv[1],
}, separators=(",", ":")))
PY
}

if [ -z "$WORKTREE" ]; then
  token_usage_null "no task worktree recorded to attribute sessions to"
  exit 0
fi
for value in "$SINCE" "$UNTIL"; do
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) token_usage_null "no attribution window: the task has no valid dispatch and completion timestamps"; exit 0 ;;
  esac
done
if ! command -v python3 >/dev/null 2>&1; then
  token_usage_null "no token reader: python3 is unavailable"
  exit 0
fi

case "$HARNESS" in
  claude)
    ROOT=${FM_CLAUDE_PROJECTS_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}
    KIND=claude
    SOURCE=claude-transcript
    ;;
  codex)
    ROOT=${FM_CODEX_SESSIONS_ROOT:-${CODEX_HOME:-$HOME/.codex}/sessions}
    KIND=codex
    SOURCE=codex-rollout
    ;;
  pi)
    ROOT=${FM_PI_SESSIONS_ROOT:-$HOME/.pi/agent/sessions}
    KIND=pi
    SOURCE=pi-session
    ;;
  *)
    token_usage_null "no verified durable per-session token record for harness ${HARNESS:-unknown}"
    exit 0
    ;;
esac

if [ ! -d "$ROOT" ]; then
  token_usage_null "no $SOURCE store at the resolved root"
  exit 0
fi

python3 - "$KIND" "$SOURCE" "$ROOT" "$WORKTREE" "$SINCE" "$UNTIL" <<'PY'
import datetime
import json
import os
import sys

kind, source, root, worktree, since_text, until_text = sys.argv[1:]


def moment(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc
    )


since = moment(since_text)
until = moment(until_text)
target = os.path.realpath(worktree)


def report(tokens, sessions, input_tokens, cached_input, output, note):
    print(json.dumps({
        "tokens": tokens,
        "source": source if tokens is not None else None,
        "sessions": sessions,
        "input": input_tokens,
        "cached_input": cached_input,
        "output": output,
        "note": note,
    }, separators=(",", ":")))
    raise SystemExit(0)


def record_time(value):
    """Parse a session record timestamp, tolerating fractional seconds and offsets."""
    if not isinstance(value, str) or not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.astimezone(datetime.timezone.utc)


def inside_worktree(cwd):
    if not isinstance(cwd, str) or not cwd:
        return False
    resolved = os.path.realpath(cwd)
    return resolved == target or resolved.startswith(target + os.sep)


def session_files():
    """Session files whose mtime could not predate the attribution window.

    An append-only session file's mtime is at or after its last write, so this
    only skips files that were finished before the task was dispatched. It
    bounds the scan; no timestamp used in a reported figure comes from it.
    """
    floor = since.timestamp()
    for base, _dirs, names in os.walk(root):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(base, name)
            try:
                if os.stat(path).st_mtime < floor:
                    continue
            except OSError:
                continue
            yield path


def records(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as source_file:
            for raw in source_file:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    yield json.loads(raw)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def claude_session(path):
    """(input, cached_input, output) for one claude transcript, or None."""
    started = None
    matched = False
    totals = [0, 0, 0]
    for record in records(path):
        moment_value = record_time(record.get("timestamp"))
        if started is None and moment_value is not None:
            started = moment_value
        if inside_worktree(record.get("cwd")):
            matched = True
        message = record.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if isinstance(usage, dict):
            totals[0] += int(usage.get("input_tokens") or 0)
            totals[0] += int(usage.get("cache_creation_input_tokens") or 0)
            totals[1] += int(usage.get("cache_read_input_tokens") or 0)
            totals[2] += int(usage.get("output_tokens") or 0)
    if not matched or started is None or not since <= started <= until:
        return None
    return tuple(totals)


def pi_session(path):
    started = None
    matched = False
    totals = [0, 0, 0]
    for record in records(path):
        moment_value = record_time(record.get("timestamp"))
        if started is None and moment_value is not None:
            started = moment_value
        if record.get("type") == "session" and inside_worktree(record.get("cwd")):
            matched = True
        message = record.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if isinstance(usage, dict):
            totals[0] += int(usage.get("input") or 0)
            totals[0] += int(usage.get("cacheWrite") or 0)
            totals[1] += int(usage.get("cacheRead") or 0)
            totals[2] += int(usage.get("output") or 0)
    if not matched or started is None or not since <= started <= until:
        return None
    return tuple(totals)


def codex_session(path):
    """codex records CUMULATIVE totals, so the last observation wins."""
    started = None
    matched = False
    latest = None
    for record in records(path):
        moment_value = record_time(record.get("timestamp"))
        if started is None and moment_value is not None:
            started = moment_value
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        if record.get("type") == "session_meta" and inside_worktree(payload.get("cwd")):
            matched = True
        if payload.get("type") == "token_count":
            info = payload.get("info")
            total = info.get("total_token_usage") if isinstance(info, dict) else None
            if isinstance(total, dict):
                latest = total
    if not matched or started is None or not since <= started <= until:
        return None
    if latest is None:
        return (0, 0, 0)
    cached = int(latest.get("cached_input_tokens") or 0)
    total_input = int(latest.get("input_tokens") or 0)
    return (max(total_input - cached, 0), cached, int(latest.get("output_tokens") or 0))


readers = {"claude": claude_session, "codex": codex_session, "pi": pi_session}
read_session = readers[kind]

sessions = 0
totals = [0, 0, 0]
for path in session_files():
    counted = read_session(path)
    if counted is None:
        continue
    sessions += 1
    for index in range(3):
        totals[index] += counted[index]

if sessions == 0:
    report(
        None,
        None,
        None,
        None,
        None,
        f"no {source} session recorded against the task worktree within its dispatch window",
    )
report(sum(totals), sessions, totals[0], totals[1], totals[2], None)
PY
