#!/usr/bin/env bash
# fm-usage-harvest.sh - append one fleet usage-ledger row for a finished task.
#
# Usage: fm-usage-harvest.sh <task-id>
#
# Reads state/<task-id>.meta (harness=, model=, effort=, worktree=; the
# backend window= line is intentionally not consumed because the ledger has no
# window field) plus the task's state/<task-id>.status timestamps for the task
# window, then sums the worker's own session-log usage into exactly one JSON
# line appended to data/usage-ledger.jsonl. data/usage-ledger.jsonl is
# gitignored runtime data.
#
# Ledger line schema (this file is the single owner of that schema; the
# report script is a consumer):
#   {"task":<id>,"harness":<name|null>,"model":<id|null>,"effort":<id|null>,
#    "spawned_at":<iso|null>,"completed_at":<iso|null>,
#    "wall_secs":<int>,"turns":<int>,
#    "input_tokens":<int|null>,"cached_input_tokens":<int|null>,
#    "output_tokens":<int|null>,"reasoning_tokens":<int|null>,
#    "source":<claude-projects|codex-sessions|pi-sessions|unavailable>}
#
# Row scope: a row describes the WHOLE task, spanning every relaunch, and
# wall_secs, the session-log window and turns all report that one span. The
# turn count dictates the scope because it can only be read from
# state/<task-id>.status, which is appended to across relaunches and carries
# no incarnation delimiter; per-incarnation turns are therefore not derivable
# from durable data, and scoping only the window to an incarnation would
# report whole-task turns against a one-incarnation window and token sum.
# ONE condition narrows a row below that span, and only for a task that was
# actually relaunched: a filesystem that reports no birth time for
# state/<task-id>.status leaves the meta's spawn_gen as the only durable
# start, and fm-spawn rewrites that token on every relaunch, so wall_secs and
# the token sum then cover the final incarnation while turns still cover the
# whole task. No per-task record of the first spawn survives a relaunch on
# such a host, so a relaunched row there is narrowed rather than wrong; a task
# that was never relaunched always yields a whole-task row on every
# filesystem.
#
# Wall clock: task start epoch -> status-file mtime epoch; the meta file's
# mtime is the fallback end when the status file is absent.
# The start is the EARLIEST durable evidence of the task's first spawn: the
# status file's birth epoch (created on the first spawn, only appended to
# afterwards, and removed only when teardown retires the task) and the epoch
# embedded in the meta's spawn_gen=s<epoch>.<pid>.<random> incarnation token,
# whichever of the two is earlier. fm-spawn writes spawn_gen once per spawn or
# relaunch and never rewrites it afterwards, so it carries the start on a host
# whose filesystem reports no usable birth time; because a relaunch replaces
# it with the relaunch epoch, the status birth is what holds the window open
# over the whole task, which is the narrowing condition stated above. The meta file's own mtime is NOT a start source in its
# own right: later meta writes (PR registration, busy-state updates) move it
# forward to near the end of the task and collapse the window. Only when
# neither durable source is available (a task spawned before the token
# existed, on a birthless filesystem) does the start fall back to the meta
# mtime, then the status mtime.
# A start later than the end (a spawn with no status append after it) is
# pinned to the end so spawned_at never postdates completed_at.
# Turn estimate: count of "^working:" lines in the status file.
#
# Per-request usage sources:
#   harness=claude: <claude-projects>/<worktree with '/' and '.' -> '-'>/*.jsonl in
#     the task window. Claude's logs record no cwd, so that path encoding is
#     what binds a log to this task. Each assistant message carries one API
#     request's usage at .message.usage (input_tokens,
#     cache_read_input_tokens, cache_creation_input_tokens, output_tokens) and
#     Claude logs one entry per content block, so requests are deduped by
#     .message.id before summing. cached_input_tokens folds cache_read + cache_creation (both
#     billed on top of input_tokens); reasoning_tokens captures
#     output_tokens_details.thinking_tokens when present (a subset of
#     output_tokens).
#   harness=codex: <codex-sessions>/**/*.jsonl in the task window whose
#     session_meta cwd equals the meta worktree. Per-turn token_count events
#     carry one request's delta at .payload.info.last_token_usage
#     (input_tokens, cached_input_tokens, cache_write_input_tokens,
#     output_tokens, reasoning_output_tokens); summing those deltas equals the
#     final cumulative total. cached_input_tokens folds cached + cache_write
#     (subsets of input_tokens); the model comes from the turn_context.
#   harness=pi, harness=pi-signed: <pi-sessions>/**/*.jsonl in the task window
#     whose "session" record's cwd equals the meta worktree. Both adapters run
#     the same Pi application and share one ~/.pi/agent state tree, so one
#     scan covers them. Each assistant "message" record carries one API
#     request's usage at .message.usage (input, cacheRead, cacheWrite, output,
#     reasoning) and Pi writes one record per message rather than one per
#     content block; records are still deduped by the record's own .id where
#     present so a replayed line cannot double-count. cached_input_tokens
#     folds cacheRead + cacheWrite; reasoning_tokens captures .reasoning (a
#     subset of output). The model is reported provider-qualified as
#     "<provider>/<model>" to match the model spelling fm-spawn records in the
#     meta, and bare when the record carries no provider.
#   harness=cursor, a task with a recorded remote_host (its worker ran on
#     another machine, so its logs are not on this filesystem), an absent log
#     tree, or no in-window log that yields this task's assistant usage: token
#     fields are null with source "unavailable". Every harness applies that
#     one rule, so a source name always asserts a parsed match and never the
#     mere presence of an in-window file.
# A corrupt log line is skipped best-effort by the parser, which reads each
# line on its own and keeps the rest of that file's usage.
#
# Idempotent: if the ledger already contains a line whose "task" is
# <task-id>, the command exits 0 without appending.
#
# Overrides (test seams and alternate homes):
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE  as usual
#   FM_USAGE_CLAUDE_DIR   default $HOME/.claude/projects
#   FM_USAGE_CODEX_DIR    default $HOME/.codex/sessions
#   FM_USAGE_PI_DIR       default $HOME/.pi/agent/sessions
#
# Exit status: 0 on a successful or already-present harvest, 1 on a missing
# task record, missing jq, or an unwritable ledger. Callers that must not
# block (teardown) own their own guard.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CLAUDE_DIR="${FM_USAGE_CLAUDE_DIR:-${HOME:-}/.claude/projects}"
CODEX_DIR="${FM_USAGE_CODEX_DIR:-${HOME:-}/.codex/sessions}"
PI_DIR="${FM_USAGE_PI_DIR:-${HOME:-}/.pi/agent/sessions}"

