#!/usr/bin/env bash
# Context-budget guardrail for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. Crew subagent turns are inert (see the scoping block
# and the sidechain filter below, and docs/context-budget.md).
#
# WHY: the captain's sessions balloon toward ~800,000 tokens before the runtime's
# own auto-compaction fires. This guard is a deliberate keep-it-lean cost and
# reasoning-quality policy that stops that balloon far earlier than anything the
# harness does on its own. It is NOT overflow prevention - nothing crashes at the
# ceiling on a 1M-context session.
#
# WHAT IT MEASURES: no hook payload on any harness carries a token count, so the
# number comes from the transcript the payload points at. transcript_path is read
# from the PAYLOAD and never derived from $HOME, because a non-default Claude
# config dir puts it somewhere $HOME cannot predict. The context total is the sum
# of input_tokens + cache_creation_input_tokens + cache_read_input_tokens +
# output_tokens on the LAST non-sidechain type=="assistant" entry. That formula
# reproduces Claude Code's own accounting exactly; docs/verification/context-
# budget.md records the cross-validation.
#
# Three correctness rules the measurement must keep:
#   1. Take LAST, never max and never a sum. Compaction RESETS the running total,
#      so a max implementation would latch the pre-compaction peak and disable
#      the guard forever after the first compaction, and a sum would report a
#      multiple of the real total. Taking the last entry also subsumes
#      multi-block dedupe for free: every JSONL line of one multi-block turn
#      carries that turn's own cumulative usage, so the last line IS the turn's
#      total and no requestId grouping is needed.
#   2. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement.
#   3. Ignore zero-total entries. Claude Code writes SYNTHETIC assistant entries
#      - type=="assistant", isSidechain false, model "<synthetic>", all four
#      usage fields 0 - whenever a turn ends abnormally, such as a login or API
#      error or an interrupt, which is exactly when this hook fires. Counting one
#      would read a long session as empty, and that false zero would then look
#      like proof the context had reset.
# The measurement is ONE streaming jq pass that filters and projects as it reads,
# so its MEMORY is constant in the transcript's size. Its TIME is still linear -
# roughly 0.7 s per 80 MB on the measured host - and that cost is paid at every
# single turn end, including far below the advisory.
#
# TWO STAGES, ONE POLICY NUMBER: the ceiling is the only policy number. The
# advisory notice is DERIVED as ceiling - headroom, so there is never a second
# threshold to keep in sync. Both are env-overridable for tests and live proof.
#
# WARNING ONLY BY DEFAULT: at the ceiling the shipped default WARNS and allows
# the turn end. Enforcement is fully implemented and switched on with
# FM_CONTEXT_BUDGET_ENFORCE=1, because a first release must observe the real
# frequency of ceiling crossings before it is allowed to interrupt anyone.
#
# TWO OUTPUT CHANNELS, CHOSEN BY EXIT STATUS: Claude Code DISCARDS a successful
# Stop hook's stderr - the hook_success attachment renders as null and only the
# SessionStart-family events feed hook output into model context - so every
# non-blocking notice here goes out as a {"systemMessage":...} object on STDOUT,
# the documented channel the runtime actually renders. Only the blocking path,
# which exits 2, uses stderr, because that path IS delivered to the model.
# docs/verification/context-budget.md records both readings.
#
# THE DEFAULT REPORTS TO THE CAPTAIN, NOT THE SESSION. systemMessage is a
# user-facing channel: a session asked about one it had visibly received answered
# that it had not seen it. Only the blocking exit-2 path reaches the model, so the
# guard reaches the session at all only with enforcement switched on. Worse, rendering is
# not guaranteed at all: a controlled experiment confirmed 30 emissions with zero
# renders. That is why the file-based TRIP RECORD below, not the notice, is the
# channel this feature relies on for observing how often the ceiling is crossed.
#
# THE TRIP RECORD IS WRITE-ONLY: every CROSSING appends one line to
# state/.context-budget-trips, and NO code path ever reads it back to decide
# anything. Only its own length is consulted, to keep it bounded. Losing or
# corrupting it therefore costs visibility and can never change a decision, which
# is exactly what keeps it out of the record loss-path class below.
# One line per CROSSING, not per turn end above the advisory: the question it
# answers is how OFTEN the guard fires, and a line per turn end answers how long a
# session lingered instead, inflating the count by the length of every episode.
# A parse failure on the block record is recorded here too, and so is a block count
# that could not be written, since a record failure leaving no trace is the one
# silent failure this file will not accept. The same rule covers a stand-down
# write that could not be persisted (the block budget is exhausted but the flag
# never lands) and a notice write that could not be persisted (the per-episode
# dedup key never lands): both are this guard violating its own stated rule if
# they go untraced.
#
# RECORD IDENTITY IS THE SESSION: both records are named per session_id, which is
# the identity of the context accumulation itself (the transcript file is
# literally <session_id>.jsonl). Two primary sessions in one home therefore
# cannot alias onto one record and wipe each other's stand-down. A missing or
# unsafe session_id makes the turn inert rather than merging distinct sessions
# under one shared identity, and the records are cleared only by evidence of a
# GENUINE reset - never by a zero, absent, or unreadable MEASUREMENT, because
# losing a stand-down costs repeated forced handoffs while keeping a stale one
# costs at most one missed warning. There are exactly two such proofs: a POSITIVE
# measurement back below the advisory, and a NEW compaction boundary in the
# transcript. The second one matters because compaction does not change
# session_id, so a session-keyed record would otherwise stay stood down across a
# real reset whose post-compaction total is still above the advisory.
# That retention bias protects a stand-down the session was actually TOLD about.
# It does NOT extend to an unparseable RECORD, which is evidence of nothing and is
# read as no record at all, leaving the guard armed; see budget_read.
#
# THE VALVE IS THE HANDOVER, NOT THIS GUARD. This guard reports earlier than the
# handover threshold and never stalls a session; AGENTS.md states the precedence and
# docs/context-budget.md owns the detail. This guard instructs and never types
# into a pane: it never injects /compact, /clear, or any other command, and it
# never spawns a replacement agent. docs/context-budget.md records the away-mode
# consequence this creates.
#
# NEVER WEDGE A SESSION: every measurement failure - absent jq or awk, missing or
# unreadable transcript_path, missing or corrupt transcript, no assistant usage,
# a zero measurement, no usable session_id, empty or malformed stdin - is a silent
# exit 0, and a block count that cannot be written degrades to the visible warning
# rather than to an unbounded block. That degrade carries its OWN notice key, so a
# ceiling notice already shown this episode cannot silence the guard's report that
# it is malfunctioning. When enforcement is on, blocking
# is bounded by FM_CONTEXT_BUDGET_BLOCK_BUDGET and then STANDS DOWN STICKILY for
# the rest of the session, re-arming only on one of the two genuine-reset proofs
# above: a POSITIVE measurement back below the advisory, or a NEW compaction
# boundary. That is deliberately unlike bin/fm-turnend-guard.sh, which resets
# its budget on every allow: a blind turn end is a repairable condition and a
# forced continuation is the repair prompt, whereas the context ceiling cannot
# clear without a captain keystroke, so blocking again would only re-run the
# handoff and grow the very context this guard exists to cap.
#
# Ships as a TRACKED Stop hook, so this file is checked out into every worktree
# of this repo, including crewmate and scout task worktrees. It therefore scopes
# itself at runtime through the shared primary predicate and stays a silent, fast
# no-op inside child task worktrees.
#
# Per-harness support is claude only in this slice. docs/context-budget.md owns
# the honest per-harness table.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CLAUDE_MODE=0

