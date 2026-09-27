# shellcheck shell=bash
# ONE OWNER for landed-work cost accounting: what a landed task cost, and what a
# project has cost so far.
#
# Both landing paths reach this library instead of accounting for themselves -
# bin/fm-merge-outcome-lib.sh records every confirmed PR merge (this home's own
# merge and a merge its poll detected), and bin/fm-merge-local.sh records an
# approved local-only landing. bin/fm-cost.sh is the operator entrypoint for the
# same records. No caller computes a cost, reads a usage record, or writes the
# ledger itself.
#
# HONESTY CONTRACT. A cost is reported in exactly one of three states, and the
# state is never upgraded to make a number available:
#   measured    - the worker runtime's own durable record states the USD amount.
#   estimated   - the runtime recorded token counts, and every model those tokens
#                 belong to has a price in this home's operator-supplied
#                 config/model-prices.json (docs/configuration.md owns that
#                 schema). The USD amount is this library's arithmetic over the
#                 operator's prices, never a vendor invoice.
#   unavailable - no authoritative record, or no operator price for some model or
#                 token bucket that was actually used. FM_COST_REASON always says
#                 which. Token counts are still reported when they were recorded,
#                 so spend stays visible even with no price table.
# Missing prices, tokens, credentials, and amounts are reported as missing. This
# library never substitutes a default price, a list price, or another model's
# price, and never partially prices a usage record: one unpriced model or bucket
# makes the whole amount unavailable rather than silently too low.
#
# USAGE SOURCES. Only a runtime's own durable machine-readable record counts;
# rendered pane text is never scraped. Currently:
#   claude - the transcript JSONL under ${CLAUDE_CONFIG_DIR:-~/.claude}/projects,
#            whose per-message usage carries token buckets and model, plus a
#            recorded per-message USD amount when that version writes one.
#   codex  - the rollout JSONL under ${CODEX_HOME:-~/.codex}/sessions, whose
#            token_count events carry the session's cumulative token usage and
#            whose turn_context carries the model.
# Every other supported harness reports unavailable naming itself, which is the
# correct answer until that runtime is shown to keep such a record.
# A task's usage is attributed by its recorded local copy plus its recorded
# incarnation start, because a pooled worktree path is reused by later tasks:
# without the time bound a slot's earlier task would be counted again. The
# incarnation token's format is owned by bin/fm-spawn.sh; an absent or
# unparseable token falls back to the task record's own mtime.
#
# IDEMPOTENCE. A landing is keyed by task id, landing kind, and landing
# reference (the merged PR URL, or the local default-branch head). Recording is
# serialized on the ledger lock and skips a key the ledger already carries, so a
# retried merge report, a re-run entrypoint, and an interrupted cleanup finished
# at the next session cannot count one landing twice. A key is checked before any
# usage record is read, so a retry is cheap as well as safe.
#
# Records are private fleet data under data/cost/ in the home that landed the
# work; nothing is written into a project.

_FM_COST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_COST_LEDGER_VERSION=1

# Public results, set by the functions below and read by sourcing callers.
# shellcheck disable=SC2034
FM_COST_STATUS=''
# shellcheck disable=SC2034
FM_COST_USD=''
# shellcheck disable=SC2034
FM_COST_TOKENS_TOTAL=''
# shellcheck disable=SC2034
FM_COST_TOKENS_INPUT=''
# shellcheck disable=SC2034
FM_COST_TOKENS_OUTPUT=''
# shellcheck disable=SC2034
FM_COST_TOKENS_CACHE_READ=''
# shellcheck disable=SC2034
FM_COST_TOKENS_CACHE_WRITE=''
# shellcheck disable=SC2034
FM_COST_HARNESS=''
# shellcheck disable=SC2034
FM_COST_MODELS=''
# shellcheck disable=SC2034
FM_COST_SOURCE=''
# shellcheck disable=SC2034
FM_COST_REASON=''
# shellcheck disable=SC2034
FM_COST_PROJECT=''
# shellcheck disable=SC2034
FM_COST_ALREADY_RECORDED=false

