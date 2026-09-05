#!/usr/bin/env bash
# fm-usage-harvest.sh - append one fleet usage-ledger row for a finished task.
#
# Usage: fm-usage-harvest.sh [--scan-to <file>|--append-from <file>] <task-id>
#
# With no flag the command scans and appends in one shot. The two flags split
# that into phases for a caller whose own work can still fail after the scan:
# --scan-to measures the task and writes the finished row to <file> without
# touching the ledger, and --append-from appends a row staged that way. See the
# two-phase contract below.
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
#   {"task":<id>,"spawn_gen":<token|null>,
#    "harness":<name|null>,"model":<id|null>,"effort":<id|null>,
#    "spawned_at":<iso|null>,"completed_at":<iso|null>,
#    "wall_secs":<int>,"turns":<int>,
#    "input_tokens":<int|null>,"cached_input_tokens":<int|null>,
#    "output_tokens":<int|null>,"reasoning_tokens":<int|null>,
#    "source":<claude-projects|codex-sessions|pi-sessions|unavailable>}
# A meta model= or effort= holding the literal "default" names no concrete id,
# so the row records null for that field rather than the word itself, which is
# the same spelling an absent line gets.
#
# Row identity is the PAIR task plus spawn_gen, not the task id alone, because
# a task id is reusable: teardown retires a task's records, and a later spawn
# may take the same id. Keying on the id alone silently dropped every such
# later run, since the append found the earlier row and skipped. spawn_gen is
# the meta's incarnation token, so a teardown rerun after a fail-closed refusal
# carries the same one and is still deduped, while a genuinely new spawn of a
# recycled id carries a different one and earns its own row. One consequence
# is a gain rather than a wart: a refused teardown followed by a relaunch and
# then a successful teardown records the relaunched incarnation instead of
# losing the work done after the refusal.
# ABSENCE has one reserved spelling, null: a task whose meta carries no
# spawn_gen writes "spawn_gen":null, and a row written before this field
# existed omits the key entirely. Both read as null, so a legacy row still
# blocks a re-harvest of that same legacy task while never matching, and never
# blocking, a row that does carry a token. A null generation is equal only to
# another null one.
#
# Token invariant, identical for every source: input_tokens counts FRESH,
# uncached input only, and cached_input_tokens counts every input token served
# from or written to a prompt cache, so the two fields are disjoint and their
# sum is the row's whole input side. reasoning_tokens is a subset of
# output_tokens. Each parser below normalizes its harness's own spelling onto
# that one meaning, so a column means the same thing across harnesses and the
# report can sum it over models that were served by different ones.
#
# Row scope: a row describes the WHOLE task, spanning every relaunch, and
# wall_secs, the session-log window and turns all report that one span. The
# turn count dictates the scope because it can only be read from
# state/<task-id>.status, which is appended to across relaunches and carries
# no incarnation delimiter; per-incarnation turns are therefore not derivable
# from durable data, and scoping only the window to an incarnation would
# report whole-task turns against a one-incarnation window and token sum.
# TWO conditions narrow a row below that span, both only for a task that was
# actually relaunched.
# First, a filesystem that reports no birth time for state/<task-id>.status
# leaves the meta's spawn_gen as the only durable start, and fm-spawn rewrites
# that token on every relaunch, so wall_secs and the token sum then cover the
# final incarnation while turns still cover the whole task. No per-task record
# of the first spawn survives a relaunch on such a host, so a relaunched row
# there is narrowed rather than wrong.
# Second, a relaunch may switch the harness, and the meta records only the
# final incarnation's harness, so the scan below reads only that harness's log
# tree: the TOKEN fields and the session-log window they are summed over then
# cover the final harness alone, and an earlier incarnation's usage under a
# different harness is not summed. wall_secs, turns, spawned_at and
# completed_at still span the whole task in that case, so only the token
# fields and their window narrow. Summing every incarnation across different
# harness trees is separate follow-up work and is deliberately not attempted
# here.
# A task that was never relaunched always yields a whole-task row on every
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
# over the whole task, which is the narrowing condition stated above.
# The meta file's own mtime is NOT a start source on any path: later meta
# writes (PR registration, busy-state updates) move it forward to near the end
# of the task, which collapses wall_secs and inverts the log-matching window.
# Only when neither durable source is available (a task spawned before the
# token existed, on a birthless filesystem) does the start fall back to the
# status file's mtime, which collapses the window to the task's last instant
# rather than resting it on a mutable timestamp; with no status file at all
# the start is the end, so the row reports a zero-length window rather than a
# fabricated one.
# A start later than the end (a spawn with no status append after it) is
# pinned to the end so spawned_at never postdates completed_at.
# The window the SESSION LOGS are matched against runs from that same start to
# the HARVEST INSTANT, which is later than completed_at. A crewmate appends
# its final status line from inside an agent turn, so the harness writes that
# turn's tool result and its closing assistant entry into the session log
# after the append returns, and matching at file granularity against
# completed_at drops the whole log rather than its tail. The harvest instant
# bounds that extension without an arbitrary grace period, and teardown is
# ordered so that bound is safe: bin/fm-teardown.sh runs the SCAN phase BEFORE
# it returns the worktree to the treehouse pool, on the main path and on the
# local secondmate child path alike, so the task still holds its pooled
# worktree and no later occupant of that slot can have written a session log
# yet. Callers that scan out of that order forfeit the guarantee.
# wall_secs, spawned_at and completed_at are unaffected and still rest on the
# status file.
# Turn estimate: count of "^working:" lines in the status file.
#
# Per-request usage sources:
#   harness=claude: <claude-projects>/<worktree with '/' and '.' -> '-'>/*.jsonl in
#     the task window. Claude's logs record no cwd, so that path encoding is
#     what binds a log to this task. Each assistant message carries one API
#     request's usage at .message.usage (input_tokens,
#     cache_read_input_tokens, cache_creation_input_tokens, output_tokens) and
#     Claude logs one entry per content block, so requests are deduped by
#     .message.id before summing. Claude's own input_tokens already excludes
#     both cache counts, so it carries the invariant's fresh input as logged,
#     and cached_input_tokens folds cache_read + cache_creation, which are
#     billed on top of it; reasoning_tokens captures
#     output_tokens_details.thinking_tokens when present.
#   harness=codex: <codex-sessions>/**/*.jsonl in the task window whose
#     session_meta cwd equals the meta worktree. Per-turn token_count events
#     carry one request's delta at .payload.info.last_token_usage
#     (input_tokens, cached_input_tokens, cache_write_input_tokens,
#     output_tokens, reasoning_output_tokens); summing those deltas equals the
#     final cumulative total. Codex is the one source whose own input_tokens
#     COUNTS cached_input_tokens inside itself, which real logs establish
#     because total_tokens equals input_tokens + output_tokens on every event
#     carrying usage. The ledger therefore subtracts cached_input_tokens from
#     the event's input_tokens, clamped at zero, so a codex row reports fresh
#     input like every other source instead of counting its cached tokens
#     twice. Whether cache_write_input_tokens is inside input_tokens too is
#     UNKNOWN, assumed neither way, because that field is zero in every
#     observed session: it is folded into cached_input_tokens but NOT
#     subtracted, since subtracting an uncontained field would silently
#     under-count fresh input. If it ever turns up non-zero, re-check whether
#     total_tokens still equals input_tokens + output_tokens on such an event,
#     which is the arithmetic that settles containment. The model comes from
#     the turn_context.
#   harness=pi, harness=pi-signed: <pi-sessions>/**/*.jsonl in the task window
#     whose "session" record's cwd equals the meta worktree. Both adapters run
#     the same Pi application and share one ~/.pi/agent state tree, so one
#     scan covers them. Each assistant "message" record carries one API
#     request's usage at .message.usage (input, cacheRead, cacheWrite, output,
#     reasoning) and Pi writes one record per message rather than one per
#     content block; records are still deduped by the record's own .id where
#     present so a replayed line cannot double-count. Pi's own input is
#     already disjoint from its cache counts, verified on real logs where
#     input + output + cacheRead equals Pi's own totalTokens, so it carries
#     the invariant's fresh input as logged and cached_input_tokens folds
#     cacheRead + cacheWrite; reasoning_tokens captures .reasoning. The model
#     is reported provider-qualified as "<provider>/<model>" to match the
#     model spelling fm-spawn records in the meta, and bare when the record
#     carries no provider.
#   harness=opencode, harness=grok, harness=kimi, harness=cursor,
#     harness=muse, a task with a recorded remote_host (its worker ran on
#     another machine, so its logs are not on this filesystem), an absent log
#     tree, or no in-window log that yields this task's assistant usage: token
#     fields are null with source "unavailable". Every harness applies that
#     one rule, so a source name always asserts a parsed match and never the
#     mere presence of an in-window file.
# A corrupt log line is skipped best-effort by the parser, which reads each
# line on its own and keeps the rest of that file's usage.
# Matching logs are scanned in a deterministic order, oldest mtime first and
# ties broken by path, and the row's model is the one recorded by the LAST
# such log that yielded usage, so a task relaunched onto another model on the
# same harness reports the final incarnation's model, which is the one the
# meta itself records. The same inputs therefore always produce the same model
# field. It falls back to the meta model when no log yields one.
# The two cwd-bound scans (codex, pi) run inside a synchronous teardown over a
# session tree holding thousands of unrelated sibling logs, so a candidate
# that survives the mtime window is first probed for the cwd on its FIRST
# line, which is where both harnesses write the record carrying it, and is
# skipped without a full parse when that cwd names another worktree. The probe
# only ever REJECTS: a first line that is corrupt or carries no cwd falls
# through to the full parse, and the full parse still admits a file only when
# the cwd it reports equals the meta worktree.
#
# Idempotent: if the ledger already contains a line whose "task" and
# "spawn_gen" both match this incarnation, the command exits 0 without
# appending.
#
# Two-phase contract: measuring and appending are separable because the ledger
# row is permanent while the caller's own work may still fail. --scan-to reads
# the meta, the status log and the session logs and writes the row it would
# have appended; --append-from reads nothing but that file and appends it under
# the same lock and the same idempotency guard. A caller that aborts between
# the phases therefore leaves NO row, so its retry measures the task again
# rather than inheriting the abandoned attempt's numbers. The staging file
# belongs to the caller, which owns creating it, keeping it private to one task
# and one run, and removing it on every exit path; the scan renames it into
# place through a sibling temp file, so that cleanup has to cover the directory
# rather than just the row file. --append-from refuses a file that is missing,
# unparseable, or names another task rather than appending something it cannot
# attribute.
#
# Overrides (test seams and alternate homes):
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE  as usual
#   FM_USAGE_CLAUDE_DIR   default $HOME/.claude/projects
#   FM_USAGE_CODEX_DIR    default $HOME/.codex/sessions
#   FM_USAGE_PI_DIR       default $HOME/.pi/agent/sessions
#   FM_USAGE_LEDGER_LOCK_WAIT      seconds to wait for the ledger lock, default 30
#   FM_USAGE_HARVEST_APPEND_DELAY  test-only delay inside the ledger critical section
#
# Exit status: 0 on a successful or already-present harvest, 1 on a missing
# task record, missing jq, an unwritable ledger, an unusable staging file, or a
# ledger lock still held by a live concurrent harvest past
# FM_USAGE_LEDGER_LOCK_WAIT. Callers that must not block (teardown) own their
# own guard.
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

