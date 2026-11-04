#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
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
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#                       It ends with the house-wiki stanza
#                       (bin/fm-house-wiki-stanza.txt, the shared read
#                       contract) plus firstmate's rule for filing worker
#                       `lesson:` clauses before teardown.
#
# Those nine names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran.
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
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
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
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes, writing X-mode artifacts,
# and fetching or fast-forwarding every project clone - before ever discovering
# another session already holds the lock. Two sessions racing those sweeps is
# exactly the hazard the lock exists to prevent, so locking first closes the
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
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/fm-bearings-snapshot.sh, /ahoy), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every in-flight, held, and blocked row is listed IN FULL, with its
#     hold_kind/hold_reason and blocked_by. Those are the rows AGENTS.md
#     sections 7 and 10 make actionable at startup, so they are never bounded
#     away.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     FM_SESSION_START_QUEUED_LIMIT, default 20. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces FM_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; the groups
# can overlap, because an in-flight item that is also held appears under both.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS TAILS: FM_SESSION_START_STATUS_TAIL bounds how many lines each task's
# tail prints, and bin/fm-line-cap-lib.sh bounds how long each of those lines
# may be. Both bounds are safe because the section prints every task's full
# status log path, and AGENTS.md section 8 treats a status line as a wake EVENT
# rather than current state - bin/fm-crew-state.sh owns current state.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes, the backlog listing,
# and the per-task endpoint reads are all unbounded subprocesses. So the whole
# digest still runs as ONE bounded child of this script
# (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the bound was hit is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner naming the stage that did not finish and the
# sections that were therefore never emitted, and still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--compact] [--source <source>]
#   Prints the full ordered digest to stdout and exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest. The one exception is a broken
#   checkout: a missing bin/fm-house-wiki-stanza.txt refuses with exit 1
#   before the lock is taken and before any digest is printed.
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
#             ownership must be re-verified rather than assumed: fm-lock.sh already treats a lock
#             this session's own harness holds as its own, so the re-emit
#             proceeds, while a lock another live session took meanwhile still
#             produces the ordinary read-only path.
#
#   --compact Render the COMPACT view a context compaction re-delivers, passed
#             only by fm-sessionstart-run.sh for the `compact` source (with or
#             without --reemit). The full digest re-injected after every
#             compaction exceeded 512 KiB on a large fleet and refilled the
#             context it was compacted from, so the next compaction followed
#             minutes later. Composition, lock, sweeps, and the completion
#             record are unchanged; only rendering differs. Kept verbatim: the
#             lock and bootstrap sections, the whole wake-queue presentation
#             (records, OPEN DECISIONS, UNREAD STATUS, WAKE_ACK_REQUIRED),
#             the supervision operating instructions, any AGENTS.md
#             instruction refresh (the cached system-prompt copy is stale, and
#             a pointer would only move the same bytes into a discretionary
#             read), network checks, and the closing reminder and wiki stanza.
#             Bounded: the backlog as one line per item without hold reasons
#             or bodies (titles cut, the ready list capped), every task record
#             as one line (id, endpoint alive/dead, PR, newest status event;
#             backend and terminal only when the endpoint is not alive),
#             and orphan status logs by id. The projects and secondmates
#             routing tables print verbatim, as in the full view. Curated
#             memory (captain, then captain-shared, then learnings) is named
#             with its size and re-inlined only as the head of each file
#             within one shared byte budget derived from
#             config/startup-memory-budget; a file cut at a line boundary says
#             so and names the path that holds the rest. The COMPACT_* budgets
#             below own the exact bounds; every section that hits one
#             discloses its omitted count, the omitted ids where useful, and
#             the command that lists the rest.
#             Every other caller - a true startup, /clear, and any explicit
#             run - keeps the full digest.
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
COMPACT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --compact)
      COMPACT=1
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
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--compact] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

WIKI_STANZA_FILE="$SCRIPT_DIR/fm-house-wiki-stanza.txt"
if [ ! -f "$WIKI_STANZA_FILE" ]; then
  echo "fm-session-start.sh: missing house-wiki stanza $WIKI_STANZA_FILE" >&2
  exit 1
