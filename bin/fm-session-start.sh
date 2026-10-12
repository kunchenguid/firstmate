#!/usr/bin/env bash
# fm-session-start.sh - one command for session start.
#
# The core part prints the lock, bootstrap, wake queue, supervision block,
# one fleet row per task, network checks, and short project and secondmate
# lines. Captain preferences and learnings are their own parts so a harness
# that shows one hook message per command can deliver each under its own cap.
# The default --part all prints core, then preferences, then learnings, for a
# harness that shows a single message.
# A section that does not fit the byte budget is replaced where it stood by a
# WITHHELD line naming a read-only command. Nothing is dropped unnamed.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-wake-drain.sh, and fm-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (same-home backlog reconciliation,
#                       secondmate convergence, secondmate liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#                       First, on every harness and away posture, it seeds the
#                       outcome store's display tail copy when that is absent
#                       (bin/fm-branch-outcome.sh seed-tail).
#   4. supervision-instructions - the emitted operating block for the detected
#                       primary harness. It is never withheld. Claude uses
#                       --brief; every other harness gets the full block.
#   5. fleet digest   - one row per task (kind, project, endpoint verdict,
#                       last status state and age, PR URL, open decision keys),
#                       the away posture, an orphan-status count,
#                       and a cheap per-task endpoint read. Full meta and
#                       status tails are not printed. The per-task reads run
#                       serially, so with a wedged backend the stage's ceiling
#                       is tasks x the per-read bound
#                       (FM_SESSION_START_ENDPOINT_TIMEOUT, default 10s).
#   6. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it. It prints
#                       before the budgeted sections, so it is never withheld.
#   7. context        - the backlog summary, project names, and secondmate
#                       names, each budgeted. Captain preferences and learnings
#                       are separate --part messages.
#   8. closing reminder - points back at the supervision block and never arms
#                       the watcher itself.
#
# Those names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran - and the parent banners
# EVERY nonzero child exit, not only the bound: a child that dies or is killed
# mid-stage must never truncate the digest silently.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote secondmate could burn the
# entire FM_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, secondmate liveness, secondmate
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 6 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/fm-startup-network.sh owns that stage and its safety argument;
# bin/fm-bootstrap.sh and bin/fm-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING: the harness truncates an oversized hook payload from the tail, and
# a trailing index of omissions is lost when the child dies mid-run. The child
# therefore measures its own output in bytes and, when the next budgeted
# section would pass the harness budget, prints a WITHHELD line in that
# section's place. The line names a read-only command. Every budgeted section
# prints after the never-cut ones except the closing text, whose size is
# reserved before the budgeted sections are measured. Never-cut sections
# still print when they alone exceed the budget. Captain preferences and
# learnings are not in the core budget; they are their own parts.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: counts per group, the ready ids, the captain-held ids, and
# the count of other holds. Done rows are never listed. Hold reasons are not
# printed; `bin/fm-tasks-axi.sh list --state held --fields hold_kind,hold_reason`
# retrieves them, one state per call. A tasks-axi list failure prints its
# error text and falls back to the same counts taken from title lines.
# Full bodies stay on demand: `bin/fm-tasks-axi.sh show <id> --full`, or
# `data/backlog.md` when the file body is truly needed.
#
# FLEET ROWS: each row prints whole and is never cut; every field is
# structured, with no status prose. One line above the rows
# names the per-task record files and the current-state commands; the row
# itself prints no status tail, meta, or record path. bin/fm-crew-state.sh owns
# current state. Open decision keys come from bin/fm-classify-lib.sh.
# The byte budget is bytes, not characters: claude 8500, codex 7000, every
# other harness 8500. FM_SESSION_START_BUDGET_BYTES overrides it for tests.
# The Pi/pi-signed compaction AGENTS.md refresh is outside that budget.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes and the backlog
# listing are unbounded subprocesses, while each per-task endpoint read runs
# in its own crash-isolated child under FM_SESSION_START_ENDPOINT_TIMEOUT
# (default 10s). So the whole digest still runs as ONE bounded child of this
# script (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the child stopped is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner on ANY nonzero child exit - the runtime bound
# or an unexpected child death, named with its exit status - naming the stage
# that did not finish and the sections that were therefore never emitted, and
# still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--source <source>] [--part core|preferences|learnings|all]
#   Prints the selected session-start part to stdout and always exits 0: this
#   is a reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#   --part defaults to all. all prints the core, then captain preferences,
#   then learnings. preferences and learnings print only that part and take
#   no lock. core prints the budgeted startup message without those files.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, secondmate convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: fm-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path.
#
#   --source  The native session-open source, supplied only by
#             fm-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a missing baseline, a baseline
#             for another harness pid, or a changed hash causes the complete
#             current AGENTS.md to print before the bulky digest. The baseline
#             remains immutable so every later drifted compaction refreshes
#             again, while an equal baseline emits no instruction refresh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"