# Portable directory-lock helpers (fm_lock_try_acquire / fm_lock_release) let
# the idempotent check-and-append below run as one critical section, so two
# concurrent harvests of the same task cannot both pass the existence check and
# each append a duplicate row. The acquire is bounded (see below) so it never
# blocks the synchronous teardown caller indefinitely.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

err() { printf 'error: %s\n' "$1" >&2; }

if [ "$#" -ne 1 ] || [ -z "$1" ] || case "$1" in *[!A-Za-z0-9._-]*) true ;; *) false ;; esac; then
  err "usage: fm-usage-harvest.sh <task-id>"
  exit 1
fi
command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }

ID=$1
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
[ -f "$META" ] || { err "no task record: $META"; exit 1; }

meta_get() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
HARNESS=$(meta_get harness)
WORKTREE=$(meta_get worktree)
MODEL_META=$(meta_get model)
EFFORT_META=$(meta_get effort)
# A remote secondmate's worker ran on another machine, so its session logs are
# not on this filesystem. Harvesting the local claude/codex trees for such a
# task would at best find nothing and at worst misattribute an unrelated local
# session that happens to match the worktree path, so a task with a recorded
# remote_host is recorded as source=unavailable without a local scan.
REMOTE_HOST=$(meta_get remote_host)
SPAWN_GEN=$(meta_get spawn_gen)

file_mtime_epoch() {  # <file>
  local t
  t=$(stat -f %m -- "$1" 2>/dev/null) || t=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$t"
}
file_birth_epoch() {  # <file>
  local t
  t=$(stat -f %B -- "$1" 2>/dev/null) || t=$(stat -c %W -- "$1" 2>/dev/null) || return 1
  # The plausible-epoch guard keeps GNU stat's filesystem-mode %B output
  # (block size) from being misread as a birth time.
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  [ "$t" -ge 1000000000 ] 2>/dev/null || return 1
  printf '%s' "$t"
}
iso_from_epoch() {  # <epoch>
  date -r "$1" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || return 1
}

spawn_gen_epoch() {  # <spawn_gen token>
  local e
  case "$1" in s[0-9]*) ;; *) return 1 ;; esac
  e=${1#s}
  e=${e%%.*}
  # The same plausible-epoch guard used for birth times rejects a token whose
  # leading field is not a real second count.
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$e" -ge 1000000000 ] 2>/dev/null || return 1
  printf '%s' "$e"
}