fi

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

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
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*|0) SESSION_START_BUDGET=120 ;; esac
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  SESSION_START_CHILD_ARGS=()
  [ "$REEMIT" -eq 0 ] || SESSION_START_CHILD_ARGS+=(--reemit)
  [ "$COMPACT" -eq 0 ] || SESSION_START_CHILD_ARGS+=(--compact)
  [ -z "$SESSION_SOURCE" ] || SESSION_START_CHILD_ARGS+=(--source "$SESSION_SOURCE")
  fm_run_timed "$SESSION_START_BUDGET" \
    env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
    "$SCRIPT_DIR/fm-session-start.sh" ${SESSION_START_CHILD_ARGS[@]+"${SESSION_START_CHILD_ARGS[@]}"}
  SESSION_START_RC=$?
  if [ "$SESSION_START_RC" -eq 124 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
    printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

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
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as MISSING. Computing it once and handing it to that
# child collapses six subprocesses to three. fm-tasks-axi-lib.sh owns both reuse
# layers and the one-hop consumption rule that keeps the verdict out of any
# agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

# Compact post-compaction view (--compact). Every bound below is a fixed byte or
# character budget rather than a per-fleet scale. With the curated-memory
# excerpt (config/startup-memory-budget estimated tokens at that library's 3
# bytes per token, about 22.5 KB at its 7500 default, shared across the three
# memory files), the whole compact digest - excluding only the verbatim
# wake-queue presentation, the verbatim routing tables, and an AGENTS.md
# instruction refresh - stays under 128 KiB however large the fleet grows; their
# sum, plus this script's fixed sections, is what
# tests/fm-session-start.test.sh holds to that bound. Each section that hits its
# budget discloses an exact omitted count and the command that shows the rest.
COMPACT_TITLE_CAP=40
COMPACT_STATUS_CAP=64
COMPACT_ROW_CAP=160
COMPACT_READY_LIMIT=10
COMPACT_INFLIGHT_BUDGET=2048
COMPACT_HELD_BUDGET=11264
COMPACT_BLOCKED_BUDGET=2048
COMPACT_MANUAL_BUDGET=16384
COMPACT_TASKS_BUDGET=12288
COMPACT_OMITTED_IDS_BUDGET=1024
COMPACT_ORPHAN_BUDGET=1024

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

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print $0; next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path"
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1 path=$2
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" -v path="$path" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - tasks-axi ready --file %s)\n", total - shown, path
        }
      }
    }
  '
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | strip_axi_help
    printf '\nheld (captain- or time-gated; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | strip_axi_help
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | strip_axi_help
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready" "$path"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$FM_LINE_CAP_DEFAULT" "$status"
  # A crewmate writes its own status lines, so their length is unbounded: one
  # observed line ran 865 characters. Cap each one the way the wake digest's
  # OPEN DECISIONS section does; the lede carries the state word and the key,
  # and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

# compact_budget <bytes> <noun> <pointer> [<id-list-bytes>]: pass stdin row
# lines - indented or list-item lines - through while they fit in <bytes>, then
# count every remaining row and disclose it with <pointer>. Every other line (a
# heading, a header, a "(...)" summary or footer) passes through uncounted, so
# the omitted count is exact and a section's own totals survive. A positive
# <id-list-bytes> also names the omitted rows' first words (their task ids)
# within that second budget, so a bounded section still says WHICH records it
# left out. Byte semantics under LC_ALL=C.
compact_budget() {
  LC_ALL=C awk -v budget="$1" -v noun="$2" -v pointer="$3" -v idbudget="${4:-0}" '
    !/^[[:space:]*-]/ { print; next }
    {
      n = length($0) + 1
      if (!over && used + n <= budget) { print; used += n; next }
      over = 1
      omitted++
      if (idbudget > 0 && $1 != "") {
        if (idused + length($1) + 2 <= idbudget) {
          ids = ids (ids == "" ? "" : ", ") $1
          idused += length($1) + 2
          listed++
        }
      }
    }
    END {
      if (omitted > 0) {
        printf "(%d more %s omitted by the post-compaction size budget - %s)\n", omitted, noun, pointer
        if (listed > 0) {
          printf "(omitted: %s%s)\n", ids, (omitted > listed ? sprintf(" and %d more", omitted - listed) : "")
        }
      }
    }
  '
}