REEMIT=0
SESSION_SOURCE=
PART=all
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    --part)
      PART=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --part=*)
      PART=${1#--part=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>] [--part core|preferences|learnings|all]\n' >&2
      exit 2
      ;;
  esac
done
case "$PART" in
  core|preferences|learnings|all) ;;
  *)
    printf 'fm-session-start: unknown --part: %s\n' "$PART" >&2
    exit 2
    ;;
esac

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
case "$PART" in
  preferences) SESSION_START_STAGES='preferences' ;;
  learnings) SESSION_START_STAGES='learnings' ;;
  *) SESSION_START_STAGES='lock bootstrap wake-queue supervision-instructions fleet-state network-checks context next-step' ;;
esac

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  CHILD_ARGS=()
  [ "$REEMIT" -eq 1 ] && CHILD_ARGS+=(--reemit)
  [ -n "$SESSION_SOURCE" ] && CHILD_ARGS+=(--source "$SESSION_SOURCE")
  CHILD_ARGS+=(--part "$PART")
  # Detect the harness here, not in the child: the timeout wrapper and the
  # child add process levels, and inside a Codex exec hook that pushed codex
  # past the eight levels bin/fm-harness.sh climbs, so the child saw unknown.
  SESSION_START_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  fm_run_timed "$SESSION_START_BUDGET" \
    env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
    FM_SESSION_START_PRIMARY_HARNESS="$SESSION_START_HARNESS" \
    "$SCRIPT_DIR/fm-session-start.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}
  SESSION_START_RC=$?
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=${FM_SESSION_START_PRIMARY_HARNESS:-unknown}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"


# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint=ERROR row instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${FM_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# 10# keeps a leading zero out of octal.
session_start_budget_bytes() {
  local raw=${FM_SESSION_START_BUDGET_BYTES:-}
  case "$raw" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$((10#$raw))"; return 0 ;;
  esac
  case "$PRIMARY_HARNESS" in
    codex) printf '7000\n' ;;
    *) printf '8500\n' ;;
  esac
}