# The ceiling is the enforce point and the ONLY policy number.
CEILING=${FM_CONTEXT_BUDGET_CEILING:-180000}
# The advisory notice is derived: ceiling - headroom. Headroom buys the session
# one warning while it still has room to run the valve. The default 30,000 is
# about two worst-case turns (measured max single-turn delta 17,050) on top of
# the valve's own cost.
HEADROOM=${FM_CONTEXT_BUDGET_HEADROOM:-30000}
BLOCK_BUDGET=${FM_CONTEXT_BUDGET_BLOCK_BUDGET:-3}
# Enforcement is opt-in. Anything other than an exact 1 leaves the shipped
# warning-only default in place, so a typo can never start blocking sessions.
ENFORCE=0
[ "${FM_CONTEXT_BUDGET_ENFORCE:-}" = 1 ] && ENFORCE=1
case "$CEILING" in ''|*[!0-9]*|0) CEILING=180000 ;; esac
case "$HEADROOM" in ''|*[!0-9]*) HEADROOM=30000 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
ADVISORY=$((CEILING - HEADROOM))
[ "$ADVISORY" -gt 0 ] || ADVISORY=$CEILING

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    -h|--help) sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") --claude" >&2; exit 0 ;;
  esac
done

# --claude is the only supported mode in this slice, and it is required rather
# than a default. Claude is the only harness whose turn-end payload carries a
# transcript pointer this guard can measure; docs/context-budget.md owns the
# per-harness table. A bare or misconfigured invocation is inert rather than a
# usage error, because this runs as a Stop hook and must never wedge a session.
if [ "$CLAUDE_MODE" -ne 1 ]; then
  echo "usage: $(basename "$0") --claude" >&2
  exit 0
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# Read the whole turn-end hook payload once; never block on unreadable or absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Scope precisely to a PRIMARY checkout, before any JSON work. A genuinely-marked
# secondmate home runs its OWN primary firstmate session and is force-included;
# an unmarked linked worktree (every crewmate and scout task worktree) falls
# through and exits. Scoping first keeps the common case in a busy fleet - a
# crewmate turn end - down to a couple of git calls with no jq spawn at all.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Pin the record location for the rest of this run. Canonicalizing once means a
# symlinked or relative state path cannot resolve to two different record
# locations across a session's invocations and split one session's records in
# two, which would silently re-arm a spent stand-down.
STATE=$(cd "$STATE" 2>/dev/null && pwd -P) || exit 0