fm_cost_ledger_dir() {  # <home>
  printf '%s/data/cost\n' "${1%/}"
}

fm_cost_ledger_path() {  # <home>
  printf '%s/ledger.jsonl\n' "$(fm_cost_ledger_dir "$1")"
}

fm_cost_prices_path() {  # <home>
  printf '%s/config/model-prices.json\n' "${1%/}"
}

# Task ids reach this library from metadata and from an operator argument, so the
# same shape check guards both. Kept local so this leaf library pulls in no
# PR machinery to validate a name.
fm_cost_task_id_valid() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .|..|-*|.*) return 1 ;;
  esac
  return 0
}

_fm_cost_meta_field() {  # <meta> <field>
  LC_ALL=C awk -F= -v f="$2" '$1 == f { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

# Lower time bound for attributing a runtime's usage record to this task: the
# recorded incarnation's start. bin/fm-spawn.sh owns the token format; anything
# it does not match falls back to the record's own mtime, which is never later
# than the incarnation it describes.
_fm_cost_since_epoch() {  # <meta>
  local meta=$1 token epoch
  token=$(_fm_cost_meta_field "$meta" spawn_gen)
  epoch=${token#s}
  epoch=${epoch%%.*}
  case "$epoch" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$epoch"; return 0 ;;
  esac
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    epoch=$(/usr/bin/stat -f %m "$meta" 2>/dev/null) || return 1
  else
    epoch=$(stat -c %Y "$meta" 2>/dev/null) || return 1
  fi
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

# shellcheck disable=SC2034  # Public FM_COST_* results, read by sourcing callers.
_fm_cost_unavailable() {  # <harness> <reason>
  FM_COST_STATUS=unavailable
  FM_COST_USD=''
  FM_COST_TOKENS_TOTAL=''
  FM_COST_TOKENS_INPUT=''
  FM_COST_TOKENS_OUTPUT=''
  FM_COST_TOKENS_CACHE_READ=''
  FM_COST_TOKENS_CACHE_WRITE=''
  FM_COST_HARNESS=$1
  FM_COST_MODELS=''
  FM_COST_SOURCE=''
  FM_COST_REASON=$2
}

# fm_cost_usage <home> <state> <task-id>
#
# Read the task's cost from the worker runtime's own durable usage record and
# this home's operator-supplied prices. Sets the FM_COST_* results above and
# returns 0 for every honest answer, including unavailable with a reason.
# Returns 2 on an invalid request. No side effects and no network access.
fm_cost_usage() {  # <home> <state> <task-id>
  local home=$1 state=$2 id=$3 meta harness worktree project since prices scan
  FM_COST_PROJECT=''
  fm_cost_task_id_valid "$id" || return 2
  [ -d "$state" ] || return 2
  meta="$state/$id.meta"
  if [ ! -f "$meta" ]; then
    _fm_cost_unavailable '' "no local record for task $id"
    return 0
  fi
  harness=$(_fm_cost_meta_field "$meta" harness)
  worktree=$(_fm_cost_meta_field "$meta" worktree)
  project=$(_fm_cost_meta_field "$meta" project)
  FM_COST_PROJECT=$project
  if [ -z "$harness" ] || [ -z "$worktree" ]; then
    _fm_cost_unavailable "$harness" \
      "the local record for task $id names no worker runtime and local copy"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _fm_cost_unavailable "$harness" \
      'python3 is required to read a worker runtime usage record'
    return 0
  fi
  since=$(_fm_cost_since_epoch "$meta") || {
    _fm_cost_unavailable "$harness" \
      "cannot establish when the worker for task $id started"
    return 0
  }
  prices=$(fm_cost_prices_path "$home")
  scan=$(_fm_cost_scan "$harness" "$worktree" "$since" "$prices") || {
    _fm_cost_unavailable "$harness" \
      'the worker runtime usage record could not be read'
    return 0
  }
  eval "$scan"
  FM_COST_HARNESS=$harness
  return 0
}

# Print shell assignments for the FM_COST_* results. The scan itself is one
# bounded read of the runtime's own record files: it never runs the harness,
# never touches the network, and never reads rendered pane text.
_fm_cost_scan() {  # <harness> <worktree> <since-epoch> <prices-path>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import glob
import json
import os
import re
import sys

harness, worktree, since, prices_path = sys.argv[1:5]
since = int(since)
worktree = os.path.normpath(worktree)

BUCKETS = ("input", "output", "cache_read", "cache_write")


def emit(status, reason="", tokens=None, usd=None, models=(), source=""):
    fields = {
        "FM_COST_STATUS": status,
        "FM_COST_USD": "" if usd is None else "%.4f" % usd,
        "FM_COST_TOKENS_INPUT": "",
        "FM_COST_TOKENS_OUTPUT": "",
        "FM_COST_TOKENS_CACHE_READ": "",
        "FM_COST_TOKENS_CACHE_WRITE": "",
        "FM_COST_TOKENS_TOTAL": "",
        "FM_COST_MODELS": " ".join(sorted(models)),
        "FM_COST_SOURCE": source,
        "FM_COST_REASON": reason,
    }
    if tokens:
        total = 0
        for bucket in BUCKETS:
            value = int(tokens.get(bucket, 0))
            total += value
            fields["FM_COST_TOKENS_" + bucket.upper()] = str(value)
        fields["FM_COST_TOKENS_TOTAL"] = str(total)
    for name, value in fields.items():
        print("%s=%s" % (name, "'" + value.replace("'", "'\\''") + "'"))
    raise SystemExit(0)


def load_prices():
    """Operator-supplied prices, or None when this home configured none."""
    if not prices_path or not os.path.isfile(prices_path):
        return None
    try:
        with open(prices_path) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return False
    models = data.get("models")
    if not isinstance(models, dict):
        return False
    return models


def price(per_model, models):
    """USD for per-model token buckets, or (None, reason) when a price is absent.

    Every bucket that carries tokens needs its own operator price. A single
    missing model or bucket makes the whole amount unavailable: a partial sum
    would read as a real, and far too low, cost.
    """
    if models is None:
        return None, "no operator price table (config/model-prices.json is absent)"
    if models is False:
        return None, "config/model-prices.json is not readable price data"
    total = 0.0
    for model, tokens in sorted(per_model.items()):
        entry = models.get(model)
        if not isinstance(entry, dict):
            return None, "no operator price for model %s" % (model or "(unrecorded)")
        for bucket in BUCKETS:
            count = int(tokens.get(bucket, 0))
            if not count:
                continue
            rate = entry.get(bucket)
            if not isinstance(rate, (int, float)):
                return None, "no operator %s price for model %s" % (bucket, model)
            total += count * float(rate) / 1000000.0
    return total, ""


def add(target, bucket, count):
    target[bucket] = target.get(bucket, 0) + int(count or 0)


def claude_root():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )


def claude_project_dirs():
    """Claude Code names a project directory after the worker's cwd."""
    root = os.path.join(claude_root(), "projects")
    candidates = []
    for pattern in ("[^A-Za-z0-9]", "[/.]"):
        slug = re.sub(pattern, "-", worktree)
        path = os.path.join(root, slug)
        if os.path.isdir(path) and path not in candidates:
            candidates.append(path)
    return candidates


def iso_epoch(value):
    if not isinstance(value, str):
        return None
    text = value.replace("Z", "+00:00")
    try:
        import datetime

        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def scan_claude():
    dirs = claude_project_dirs()
    if not dirs:
        return emit(
            "unavailable",
            "the worker runtime kept no usage record for %s" % worktree,
        )
    per_model = {}
    tokens = {}
    seen = set()
    recorded_usd = 0.0
    entries = 0
    priced_entries = 0
    for directory in dirs:
        for path in sorted(glob.glob(os.path.join(directory, "*.jsonl"))):
            try:
                handle = open(path)
            except OSError:
                continue
            with handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if record.get("type") != "assistant":
                        continue
                    if os.path.normpath(record.get("cwd") or "") != worktree:
                        continue
                    stamp = iso_epoch(record.get("timestamp"))
                    if stamp is None or stamp < since:
                        continue
                    uuid = record.get("uuid")
                    if uuid in seen:
                        continue
                    if uuid:
                        seen.add(uuid)
                    message = record.get("message") or {}
                    usage = message.get("usage") or {}
                    if not usage:
                        continue
                    entries += 1
                    model = message.get("model") or ""
                    bucket = per_model.setdefault(model, {})
                    for name, key in (
                        ("input", "input_tokens"),
                        ("output", "output_tokens"),
                        ("cache_read", "cache_read_input_tokens"),
                        ("cache_write", "cache_creation_input_tokens"),
                    ):
                        add(bucket, name, usage.get(key, 0))
                        add(tokens, name, usage.get(key, 0))
                    amount = record.get("costUSD")
                    if isinstance(amount, (int, float)):
                        recorded_usd += float(amount)
                        priced_entries += 1
    if not entries:
        return emit(
            "unavailable",
            "the worker runtime recorded no usage for this task",
            source="claude-transcript",
        )
    models = [name for name in per_model if name]
    if priced_entries == entries:
        return emit(
            "measured",
            tokens=tokens,
            usd=recorded_usd,
            models=models,
            source="claude-transcript",
        )
    amount, reason = price(per_model, load_prices())
    if amount is None:
        return emit(
            "unavailable", reason, tokens=tokens, models=models,
            source="claude-transcript",
        )
    return emit(
        "estimated", tokens=tokens, usd=amount, models=models,
        source="claude-transcript",
    )


def codex_root():
    return os.environ.get("CODEX_HOME") or os.path.join(
        os.path.expanduser("~"), ".codex"
    )


def scan_codex():
    root = os.path.join(codex_root(), "sessions")
    if not os.path.isdir(root):
        return emit(
            "unavailable", "the worker runtime kept no session record directory"
        )
    per_model = {}
    tokens = {}
    sessions = 0
    for path in sorted(
        glob.glob(os.path.join(root, "*", "*", "*", "rollout-*.jsonl"))
    ):
        try:
            if os.path.getmtime(path) < since:
                continue
            handle = open(path)
        except OSError:
            continue
        cwd = None
        model = ""
        usage = None
        with handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                payload = record.get("payload") or {}
                if record.get("type") == "session_meta":
                    cwd = os.path.normpath(payload.get("cwd") or "")
                    if cwd != worktree:
                        break
                    continue
                if cwd is None:
                    continue
                if payload.get("type") == "turn_context":
                    model = payload.get("model") or model
                elif payload.get("type") == "token_count":
                    info = payload.get("info") or {}
                    total = info.get("total_token_usage")
                    if isinstance(total, dict):
                        usage = total
        if cwd != worktree or not usage:
            continue
        sessions += 1
        bucket = per_model.setdefault(model, {})
        cached = int(usage.get("cached_input_tokens", 0) or 0)
        uncached = int(usage.get("input_tokens", 0) or 0) - cached
        for name, count in (
            ("input", max(uncached, 0)),
            ("output", usage.get("output_tokens", 0)),
            ("cache_read", cached),
            ("cache_write", usage.get("cache_write_input_tokens", 0)),
        ):
            add(bucket, name, count)
            add(tokens, name, count)
    if not sessions:
        return emit(
            "unavailable",
            "the worker runtime recorded no usage for this task",
            source="codex-rollout",
        )
    models = [name for name in per_model if name]
    amount, reason = price(per_model, load_prices())
    if amount is None:
        return emit(
            "unavailable", reason, tokens=tokens, models=models,
            source="codex-rollout",
        )
    return emit(
        "estimated", tokens=tokens, usd=amount, models=models,
        source="codex-rollout",
    )


if harness == "claude":
    scan_claude()
elif harness == "codex":
    scan_codex()
emit("unavailable", "%s keeps no durable usage record this home can read" % harness)
PY
}

# Lock helpers live with the wake queue; load them only when a caller actually
# writes the ledger, so a read-only cost question drags in no queue machinery.
_fm_cost_require_lock() {
  command -v fm_lock_acquire_wait >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_COST_LIB_DIR/fm-wake-lib.sh"
}

# fm_cost_record <home> <state> <task-id> <landing> <ref>
#
# Record what this landing cost, exactly once. <landing> is pr or local, and
# <ref> is the merged PR URL or the local default-branch head that landing
# produced; together with the task id they are the ledger key.
#
# Returns 0 when the landing is recorded or the ledger already carried it (then
# FM_COST_ALREADY_RECORDED is true and the FM_COST_* results describe the
# existing entry), 2 on an invalid request, and 1 when the record could not be
# written. A caller whose landing already happened reports a non-zero return as
# a diagnostic and never as a failed landing: the work landed, the accounting
# did not, and bin/fm-cost.sh record repairs it.
fm_cost_record() {  # <home> <state> <task-id> <landing> <ref>
  local home=$1 state=$2 id=$3 landing=$4 ref=$5
  local dir ledger lock existing status=0
  # shellcheck disable=SC2034  # Public result, read by sourcing callers.
  FM_COST_ALREADY_RECORDED=false
  fm_cost_task_id_valid "$id" || return 2
  case "$landing" in pr|local) ;; *) return 2 ;; esac
  case "$ref" in ''|*[$'\n\t']*) return 2 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 1
  dir=$(fm_cost_ledger_dir "$home")
  ledger=$(fm_cost_ledger_path "$home")
  mkdir -p "$dir" || return 1
  _fm_cost_require_lock
  lock="$dir/.ledger.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if existing=$(_fm_cost_ledger_find "$ledger" "$id" "$landing" "$ref"); then
    if [ -n "$existing" ]; then
      eval "$existing"
      # shellcheck disable=SC2034  # Public result, read by sourcing callers.
      FM_COST_ALREADY_RECORDED=true
      fm_lock_release "$lock"
      return 0
    fi
  else
    fm_lock_release "$lock"
    return 1
  fi
  fm_cost_usage "$home" "$state" "$id" || status=$?
  if [ "$status" -ne 0 ]; then
    fm_lock_release "$lock"
    return 2
  fi
  _fm_cost_ledger_append "$ledger" "$id" "$landing" "$ref" || status=1
  fm_lock_release "$lock"
  return "$status"
}