note_bytes() {
  local n
  n=$(printf '%s' "$1" | wc -c | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  COUNTED_BYTES=$((COUNTED_BYTES + n))
}

emit() {
  printf '%s' "$1"
  note_bytes "$1"
}

emit_uncounted() {
  cat
}

part_header_lines() {
  local part=$1 extra=${2:-}
  if [ -n "$extra" ]; then
    printf 'SESSION START %s - %s part, budget %s bytes, %s; withheld sections are named inline with a read-only command to retrieve each.\n' \
      "$FM_HOME" "$part" "$BUDGET_BYTES" "$extra"
  else
    printf 'SESSION START %s - %s part, budget %s bytes; withheld sections are named inline with a read-only command to retrieve each.\n' \
      "$FM_HOME" "$part" "$BUDGET_BYTES"
  fi
  printf '%s\n' 'If this message reached you as a truncated preview, read the full output file the harness named before any other action.'
}

try_budgeted() {
  local body=$1 withheld=$2 n
  n=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ $((COUNTED_BYTES + n + TAIL_RESERVE)) -le "$BUDGET_BYTES" ]; then
    emit "$body"
  else
    emit "$withheld"
  fi
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

print_preferences_files() {
  print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
  print_file_or_absent "$DATA/captain.md" "data/captain.md"
}

print_preferences_part() {
  local body
  body=$(print_preferences_files; printf x)
  print_file_part preferences "${body%x}" "read data/captain-shared.md and data/captain.md"
}

print_learnings_files() {
  print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
}

print_learnings_part() {
  local body
  body=$(print_learnings_files; printf x)
  print_file_part learnings "${body%x}" "read data/learnings.md"
}

print_file_part() {
  local part=$1 body=$2 hint=$3 n headers hn
  n=$(printf '%s' "$body" | wc -c | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  headers=$(part_header_lines "$part")
  hn=$(printf '%s' "$headers" | wc -c | tr -d '[:space:]')
  case "$hn" in ''|*[!0-9]*) hn=0 ;; esac
  if [ $((hn + n)) -gt "$BUDGET_BYTES" ]; then
    headers=$(part_header_lines "$part" "OVERFLOW ${n} bytes, printed in full below; if a preview cut it, $hint")
  fi
  printf '%s%s' "$headers" "$body"
}

print_core_absence_lines() {
  printf '%s\n' 'If preferences are absent, read data/captain-shared.md and data/captain.md now.'
  printf '%s\n' 'If the learnings message is absent, read data/learnings.md now.'
}

fm_parse_axi_table() {
  awk -v mode="$1" '
    function csvn(line, out,   i, n, c, q, field) {
      n = 0
      field = ""
      q = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q) {
          if (c == "\"") {
            if (substr(line, i + 1, 1) == "\"") {
              field = field "\""
              i++
            } else q = 0
          } else field = field c
        } else if (c == "\"") q = 1
        else if (c == ",") {
          n++
          out[n] = field
          field = ""
        } else field = field c
      }
      n++
      out[n] = field
      return n
    }
    /^help\[/ { in_rows = 0; next }
    /^ready_public_followups:/ { print "F\t" $0; next }
    /^tasks\[[0-9]+\]\{/ || /^ready\[[0-9]+\]\{/ {
      spec = $0
      sub(/^[[:alpha:]]+\[[0-9]+\]\{/, "", spec)
      sub(/\}:.*$/, "", spec)
      ncol = split(spec, cols, ",")
      kind_col = 0
      for (i = 1; i <= ncol; i++) if (cols[i] == "hold_kind") kind_col = i
      in_rows = 1
      next
    }
    in_rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = csvn(line, f)
      id = f[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      if (id == "") next
      if (mode == "ready") { print id; next }
      kind = ""
      if (kind_col > 0 && kind_col <= n) kind = f[kind_col]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", kind)
      print id "\t" kind
    }
  '
}

ss_render_backlog_texts() {
  local mode=$1 style=$2 sed_cmd=$3 ready_ids cap_ids done_line
  ready_ids=${SS_READY_IDS# }
  cap_ids=${SS_CAP_IDS# }
  [ -n "$ready_ids" ] || ready_ids='(none)'
  [ -n "$cap_ids" ] || cap_ids='(none)'
  if [ -n "$SS_DONE" ]; then
    done_line="done rows omitted: $SS_DONE"
  else
    done_line="done rows omitted"
  fi
  BACKLOG_BODY=$(printf '%s\n' \
    "backlog ($mode): in_flight=$SS_IN held=$SS_HELD blocked=$SS_BLOCKED ready=$SS_READY" \
    "ready ids: $ready_ids" \
    "captain-held ids: $cap_ids" \
    "other holds: $SS_OTHER" \
    "$done_line")
  if [ -n "$SS_FOLLOW" ]; then
    BACKLOG_BODY="$BACKLOG_BODY"$'\n'"$SS_FOLLOW"
  fi
  BACKLOG_BODY="$BACKLOG_BODY"$'\n'"Full task bodies: bin/fm-tasks-axi.sh show <id> --full"
  if [ "$style" = axi ]; then
    BACKLOG_BODY="$BACKLOG_BODY"$'\n'"WITHHELD hold reasons :: bin/fm-tasks-axi.sh list --state held --fields hold_kind,hold_reason"
    BACKLOG_WITHHELD=$(printf '%s\n' \
      "WITHHELD backlog in_flight=$SS_IN :: bin/fm-tasks-axi.sh list --state in_flight --fields hold_kind,hold_until" \
      "WITHHELD backlog held=$SS_HELD captain=$((SS_HELD - SS_OTHER)) other=$SS_OTHER :: bin/fm-tasks-axi.sh list --state held --fields hold_kind,hold_reason" \
      "WITHHELD backlog blocked=$SS_BLOCKED :: bin/fm-tasks-axi.sh list --state queued --blocked --fields blocked_by" \
      "WITHHELD backlog ready=$SS_READY :: bin/fm-tasks-axi.sh ready" \
      "$done_line")
  else
    BACKLOG_BODY="$BACKLOG_BODY"$'\n'"WITHHELD backlog file :: $sed_cmd"
    BACKLOG_WITHHELD=$(printf '%s\n' \
      "WITHHELD backlog in_flight=$SS_IN held=$SS_HELD blocked=$SS_BLOCKED ready=$SS_READY :: $sed_cmd" \
      "$done_line")
  fi
}

ss_reset_backlog_counts() {
  SS_IN=0
  SS_HELD=0
  SS_BLOCKED=0
  SS_READY=0
  SS_OTHER=0
  SS_CAP_N=0
  SS_DONE=
  SS_CAP_IDS=
  SS_READY_IDS=
  SS_FOLLOW=
}

fill_backlog_from_tasks_axi() {
  local path=$1 in_flight held blocked ready id kind
  BACKLOG_AXI_ERROR=
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields hold_kind,hold_until 2>&1); then
    BACKLOG_AXI_ERROR=$in_flight
    return 1
  fi
  if ! held=$(tasks-axi list --file "$path" --state held --fields hold_kind,hold_until 2>&1); then
    BACKLOG_AXI_ERROR=$held
    return 1
  fi
  if ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields blocked_by 2>&1); then
    BACKLOG_AXI_ERROR=$blocked
    return 1
  fi
  if ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    BACKLOG_AXI_ERROR=$ready
    return 1
  fi
  ss_reset_backlog_counts
  while IFS=$'\t' read -r id kind || [ -n "${id:-}" ]; do
    [ -n "$id" ] || continue
    SS_IN=$((SS_IN + 1))
    if [ "$kind" = captain ]; then
      case " $SS_CAP_IDS " in
        *" $id "*) ;;
        *)
          SS_CAP_N=$((SS_CAP_N + 1))
          SS_CAP_IDS="$SS_CAP_IDS $id"
          ;;
      esac
    fi
  done < <(printf '%s\n' "$in_flight" | fm_parse_axi_table list)
  while IFS=$'\t' read -r id kind || [ -n "${id:-}" ]; do
    [ -n "$id" ] || continue
    SS_HELD=$((SS_HELD + 1))
    if [ "$kind" = captain ]; then
      case " $SS_CAP_IDS " in
        *" $id "*) ;;
        *)
          SS_CAP_N=$((SS_CAP_N + 1))
          SS_CAP_IDS="$SS_CAP_IDS $id"
          ;;
      esac
    else
      SS_OTHER=$((SS_OTHER + 1))
    fi
  done < <(printf '%s\n' "$held" | fm_parse_axi_table list)
  while IFS=$'\t' read -r id kind || [ -n "${id:-}" ]; do
    [ -n "$id" ] || continue
    SS_BLOCKED=$((SS_BLOCKED + 1))
  done < <(printf '%s\n' "$blocked" | fm_parse_axi_table list)
  while IFS= read -r id || [ -n "${id:-}" ]; do
    [ -n "$id" ] || continue
    case "$id" in
      F$'\t'*) SS_FOLLOW=${id#F$'\t'} ;;
      *)
        SS_READY=$((SS_READY + 1))
        SS_READY_IDS="$SS_READY_IDS $id"
        ;;
    esac
  done < <(printf '%s\n' "$ready" | fm_parse_axi_table ready)
  ss_render_backlog_texts tasks-axi axi ""
  return 0
}