# jq is the repo's established JSON dependency (bin/fm-turnend-guard.sh:95 uses
# the same "missing jq -> silent no-op" degrade). Without it we cannot read the
# payload or the transcript at all, so we must never block.
command -v jq >/dev/null 2>&1 || exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0

# --- the measurement ---------------------------------------------------------
# ONE streaming pass: jq -R reads a line at a time and emits a tagged token for
# each line worth counting - "t <total>" for a countable assistant entry, "c" for
# a compaction boundary. awk then reduces the stream to the LAST total and the
# COUNT of boundaries. Nothing is slurped at either stage, so MEMORY is constant
# in the transcript's size; the time is still linear, and it is paid at every turn
# end including the common case far below the advisory.
#   fromjson? drops malformed or truncated lines instead of aborting, so a
#   partially written transcript degrades to "measure what parsed".
#   select(type == "object") skips a line that parses to a valid JSON SCALAR or
#   array. It is not abort protection: with jq -R every line is its own input, so
#   an error on one line is reported and the next line still runs. What the clause
#   buys is that such a line is skipped deliberately rather than by way of a
#   suppressed per-line error, which keeps the pass's diagnostics meaningful.
#   select(. > 0) drops a synthetic zero-usage entry (rule 3 in the header): a
#   real long session never measures 0, so a 0 here is a missing measurement
#   masquerading as a reset, and taking the last POSITIVE total instead reports
#   the session's real size.
#   select(.isSidechain != true) sits ABOVE the branch, so rule 2 governs the
#   WHOLE pass rather than only the token total. The boundary tally is part of
#   that measurement now that a boundary CLEARS a record, and a subagent's
#   compaction is no evidence at all that the primary's context reset.
#   The compaction tally rides along in the same pass, so proving a genuine reset
#   costs no second read of the transcript.
measure_context() {
  jq -R -r '
    def usage_total:
      (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.output_tokens // 0);
    (fromjson? // empty)
    | select(type == "object")
    | select(.isSidechain != true)
    | if (.type == "system" and .subtype == "compact_boundary") then "c"
      else
        select((.type == "assistant")
          and ((.message.usage | type) == "object"))
        | .message.usage
        | usage_total
        | floor
        | select(. > 0)
        | "t \(.)"
      end
  ' "$TRANSCRIPT" 2>/dev/null | awk '
    $1 == "c" { compacts += 1; next }
    $1 == "t" { total = $2 }
    END { printf "%s %s\n", (total == "" ? "0" : total), compacts + 0 }
  '
}

MEASURED=$(measure_context) || exit 0
TOTAL=${MEASURED%% *}
COMPACTS=${MEASURED##* }
case "$TOTAL" in
  ''|*[!0-9]*) exit 0 ;;
esac
case "$COMPACTS" in
  ''|*[!0-9]*) COMPACTS=0 ;;
esac
# A non-positive measurement is not evidence of anything: it means nothing
# countable was found, not that the context is empty. Stay completely inert on it
# rather than warning on a false number or treating it as proof of a drop.
[ "$TOTAL" -gt 0 ] || exit 0

# --- record identity ---------------------------------------------------------
# session_id is the identity of the context accumulation, so it names the
# records. A missing, empty, or unsafe id makes this turn inert: acting on a
# placeholder would merge two distinct sessions into one shared record, and an
# id that is not a plain filename token has no business in a path.
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
case "$SESSION_ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ "${#SESSION_ID}" -le 128 ] || exit 0

# The consecutive-block record doubles as the STICKY stand-down record: once the
# recorded standdown flag is set it stays set, and only evidence of a genuine
# reset - a positive measurement back below the advisory, or a compaction
# boundary newer than the one this record was written with - removes the file.
BUDGET_FILE="$STATE/.context-budget-blocks-$SESSION_ID"
# Which visible notice stage this session has already been shown, so neither the
# advisory nor the warning-only ceiling notice repeats inside one episode.
NOTICE_FILE="$STATE/.context-budget-notice-$SESSION_ID"

# One session's records belong to that session and nothing else clears them, so
# prune only records old enough that no live session could own them. The sticky
# path refreshes its own record on every stood-down turn end, so pruning can
# never take a stand-down away from a session that is still running. The trip
# record is deliberately not in this sweep: it spans sessions and is bounded by
# its own size cap instead.
prune_dead_records() {
  find "$STATE" -maxdepth 1 -type f \
    \( -name '.context-budget-blocks-*' -o -name '.context-budget-notice-*' \) \
    -mtime +30 -delete >/dev/null 2>&1 || true
}

# KNOWN UNFIXED: a session oscillating across the ceiling re-notices on every turn
# end. The recorded stage alternates ceiling, advisory, ceiling, so each crossing
# back looks new and prints again, and the once-per-episode contract fails on a
# DOWNWARD crossing.
#
# This is left unfixed on purpose. Replayed twice over real transcripts with the
# shipped measurement and stage logic - 189 sessions and 41,244 turns, then 190
# sessions and 41,353 turns - the condition occurred ZERO times: sessions that
# reach the ceiling climb past it rather than hover, so the case is latent, not
# live. Downward moves above the advisory do exist (155 of them), so the mechanism
# is reachable in principle. But the measurement is also effectively monotonic
# within an episode by arithmetic, since each total is the previous prompt plus
# this turn's output plus whatever else arrived: it can only FALL on a reset, and a
# compaction boundary already ends the episode.
#
# Do not "fix it while you are here". The obvious fixes - making the stage
# monotonic, or recording the highest stage reached - both close this and make the
# independent-key cases below strictly worse, because a recorded ceiling could then
# never be superseded by the count-not-recorded degrade. If it ever does occur the
# failure mode is a notice on every turn end: noisy, harmless, and self-announcing,
# so we would know within one session. tests/fm-context-budget.test.sh pins the
# current behavior deliberately.

# One field out of a record, matched by key rather than by line number so a field
# can be added without re-numbering the readers.
record_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'
}

# The notice record tracks SEVERAL INDEPENDENT things, each in its own field,
# because one field standing for several meant whichever fired first silenced the
# others for the whole episode:
#   stage         - the threshold notice last shown, advisory or ceiling.
#   unrecorded    - the count-not-recorded degrade has been reported.
#   badrecord     - an unparseable block record has been traced.
#   standdownfail - the sticky stand-down write itself could not be persisted.
#   noticedegraded - this very record could not be written and fell back to
#                    NOTICE_DEGRADED_FILE below.
# These are independent flags and NOT an ordering: nothing here ranks one above
# another, which is what keeps this shape clear of the straddle case above.
# `stage` holds a value and the others are 0/1, so the mapping lives in one place.
notice_field() {  # <notice>
  case "$1" in
    ceiling-unrecorded) printf 'unrecorded\n' ;;
    record-unparseable) printf 'badrecord\n' ;;
    standdown-unrecorded) printf 'standdownfail\n' ;;
    notice-unwritable) printf 'noticedegraded\n' ;;
    *) printf 'stage\n' ;;
  esac
}