# compact_axi_rows <title-cap> <ready-limit> <skip-ids>: re-render one
# tasks-axi TOON listing as one bounded line per task - id, kind, repo, any
# extra fields (hold_kind, blocked_by) as name=value, then the title cut to
# <title-cap> characters. hold_reason is never rendered here; it is the long
# field the compact view exists to drop. TOON quoting ("..." with backslash
# escapes) is decoded so a comma inside a title cannot shift fields. A
# positive <ready-limit> keeps only that many rows; <skip-ids> is a
# space-separated id list to leave out (in-flight tasks the work-under-way
# section already shows). The tool's count line, field header, and help block
# are dropped, and this function prints its own count; any other tool line,
# such as ready_public_followups, passes through capped. Cuts count UTF-8
# characters, the bin/fm-line-cap-lib.sh rule, so a multibyte character is
# never cut in half.
compact_axi_rows() {
  LC_ALL=C awk -v cap="$1" -v limit="$2" -v skip=" $3 " -v rowcap="$COMPACT_ROW_CAP" '
    function cut(s, max,    i, n, c, keep) {
      n = 0; keep = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "\200" && c <= "\277") continue
        n++
        if (n == max - 2) keep = i - 1
        if (n > max) return substr(s, 1, keep) "..."
      }
      return s
    }
    function parse(s,    i, c, val, inq, n) {
      n = 0; val = ""; inq = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) {
          if (c == "\\") {
            i++
            c = substr(s, i, 1)
            val = val (c == "n" || c == "t" ? " " : c)
            continue
          }
          if (c == "\"") { inq = 0; continue }
          val = val c
          continue
        }
        if (c == "\"") { inq = 1; continue }
        if (c == ",") { F[++n] = val; val = ""; continue }
        val = val c
      }
      F[++n] = val
      return n
    }
    /^help\[/ { exit }
    /^[a-z_]+\[[0-9]+\][{].*[}]:[[:space:]]*$/ {
      hdr = $0
      sub(/^[^{]*[{]/, "", hdr)
      sub(/[}]:[[:space:]]*$/, "", hdr)
      nf = split(hdr, NAMES, ",")
      rows = 1
      next
    }
    rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split("", F)
      parse(line)
      delete V
      for (i = 1; i <= nf; i++) V[NAMES[i]] = F[i]
      if (index(skip, " " V["id"] " ") > 0) { skipped++; next }
      total++
      if (limit > 0 && shown >= limit) next
      out = "  " V["id"] " (" V["kind"] ", " V["repo"] ")"
      for (i = 1; i <= nf; i++) {
        name = NAMES[i]
        if (name == "id" || name == "state" || name == "kind" || name == "repo" || name == "title" || name == "hold_reason") continue
        if (V[name] == "" || V[name] == "-" || V[name] == "none") continue
        if (name == "hold_kind" && V[name] == "captain") continue
        out = out " " (name == "hold_kind" ? "hold" : name) "=" V[name]
      }
      out = out " - " cut(V["title"], cap)
      print cut(out, rowcap)
      shown++
      next
    }
    { rows = 0 }
    /^count:[[:space:]]*[0-9]+[[:space:]]*$/ || /^[[:space:]]*$/ { next }
    { print cut($0, rowcap) }
    END {
      printf "(%d item(s)", total + 0
      if (limit > 0 && total > shown) printf ", first %d shown, %d more", shown, total - shown
      if (skipped > 0) printf ", %d more listed under Work under way", skipped
      printf ")\n"
    }
  '
}