fill_backlog_from_manual() {
  local path=$1 mode=$2 parsed tag rest id
  ss_reset_backlog_counts
  parsed=$(awk '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ { state = state_for_heading($0); next }
    /^- \[[ xX]\] / {
      rest = $0
      sub(/^- \[[ xX]\] /, "", rest)
      id = rest
      sub(/ - .*/, "", id)
      if (state == "done") { done++; next }
      if (state == "in_flight") {
        inflight++
        if ($0 ~ /hold-kind:[[:space:]]*captain/) print "CAP", id
        next
      }
      if (state == "queued") {
        if ($0 ~ /blocked-by:/) { blocked++; next }
        if ($0 ~ /hold-kind:[[:space:]]*captain/) { held++; print "CAP", id; next }
        if ($0 ~ /\(hold[):]/ || $0 ~ /hold-until:/) { held++; other++; next }
        print "READY", id
        next
      }
    }
    END {
      print "IN", inflight + 0
      print "BLOCKED", blocked + 0
      print "HELD", held + 0
      print "OTHER", other + 0
      print "DONE", done + 0
    }
  ' "$path")
  while read -r tag rest || [ -n "${tag:-}" ]; do
    [ -n "$tag" ] || continue
    case "$tag" in
      IN) SS_IN=$rest ;;
      BLOCKED) SS_BLOCKED=$rest ;;
      HELD) SS_HELD=$rest ;;
      OTHER) SS_OTHER=$rest ;;
      DONE) SS_DONE=$rest ;;
      CAP)
        SS_CAP_N=$((SS_CAP_N + 1))
        SS_CAP_IDS="$SS_CAP_IDS $rest"
        ;;
      READY)
        SS_READY=$((SS_READY + 1))
        SS_READY_IDS="$SS_READY_IDS $rest"
        ;;
    esac
  done <<EOF