# Print the recorded entry's FM_COST_* assignments when the ledger already
# carries this key, nothing when it does not, and fail when the ledger is
# present but unreadable - an unreadable ledger must never read as "not yet
# recorded", which would double-count the landing.
_fm_cost_ledger_find() {  # <ledger> <task-id> <landing> <ref>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import os
import sys

ledger, task, landing, ref = sys.argv[1:5]
if not os.path.exists(ledger):
    raise SystemExit(0)
try:
    handle = open(ledger)
except OSError:
    raise SystemExit(1)
match = None
with handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            raise SystemExit(1)
        if (
            entry.get("task") == task
            and entry.get("landing") == landing
            and entry.get("ref") == ref
        ):
            match = entry
if match is None:
    raise SystemExit(0)
tokens = match.get("tokens") or {}
usd = match.get("usd")
fields = {
    "FM_COST_STATUS": match.get("status") or "",
    "FM_COST_USD": "" if usd is None else "%.4f" % float(usd),
    "FM_COST_TOKENS_INPUT": str(tokens.get("input", "") or ""),
    "FM_COST_TOKENS_OUTPUT": str(tokens.get("output", "") or ""),
    "FM_COST_TOKENS_CACHE_READ": str(tokens.get("cache_read", "") or ""),
    "FM_COST_TOKENS_CACHE_WRITE": str(tokens.get("cache_write", "") or ""),
    "FM_COST_TOKENS_TOTAL": str(tokens.get("total", "") or ""),
    "FM_COST_HARNESS": match.get("harness") or "",
    "FM_COST_MODELS": " ".join(match.get("models") or []),
    "FM_COST_SOURCE": match.get("source") or "",
    "FM_COST_REASON": match.get("reason") or "",
    "FM_COST_PROJECT": match.get("project") or "",
}
for name, value in fields.items():
    print("%s=%s" % (name, "'" + value.replace("'", "'\\''") + "'"))
PY
}

