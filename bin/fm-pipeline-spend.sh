#!/usr/bin/env bash
# fm-pipeline-spend.sh - attribute a task's no-mistakes pipeline spend to the
# task and keep it in Firstmate's own records.
#
# Usage:
#   fm-pipeline-spend.sh show <task-id>
#   fm-pipeline-spend.sh record <task-id>
#
# show prints the task's pipeline spend as one JSON object and writes nothing,
# so it can be read while the task's runs are still going. record appends that
# same object as one line to data/pipeline-spend.jsonl, at most once per task
# incarnation (task id plus the record's spawn_gen): repeating it for an
# incarnation already in the ledger appends nothing, so a retried cleanup never
# counts a task twice. bin/fm-teardown.sh calls record for every ship task
# whose local copy it cleans up, before it deletes the task branch this script
# attributes runs by and before it removes state/<id>.meta. The ledger is
# private and gitignored with the rest of data/.
# Exit status: 0 when a record was printed or recorded (including one whose
# source is unavailable), 1 when the task record is missing, names a
# secondmate, or the record could not be built or written, 2 for bad usage.
#
# Source. no-mistakes keeps each agent invocation's token usage only in its
# local state database, one agent_invocations row per invocation; its
# environment reference documents those fields, and `no-mistakes stats --run
# <id>` renders the same rows as a human table. There is no machine-readable
# export yet, so this script reads the database read-only (mode=ro), located
# by bin/fm-nm-run-lib.sh's fm_nm_state_db, and bounded by
# FM_PIPELINE_SPEND_TIMEOUT seconds (default 30) per no-mistakes or database
# call.
#
# Attribution. A task's runs are the runs no-mistakes recorded for the task
# copy's repository and current branch since that branch was created:
#   - repository: the `repo:` line `no-mistakes axi` prints from the task copy,
#     which is the CLI's own resolution (a pooled worker copy resolves to the
#     registered primary clone), matched exactly against repos.working_path;
#   - branch: the task copy's current branch, the one bin/fm-crew-state.sh
#     reads;
#   - since: the oldest surviving reflog entry of that branch. spawn_gen cannot
#     bound the task, because a relaunch mints a new one while the same branch
#     keeps validating. Teardown deletes the branch, so a later task that
#     reuses the id and branch name starts a fresh reflog and never inherits an
#     earlier task's runs. With no reflog, every run on the branch counts and
#     since is null.
# Two live tasks sharing one branch name in one repository would both count
# its runs; each record lists run ids, so such an overlap stays visible.
#
# Counting. Every invocation of those runs counts, whatever its exit status
# (ok, error, cancelled), and each token field is no-mistakes' own, summed
# without reinterpretation (whether input includes cache reads differs by
# agent; see no-mistakes' environment reference):
#   - input_tokens, output_tokens, cache_read_tokens sum the per-round
#     delta_* columns, because a resumed session's raw counters are cumulative
#     for some agents (codex) and summing them would count earlier review
#     rounds again. A row with no delta (written before the delta columns
#     existed) falls back to its raw counter only when its session_mode is not
#     `resumed`, since no-mistakes defines a cold, started, or fallback row's
#     delta as its raw counter.
#   - cache_creation_tokens sums the raw counter, which has no per-round
#     delta, so it counts only for a row whose counters are proven
#     per-invocation: not resumed, or every delta equal to its raw counter.
#   - reasoning is not summed: no-mistakes counts it inside output and keeps no
#     per-round delta for it.
# A value no-mistakes did not record is unknown, never zero: each token field
# carries its known total and how many invocations were unknown, so a total
# with unknown > 0 is a lower bound.
#
# Record schema (this header is its one owner). One JSON object:
#   task, spawn_gen         the task id and the incarnation recorded in its meta
#   recorded_at             UTC time the record was built
#   source                  "no-mistakes-state", or "unavailable" when the runs
#                           could not be read; reason then says why, total
#                           is null, and runs and purposes are empty
#   repo, branch, since     the attribution above (since as UTC time or null)
#   total                   a tally over every counted invocation
#   runs[]                  {id, status, created_at} plus a tally, oldest first
#   purposes[]              {purpose} plus a tally, by no-mistakes' purpose
#                           name (review, review-fix, test, document, ci, ...)
# A tally is {invocations, exit: {<exit status>: count}, duration_ms,
# input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens}, and
# each token field is {total, unknown}.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-pipeline-spend: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  show|record) ACTION=$1 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
ID=$2
fm_task_id_path_safe "$ID" || { echo "fm-pipeline-spend: invalid task id" >&2; exit 2; }
TIMEOUT=${FM_PIPELINE_SPEND_TIMEOUT:-30}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=30 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || fail "no task record for $ID"
meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
[ "$(meta_value kind)" != secondmate ] || fail "$ID is a secondmate, not a task"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to read no-mistakes' state database"