STAGE_MODE=
STAGE_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scan-to|--append-from)
      case "$1" in --scan-to) STAGE_MODE=scan ;; *) STAGE_MODE=append ;; esac
      STAGE_FILE=${2:-}
      shift
      [ "$#" -eq 0 ] || shift
      ;;
    *) break ;;
  esac
done
if [ "$#" -ne 1 ] || [ -z "$1" ] || case "$1" in *[!A-Za-z0-9._-]*) true ;; *) false ;; esac \
  || { [ -n "$STAGE_MODE" ] && [ -z "$STAGE_FILE" ]; }; then
  err "usage: fm-usage-harvest.sh [--scan-to <file>|--append-from <file>] <task-id>"
  exit 1
fi
command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }

ID=$1
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
LEDGER="$DATA/usage-ledger.jsonl"

REFDIR=
LEDGER_LOCK=
LEDGER_LOCK_HELD=0
harvest_cleanup() {
  local rc=$?
  [ "$LEDGER_LOCK_HELD" != 1 ] || fm_lock_release "$LEDGER_LOCK" || true
  [ -z "$REFDIR" ] || rm -rf -- "$REFDIR" || true
  return "$rc"
}
trap harvest_cleanup EXIT

# ledger_append_row <row-json> : the whole critical section, shared by the
# one-shot harvest and by --append-from.
#
# Serialize the check-and-append as one critical section: acquire the ledger
# lock, then test for an existing row for this task and append only when
# absent. Two concurrent harvests of the same task cannot both pass the
# existence test and each append a duplicate row.
#
# The acquire is BOUNDED, not fm_lock_acquire_wait's unbounded spin, because
# this runs synchronously inside teardown: a wedged live holder must never
# block teardown from retiring the task. fm_lock_try_acquire already steals a
# dead owner's lock, so only a live concurrent harvest makes us wait, and its
# critical section is one ledger scan plus an append. If the lock stays busy
# past the bound we give up best-effort (exit 1, which teardown warns on and
# continues) rather than duplicate the row by appending unserialized.
ledger_append_row() {  # <row-json>
  local row=$1 lock_deadline row_gen
  row_gen=$(printf '%s' "$row" | jq -r '.spawn_gen // ""' 2>/dev/null || true)
  mkdir -p -- "$DATA"
  LEDGER_LOCK="$DATA/.usage-ledger.lock"
  LEDGER_LOCK_WAIT=${FM_USAGE_LEDGER_LOCK_WAIT:-30}
  lock_deadline=$(( $(date +%s) + LEDGER_LOCK_WAIT ))
  until fm_lock_try_acquire "$LEDGER_LOCK"; do
    if [ "$(date +%s)" -ge "$lock_deadline" ]; then
      err "ledger lock busy after ${LEDGER_LOCK_WAIT}s; skipping harvest for $ID"
      return 1
    fi
    sleep 0.1
  done
  LEDGER_LOCK_HELD=1
  # The identity test parses each ledger line and compares the task and
  # spawn_gen fields' own values, so exactness is structural rather than
  # resting on the punctuation that happens to surround them today: it stays
  # exact if the schema or the key order ever changes. An absent or null
  # generation on either side reads as the empty string, so it matches only
  # another absent one. A line this cannot parse simply does not match, which
  # risks a duplicate row rather than a lost one.
  if [ -f "$LEDGER" ] && jq -Rn --exit-status --arg id "$ID" --arg gen "$row_gen" \
      'any(inputs | try (fromjson | objects) catch empty;
           .task == $id and (.spawn_gen // "") == $gen)' \
      "$LEDGER" >/dev/null 2>&1; then
    return 0
  fi
  # Test seam: widen the check-to-append window so a concurrency regression (a
  # removed lock) is observable deterministically; unset in production.
  [ -z "${FM_USAGE_HARVEST_APPEND_DELAY:-}" ] || sleep "$FM_USAGE_HARVEST_APPEND_DELAY"
  printf '%s\n' "$row" >> "$LEDGER"
}

# --append-from needs nothing but the staged row: no meta, no status log, no
# session-log scan. That is what lets teardown run it after the refusals that
# would retain the task's worktree and status log, long after the worktree it
# scanned has been returned.
if [ "$STAGE_MODE" = append ]; then
  [ -f "$STAGE_FILE" ] || { err "no staged usage row for $ID at $STAGE_FILE"; exit 1; }
  STAGED_ROW=$(head -n 1 -- "$STAGE_FILE" 2>/dev/null || true)
  printf '%s' "$STAGED_ROW" | jq -e --arg id "$ID" \
    'objects | select(.task == $id)' >/dev/null 2>&1 \
    || { err "staged usage row for $ID is unreadable or names another task"; exit 1; }
  ledger_append_row "$STAGED_ROW"
  exit 0
fi

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
# The meta's mtime is deliberately absent from this chain: it moves forward on
# every later meta write, so resting the start on it collapses wall_secs and
# inverts the log-matching window.
[ -n "$START_EPOCH" ] \
  || START_EPOCH=$(file_mtime_epoch "$STATUS" 2>/dev/null || printf '%s' "$END_EPOCH")
# Pin an impossible start to the end rather than inverting the window, which
# would both report a negative duration and drop every session log.
[ "$START_EPOCH" -le "$END_EPOCH" ] 2>/dev/null || START_EPOCH=$END_EPOCH
WALL=$((END_EPOCH - START_EPOCH))
TURNS=$(grep -c '^working:' "$STATUS" 2>/dev/null || true)
case "$TURNS" in ''|*[!0-9]*) TURNS=0 ;; esac