# The scan results reach the writer as environment, so the ledger entry records
# exactly the result the caller is about to report and nothing re-derived.
_fm_cost_ledger_append() {  # <ledger> <task-id> <landing> <ref>
  FM_COST_STATUS="$FM_COST_STATUS" \
  FM_COST_USD="$FM_COST_USD" \
  FM_COST_TOKENS_INPUT="$FM_COST_TOKENS_INPUT" \
  FM_COST_TOKENS_OUTPUT="$FM_COST_TOKENS_OUTPUT" \
  FM_COST_TOKENS_CACHE_READ="$FM_COST_TOKENS_CACHE_READ" \
  FM_COST_TOKENS_CACHE_WRITE="$FM_COST_TOKENS_CACHE_WRITE" \
  FM_COST_TOKENS_TOTAL="$FM_COST_TOKENS_TOTAL" \
  FM_COST_HARNESS="$FM_COST_HARNESS" \
  FM_COST_MODELS="$FM_COST_MODELS" \
  FM_COST_SOURCE="$FM_COST_SOURCE" \
  FM_COST_REASON="$FM_COST_REASON" \
  FM_COST_PROJECT="$FM_COST_PROJECT" \
  python3 - "$1" "$2" "$3" "$4" "$FM_COST_LEDGER_VERSION" <<'PY'
import json
import os
import sys
import time

ledger, task, landing, ref, version = sys.argv[1:6]


def env(name):
    return os.environ.get(name) or ""


def count(name):
    value = env(name)
    return int(value) if value.isdigit() else 0


usd = env("FM_COST_USD")
project = env("FM_COST_PROJECT")
entry = {
    "v": int(version),
    "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "task": task,
    "project": project,
    "project_name": os.path.basename(project.rstrip("/")) if project else "",
    "landing": landing,
    "ref": ref,
    "harness": env("FM_COST_HARNESS"),
    "models": [name for name in env("FM_COST_MODELS").split(" ") if name],
    "status": env("FM_COST_STATUS"),
    "usd": float(usd) if usd else None,
    "tokens": {
        "input": count("FM_COST_TOKENS_INPUT"),
        "output": count("FM_COST_TOKENS_OUTPUT"),
        "cache_read": count("FM_COST_TOKENS_CACHE_READ"),
        "cache_write": count("FM_COST_TOKENS_CACHE_WRITE"),
        "total": count("FM_COST_TOKENS_TOTAL"),
    },
    "source": env("FM_COST_SOURCE"),
    "reason": env("FM_COST_REASON"),
}
line = json.dumps(entry, sort_keys=True)
try:
    with open(ledger, "a") as handle:
        handle.write(line + "\n")
        handle.flush()
        os.fsync(handle.fileno())
except OSError:
    raise SystemExit(1)
PY
}

