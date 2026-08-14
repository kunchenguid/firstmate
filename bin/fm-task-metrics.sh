#!/usr/bin/env bash
# Prepare and commit one honest per-task metrics row from durable task records.
#
# Teardown uses two phases so destructive cleanup cannot erase the inputs before
# the row exists, while a later cleanup refusal cannot create a duplicate row:
#
#   fm-task-metrics.sh prepare <task-id>
#     Reads state/<id>.meta, state/<id>.status, the task branch's durable
#     no-mistakes records, and the recorded PR. It atomically writes the private
#     recovery receipt state/<id>.task-metrics-row but does not append metrics.
#
#   fm-task-metrics.sh commit <task-id>
#     Under the data/task-metrics lock, validates the complete JSONL destination,
#     appends the prepared row exactly once, fsyncs it, and retires the receipt.
#     A corrupt or unsafe destination refuses without losing the receipt.
#
#   fm-task-metrics.sh emit <task-id>
#     Runs prepare then commit. This is the standalone convenience interface;
#     guarded teardown prepares before cleanup and commits after cleanup has
#     succeeded but before it retires the metadata and status inputs.
#
# Only mechanically attributable values are populated. Judgment-only fields,
# timing without a durable terminal timestamp, and unattributable token usage
# remain JSON null. Missing optional no-mistakes or forge evidence also yields
# null for the affected fields rather than a guessed value. The exact formulas:
#   pipeline_runs: distinct no-mistakes runs for the metadata project and exact
#     current task branch.
#   fix_rounds: no-mistakes auto_fix rounds in review or test steps only.
#   decisions_raised: status lines whose classified verb is needs-decision or
#     blocked.
#   ci_green_first_push: all GitHub workflow runs for the first durable pushed
#     SHA completed successfully/skipped/neutral; false on any other completed
#     conclusion, null when no complete observation exists.
#   merged/outcome: the recorded PR's current forge state, or the last durable
#     terminal status when there is no PR.
#
# The no-mistakes SQLite path defaults to
# ${NO_MISTAKES_HOME:-$HOME/.no-mistakes}/state.sqlite. Tests and specialized
# homes may set FM_NM_STATE_DB_OVERRIDE. External forge reads are bounded by
# FM_TASK_METRICS_GH_TIMEOUT seconds (default 15).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  prepare|commit|emit) ACTION=$1 ;;
  *) echo "error: usage: fm-task-metrics.sh <prepare|commit|emit> <task-id>" >&2; exit 2 ;;
esac
ID=${2:-}
if [ "$#" -ne 2 ] || ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid task metrics request" >&2
  exit 2
fi

META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
RECEIPT="$STATE/$ID.task-metrics-row"
METRICS="$DATA/task-metrics.jsonl"
METRICS_LOCK="$DATA/.task-metrics.lock"
GH_TIMEOUT=${FM_TASK_METRICS_GH_TIMEOUT:-15}
case "$GH_TIMEOUT" in ''|*[!0-9]*|0) echo "error: invalid FM_TASK_METRICS_GH_TIMEOUT" >&2; exit 2 ;; esac

task_metrics_prior_branch() {
  [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || return 0
  python3 - "$RECEIPT" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source).get("branch")
if isinstance(value, str):
    print(value)
PY
}