# The LOG-matching window ends at the harvest instant rather than at
# END_EPOCH: a crewmate appends its final status line from inside an agent
# turn, so the harness writes that turn's tool result and closing assistant
# entry into its own session log after the append returns, and a file-level
# filter cut at END_EPOCH drops the whole log rather than just its tail. The
# harvest instant is a safe bound because teardown runs this harvest before it
# returns the worktree to the pool, so the task still holds that slot and no
# later occupant can have written into it yet.
SCAN_END_EPOCH=$(date +%s 2>/dev/null || printf '%s' "$END_EPOCH")
case "$SCAN_END_EPOCH" in ''|*[!0-9]*) SCAN_END_EPOCH=$END_EPOCH ;; esac
[ "$SCAN_END_EPOCH" -ge "$END_EPOCH" ] 2>/dev/null || SCAN_END_EPOCH=$END_EPOCH

# Ref files pin find's mtime window portably (BSD and GNU find both compare
# against -newer file mtimes, and touch -t exists on both).
REFDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-usage-harvest.XXXXXX")
epoch_to_touch() {  # <epoch>
  # Both renderings are LOCAL time because that is what touch -t reads; a UTC
  # stamp would shift both window refs by the host's offset and drop real logs.
  date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S
}
# find -newer compares sub-second mtimes, so the refs only narrow to
# [START-1, SCAN_END+1]; the per-file epoch filter below then applies the true
# inclusive whole-second window [START_EPOCH, SCAN_END_EPOCH].
touch -t "$(epoch_to_touch "$((START_EPOCH - 1))")" "$REFDIR/start"
touch -t "$(epoch_to_touch "$((SCAN_END_EPOCH + 1))")" "$REFDIR/end"