# fm_cost_landing_report <home> <state> <task-id> <landing> <ref>
#
# Record the landing, then print its overview. A landing path that does its own
# landing end to end uses this; a path whose merge was already accounted for by
# bin/fm-merge-outcome-lib.sh prints with fm_cost_landing_lines instead of
# recording a second time.
# Returns what fm_cost_record returned; the overview prints either way.
fm_cost_landing_report() {  # <home> <state> <task-id> <landing> <ref>
  local status=0
  fm_cost_record "$@" || status=$?
  fm_cost_landing_lines "$1" "$3" "$4" "$5"
  return "$status"
}

# fm_cost_landing_lines <home> <task-id> <landing> <ref>
#
# Print the compact overview a landing entrypoint hands back: what this task
# cost, and what its project has cost so far. This is the structured output a
# supervisor relays, so every line is prefixed cost: and names its own state -
# measured, estimated, or unavailable with the reason - and an accounting that
# never landed says unrecorded instead of printing a number it does not have.
# Reads only the ledger, so it is cheap to call right after recording.
fm_cost_landing_lines() {  # <home> <task-id> <landing> <ref>
  local home=$1 id=$2 landing=$3 ref=$4 ledger entry amount detail
  ledger=$(fm_cost_ledger_path "$home")
  if ! entry=$(_fm_cost_ledger_find "$ledger" "$id" "$landing" "$ref") \
    || [ -z "$entry" ]; then
    printf 'cost: task %s unrecorded (this landing was not accounted; repair with bin/fm-cost.sh record %s %s %s)\n' \
      "$id" "$id" "$landing" "$ref"
    return 0
  fi
  eval "$entry"
  amount=$(fm_cost_amount_text)
  detail=$(fm_cost_detail_text)
  printf 'cost: task %s %s %s%s\n' "$id" "$FM_COST_STATUS" "$amount" "$detail"
  fm_cost_project_total_line "$home" "$FM_COST_PROJECT"
}