$parsed
EOF
  ss_render_backlog_texts "$mode" file "sed -n p $(shell_quote "$path")"
}

prepare_backlog() {
  local path=$1
  BACKLOG_KIND=summary
  BACKLOG_BODY=
  BACKLOG_WITHHELD=
  BACKLOG_ERROR=
  BACKLOG_AXI_ERROR=
  if [ ! -f "$path" ]; then
    BACKLOG_KIND=absent
    return 0
  fi
  if [ ! -s "$path" ]; then
    BACKLOG_KIND=empty
    return 0
  fi
  if fm_tasks_axi_backend_available "$CONFIG"; then
    if ! fill_backlog_from_tasks_axi "$path"; then
      BACKLOG_ERROR=$BACKLOG_AXI_ERROR
      fill_backlog_from_manual "$path" fallback
    fi
  elif fm_backlog_backend_manual "$CONFIG"; then
    fill_backlog_from_manual "$path" "manual backend"
  else
    fill_backlog_from_manual "$path" "tasks-axi unavailable or incompatible"
  fi
}

registry_names() {
  awk '
    /^[[:space:]]*-[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      sub(/[[:space:]].*/, "", line)
      if (line != "") print line
    }
  ' "$1"
}

print_registry_section() {
  local path=$1 label=$2 what=$3 names body withheld cmd
  if [ ! -f "$path" ]; then
    body=$(subsection "$label"; printf 'ABSENT\n'; printf x)
    body=${body%x}
    emit "$body"
    return 0
  fi
  if [ ! -s "$path" ]; then
    body=$(subsection "$label"; printf '(present, empty)\n'; printf x)
    body=${body%x}
    emit "$body"
    return 0
  fi
  names=$(registry_names "$path" | awk 'NF { printf "%s%s", (n ? " " : ""), $0; n = 1 }')
  [ -n "$names" ] || names='(no registry lines)'
  cmd="sed -n p $(shell_quote "$path")"
  withheld=$(subsection "$label"; printf 'WITHHELD %s :: %s\n' "$what" "$cmd"; printf x)
  withheld=${withheld%x}
  body=$(subsection "$label"
    printf '%s: %s\n' "$what" "$names"
    printf 'WITHHELD %s lines :: %s\n' "$what" "$cmd"
    printf x)
  body=${body%x}
  try_budgeted "$body" "$withheld"
}

format_age() {  # <seconds>
  local s=$1
  if [ "$s" -lt 120 ]; then
    printf '%ss\n' "$s"
  elif [ "$s" -lt 7200 ]; then
    printf '%sm\n' "$((s / 60))"
  elif [ "$s" -lt 172800 ]; then
    printf '%sh\n' "$((s / 3600))"
  else
    printf '%sd\n' "$((s / 86400))"
  fi
}