WT=$(meta_value worktree)
SPAWN_GEN=$(meta_value spawn_gen)
BRANCH=
SINCE=
REPO=
DB=
REASON=
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  REASON="the task copy ${WT:-<unrecorded>} is gone"
elif ! BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || [ -z "$BRANCH" ]; then
  BRANCH=
  REASON="the task copy is not on a branch"
elif ! command -v no-mistakes >/dev/null 2>&1; then
  REASON="no-mistakes is not installed"
else
  # `--format=%gd --date=unix` prints <branch>@{<epoch>} newest first; the last
  # line is the oldest surviving entry, normally the branch's creation.
  SINCE=$(git -C "$WT" reflog show --date=unix --format=%gd "refs/heads/$BRANCH" -- 2>/dev/null \
    | tail -1 | sed -n 's/.*@{\([0-9][0-9]*\)}$/\1/p') || SINCE=
  OVERVIEW=$(fm_nm_run_checked "$WT" "$TIMEOUT" axi) || true
  REPO=$(fm_nm_strip_quotes "$(printf '%s\n' "$OVERVIEW" | sed -n 's/^repo:[[:space:]]*//p' | head -1)")
  if [ -z "$REPO" ]; then
    REASON="no-mistakes resolved no repository for the task copy"
    FIRST_LINE=$(printf '%s\n' "$OVERVIEW" | sed -n '/^error:/{p;q;}')
    [ -n "$FIRST_LINE" ] || FIRST_LINE=$(printf '%s\n' "$OVERVIEW" | sed -n '/[^[:space:]]/{p;q;}')
    [ -z "$FIRST_LINE" ] || REASON="$REASON: $FIRST_LINE"
  else
    DB=$(fm_nm_state_db "$WT")
  fi
fi

LEDGER=
if [ "$ACTION" = record ]; then
  [ -d "$DATA" ] || fail "data directory $DATA is missing"
  LEDGER="$DATA/pipeline-spend.jsonl"
fi

RUN_DIR=$WT
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || RUN_DIR=$STATE
fm_nm_bounded "$RUN_DIR" "$TIMEOUT" python3 - "$ACTION" "$LEDGER" "$ID" "$SPAWN_GEN" \
    "$REPO" "$BRANCH" "$SINCE" "$DB" "$REASON" <<'PY' || fail "could not build the pipeline spend record for $ID"
import fcntl
import json
import os
import sqlite3
import sys
import time
from contextlib import closing
from pathlib import Path

action, ledger, task, spawn_gen, repo, branch, since, database, reason = sys.argv[1:]
COUNTERS = ("input", "output", "cache_read")
TOKENS = tuple(f + "_tokens" for f in COUNTERS) + ("cache_creation_tokens",)


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def tally():
    t = {"invocations": 0, "exit": {}, "duration_ms": 0}
    for field in TOKENS:
        t[field] = {"total": 0, "unknown": 0}
    return t