# fm_cost_task_recorded_lines <home> <task-id>
#
# Print the cost: lines for every landing already recorded for this task, and
# return 1 when the ledger holds none. This is what answers "what did that task
# cost" after its local records are gone: the ledger outlives the task record,
# the local copy, and the runtime's own transcript.
fm_cost_task_recorded_lines() {  # <home> <task-id>
  local ledger
  ledger=$(fm_cost_ledger_path "$1")
  command -v python3 >/dev/null 2>&1 || return 1
  _fm_cost_task_entries "$ledger" "$2"
}

_fm_cost_task_entries() {  # <ledger> <task-id>
  python3 - "$1" "$2" <<'PY'
import json
import os
import sys

ledger, task = sys.argv[1:3]
if not os.path.exists(ledger):
    raise SystemExit(1)
try:
    handle = open(ledger)
except OSError:
    raise SystemExit(1)
found = False
with handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("task") != task:
            continue
        found = True
        usd = entry.get("usd")
        if isinstance(usd, (int, float)):
            amount = "USD %.4f" % float(usd)
        else:
            amount = "USD unavailable"
        tokens = (entry.get("tokens") or {}).get("total") or 0
        detail = " %d tokens" % tokens if tokens else ""
        runtime = entry.get("harness") or ""
        models = " ".join(entry.get("models") or [])
        if runtime:
            detail += " [%s%s]" % (runtime, (" " + models) if models else "")
        if entry.get("reason"):
            detail += " (%s)" % entry["reason"]
        print(
            "cost: task %s %s %s%s recorded for %s landing %s"
            % (
                task,
                entry.get("status") or "unavailable",
                amount,
                detail,
                entry.get("landing") or "?",
                entry.get("ref") or "?",
            )
        )
raise SystemExit(0 if found else 1)
PY
}