print_backlog_tasks_axi_compact_view() {
  local path=$1 in_flight held blocked ready err meta_ids meta id
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields hold_kind 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields blocked_by 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    meta_ids=
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      meta_ids="$meta_ids $id"
    done
    printf 'compact backlog listing (tasks-axi; one line per item, titles cut to %s characters, hold reasons and bodies omitted; full row: tasks-axi show <id> --full; every hold reason: tasks-axi list --file %s --state held --fields hold_kind,hold_reason)\n' \
      "$COMPACT_TITLE_CAP" "$path"
    printf '\nin flight without a live task record below:\n'
    printf '%s\n' "$in_flight" | compact_axi_rows "$COMPACT_TITLE_CAP" 0 "$meta_ids" |
      compact_budget "$COMPACT_INFLIGHT_BUDGET" "in-flight item(s)" "tasks-axi list --file $path --state in_flight" "$COMPACT_OMITTED_IDS_BUDGET"
    printf '\nheld (captain- or time-gated; hold kind is captain unless a hold= field says otherwise; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | compact_axi_rows "$COMPACT_TITLE_CAP" 0 "" |
      compact_budget "$COMPACT_HELD_BUDGET" "held item(s)" "tasks-axi list --file $path --state held" "$COMPACT_OMITTED_IDS_BUDGET"
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | compact_axi_rows "$COMPACT_TITLE_CAP" 0 "" |
      compact_budget "$COMPACT_BLOCKED_BUDGET" "blocked item(s)" "tasks-axi list --file $path --state queued --blocked"
    printf '\nready queued (dispatchable now):\n'
    printf '%s\n' "$ready" | compact_axi_rows "$COMPACT_TITLE_CAP" "$COMPACT_READY_LIMIT" ""
    printf '(full ready list: tasks-axi ready --file %s)\n' "$path"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  fm_cap_line "$err" "$COMPACT_ROW_CAP"
  print_backlog_manual_compact_view "$path" "fallback"
}

print_backlog_manual_compact_view() {
  local path=$1 reason=$2 line
  print_backlog_manual_compact "$path" "$reason" |
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        [-*][[:space:]]*) fm_cap_line "$line" "$COMPACT_ROW_CAP" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done |
    compact_budget "$COMPACT_MANUAL_BUDGET" "backlog title line(s)" "read data/backlog.md"
}

# The compact view of data/backlog.md: the same backend selection as the full
# listing, rendered one bounded line per item under fixed byte budgets.
print_backlog_compact_view() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact_view "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact_view "$path" "manual backend"
      else
        print_backlog_manual_compact_view "$path" "tasks-axi unavailable or incompatible"
      fi
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# endpoint_liveness <meta> <id> <window> <backend>: the same cheap alive/dead
# presence read the full view prints, as one word: alive, dead, or unknown.
endpoint_liveness() {
  local meta=$1 id=$2 window=$3 backend=$4 target
  if [ -z "$window" ]; then
    printf 'unknown\n'
    return 0
  fi
  target=$(fm_backend_target_of_meta "$meta")
  if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
    printf 'alive\n'
  else
    printf 'dead\n'
  fi
}

# The compact work-under-way view: one line per task carrying what supervision
# acts on - task id, endpoint alive/dead, PR URL, and the newest status event.
# The terminal handle prints only for an endpoint that is not alive, because a
# live worker is steered by task id and only recovery needs the handle (the
# window too, when it is not the default fm-<id>). The newest event prints as
# its state word alone, except a decision, blocker, or failure, whose text
# prints cut to COMPACT_STATUS_CAP: the wake queue and its OPEN DECISIONS and
# UNREAD STATUS sections above already carry every event that still needs
# handling, so routine history is the cheapest thing to drop. Lines are ordered
# endpoints that are not alive first, then tasks whose newest event is a
# decision, blocker, failure, pause, or completion, then the rest, so the byte
# budget only ever omits live, routinely working tasks first.
print_work_under_way_compact() {
  local meta id window backend endpoint pr terminal status last word line urgent='' actionable='' routine=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    window=$(fm_meta_get "$meta" window)
    backend=
    [ -z "$window" ] || backend=$(fm_backend_of_meta "$meta")
    endpoint=$(endpoint_liveness "$meta" "$id" "$window" "$backend")
    pr=$(fm_meta_get "$meta" pr)
    line="  $id $endpoint"
    if [ "$endpoint" != alive ]; then
      terminal=$(fm_meta_get "$meta" terminal)
      [ "$window" = "fm-$id" ] || line="$line window=${window:-none}"
      [ -z "$terminal" ] || line="$line terminal=$terminal"
    fi
    [ -z "$pr" ] || line="$line pr=$pr"
    status="$STATE/$id.status"
    last=
    [ -f "$status" ] && last=$(tail -n 1 "$status" 2>/dev/null)
    word=${last%%:*}
    word=${word%% *}
    case "$word" in
      ''|*[!a-z-]*) word=other ;;
    esac
    if [ -z "$last" ]; then
      line="$line last=(none)"
    else
      case "$word" in
        needs-decision|blocked|failed)
          fm_cap_line_var "$last" "$COMPACT_STATUS_CAP"
          line="$line last: $FM_LINE_CAP_LINE"
          ;;
        *) line="$line last=$word" ;;
      esac
    fi
    if [ "$endpoint" != alive ]; then
      urgent="$urgent$line"$'\n'
    elif [ -n "$last" ] && [ "$word" != working ]; then
      actionable="$actionable$line"$'\n'
    else
      routine="$routine$line"$'\n'
    fi
  done
  if [ -z "$urgent$actionable$routine" ]; then
    printf '(none)\n'
    return 0
  fi
  printf '%s' "$urgent$actionable$routine" |
    compact_budget "$COMPACT_TASKS_BUDGET" "task record(s)" "read state/<id>.meta and bin/fm-crew-state.sh <id>" "$COMPACT_OMITTED_IDS_BUDGET"
}