END_EPOCH=$(file_mtime_epoch "$STATUS" 2>/dev/null || file_mtime_epoch "$META")
# The two durable first-spawn witnesses are combined by taking the earlier of
# them, so a relaunch (which rewrites spawn_gen but only appends to the status
# log) cannot narrow the window below the span the turn count already covers.
START_GEN=$(spawn_gen_epoch "$SPAWN_GEN" 2>/dev/null || true)
START_BIRTH=$(file_birth_epoch "$STATUS" 2>/dev/null || true)
START_EPOCH=
for start_candidate in "$START_GEN" "$START_BIRTH"; do
  [ -n "$start_candidate" ] || continue
  if [ -z "$START_EPOCH" ] || [ "$start_candidate" -lt "$START_EPOCH" ]; then
    START_EPOCH=$start_candidate
  fi
done
[ -n "$START_EPOCH" ] \
  || START_EPOCH=$(file_mtime_epoch "$META" 2>/dev/null || file_mtime_epoch "$STATUS" 2>/dev/null || printf '%s' "$END_EPOCH")
# Pin an impossible start to the end rather than inverting the window, which
# would both report a negative duration and drop every session log.
[ "$START_EPOCH" -le "$END_EPOCH" ] 2>/dev/null || START_EPOCH=$END_EPOCH
WALL=$((END_EPOCH - START_EPOCH))
TURNS=$(grep -c '^working:' "$STATUS" 2>/dev/null || true)
case "$TURNS" in ''|*[!0-9]*) TURNS=0 ;; esac

# Ref files pin find's mtime window portably (BSD and GNU find both compare
# against -newer file mtimes, and touch -t exists on both).
REFDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-usage-harvest.XXXXXX")
LEDGER_LOCK=
LEDGER_LOCK_HELD=0
harvest_cleanup() {
  local rc=$?
  [ "$LEDGER_LOCK_HELD" != 1 ] || fm_lock_release "$LEDGER_LOCK" || true
  rm -rf -- "$REFDIR"
  return "$rc"
}
trap harvest_cleanup EXIT
epoch_to_touch() {  # <epoch>
  # Both renderings are LOCAL time because that is what touch -t reads; a UTC
  # stamp would shift both window refs by the host's offset and drop real logs.
  date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S
}
# find -newer compares sub-second mtimes, so the refs only narrow to
# [START-1, END+1]; the per-file epoch filter below then applies the true
# inclusive whole-second window [START_EPOCH, END_EPOCH].
touch -t "$(epoch_to_touch "$((START_EPOCH - 1))")" "$REFDIR/start"
touch -t "$(epoch_to_touch "$((END_EPOCH + 1))")" "$REFDIR/end"

LEDGER="$DATA/usage-ledger.jsonl"

SRC=unavailable
MODEL_LOG=
matched_files() {  # <dir> <maxdepth-or-empty> : print in-window *.jsonl paths
  local dir=$1 depthargs=() f m
  [ -d "$dir" ] || return 0
  if [ -n "$2" ]; then
    depthargs=(-maxdepth "$2")
  fi
  while IFS= read -r f; do
    m=$(file_mtime_epoch "$f") || continue
    if [ "$m" -ge "$START_EPOCH" ] && [ "$m" -le "$END_EPOCH" ]; then
      printf '%s\n' "$f"
    fi
  done < <(find "$dir" ${depthargs[@]+"${depthargs[@]}"} -type f -name '*.jsonl' \
    -newer "$REFDIR/start" ! -newer "$REFDIR/end" -print 2>/dev/null) || true
}

IT=null; CT=null; OT=null; RT=null