fm_cost_amount_text() {
  if [ -n "$FM_COST_USD" ]; then
    printf 'USD %s\n' "$FM_COST_USD"
  else
    printf 'USD unavailable\n'
  fi
}

fm_cost_detail_text() {
  local detail=''
  [ -n "$FM_COST_TOKENS_TOTAL" ] && detail=" ${FM_COST_TOKENS_TOTAL} tokens"
  [ -n "$FM_COST_HARNESS" ] && detail="$detail [$FM_COST_HARNESS${FM_COST_MODELS:+ $FM_COST_MODELS}]"
  [ -n "$FM_COST_REASON" ] && detail="$detail ($FM_COST_REASON)"
  printf '%s\n' "$detail"
}

# fm_cost_project_total_line <home> <project-path>
#
# One cost: line for everything this home has recorded against that project.
# An unknown project prints the same line shape with no totals rather than
# silently nothing.
fm_cost_project_total_line() {  # <home> <project-path>
  local home=$1 project=$2 ledger
  ledger=$(fm_cost_ledger_path "$home")
  if [ -z "$project" ] || ! command -v python3 >/dev/null 2>&1; then
    printf 'cost: project unknown (no recorded spend to total)\n'
    return 0
  fi
  _fm_cost_project_report "$ledger" "$project"
}