# compact_memory_budget_bytes: the one byte budget the compact view's three
# curated-memory excerpts share - config/startup-memory-budget's estimated
# tokens (its default when absent or invalid) at that library's 3 bytes per
# token.
compact_memory_budget_bytes() {
  local tokens
  tokens=$(fm_startup_memory_budget_read "$CONFIG" 2>/dev/null) || tokens=$FM_STARTUP_MEMORY_BUDGET_DEFAULT
  printf '%s\n' "$((tokens * 3))"
}

# print_memory_excerpt <path> <label>: curated memory after a compaction - its
# size, then the head of the file cut at a line boundary within whatever of
# COMPACT_MEMORY_LEFT earlier files left, which it spends. The full digest
# delivered the whole file at true session start, and this script's ORDERING
# note ranks it cheapest to lose, so a cut file names the path holding the rest.
print_memory_excerpt() {
  local path=$1 label=$2 bytes excerpt rc used
  subsection "$label"
  if [ ! -f "$path" ]; then
    printf 'ABSENT\n'
    return 0
  fi
  bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
  printf 'present (%s bytes) - head re-inlined within the shared post-compaction memory budget; read %s, or grep it, before a decision that depends on the rest.\n' "${bytes:-?}" "$path"
  excerpt=$(LC_ALL=C awk -v budget="$COMPACT_MEMORY_LEFT" '
    { n = length($0) + 1; if (used + n > budget) { cut = 1; exit } print; used += n }
    END { if (cut) exit 3 }
  ' "$path")
  rc=$?
  if [ -n "$excerpt" ]; then
    printf '%s\n' "$excerpt"
    used=$(printf '%s\n' "$excerpt" | LC_ALL=C wc -c | tr -d ' ')
    COMPACT_MEMORY_LEFT=$((COMPACT_MEMORY_LEFT - used))
  fi
  [ "$rc" -ne 3 ] || printf '(truncated - read %s for the rest)\n' "$path"
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
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'secondmate convergence and liveness, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $FM_HOME"
fi
if [ "$COMPACT" -eq 1 ]; then
  printf 'COMPACT POST-COMPACTION VIEW: the wake queue, its acknowledgement, open\n'
  printf 'decisions, and supervision instructions are complete; the fleet state is\n'
  printf 'one bounded line per item and curated memory is re-inlined only as a\n'
  printf 'bounded head of each file.\n'
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
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
  }
fi
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result. A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
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
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

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
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
if [ "$COMPACT" -eq 1 ]; then
cat <<'EOF'
This is the COMPACT view a context compaction re-delivers, so it stays small
enough not to refill the context it was compacted from. Below: every task
record as one line (id, endpoint alive/dead, PR, newest status event), the
backlog as one line per item without hold reasons, the ready list capped, the
routing tables in full, and the curated memory files named with their sizes,
each re-inlined only as its head within one shared budget (a cut file says
"(truncated - read <path> for the rest)").
Every section that hit its budget says how many items it left out and how to
list them.
Do NOT bulk re-read data/backlog.md, state/*.meta, or state/*.status to rebuild
the full view. Go to a source directly only for the item a decision needs:
  - one task: state/<id>.meta, state/<id>.status, bin/fm-crew-state.sh <id>,
  - one backlog item or hold reason: tasks-axi show <id> --full,
  - curated memory past its excerpt that a decision depends on:
    data/captain.md, data/captain-shared.md, data/learnings.md,
  - the NETWORK CHECKS verdict when still IN PROGRESS
    (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
EOF
else
cat <<'EOF'
Everything below is printed in full for this session start: every state/*.meta,
a compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (tasks-axi show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
EOF
fi

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
print_work_under_way_full() {
  local meta id window target backend status META_FOUND=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    META_FOUND=1
    id=$(basename "$meta" .meta)
    printf '\n--- %s ---\n' "$id"
    cat "$meta"

    window=$(fm_meta_get "$meta" window)
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$window" ]; then
      backend=$(fm_backend_of_meta "$meta")
      if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
        printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
      else
        printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
      fi
    else
      printf 'endpoint: unknown (no window recorded)\n'
    fi

    status="$STATE/$id.status"
    if [ -f "$status" ]; then
      print_status_tail "$status"
    else
      printf 'status tail: (no status file yet: %s)\n' "$status"
    fi
  done
  [ "$META_FOUND" -eq 1 ] || printf '(none)\n'
}

# print_orphan_status_logs <full|compact>: status logs whose task record is
# gone. The compact view names them only; the full view prints their tails.
print_orphan_status_logs() {
  local view=$1 status id found=0
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    found=1
    if [ "$view" = compact ]; then
      printf '  %s\n' "$id"
    else
      printf '\n--- %s ---\n' "$id"
      print_status_tail "$status"
    fi
  done
  [ "$found" -eq 1 ] || printf '(none)\n'
}

stage fleet-state
section "FLEET STATE"
if [ "$COMPACT" -eq 1 ]; then
  print_backlog_compact_view "$DATA/backlog.md" "data/backlog.md"
  subsection "Work under way (state/*.meta: <id> <endpoint alive|dead|unknown> [terminal when not alive] [pr] <newest status event - wake-EVENT history, not current state; full log state/<id>.status>)"
  print_work_under_way_compact
  subsection "Orphan status logs (state/*.status without matching .meta; full log: state/<id>.status)"
  print_orphan_status_logs compact |
    compact_budget "$COMPACT_ORPHAN_BUDGET" "orphan status log(s)" "ls $STATE/*.status"
else
  print_backlog_compact "$DATA/backlog.md" "data/backlog.md"
  subsection "Work under way (state/*.meta)"
  print_work_under_way_full
  subsection "Orphan status logs (state/*.status without matching .meta)"
  print_orphan_status_logs full
fi

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
    printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
if [ "$COMPACT" -eq 1 ]; then
  print_file_or_absent "$DATA/projects.md" "data/projects.md"
  print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
  COMPACT_MEMORY_LEFT=$(compact_memory_budget_bytes)
  print_memory_excerpt "$DATA/captain.md" "data/captain.md"
  print_memory_excerpt "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
  print_memory_excerpt "$DATA/learnings.md" "data/learnings.md"
else
  print_file_or_absent "$DATA/projects.md" "data/projects.md"
  print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
  print_file_or_absent "$DATA/captain.md" "data/captain.md"
  print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
  print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
fi

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF
printf '\n'
cat "$WIKI_STANZA_FILE"
cat <<'EOF'
Workers never write the vault: `lesson:` is not a status state but a trailing clause permitted only on a worker's `done:` or `failed:` line. Before running `bin/fm-teardown.sh` for a task, which removes `state/<id>.status`, scan that log for `lesson:` clauses (a deterministic read, never a wake-dependent one) and file each, plus any durable lesson of your own, with `wiki-retro` (Pi: `wiki_retro`).
Never edit `raw/` or `meta/`; never call `/wiki-run` or `wiki_watch`.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