# A fallback marker used ONLY when $NOTICE_FILE itself is unwritable while the
# state directory still accepts a new file - the same narrower shape reproduced
# for an unwritable block record, not the wholly-unwritable state directory
# below. It carries the SAME fields as $NOTICE_FILE and exists to restore
# stage_enter's once-per-crossing dedup when the primary record cannot be
# rewritten, so a session stuck in that shape traces one notice-write failure
# and then keeps deduping the ordinary crossing notices instead of retripping
# on every turn end. It is consulted only when $NOTICE_FILE has no value for a
# field, never treated as authoritative over it, and never read back to decide
# anything the trip record itself decides.
NOTICE_DEGRADED_FILE="$STATE/.context-budget-notice-degraded-$SESSION_ID"

notice_record_field() {  # <key>
  local val
  val=$(record_field "$NOTICE_FILE" "$1")
  [ -n "$val" ] || val=$(record_field "$NOTICE_DEGRADED_FILE" "$1")
  printf '%s\n' "$val"
}

notice_seen() {  # <notice>
  local field
  field=$(notice_field "$1")
  if [ "$field" = stage ]; then
    [ "$(notice_record_field stage)" = "$1" ]
  else
    [ "$(notice_record_field "$field")" = 1 ]
  fi
}

# Recording one notice PRESERVES every other field. A blind overwrite would put
# these messages back on one key and resurrect the silent-degrade case.
# A notice that cannot be recorded may repeat on a later turn end. That is the
# deliberate degrade: a repeated visible warning is harmless, while suppressing
# it would lose the shipped default's only rendered behavior.
#
# But repeating is only acceptable when nothing CAN be deduped, as in the wholly
# unwritable state directory below. When only $NOTICE_FILE is unwritable, falling
# straight through here would silently lose stage_enter's per-crossing dedup and
# retrip the guard's non-blocking notices on every single turn end above the
# threshold - reintroducing the exact per-turn-end inflation this file's trip
# record exists to avoid. The degraded marker preserves the same fields outside
# $NOTICE_FILE so the next notice_seen still finds them, and falling back to it
# is itself traced through the trip record exactly once per episode, via
# noticedegraded, never by reading a decision back out of the trip file.
notice_record() {  # <notice>
  local stage unrecorded badrecord standdownfail noticedegraded already_degraded
  stage=$(notice_record_field stage)
  unrecorded=$(notice_record_field unrecorded)
  badrecord=$(notice_record_field badrecord)
  standdownfail=$(notice_record_field standdownfail)
  noticedegraded=$(notice_record_field noticedegraded)
  case "$(notice_field "$1")" in
    unrecorded) unrecorded=1 ;;
    badrecord) badrecord=1 ;;
    standdownfail) standdownfail=1 ;;
    noticedegraded) noticedegraded=1 ;;
    *) stage=$1 ;;
  esac
  [ "$unrecorded" = 1 ] || unrecorded=0
  [ "$badrecord" = 1 ] || badrecord=0
  [ "$standdownfail" = 1 ] || standdownfail=0
  already_degraded=$noticedegraded
  [ "$noticedegraded" = 1 ] || noticedegraded=0
  [ -e "$NOTICE_FILE" ] || prune_dead_records
  # 2>/dev/null FIRST on every record write in this file: bash applies
  # redirections left to right, so a trailing one is not in place yet when the
  # output redirection itself fails on an unwritable record, and the shell's
  # "Permission denied" would leak - onto the very stderr the blocking path uses
  # to deliver the banner to the model.
  if printf 'stage=%s\nunrecorded=%s\nbadrecord=%s\nstanddownfail=%s\nnoticedegraded=%s\ncompacts=%s\nsession=%s\n' \
    "$stage" "$unrecorded" "$badrecord" "$standdownfail" "$noticedegraded" "$COMPACTS" "$SESSION_ID" \
    2>/dev/null > "$NOTICE_FILE"; then
    return 0
  fi
  noticedegraded=1
  printf 'stage=%s\nunrecorded=%s\nbadrecord=%s\nstanddownfail=%s\nnoticedegraded=%s\ncompacts=%s\nsession=%s\n' \
    "$stage" "$unrecorded" "$badrecord" "$standdownfail" "$noticedegraded" "$COMPACTS" "$SESSION_ID" \
    2>/dev/null > "$NOTICE_DEGRADED_FILE" || true
  [ "$already_degraded" = 1 ] || trip_record notice-unwritable
  return 1
}