# accumulate_usage <dir> <maxdepth-or-empty> <source-label> <jq-program>
#
# The three harness parsers differ only in their jq program; everything around
# it lives here once. Each program reduces one session log to at most one
# "<cwd>\t<model>\t<input>\t<cached>\t<output>\t<reasoning>" row, and emits
# that row ONLY when the log actually yielded assistant usage, so a file that
# parses to nothing leaves the source unavailable. Each program also reads its
# input line by line through "try fromjson", so one corrupt line costs that
# line rather than the whole file's usage. This loop then binds the row to
# this task by the cwd it reports, sums the counts and remembers the first
# model seen.
accumulate_usage() {
  local dir=$1 depth=$2 label=$3 prog=$4
  local files f row cwd m it ct ot rt
  files=$(matched_files "$dir" "$depth")
  [ -n "$files" ] || return 0
  IT=0; CT=0; OT=0; RT=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # @tsv renders a null field as an empty one, and "IFS=$'\t' read" would
    # drop those empty fields because tab is an IFS whitespace character,
    # shifting every later field into the wrong variable. Translating the
    # separators to the non-whitespace unit separator keeps each field in its
    # own slot; @tsv escapes any tab inside a value, so every remaining tab
    # byte is a separator.
    row=$(jq -Rrn --arg wt "$WORKTREE" "$prog" "$f" 2>/dev/null | tr '\t' '\037')
    [ -n "$row" ] || continue
    IFS=$'\037' read -r cwd m it ct ot rt <<<"$row"
    [ "$cwd" = "$WORKTREE" ] || continue
    SRC=$label
    [ -n "$m" ] && [ -z "$MODEL_LOG" ] && MODEL_LOG=$m
    IT=$((IT + ${it:-0}))
    CT=$((CT + ${ct:-0}))
    OT=$((OT + ${ot:-0}))
    RT=$((RT + ${rt:-0}))
  done <<FMINNER
$files
FMINNER
  return 0
}