LEDGER="$DATA/usage-ledger.jsonl"

SRC=unavailable
MODEL_LOG=
matched_files() {  # <dir> <maxdepth-or-empty> : print in-window *.jsonl paths
  local dir=$1 depthargs=() f m
  [ -d "$dir" ] || return 0
  if [ -n "$2" ]; then
    depthargs=(-maxdepth "$2")
  fi
  # find's enumeration order is unspecified, so the mtime it already read is
  # promoted to a sort key: oldest first, ties broken by path. The caller
  # depends on that order to resolve the model to the last incarnation's.
  while IFS= read -r f; do
    m=$(file_mtime_epoch "$f") || continue
    if [ "$m" -ge "$START_EPOCH" ] && [ "$m" -le "$SCAN_END_EPOCH" ]; then
      printf '%s\t%s\n' "$m" "$f"
    fi
  done < <(find "$dir" ${depthargs[@]+"${depthargs[@]}"} -type f -name '*.jsonl' \
    -newer "$REFDIR/start" ! -newer "$REFDIR/end" -print 2>/dev/null) \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2-
}

IT=null; CT=null; OT=null; RT=null

# accumulate_usage <dir> <maxdepth-or-empty> <source-label> <cwd-probe> <jq-program>
#
# The three harness parsers differ only in their jq program; everything around
# it lives here once. Each program reduces one session log to at most one
# "<cwd>\t<model>\t<input>\t<cached>\t<output>\t<reasoning>" row, and emits
# that row ONLY when the log actually yielded assistant usage, so a file that
# parses to nothing leaves the source unavailable. Each program also reads its
# input line by line through "try fromjson", so one corrupt line costs that
# line rather than the whole file's usage. This loop then binds the row to
# this task by the cwd it reports, sums the counts and keeps the model of the
# LAST matching log in matched_files' oldest-first order, which is the final
# incarnation's.
#
# <cwd-probe> is a jq program run against the file's FIRST LINE only, printing
# the cwd that line records or nothing. A candidate whose probe names a
# different worktree is skipped before the full parse, which keeps a teardown
# from parsing thousands of unrelated sibling sessions in a shared tree.
# The probe can only reject: a first line that is corrupt, is not the session
# record or carries no cwd prints nothing and falls through to the full parse,
# and the full parse below still binds on the cwd the whole file reports.
# An empty probe (claude, whose logs carry no cwd at all) skips the step.
accumulate_usage() {
  local dir=$1 depth=$2 label=$3 probe=$4 prog=$5
  local files f row cwd m it ct ot rt head_cwd
  files=$(matched_files "$dir" "$depth")
  [ -n "$files" ] || return 0
  IT=0; CT=0; OT=0; RT=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$probe" ]; then
      head_cwd=$(head -n 1 -- "$f" 2>/dev/null | jq -Rr "$probe" 2>/dev/null) || head_cwd=
      if [ -n "$head_cwd" ] && [ "$head_cwd" != "$WORKTREE" ]; then
        continue
      fi
    fi
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
    [ -n "$m" ] && MODEL_LOG=$m
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
      accumulate_usage "$CLAUDE_DIR/$encoded" 1 claude-projects '' '
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
      accumulate_usage "$CODEX_DIR" "" codex-sessions \
        'fromjson? | objects | select(.type == "session_meta") | .payload.cwd // empty' '
        reduce (inputs | try (fromjson | objects) catch empty) as $l
          ({cwd:null,n:0,m:null,it:0,ct:0,ot:0,rt:0};
            if $l.type == "session_meta" then
              .cwd = ($l.payload.cwd // .cwd)
            elif $l.type == "turn_context" and ($l.payload.model // null) != null then
              .m = $l.payload.model
            elif $l.type == "event_msg" and $l.payload.type == "token_count"
                 and ($l.payload.info.last_token_usage // null) != null then
              ($l.payload.info.last_token_usage) as $u
              | .n += 1
              # Codex counts cached_input_tokens inside its own input_tokens, so
              # the fresh input the ledger reports is the remainder, clamped at
              # zero rather than going negative on a log that breaks that.
              # cache_write_input_tokens is NOT subtracted: no observed log
              # establishes whether it is inside input_tokens.
              | .it += ([(($u.input_tokens // 0)
                          - ($u.cached_input_tokens // 0)), 0] | max)
              | .ct += (($u.cached_input_tokens // 0)
                        + ($u.cache_write_input_tokens // 0))
              | .ot += ($u.output_tokens // 0)
              | .rt += ($u.reasoning_output_tokens // 0)
            else . end)
        | if .n > 0 then [.cwd, .m, .it, .ct, .ot, .rt] | @tsv else empty end'
    fi
    ;;
  pi|pi-signed)
    if [ -z "$REMOTE_HOST" ] && [ -n "$WORKTREE" ]; then
      # shellcheck disable=SC2016  # jq owns every $ expression in these literal programs.
      accumulate_usage "$PI_DIR" "" pi-sessions \
        'fromjson? | objects | select(.type == "session") | .cwd // empty' '
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

ROW=$(jq -cn \
  --arg task "$ID" --arg gen "$SPAWN_GEN" --arg harness "$HARNESS" \
  --arg model "$MODEL" --arg effort "$EFFORT" \
  --arg spawned "$SPAWNED" --arg completed "$COMPLETED" \
  --argjson wall "$WALL" --argjson turns "$TURNS" \
  --argjson it "$IT" --argjson ct "$CT" --argjson ot "$OT" --argjson rt "$RT" \
  --arg source "$SRC" \
  '{task:$task, spawn_gen:(if $gen == "" then null else $gen end),
    harness:(if $harness == "" then null else $harness end),
    model:(if ($model == "" or $model == "default") then null else $model end),
    effort:(if ($effort == "" or $effort == "default") then null else $effort end),
    spawned_at:(if $spawned == "" then null else $spawned end),
    completed_at:(if $completed == "" then null else $completed end),
    wall_secs:$wall, turns:$turns,
    input_tokens:$it, cached_input_tokens:$ct, output_tokens:$ot,
    reasoning_tokens:$rt, source:$source}')

# --scan-to stops here: the row is staged for a later --append-from and the
# ledger is untouched, so a caller that aborts between the two phases leaves no
# row to freeze. The staging file is written through a sibling temp file and
# renamed, so a scan killed mid-write leaves the previous content rather than a
# half row, and a torn file that reaches --append-from anyway fails its parse
# rather than appending half a row.
if [ "$STAGE_MODE" = scan ]; then
  printf '%s\n' "$ROW" > "$STAGE_FILE.tmp.$$"
  mv -f -- "$STAGE_FILE.tmp.$$" "$STAGE_FILE"
  exit 0
fi

ledger_append_row "$ROW"