BUDGET_COUNT=0
BUDGET_STOOD_DOWN=0
# An unparseable count is read as NO record, so the guard stays ARMED, and the
# parse failure is recorded once.
#
# The retention bias everywhere else in this file protects a GENUINE stand-down:
# once the session has been told, stay quiet. An unparseable record is not
# evidence of that - it is evidence of nothing - and reading it as a spent
# stand-down conflates unknown with dismissed, letting a corrupt file impersonate
# a dismissal and silence the guard for the whole session. The asymmetry decides
# it: this guard only ever warns, so a spurious warning costs one printed line
# while a suppressed one costs a session blown past the ceiling with nothing to
# explain why. Failing toward the warning is right, and failing silently is not,
# which is why the parse failure leaves a line behind.
budget_read() {
  local raw_count raw_standdown
  [ -e "$BUDGET_FILE" ] || return 0
  raw_count=$(record_field "$BUDGET_FILE" count)
  raw_standdown=$(record_field "$BUDGET_FILE" standdown)
  case "$raw_count" in
    ''|*[!0-9]*)
      # Once per episode, not once per turn end. A record that is corrupt AND
      # cannot be rewritten is re-read at every turn end, and the trip record is
      # bounded, so a line each time would crowd out the crossing history the
      # warning-only release exists to collect.
      stage_enter record-unparseable || true
      return 0
      ;;
  esac
  BUDGET_COUNT=$raw_count
  [ "$raw_standdown" = 1 ] && BUDGET_STOOD_DOWN=1
  return 0
}