print_fleet_row() {
  local meta=$1 id kind project window target backend endpoint_rc verdict
  local status line last age epoch now keys pr row endpoint_text
  id=$(basename "$meta" .meta)
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  project=$(fm_meta_get "$meta" project)
  if [ -n "$project" ]; then
    project=$(basename "$project")
  else
    project=-
  fi
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] || pr=-
  window=$(fm_meta_get "$meta" window)
  status="$STATE/$id.status"
  last=-
  age=-
  keys=-
  if [ -f "$status" ]; then
    line=$(last_status_line "$status")
    if [ -n "$line" ]; then
      status_line_verb "$line" last
      _fm_status_verb_recognized "$last" || last=-
      if epoch=$(status_line_at_epoch "$line"); then
        now=$(date +%s)
        case "$now" in
          ''|*[!0-9]*) ;;
          *) [ "$now" -lt "$epoch" ] || age=$(format_age $((now - epoch))) ;;
        esac
      fi
    fi
    keys=$(status_open_decisions "$status" "$kind" | awk -F '\t' 'NF && $1 != "" { printf "%s%s", (n ? "," : ""), $1; n = 1 }')
    [ -n "$keys" ] || keys=-
  fi
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    endpoint_rc=0
    fm_session_start_endpoint_read "$backend" "${target:-$window}" "fm-$id" || endpoint_rc=$?
    if [ "$endpoint_rc" -eq 0 ]; then
      verdict=alive
    elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
      verdict=ERROR
    else
      verdict=DEAD
    fi
    endpoint_text="endpoint=$verdict"
  else
    endpoint_text="endpoint=NO-WINDOW"
  fi
  row="$id kind=$kind project=$project $endpoint_text last=$last age=$age pr=$pr decisions=$keys"
  printf '%s\n' "$row"
}

print_orphan_count() {
  local status id n=0
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    printf 'Orphan status logs: none\n'
  else
    printf 'Orphan status logs: %s (each file is state/<id>.status with no matching state/<id>.meta)\n' "$n"
  fi
}

print_afk_line() {
  subsection "AFK"
  if [ -f "$STATE/.afk-contract" ]; then
    if [ "$("$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = quiet ]; then
      printf 'present - quiet mode recorded at %s (the captain is present and nothing is held for a return: requested actions proceed under ordinary attended authority; only an explicit /quiet off exits it)' \
        "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
    else
      printf 'present - away posture recorded at %s (hold-for-return only; bin/fm-afk-contract.sh readback for the mandate)' \
        "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
    fi
    if [ -e "$STATE/.afk" ]; then
      if [ "$AFK_MODE" = quiet ]; then
        printf '; the quiet daemon owns the watcher.\n'
      else
        printf '; the away daemon owns the watcher.\n'
      fi
    else
      printf '; no daemon runs, the ordinary supervision session continues.\n'
    fi
  elif [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /quiet off exits it (legacy flag with no posture record).\n'
    else
      printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
    fi
  else
    printf 'absent\n'
  fi
}

print_public_commitments() {
  local public_followup
  if fm_pf_relay_active "$FM_HOME" \
    && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
    public_followup=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || public_followup=
    if [ -n "$public_followup" ]; then
      subsection "Public commitments"
      printf '%s\n' "$public_followup"
      printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
      printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
      printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
      printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
    fi
  fi
}

print_fleet_block() {
  local meta found=0 records=state
  _fm_wake_require_classify
  section "FLEET STATE"
  [ "$STATE" = "$FM_HOME/state" ] || records=$STATE
  printf 'One row per task. Records: %s/<id>.meta and %s/<id>.status (wake history, not current state).\n' "$records" "$records"
  printf 'Current state: bin/fm-crew-state.sh <id>; whole fleet: bin/fm-fleet-view.sh.\n'
  printf 'endpoint=ERROR means the read died or hit its %ss bound; NO-WINDOW means no window is recorded.\n' "$ENDPOINT_TIMEOUT"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    found=1
    print_fleet_row "$meta"
  done
  [ "$found" -eq 1 ] || printf '(none)\n'
  print_orphan_count
  print_afk_line
  print_public_commitments
}

print_harness_extension_lines() {
  local PI_EXT PI_TURNEND_EXT PI_WATCH_MARKER PI_TURNEND_MARKER PI_LOCK
  local PI_RESTART_COMMAND PI_WATCH_VERSION PI_TURNEND_VERSION
  local OMP_EXT OMP_TURNEND_EXT OMP_WATCH_MARKER OMP_TURNEND_MARKER OMP_LOCK
  local OMP_WATCH_VERSION OMP_TURNEND_VERSION
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
    PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
    PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
    PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
    PI_LOCK="$STATE/.lock"
    PI_RESTART_COMMAND=$PRIMARY_HARNESS
    [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
    PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
    PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
    if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
      || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
      printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
    fi
  fi
  if [ "$PRIMARY_HARNESS" = omp ]; then
    OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
    OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
    OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
    OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
    OMP_LOCK="$STATE/.lock"
    OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
    OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
    if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
      || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
      printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
    fi
  fi
}

# fm_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under fm_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint row - never a
# silently missing rest of digest. The inner bash re-sources fm-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
fm_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  fm_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    fm_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid baseline_hash current_hash
  [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ] || return 0
  baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  [ "$baseline_pid" = "$lock_pid" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    emit_uncounted <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    emit_uncounted < "$FM_ROOT/AGENTS.md"
  else
    printf '%s\n' 'The original AGENTS.md baseline no longer matches, but the current file is absent.' | emit_uncounted
  fi
}

BUDGET_BYTES=$(session_start_budget_bytes)
COUNTED_BYTES=0
# Bytes of the never-cut text that prints after the budgeted sections, so a
# budgeted section is withheld rather than pushing that tail over the budget.
TAIL_RESERVE=0
case "$PART" in
  preferences)
    stage preferences
    print_preferences_part
    exit 0
    ;;
  learnings)
    stage learnings
    print_learnings_part
    exit 0
    ;;