def add(t, row, tokens):
    t["invocations"] += 1
    t["exit"][row["exit_status"]] = t["exit"].get(row["exit_status"], 0) + 1
    t["duration_ms"] += row["duration_ms"] or 0
    for field in TOKENS:
        if tokens[field] is None:
            t[field]["unknown"] += 1
        else:
            t[field]["total"] += tokens[field]


def invocation_tokens(row):
    resumed = row["session_mode"] == "resumed"
    proven = True  # every per-round delta recorded and equal to its raw counter
    tokens = {}
    for counter in COUNTERS:
        raw, delta = row[counter + "_tokens"], row["delta_" + counter + "_tokens"]
        if delta is None:
            proven = False
            tokens[counter + "_tokens"] = None if resumed else raw
        else:
            proven = proven and raw == delta
            tokens[counter + "_tokens"] = delta
    per_invocation = not resumed or proven
    tokens["cache_creation_tokens"] = row["cache_creation_tokens"] if per_invocation else None
    return tokens


def read_spend():
    path = Path(database)
    if not path.is_absolute():
        raise ValueError("state database path %s is not absolute" % database)
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        columns = {r["name"] for r in db.execute("PRAGMA table_info(agent_invocations)")}
        if not columns:
            raise ValueError("no agent_invocations table")
        repo_rows = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchall()
        if len(repo_rows) != 1:
            raise ValueError("no repository %s" % repo)
        runs = db.execute(
            "SELECT id, status, created_at FROM runs WHERE repo_id = ? AND branch = ? AND created_at >= ? "
            "ORDER BY created_at, id",
            (repo_rows[0]["id"], branch, int(since) if since else 0),
        ).fetchall()
        wanted = ("run_id", "purpose", "session_mode", "exit_status", "duration_ms") + TOKENS + tuple(
            "delta_" + c + "_tokens" for c in COUNTERS
        )
        select = ", ".join(c if c in columns else "NULL AS " + c for c in wanted)
        invocations = []
        for run in runs:
            invocations.extend(db.execute(
                "SELECT %s FROM agent_invocations WHERE run_id = ? ORDER BY started_at, id" % select,
                (run["id"],),
            ).fetchall())
    total = tally()
    per_run = {run["id"]: tally() for run in runs}
    per_purpose = {}
    for row in invocations:
        tokens = invocation_tokens(row)
        add(total, row, tokens)
        add(per_run[row["run_id"]], row, tokens)
        add(per_purpose.setdefault(row["purpose"], tally()), row, tokens)
    return {
        "total": total,
        "runs": [
            dict({"id": run["id"], "status": run["status"], "created_at": utc(run["created_at"])}, **per_run[run["id"]])
            for run in runs
        ],
        "purposes": [dict({"purpose": name}, **per_purpose[name]) for name in sorted(per_purpose)],
    }


record = {
    "task": task,
    "spawn_gen": spawn_gen or None,
    "recorded_at": utc(time.time()),
    "source": "no-mistakes-state",
    "reason": None,
    "repo": repo or None,
    "branch": branch or None,
    "since": utc(int(since)) if since else None,
}
if not reason:
    try:
        spend = read_spend()
    except (ValueError, OSError, sqlite3.Error) as err:
        reason = "cannot read no-mistakes state: %s" % err
if reason:
    record.update(source="unavailable", reason=reason, total=None, runs=[], purposes=[])
else:
    record.update(spend)
line = json.dumps(record, separators=(",", ":"))

if action == "show":
    print(line)
    sys.exit(0)

try:
    fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        content = f.read()
        for existing in content.splitlines():
            try:
                row = json.loads(existing)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("task") == task and row.get("spawn_gen") == record["spawn_gen"]:
                print("already recorded %s %s" % (task, spawn_gen or "-"))
                sys.exit(0)
        f.write(("\n" if content and not content.endswith("\n") else "") + line + "\n")
        f.flush()
        os.fsync(f.fileno())
except OSError as err:
    sys.stderr.write("fm-pipeline-spend: cannot write %s: %s\n" % (ledger, err))
    sys.exit(1)
print("recorded %s %s" % (task, spawn_gen or "-"))
PY