# Returns non-zero when the record could not be persisted. The caller must then
# degrade toward NOT blocking: an unpersisted count cannot bound anything, so
# blocking on it would repeat every turn end with no bound at all.
budget_record() {  # <count> <standdown 0|1>
  [ -e "$BUDGET_FILE" ] || prune_dead_records
  printf 'count=%s\nstanddown=%s\ncompacts=%s\nsession=%s\n' \
    "$1" "$2" "$COMPACTS" "$SESSION_ID" 2>/dev/null > "$BUDGET_FILE"
}

# --- the trip record: WRITE-ONLY observation ----------------------------------
# The shipped default cannot rely on a rendered notice, so entering a stage also
# appends one line here, where the captain can count crossings after the fact.
# Nothing in this script ever reads a decision out of this file; the only thing
# read back is its own size, to keep it bounded. Deleting, corrupting, or
# truncating it therefore changes no behavior at all.
TRIP_FILE="$STATE/.context-budget-trips"
TRIP_MAX_BYTES=131072
TRIP_MAX_LINES=500

trip_trim() {
  local bytes lines kept
  bytes=$(wc -c < "$TRIP_FILE" 2>/dev/null) || return 0
  bytes=${bytes//[![:digit:]]/}
  [ -n "$bytes" ] || return 0
  [ "$bytes" -gt "$TRIP_MAX_BYTES" ] || return 0
  lines=$(wc -l < "$TRIP_FILE" 2>/dev/null) || return 0
  lines=${lines//[![:digit:]]/}
  [ -n "$lines" ] || return 0
  if [ "$lines" -gt "$TRIP_MAX_LINES" ]; then
    kept=$(sed -n "$((lines - TRIP_MAX_LINES + 1)),\$p" "$TRIP_FILE" 2>/dev/null) || return 0
    [ -n "$kept" ] || return 0
    printf '%s\n' "$kept" 2>/dev/null > "$TRIP_FILE" || return 0
  else
    # Over the byte cap on too few lines to trim by line means the content is not
    # trip lines at all. Start clean rather than let it grow unbounded.
    : 2>/dev/null > "$TRIP_FILE" || return 0
  fi
  return 0
}

trip_record() {  # <stage>
  local stamp
  stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || stamp=unknown
  [ -n "$stamp" ] || stamp=unknown
  printf '%s stage=%s total=%s ceiling=%s advisory=%s enforce=%s session=%s\n' \
    "$stamp" "$1" "$TOTAL" "$CEILING" "$ADVISORY" "$ENFORCE" "$SESSION_ID" \
    2>/dev/null >> "$TRIP_FILE" || return 0
  trip_trim
  return 0
}

# A systemMessage object on stdout: the one channel a successful Stop hook has.
# jq builds it, compact and on one line, so a multi-line message is escaped
# correctly rather than by hand.
system_message() {  # <text>
  jq -n -c --arg msg "$1" '{systemMessage: $msg}'
}

valve_text() {
  printf 'Do not stall the fleet: keep working, and tell the captain at the next natural reply.\n'
  printf 'When you do hand over, the handover mechanism owns it:\n'
  printf '  1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.\n'
  printf '  2. Load the handover skill and release the helm with bin/fm-handover.sh.\n'
  printf '  3. A successor session picks the work up from disk; nothing here clears a context.\n'
}

ceiling_text() {  # <closing line>
  printf 'CONTEXT BUDGET CEILING REACHED - HAND OVER\n'
  printf 'This session measures %s tokens, over the %s ceiling.\n' "$TOTAL" "$CEILING"
  valve_text
  printf '%s\n' "$1"
  printf 'This is a cost and reasoning-quality policy, not an overflow warning.\n'
}

# Entering a stage: a threshold crossing, or a malfunction the guard reports the
# same way. Writing the stage into the record IS the crossing, so the ONE trip
# line for it is appended here and nowhere else: that is what makes the trip
# record count how OFTEN the guard fires rather than how long a session lingered
# above the advisory. Returns 0 only when the stage is new, so every path below -
# including the enforcing one, which prints its banner on every blocked turn and
# so cannot dedupe through a notice - records its crossing exactly once. Every
# stage goes through here, so no stage can report itself to the session without
# also leaving the durable line the notice channel cannot be trusted to deliver.
stage_enter() {  # <stage>
  notice_seen "$1" && return 1
  notice_record "$1"
  trip_record "$1"
  return 0
}

# --- a new compaction boundary is a genuine reset -----------------------------
# Compaction does not change session_id, so without this a session-keyed record
# would stay stood down across a real reset whose post-compaction total is still
# above the advisory. A record whose own boundary count is absent or unreadable
# is KEPT, because retention is the bias everywhere in this file.
record_predates_a_compaction() {  # <file>
  local seen
  [ -e "$1" ] || return 1
  seen=$(record_field "$1" compacts)
  case "$seen" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$COMPACTS" -gt "$seen" ]
}

for record in "$BUDGET_FILE" "$NOTICE_FILE" "$NOTICE_DEGRADED_FILE"; do
  if record_predates_a_compaction "$record"; then
    rm -f "$record" 2>/dev/null || true
  fi
done

# --- below the advisory: silent, and re-arm the whole episode -----------------
# The other place a record is cleared, and only a POSITIVE measurement reaches
# here, so a session that has already spent its block budget is never blocked
# again until it genuinely drops back under the advisory or genuinely compacts.
if [ "$TOTAL" -lt "$ADVISORY" ]; then
  rm -f "$BUDGET_FILE" "$NOTICE_FILE" "$NOTICE_DEGRADED_FILE" 2>/dev/null || true
  exit 0
fi

# --- between advisory and ceiling: one non-blocking notice per episode ---------
if [ "$TOTAL" -lt "$CEILING" ]; then
  if stage_enter advisory; then
    system_message "$(
      printf 'CONTEXT BUDGET ADVISORY - %s tokens, ceiling %s\n' "$TOTAL" "$CEILING"
      printf 'About %s tokens of headroom left before the ceiling.\n' "$((CEILING - TOTAL))"
      printf 'Prefer cheap actions now and avoid large reads.\n'
      printf 'Run /stow and hand over before the ceiling is reached.\n'
    )"
  fi
  exit 0
fi

# Record the ceiling crossing once, whichever path below then handles it.
CEILING_IS_NEW=0
stage_enter ceiling && CEILING_IS_NEW=1

# --- at or above the ceiling, shipped default: warn once, never block ---------
if [ "$ENFORCE" -ne 1 ]; then
  if [ "$CEILING_IS_NEW" -eq 1 ]; then
    system_message "$(ceiling_text 'This is a warning: the ceiling does not block by default.')"
  fi
  exit 0
fi

# --- at or above the ceiling with enforcement on: block, bounded, then stand
# --- down stickily ------------------------------------------------------------
budget_read

if [ "$BUDGET_STOOD_DOWN" -eq 1 ]; then
  # Sticky and silent. The ceiling cannot clear without the captain, so once the
  # budget is spent this guard is out of the way for the rest of the session
  # rather than oscillating between blocking and allowing. Refreshing the record
  # keeps a long-running session's stand-down out of reach of the prune.
  touch "$BUDGET_FILE" 2>/dev/null || true
  exit 0
fi

COUNT=$((BUDGET_COUNT + 1))

if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  # Enter the stand-down as a recorded FLAG rather than a clamped count, so
  # raising FM_CONTEXT_BUDGET_BLOCK_BUDGET mid-session cannot re-arm a budget
  # that was already spent. Say so exactly once, visibly - and if the write
  # itself fails, say THAT instead: claiming a durability the guard did not
  # achieve would leave every later turn end re-reading the same unpersisted
  # count, re-entering this branch, and repeating a false claim, with no trace
  # anywhere. Through stage_enter, so the malfunction leaves its own trip line
  # rather than resting on a notice that may never render.
  if budget_record "$COUNT" 1; then
    system_message "$(printf 'firstmate context budget: this session measures %s tokens, over the %s ceiling, and the block budget is exhausted so this guard now stands down for the rest of the session. Run /stow and hand over; do not stall the fleet waiting on it.' \
      "$TOTAL" "$CEILING")"
  elif stage_enter standdown-unrecorded; then
    system_message "$(printf 'firstmate context budget: this session measures %s tokens, over the %s ceiling, and the block budget is exhausted, but the stand-down could not be persisted and may recur on later turn ends. Run /stow and hand over; do not stall the fleet waiting on it.' \
      "$TOTAL" "$CEILING")"
  fi
  exit 0
fi

if ! budget_record "$COUNT" 0; then
  # The count could not be persisted, so blocking could not be bounded by it.
  # Degrade to the visible warning instead of blocking on a count that does not
  # survive the turn.
  # Its OWN notice key, never the ceiling key: this reports a MALFUNCTION of the
  # guard rather than a threshold crossing, and sharing a key meant a ceiling
  # notice already shown this episode silenced it from its very first occurrence.
  # Through stage_enter, so the loss of the bound leaves a trip line behind
  # instead of resting on a notice that may never render.
  if stage_enter ceiling-unrecorded; then
    system_message "$(ceiling_text 'This turn is allowed rather than blocked because the block count could not be recorded.')"
  fi
  exit 0
fi

{
  printf '●%s\n' "$RULE"
  ceiling_text 'Blocking is bounded, then this guard stands down for the session.' \
    | sed 's/^/●  /'
  printf '●%s\n' "$RULE"
} >&2
exit 2