task_metrics_repo_slug() {
  local project=$1 pr_url=$2 remote slug
  if [ -n "$pr_url" ]; then
    fm_pr_url_parse "$pr_url" || return 1
    printf '%s\n' "$FM_PR_PATH"
    return 0
  fi
  remote=$(git -C "$project" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    https://github.com/*) slug=${remote#https://github.com/} ;;
    git@github.com:*) slug=${remote#git@github.com:} ;;
    *) return 1 ;;
  esac
  slug=${slug%.git}
  case "$slug" in
    */*) printf '%s\n' "$slug" ;;
    *) return 1 ;;
  esac
}

task_metrics_file_device() {  # <path>
  python3 - "$1" <<'PY' 2>/dev/null
import os
import sys

print(os.lstat(sys.argv[1]).st_dev)
PY
}

task_metrics_regular_single_link() {  # <path>
  python3 - "$1" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

info = os.lstat(sys.argv[1])
raise SystemExit(0 if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 else 1)
PY
}

task_metrics_private_file_valid() {  # <path> <octal-mode> <device>
  python3 - "$1" "$2" "$3" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

path, expected_mode, expected_device = sys.argv[1:]
info = os.lstat(path)
valid = (
    stat.S_ISREG(info.st_mode)
    and info.st_nlink == 1
    and stat.S_IMODE(info.st_mode) == int(expected_mode, 8)
    and info.st_dev == int(expected_device)
)
raise SystemExit(0 if valid else 1)
PY
}

task_metrics_pipeline_info() {
  local mode=$1 project=$2 branch=$3 db
  if [ "$mode" != no-mistakes ]; then
    printf '0\n0\n\n'
    return 0
  fi
  db=${FM_NM_STATE_DB_OVERRIDE:-${NO_MISTAKES_HOME:-${HOME}/.no-mistakes}/state.sqlite}
  [ -f "$db" ] && [ ! -L "$db" ] && [ -n "$project" ] && [ -n "$branch" ] || return 1
  fm_run_timed 10 python3 - "$db" "$project" "$branch" <<'PY'
import os
import re
import sqlite3
import sys

db, project, branch = sys.argv[1:]
uri = "file:" + os.path.abspath(db) + "?mode=ro"
con = sqlite3.connect(uri, uri=True, timeout=0.25)
con.execute("PRAGMA query_only = ON")
project_real = os.path.realpath(project)
repo_ids = [
    row[0]
    for row in con.execute(
        "SELECT id FROM repos WHERE working_path IN (?, ?)",
        (project, project_real),
    )
]
if not repo_ids:
    print("0\n0\n")
    raise SystemExit(0)
marks = ",".join("?" for _ in repo_ids)
run_rows = list(
    con.execute(
        f"SELECT id, last_pushed_sha FROM runs "
        f"WHERE repo_id IN ({marks}) AND branch = ? ORDER BY created_at, id",
        (*repo_ids, branch),
    )
)
run_ids = [row[0] for row in run_rows]
fix_rounds = 0
if run_ids:
    run_marks = ",".join("?" for _ in run_ids)
    fix_rounds = con.execute(
        f"SELECT COUNT(*) FROM step_rounds rd "
        f"JOIN step_results sr ON sr.id = rd.step_result_id "
        f"WHERE sr.run_id IN ({run_marks}) "
        "AND sr.step_name IN ('review', 'test') "
        "AND rd.trigger_type = 'auto_fix'",
        run_ids,
    ).fetchone()[0]
first_sha = ""
for _, candidate in run_rows:
    if isinstance(candidate, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", candidate):
        first_sha = candidate
        break
print(len(run_rows))
print(fix_rounds)
print(first_sha)
PY
}

task_metrics_prepare() {
  local state_device worktree project mode pr_url branch prior_branch repo_slug=''
  local pipeline_info='' pipeline_runs=null fix_rounds=null first_push_sha=''
  local pr_provider='' pr_number='' pr_out='' ci_out='' pr_tmp='' ci_tmp=''
  local decisions=0 terminal_verb='' verb line receipt_tmp

  command -v python3 >/dev/null 2>&1 || { echo "error: task metrics requires python3" >&2; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: task metrics state directory is unsafe" >&2; return 1; }
  task_metrics_regular_single_link "$META" \
    || { echo "error: task metrics metadata is unavailable" >&2; return 1; }
  if [ -e "$STATUS" ] || [ -L "$STATUS" ]; then
    task_metrics_regular_single_link "$STATUS" \
      || { echo "error: task metrics status record is unsafe" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      verb=$(status_line_verb "$line")
      case "$verb" in
        needs-decision|blocked) decisions=$((decisions + 1)) ;;
      esac
      case "$verb" in
        done|failed) terminal_verb=$verb ;;
      esac
    done < "$STATUS"
  fi

  worktree=$(fm_meta_get "$META" worktree)
  project=$(fm_meta_get "$META" project)
  mode=$(fm_meta_get "$META" mode)
  pr_url=$(fm_meta_get "$META" pr)
  if [ -n "$pr_url" ]; then
    fm_pr_url_parse "$pr_url" || { echo "error: task metrics metadata has an invalid PR URL" >&2; return 1; }
    pr_provider=$FM_PR_PROVIDER
    pr_number=$FM_PR_NUMBER
  fi
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    prior_branch=$(task_metrics_prior_branch)
    branch=$prior_branch
  fi
  repo_slug=$(task_metrics_repo_slug "$project" "$pr_url" 2>/dev/null || true)

  if pipeline_info=$(task_metrics_pipeline_info "$mode" "$project" "$branch" 2>/dev/null); then
    pipeline_runs=$(printf '%s\n' "$pipeline_info" | sed -n '1p')
    fix_rounds=$(printf '%s\n' "$pipeline_info" | sed -n '2p')
    first_push_sha=$(printf '%s\n' "$pipeline_info" | sed -n '3p')
    case "$pipeline_runs" in ''|*[!0-9]*) pipeline_runs=null ;; esac
    case "$fix_rounds" in ''|*[!0-9]*) fix_rounds=null ;; esac
  fi

  pr_tmp=$(mktemp "$STATE/.task-metrics-pr.XXXXXX") || return 1
  ci_tmp=$(mktemp "$STATE/.task-metrics-ci.XXXXXX") || { rm -f "$pr_tmp"; return 1; }
  if [ "$pr_provider" = github ] && [ -n "$repo_slug" ] && command -v gh-axi >/dev/null 2>&1; then
    if fm_run_timed "$GH_TIMEOUT" gh-axi pr view "$pr_number" --repo "$repo_slug" > "$pr_tmp" 2>/dev/null; then
      pr_out=$pr_tmp
    fi
    if [ -n "$first_push_sha" ] \
      && fm_run_timed "$GH_TIMEOUT" gh-axi run list --repo "$repo_slug" \
        --commit "$first_push_sha" --limit 100 > "$ci_tmp" 2>/dev/null; then
      ci_out=$ci_tmp
    fi
  fi

  state_device=$(task_metrics_file_device "$STATE") || { rm -f "$pr_tmp" "$ci_tmp"; return 1; }
  receipt_tmp=$(mktemp "$STATE/.task-metrics-row.XXXXXX") || { rm -f "$pr_tmp" "$ci_tmp"; return 1; }
  if ! FM_METRICS_BRANCH="$branch" FM_METRICS_REPO="$repo_slug" \
      FM_METRICS_PIPELINE_RUNS="$pipeline_runs" FM_METRICS_FIX_ROUNDS="$fix_rounds" \
      FM_METRICS_DECISIONS="$decisions" FM_METRICS_TERMINAL_VERB="$terminal_verb" \
      FM_METRICS_PR_OUT="$pr_out" FM_METRICS_CI_OUT="$ci_out" \
      fm_run_timed 10 python3 - "$META" "$receipt_tmp" <<'PY'; then
import csv
import datetime
import json
import os
import re
import sys

meta_path, output_path = sys.argv[1:]
meta = {}
with open(meta_path, encoding="utf-8") as source:
    for raw in source:
        key, sep, value = raw.rstrip("\n").partition("=")
        if sep:
            meta[key] = value

def nullable_text(value):
    return value if isinstance(value, str) and value else None

def nullable_int(value):
    return int(value) if re.fullmatch(r"[0-9]+", value or "") else None

def yolo_value(value):
    if value in ("on", "true"):
        return True
    if value in ("off", "false"):
        return False
    return None

def parse_pr(path):
    if not path:
        return None, None
    text = open(path, encoding="utf-8").read()
    state_match = re.search(r"^  state: (open|closed|merged)$", text, re.MULTILINE)
    merged_match = re.search(r"^  merged: (yes|no)$", text, re.MULTILINE)
    checks_match = re.search(r'^  checks: "([0-9]+) passed, ([0-9]+) failed, ([0-9]+) total"$', text, re.MULTILINE)
    if not merged_match:
        return None, None
    if merged_match.group(1) == "yes":
        return True, "merged"
    state = state_match.group(1) if state_match else None
    if state == "closed":
        return False, "pr_closed"
    if state == "open":
        if checks_match and int(checks_match.group(2)) == 0 and int(checks_match.group(3)) > 0:
            return False, "green_pr"
        return False, "pr_open"
    return False, None

def parse_ci(path):
    if not path:
        return None
    observations = []
    with open(path, encoding="utf-8") as source:
        for raw in source:
            if not re.match(r"^  [0-9]", raw):
                continue
            row = next(csv.reader([raw.strip()]))
            if len(row) >= 4:
                observations.append((row[2], row[3]))
    if not observations or any(status != "completed" for status, _ in observations):
        return None
    good = {"success", "skipped", "neutral"}
    return all(conclusion in good for _, conclusion in observations)

pr_url = nullable_text(meta.get("pr"))
merged, outcome = parse_pr(os.environ.get("FM_METRICS_PR_OUT")) if pr_url else (None, None)
terminal = os.environ.get("FM_METRICS_TERMINAL_VERB")
if not pr_url:
    if terminal == "done":
        outcome = "completed"
    elif terminal == "failed":
        outcome = "failed"

dispatched_at = nullable_text(meta.get("dispatched_at"))
if dispatched_at and not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", dispatched_at):
    dispatched_at = None
date = dispatched_at[:10] if dispatched_at else None
row = {
    "task": meta.get("endpoint_task_id") or os.path.basename(meta_path).removesuffix(".meta"),
    "title": None,
    "repo": nullable_text(os.environ.get("FM_METRICS_REPO")),
    "kind": nullable_text(meta.get("kind")),
    "mode": nullable_text(meta.get("mode")),
    "yolo": yolo_value(meta.get("yolo")),
    "harness": nullable_text(meta.get("harness")),
    "model": nullable_text(meta.get("model")),
    "effort": nullable_text(meta.get("effort")),
    "attribution": None,
    "date": date,
    "dispatched_at": dispatched_at,
    "done_at": None,
    "wall_clock_min": None,
    "blocked_min": None,
    "pipeline_runs": nullable_int(os.environ.get("FM_METRICS_PIPELINE_RUNS")),
    "fix_rounds": nullable_int(os.environ.get("FM_METRICS_FIX_ROUNDS")),
    "decisions_raised": nullable_int(os.environ.get("FM_METRICS_DECISIONS")),
    "firstmate_interventions": None,
    "captain_interventions": None,
    "corrections_required": None,
    "self_corrections": None,
    "nudges_to_validate": None,
    "agent_deaths": None,
    "rebases_required": None,
    "ci_green_first_push": parse_ci(os.environ.get("FM_METRICS_CI_OUT")),
    "vacuous_tests_caught": None,
    "vacuous_tests_shipped": None,
    "tokens_consumed": None,
    "token_note": "not attributable from per-task durable records",
    "outcome": outcome,
    "pr": pr_url,
    "merged": merged,
    "notes": None,
}
envelope = {
    "schema": "firstmate.task-metrics.prepare.v1",
    "branch": nullable_text(os.environ.get("FM_METRICS_BRANCH")),
    "row": row,
}
with open(output_path, "w", encoding="utf-8") as destination:
    json.dump(envelope, destination, ensure_ascii=False, separators=(",", ":"))
    destination.write("\n")
PY
    rm -f "$receipt_tmp" "$pr_tmp" "$ci_tmp"
    return 1
  fi
  rm -f "$pr_tmp" "$ci_tmp"
  chmod 0600 "$receipt_tmp" || { rm -f "$receipt_tmp"; return 1; }
  task_metrics_private_file_valid "$receipt_tmp" 600 "$state_device" \
    || { rm -f "$receipt_tmp"; echo "error: task metrics receipt is unsafe" >&2; return 1; }
  if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
    task_metrics_regular_single_link "$RECEIPT" \
      || { rm -f "$receipt_tmp"; echo "error: task metrics receipt destination is unsafe" >&2; return 1; }
  fi
  mv -f -- "$receipt_tmp" "$RECEIPT"
  echo "prepared: state/$ID.task-metrics-row"
}

task_metrics_commit() {
  local state_device data_device lock_held=0 rc=0
  command -v python3 >/dev/null 2>&1 || { echo "error: task metrics requires python3" >&2; return 1; }
  task_metrics_regular_single_link "$RECEIPT" || { echo "error: task metrics receipt is unavailable" >&2; return 1; }
  state_device=$(task_metrics_file_device "$STATE") || return 1
  task_metrics_private_file_valid "$RECEIPT" 600 "$state_device" \
    || { echo "error: task metrics receipt is unsafe" >&2; return 1; }
  if [ ! -e "$DATA" ]; then
    mkdir -p "$DATA" || return 1
    chmod 0700 "$DATA" || return 1
  fi
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || { echo "error: task metrics data directory is unsafe" >&2; return 1; }
  data_device=$(task_metrics_file_device "$DATA") || return 1
  if [ -e "$METRICS" ] || [ -L "$METRICS" ]; then
    task_metrics_regular_single_link "$METRICS" \
      && [ "$(task_metrics_file_device "$METRICS")" = "$data_device" ] \
      || { echo "error: task metrics destination is unsafe" >&2; return 1; }
  fi
  fm_lock_acquire_wait "$METRICS_LOCK" || return 1
  lock_held=1
  if python3 - "$RECEIPT" "$METRICS" "$ID" <<'PY'
import json
import os
import stat
import sys

receipt_path, metrics_path, expected_id = sys.argv[1:]
with open(receipt_path, encoding="utf-8") as source:
    envelope = json.load(source)
if envelope.get("schema") != "firstmate.task-metrics.prepare.v1":
    raise SystemExit("invalid task metrics receipt schema")
row = envelope.get("row")
if not isinstance(row, dict) or row.get("task") != expected_id:
    raise SystemExit("task metrics receipt identity mismatch")

seen = False
if os.path.exists(metrics_path):
    with open(metrics_path, encoding="utf-8") as source:
        for line_number, raw in enumerate(source, 1):
            if not raw.strip():
                continue
            try:
                existing = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"invalid task metrics JSONL at line {line_number}: {exc}")
            if isinstance(existing, dict) and existing.get("task") == expected_id:
                seen = True
if not seen:
    encoded = (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(metrics_path, flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise SystemExit("task metrics destination changed while appending")
        written = os.write(fd, encoded)
        if written != len(encoded):
            raise SystemExit("short task metrics append")
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  then
    rc=0
  else
    rc=$?
  fi
  if [ "$lock_held" -eq 1 ]; then
    fm_lock_release "$METRICS_LOCK" || rc=1
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  rm -f -- "$RECEIPT"
  echo "emitted: data/task-metrics.jsonl task=$ID"
}

case "$ACTION" in
  prepare) task_metrics_prepare ;;
  commit) task_metrics_commit ;;
  emit) task_metrics_prepare >/dev/null && task_metrics_commit ;;
esac