esac

if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

stage lock
headers=$(part_header_lines core; printf x)
headers=${headers%x}
emit "$headers"
if [ "$REEMIT" -eq 1 ]; then
  banner=$(
    printf 'SESSION START (CONTEXT RE-EMIT) - %s\n' "$FM_HOME"
    printf 'This session already took the helm at its own startup and has only lost its\n'
    printf 'context. Lock ownership is re-verified and the durable records below are\n'
    printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
    printf 'secondmate convergence and liveness, pending remote handoff\n'
    printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
    printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
    printf x
  )
else
  banner=$(printf 'SESSION START - %s\n' "$FM_HOME"; printf x)
fi
banner=${banner%x}
emit "$banner"

LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
fi
lock_text=$(
  subsection "LOCK"
  printf '%s\n' "$LOCK_OUT"
  if [ "$READ_ONLY" -eq 1 ]; then
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  fi
  printf x
)
lock_text=${lock_text%x}
emit "$lock_text"
print_agents_refresh_if_required "$(fm_harness_ancestry_pid 2>/dev/null || true)"

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  fi
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

stage bootstrap
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
boot_text=$(
  subsection "BOOTSTRAP"
  if [ -n "$BOOT_OUT" ]; then
    printf '%s\n' "$BOOT_OUT"
  else
    printf '(silent - all good)\n'
  fi
  printf x
)
boot_text=${boot_text%x}
emit "$boot_text"

stage wake-queue
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1) || true
  wake_text=$(
    subsection "WAKE QUEUE"
    printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
    [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
    printf x
  )
else
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  BRANCH_REPLAY_OUT=
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1) || true
  wake_text=$(
    subsection "WAKE QUEUE"
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
    if [ -n "$DRAIN_OUT" ]; then
      printf '%s\n' "$DRAIN_OUT"
    else
      printf '(no queued wakes)\n'
    fi
    printf x
  )
fi
wake_text=${wake_text%x}
emit "$wake_text"

stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(fm_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1
ext_text=$(print_harness_extension_lines; printf x)
ext_text=${ext_text%x}
emit "$ext_text"
sup_args=(--harness "$PRIMARY_HARNESS" --read-only "$READ_ONLY" --afk "$AFK_PRESENT" --afk-mode "$AFK_MODE" --x-mode "$X_MODE_PRESENT")
[ "$PRIMARY_HARNESS" = claude ] && sup_args+=(--brief)
sup_text=$("$SCRIPT_DIR/fm-supervision-instructions.sh" "${sup_args[@]}"; printf x)
sup_text=${sup_text%x}
emit "$sup_text"

stage fleet-state
fleet_text=$(print_fleet_block; printf x)
fleet_text=${fleet_text%x}
emit "$fleet_text"

stage network-checks
net_text=$(
  section "NETWORK CHECKS"
  if [ "$READ_ONLY" -eq 1 ]; then
    printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
    printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
    printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
    printf 'has no action they would gate. The session holding the lock runs them.\n'
  else
    "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
  fi
  printf x
)
net_text=${net_text%x}
emit "$net_text"

stage context
# The closing text is fixed before the budgeted sections print, so its size
# is reserved in the budget. The completion lines are reserved at their
# longest because they are decided only after the closing text prints.
next_text=$(
  section "NEXT STEP"
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' \
      'This session did not acquire the fleet lock. Stay read-only: do not arm,' \
      'drain, spawn, steer, merge, or repair fleet state from here. Only a session' \
      'with verified fleet-lock ownership may perform mutable follow-up.' \
      ''
  elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
    printf '%s\n' \
      'Quiet mode is active. Follow the supervision operating instructions block' \
      'above: load /quiet and ensure the daemon is running, because the daemon owns' \
      'watcher supervision. Ordinary captain chat does not exit it; only an' \
      'explicit /quiet off does.' \
      ''
  elif [ "$AFK_PRESENT" -eq 1 ]; then
    printf '%s\n' \
      'Away mode is active. Follow the supervision operating instructions block above:' \
      'load /afk and ensure the daemon is running, because the daemon owns watcher' \
      'supervision.' \
      ''
  elif [ -f "$CONFIG/x-mode.env" ]; then
    printf '%s\n' \
      "Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'." \
      "X mode is active, so the emitted block's cadence instruction applies." \
      'This script never starts supervision itself.' \
      ''
  else
    printf '%s\n' \
      "Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'." \
      'This script never starts supervision itself.' \
      ''
  fi
  printf '%s\n' \
    'WITHHELD lines above name a read-only command for each omission.' \
    'Captain preferences and learnings are separate messages unless this run used --part all.'
  printf x
)
next_text=${next_text%x}
absence=$(print_core_absence_lines; printf x)
absence=${absence%x}
TAIL_RESERVE=$(printf '%s%s' "$absence" "$next_text" | wc -c | tr -d '[:space:]')
case "$TAIL_RESERVE" in ''|*[!0-9]*) TAIL_RESERVE=0 ;; esac
if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  TAIL_RESERVE=$((TAIL_RESERVE + 256))
fi
ctx_head=$(section "CONTEXT"; printf x)
ctx_head=${ctx_head%x}
emit "$ctx_head"
prepare_backlog "$DATA/backlog.md"
case "$BACKLOG_KIND" in
  absent)
    backlog_text=$(subsection "data/backlog.md"; printf 'ABSENT\n'; printf x)
    backlog_text=${backlog_text%x}
    emit "$backlog_text"
    ;;
  empty)
    backlog_text=$(subsection "data/backlog.md"; printf '(present, empty)\n'; printf x)
    backlog_text=${backlog_text%x}
    emit "$backlog_text"
    ;;
  *)
    if [ -n "$BACKLOG_ERROR" ]; then
      backlog_err=$(printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n%s\n' "$BACKLOG_ERROR"; printf x)
      backlog_err=${backlog_err%x}
      emit "$backlog_err"
    fi
    backlog_body=$(subsection "data/backlog.md"; printf '%s\n' "$BACKLOG_BODY"; printf x)
    backlog_body=${backlog_body%x}
    backlog_withheld=$(subsection "data/backlog.md"; printf '%s\n' "$BACKLOG_WITHHELD"; printf x)
    backlog_withheld=${backlog_withheld%x}
    try_budgeted "$backlog_body" "$backlog_withheld"
    ;;
esac

print_registry_section "$DATA/projects.md" "data/projects.md" "projects"
print_registry_section "$DATA/secondmates.md" "data/secondmates.md" "secondmates"
emit "$absence"

stage next-step
emit "$next_text"

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  COMPLETION_NOTE=
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    COMPLETION_NOTE=$'\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      COMPLETION_NOTE="$COMPLETION_NOTE"$'\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
  if [ -n "$COMPLETION_NOTE" ]; then
    emit "$COMPLETION_NOTE"
  fi
fi

if [ "$PART" = all ]; then
  print_preferences_part
  print_learnings_part
fi

exit 0