# fm_cost_projects <home>
#
# The operator view: one line per project this home has recorded spend against,
# newest activity last, plus a fleet total. Priced and unpriced landings are
# counted separately so a total is never quietly short.
fm_cost_projects() {  # <home>
  local ledger
  ledger=$(fm_cost_ledger_path "$1")
  command -v python3 >/dev/null 2>&1 || {
    echo 'error: python3 is required to read the cost ledger' >&2
    return 1
  }
  _fm_cost_project_report "$ledger" ''
}

_fm_cost_project_report() {  # <ledger> <project-path-or-empty>
  python3 - "$1" "$2" <<'PY'
import json
import os
import sys

ledger, only = sys.argv[1:3]
rows = {}
order = []
broken = 0
if os.path.exists(ledger):
    try:
        handle = open(ledger)
    except OSError:
        print("cost: ledger unreadable (recorded spend cannot be totalled)")
        raise SystemExit(1)
    with handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                broken += 1
                continue
            project = entry.get("project") or ""
            if only and project != only:
                continue
            name = entry.get("project_name") or project or "(unrecorded project)"
            row = rows.get(name)
            if row is None:
                row = rows[name] = {
                    "usd": 0.0, "priced": 0, "unpriced": 0, "tokens": 0,
                }
                order.append(name)
            usd = entry.get("usd")
            if isinstance(usd, (int, float)):
                row["usd"] += float(usd)
                row["priced"] += 1
            else:
                row["unpriced"] += 1
            tokens = (entry.get("tokens") or {}).get("total")
            if isinstance(tokens, int):
                row["tokens"] += tokens

if only:
    name = os.path.basename(only.rstrip("/")) or only
    row = rows.get(name)
    if row is None:
        print("cost: project %s no recorded spend yet" % name)
        raise SystemExit(0)
    print(
        "cost: project %s USD %.4f across %d priced landing(s), "
        "%d unpriced, %d tokens"
        % (name, row["usd"], row["priced"], row["unpriced"], row["tokens"])
    )
    raise SystemExit(0)

if not order:
    print("no recorded spend yet")
    raise SystemExit(0)
total_usd = 0.0
total_priced = 0
total_unpriced = 0
total_tokens = 0
print("%-28s %12s %8s %10s %14s" % ("PROJECT", "USD", "PRICED", "UNPRICED", "TOKENS"))
for name in order:
    row = rows[name]
    total_usd += row["usd"]
    total_priced += row["priced"]
    total_unpriced += row["unpriced"]
    total_tokens += row["tokens"]
    print(
        "%-28s %12.4f %8d %10d %14d"
        % (name[:28], row["usd"], row["priced"], row["unpriced"], row["tokens"])
    )
print(
    "%-28s %12.4f %8d %10d %14d"
    % ("ALL", total_usd, total_priced, total_unpriced, total_tokens)
)
if total_unpriced:
    print(
        "note: %d landing(s) carry no USD amount; their spend is not in the "
        "total (see bin/fm-cost.sh show <task-id>)" % total_unpriced
    )
if broken:
    print("note: %d unreadable ledger line(s) skipped" % broken)
PY
}