case "$HARNESS" in
  claude)
    if [ -z "$REMOTE_HOST" ] && [ -n "$WORKTREE" ]; then
      encoded=${WORKTREE//\//-}
      encoded=${encoded//./-}
      # Claude's logs carry no cwd, so the encoded directory is the binding and
      # the row reports the worktree it was resolved from.
      # shellcheck disable=SC2016  # jq owns every $ expression in these literal programs.
      accumulate_usage "$CLAUDE_DIR/$encoded" 1 claude-projects '
        reduce (inputs | try (fromjson | objects) catch empty) as $l
          ({seen:{},n:0,m:null,it:0,ct:0,ot:0,rt:0};
            if $l.type == "assistant" and ($l.message.usage // null) != null then
              ($l.message.id // "no-id") as $id
              | if .seen[$id] then . else
                  .seen[$id] = 1
                  | .n += 1
                  | .it += ($l.message.usage.input_tokens // 0)
                  | .ct += (($l.message.usage.cache_read_input_tokens // 0)
                            + ($l.message.usage.cache_creation_input_tokens // 0))
                  | .ot += ($l.message.usage.output_tokens // 0)
                  | .rt += ($l.message.usage.output_tokens_details.thinking_tokens // 0)
                  | (if .m == null then .m = ($l.message.model // null) else . end)
                end
            elif $l.type == "assistant" and ($l.message.model // null) != null and .m == null then
              .m = $l.message.model
            else . end)
        | if .n > 0 then [$wt, .m, .it, .ct, .ot, .rt] | @tsv else empty end'
    fi
    ;;
  codex)
    if [ -z "$REMOTE_HOST" ] && [ -n "$WORKTREE" ]; then
      # shellcheck disable=SC2016  # jq owns every $ expression in these literal programs.
      accumulate_usage "$CODEX_DIR" "" codex-sessions '
        reduce (inputs | try (fromjson | objects) catch empty) as $l
          ({cwd:null,n:0,m:null,it:0,ct:0,ot:0,rt:0};
            if $l.type == "session_meta" then
              .cwd = ($l.payload.cwd // .cwd)
            elif $l.type == "turn_context" and ($l.payload.model // null) != null then
              .m = $l.payload.model
            elif $l.type == "event_msg" and $l.payload.type == "token_count"
                 and ($l.payload.info.last_token_usage // null) != null then
              .n += 1
              | .it += ($l.payload.info.last_token_usage.input_tokens // 0)
              | .ct += (($l.payload.info.last_token_usage.cached_input_tokens // 0)
                        + ($l.payload.info.last_token_usage.cache_write_input_tokens // 0))
              | .ot += ($l.payload.info.last_token_usage.output_tokens // 0)
              | .rt += ($l.payload.info.last_token_usage.reasoning_output_tokens // 0)
            else . end)
        | if .n > 0 then [.cwd, .m, .it, .ct, .ot, .rt] | @tsv else empty end'
    fi
    ;;
  pi|pi-signed)
    if [ -z "$REMOTE_HOST" ] && [ -n "$WORKTREE" ]; then
      # shellcheck disable=SC2016  # jq owns every $ expression in these literal programs.
      accumulate_usage "$PI_DIR" "" pi-sessions '
        reduce (inputs | try (fromjson | objects) catch empty) as $l
          ({cwd:null,seen:{},n:0,m:null,it:0,ct:0,ot:0,rt:0};
            if $l.type == "session" then
              .cwd = ($l.cwd // .cwd)
            elif $l.type == "message" and $l.message.role == "assistant"
                 and ($l.message.usage // null) != null then
              ($l.id // null) as $id
              | if $id != null and .seen[$id] then . else
                  (if $id == null then . else .seen[$id] = 1 end)
                  | .n += 1
                  | .it += ($l.message.usage.input // 0)
                  | .ct += (($l.message.usage.cacheRead // 0)
                            + ($l.message.usage.cacheWrite // 0))
                  | .ot += ($l.message.usage.output // 0)
                  | .rt += ($l.message.usage.reasoning // 0)
                  | (if .m == null and ($l.message.model // null) != null then
                       .m = (if ($l.message.provider // null) != null
                             then ($l.message.provider + "/" + $l.message.model)
                             else $l.message.model end)
                     else . end)
                end
            else . end)
        | if .n > 0 then [.cwd, .m, .it, .ct, .ot, .rt] | @tsv else empty end'
    fi
    ;;
esac

if [ "$SRC" = unavailable ]; then
  MODEL_LOG=
  IT=null; CT=null; OT=null; RT=null
fi

MODEL=${MODEL_LOG:-$MODEL_META}
EFFORT=$EFFORT_META

SPAWNED=$(iso_from_epoch "$START_EPOCH" || true)
COMPLETED=$(iso_from_epoch "$END_EPOCH" || true)

mkdir -p -- "$DATA"
# Serialize the check-and-append as one critical section: acquire the ledger
# lock, then test for an existing row for this task and append only when
# absent. Two concurrent harvests of the same task cannot both pass the
# existence test and each append a duplicate row.
#
# The acquire is BOUNDED, not fm_lock_acquire_wait's unbounded spin, because
# this runs synchronously inside teardown: a wedged live holder must never
# block teardown from retiring the task. fm_lock_try_acquire already steals a
# dead owner's lock, so only a live concurrent harvest makes us wait, and its
# critical section is a grep plus an append. If the lock stays busy past the
# bound we give up best-effort (exit 1, which teardown warns on and continues)
# rather than duplicate the row by appending unserialized.
LEDGER_LOCK="$DATA/.usage-ledger.lock"
LEDGER_LOCK_WAIT=${FM_USAGE_LEDGER_LOCK_WAIT:-30}
lock_deadline=$(( $(date +%s) + LEDGER_LOCK_WAIT ))
until fm_lock_try_acquire "$LEDGER_LOCK"; do
  if [ "$(date +%s)" -ge "$lock_deadline" ]; then
    err "ledger lock busy after ${LEDGER_LOCK_WAIT}s; skipping harvest for $ID"
    exit 1
  fi
  sleep 0.1
done
LEDGER_LOCK_HELD=1
if [ -f "$LEDGER" ] && grep -qF "\"task\":\"$ID\"" "$LEDGER" 2>/dev/null; then
  exit 0
fi
# Test seam: widen the check-to-append window so a concurrency regression (a
# removed lock) is observable deterministically; unset in production.
[ -z "${FM_USAGE_HARVEST_APPEND_DELAY:-}" ] || sleep "$FM_USAGE_HARVEST_APPEND_DELAY"
jq -cn \
  --arg task "$ID" --arg harness "$HARNESS" \
  --arg model "$MODEL" --arg effort "$EFFORT" \
  --arg spawned "$SPAWNED" --arg completed "$COMPLETED" \
  --argjson wall "$WALL" --argjson turns "$TURNS" \
  --argjson it "$IT" --argjson ct "$CT" --argjson ot "$OT" --argjson rt "$RT" \
  --arg source "$SRC" \
  '{task:$task, harness:(if $harness == "" then null else $harness end),
    model:(if ($model == "" or $model == "default") then null else $model end),
    effort:(if ($effort == "" or $effort == "default") then null else $effort end),
    spawned_at:(if $spawned == "" then null else $spawned end),
    completed_at:(if $completed == "" then null else $completed end),
    wall_secs:$wall, turns:$turns,
    input_tokens:$it, cached_input_tokens:$ct, output_tokens:$ot,
    reasoning_tokens:$rt, source:$source}' >> "$DATA/usage-ledger.jsonl.tmp.$$"
cat "$DATA/usage-ledger.jsonl.tmp.$$" >> "$LEDGER" && rm -f -- "$DATA/usage-ledger.jsonl.tmp.$$"
