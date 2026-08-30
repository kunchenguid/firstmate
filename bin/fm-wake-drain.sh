#!/usr/bin/env bash
# Present durable watcher wake records, optionally acknowledge handled records,
# annotate every unread line for validated signal status keys, surface unread
# informational status lines, OPEN DECISIONS, and captain-call record
# divergence, then assert liveness.
#
# Keep sequence-bound row consumption independent from generation-bound episode
# retirement; docs/watcher-continuity.md owns the recovery contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

DRAIN_TMP=
DRAIN_VIEW_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=
RECOVERY_MARKER="$STATE/.watcher-down"
RECOVERY_MARKER_TOKEN=
RECOVERY_ACK_REQUIRED=false
RECOVERY_ACK_MOVED=false
ACK_THROUGH=
ACK_GENERATION=
ACK_FINGERPRINTS=
ACK_NOTICE_FINGERPRINTS=

# --- per-actor consume (docs/watcher-continuity.md "Per-actor acknowledgement") --
# main (FM_SUPERVISION_ACTOR unset or "main", via fm-lease-lib.sh's fm_lease_actor
# - the same actor identity fm-send.sh/fm-control.sh/fm-teardown.sh already use)
# claims every row not already granted to branch, then drains and acks only
# that claimed set. branch (FM_SUPERVISION_ACTOR=branch, injected
# deterministically by the Pi branch extension's bash tool - never agent
# memory) drains and acks only the row set the extension granted to it.
# .pi/extensions/lib/fm-branch-dispatch.ts is the single owner of that
# eligibility classification (which signal/stale rows resolve to a known
# project, and the existing all-unread-rows-safe rule for a heartbeat); this
# script never reclassifies a row itself, it only consumes the extension's
# already-computed verdict. The extension writes the exact eligible sequence
# numbers to ELIGIBLE_ROWS_FILE under the queue lock, immediately before every
# branch prompt, so the file is always fresh for the one wake that prompt is about to
# handle (the branch drains and acks exactly once per prompt, serialized by
# its own branchChain, before the next wake can overwrite the file).
# A row whose sequence number is not in that file is left completely
# untouched by a branch-actor drain or ack, no matter its sequence number
# relative to what the branch presents or consumes - that per-row scoping,
# not a cutoff comparison, is what makes a mixed main-only + task-local queue
# safe to split: the branch's ack can never remove a row it was not granted,
# so it can never swallow a main-owned row still waiting for main.
ACTOR=$(fm_lease_actor) || exit 2
ELIGIBLE_ROWS_FILE="$STATE/.branch-eligible-rows"
ELIGIBLE_OWNER_FILE="$STATE/.branch-eligible-owner"
MAIN_ROWS_FILE="$STATE/.main-eligible-rows"

rows_file_valid() {
  [ -s "$1" ] && awk 'BEGIN { ok=1 } !/^[0-9]+$/ || seen[$0]++ { ok=0 } END { exit !ok }' "$1"
}

branch_grant_live_locked() {
  local version pid identity generation current
  [ -f "$ELIGIBLE_OWNER_FILE" ] && [ ! -L "$ELIGIBLE_OWNER_FILE" ] || return 1
  exec 8< "$ELIGIBLE_OWNER_FILE" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r pid <&8 || { exec 8<&-; return 1; }
  IFS= read -r identity <&8 || { exec 8<&-; return 1; }
  IFS= read -r generation <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = fm-branch-eligible-owner-v1 ] || return 1
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  case "$generation" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] && [ "$current" = "$identity" ]
}

reclaim_stale_branch_grant_locked() {
  [ -e "$ELIGIBLE_ROWS_FILE" ] || [ -L "$ELIGIBLE_ROWS_FILE" ] || return 0
  if ! rows_file_valid "$ELIGIBLE_ROWS_FILE" || ! branch_grant_live_locked; then
    rm -f -- "$ELIGIBLE_ROWS_FILE" "$ELIGIBLE_OWNER_FILE"
  fi
}

write_rows_file_locked() { # <target> <source>
  local target=$1 source=$2
  if [ ! -s "$source" ]; then
    rm -f -- "$target"
    return
  fi
  chmod 0600 "$source" || return 1
  _fm_atomic_replace "$source" "$target"
}

claim_main_rows_locked() {
  DRAIN_TMP=$(mktemp "$STATE/.main-eligible-rows.tmp.XXXXXX") || return 1
  awk -F '\t' -v branch="$ELIGIBLE_ROWS_FILE" -v main="$MAIN_ROWS_FILE" '
    BEGIN {
      while ((getline line < branch) > 0) reserved[line]=1
      while ((getline line < main) > 0) owned[line]=1
    }
    NF >= 5 && $2 ~ /^[0-9]+$/ {
      present[$2]=1
      if (!($2 in reserved)) owned[$2]=1
    }
    END { for (seq in owned) if (seq in present) print seq }
  ' "$FM_WAKE_QUEUE" | LC_ALL=C sort -n > "$DRAIN_TMP" || return 1
  write_rows_file_locked "$MAIN_ROWS_FILE" "$DRAIN_TMP" || return 1
  DRAIN_TMP=
}

consume_actor_rows_locked() { # <rows-file> <cutoff>
  local rows=$1 cutoff=$2
  if [ ! -e "$rows" ] && [ ! -L "$rows" ]; then
    return 0
  fi
  DRAIN_TMP=$(mktemp "$STATE/.wake-rows.consume.XXXXXX") || return 1
  awk -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 > cutoff { print $1 }' "$rows" > "$DRAIN_TMP" || return 1
  write_rows_file_locked "$rows" "$DRAIN_TMP" || return 1
  DRAIN_TMP=
}

# A branch-actor drain or ack requires a snapshot to already exist and name at
# least one row. The extension always writes a non-empty snapshot before it
# ever prompts the branch (an empty eligible set means no prompt at all), so a
# missing or empty file here means this ran outside that handoff - a wiring
# bug, never "nothing eligible" - and must fail loudly rather than silently
# draining or acking nothing.
require_branch_eligible_rows() {
  rows_file_valid "$ELIGIBLE_ROWS_FILE" || {
    echo "wake drain: no branch-eligible row snapshot at $ELIGIBLE_ROWS_FILE; refusing to guess what this actor may consume" >&2
    return 1
  }
}

case "${1:-}" in
  '') ;;
  --ack-through)
    ACK_THROUGH=${2:-}
    case "$ACK_THROUGH" in ''|*[!0-9]*) echo "wake drain: invalid acknowledgement sequence" >&2; exit 2 ;; esac
    [ "${3:-}" = --recovery-generation ] \
      || { echo "wake drain: acknowledgement requires its recovery generation" >&2; exit 2; }
    ACK_GENERATION=${4:-}
    case "$ACK_GENERATION" in ''|*[!A-Za-z0-9._-]*) echo "wake drain: invalid recovery generation" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "wake drain: unexpected acknowledgement arguments" >&2; exit 2; }
    ;;
  *) echo "usage: fm-wake-drain.sh [--ack-through SEQUENCE --recovery-generation GENERATION]" >&2; exit 2 ;;
esac

[ "$ACTOR" != branch ] || require_branch_eligible_rows || exit 1

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's model-aware alarm and FM_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# the Pi extension model, a fresh beacon also stays silent during a genuinely
# unheld-lock hand-off only while the live session proves extension ownership.
# Persistent-watcher models still require the live identity-matched watcher.
# Never let a guard hiccup change the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# Mark presentation-stage inactive terminal outcomes only after the handling
# turn has completed and before this acknowledgement consumes its queue rows.
# The helper ignores non-presentation and legacy keys, so this is a narrow
# receipt path rather than a second interpretation of general check wakes.
inactive_outcome_fingerprints() { # <sequence> <key-prefix> [<rows-file>]
  local cutoff=$1 prefix=$2 rows=${3:-} epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = check ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$cutoff" ] || continue
    if [ -n "$rows" ] && ! grep -qxF "$seq" "$rows"; then continue; fi
    case "$key" in
      "$prefix"*) printf '%s\n' "${key#"$prefix"}" ;;
    esac
  done < "$FM_WAKE_QUEUE"
}

acknowledge_inactive_outcomes() { # <mode> <newline-separated-fingerprints>
  local mode=$1 fingerprints=$2 fingerprint
  while IFS= read -r fingerprint; do
    [ -n "$fingerprint" ] || continue
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" "$mode" "$fingerprint" || return 1
  done <<< "$fingerprints"
}

# Print still-unread informational status lines (note: answers and pending-reply
# resolutions) that the OPEN DECISIONS fold never carries. Uses the same
# cursor-backed unread span as the annotation path, and runs on every drain -
# including the empty-queue fast path - so a buried answer cannot be swallowed
# when the fold later advances the cursor. Prints nothing when nothing is
# unread, which is the common case.
print_unread_status_section() {
  local snapshot=${1:-} unread task line shown=0

  if [ -n "$snapshot" ]; then
    unread=$(scan_unread_surface_snapshot "$STATE" "$snapshot") || return 1
  else
    unread=$(scan_unread_surface_lines "$STATE") || return 1
  fi
  [ -n "$unread" ] || return 0

  while IFS=$(printf '\t') read -r task line; do
    [ -n "$task" ] || continue
    [ -n "$line" ] || continue
    line="$task $line"
    if [ "$shown" -eq 0 ]; then
      printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n' || return 1
    fi
    printf '%s\n' "$line" || return 1
    shown=$((shown + 1))
  done <<EOF
$unread
EOF

  [ "$shown" -gt 0 ] || return 0
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, fleet-wide, folded from the durable status logs by
# fm-classify-lib.sh's status_open_decisions fold (via its cursor-backed
# scan_open_decisions_incremental wrapper) rather than from the annotations
# above, so a decision buried under later unrelated appends cannot be silently
# missed. Informational `note:` lines and pending-reply resolutions are not
# decisions; print_unread_status_section owns their one-shot surface. Runs on
# every drain - including the empty-queue fast path - because the decision can
# still be open even when nothing new is queued for
# its task this turn. The incremental wrapper bounds this scan's cost to bytes
# appended to each task's status log since the LAST drain, not that log's whole
# lifetime, while still never dropping an old buried decision (see
# fm-classify-lib.sh's "incremental (cursor-backed) open-decisions fold").
# Bounded and silent: prints nothing when no decision is open, which is the
# common case.
print_open_decisions_section() {
  local snapshot=${1:-} open task key verb note line item_bytes=220 global_bytes=4000
  local output='' used=0 shown=0 omitted=0 bytes

  if [ -n "$snapshot" ]; then
    open=$(scan_open_decisions_snapshot "$STATE" "$snapshot") || return 1
  else
    open=$(scan_open_decisions_incremental "$STATE") || return 1
  fi
  [ -n "$open" ] || return 0

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    line="$line $verb: $note"
    # The shared cut counts the item's own characters; the trailing newline this
    # section's global budget also pays for is this caller's, so the per-item
    # allowance passed down is one short of the cap.
    fm_cap_line_var "$line" $((item_bytes - 1))
    line=$FM_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$open
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n' || return 1
  printf '%s' "$output" || return 1
  if [ "$omitted" -gt 0 ]; then
    printf 'OPEN DECISIONS: %d more omitted (byte cap)\n' "$omitted" || return 1
  fi
  # Answerer-closes hint, printed at exactly the moment an answer gets written:
  # the send that answers a listed decision also closes it, so closure never
  # depends on the busy worker writing a matching resolved line (contract:
  # bin/fm-send.sh header).
  printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n" || return 1
}

# Print the RECORD DIVERGENCE section: every captain call whose two records
# contradict each other - the status log says a key was resolved outright while
# the task held for the captain is still open. Nothing here closes anything; the
# section exists because posting the resolution alone reads as complete on the
# status side, so the durable record can keep saying the captain owes an answer
# with no warning at all. bin/fm-captain-hold.sh's `diverged` owns which pairs
# count and why; this prints what it reports.
#
# Bounded and silent like OPEN DECISIONS above: nothing prints when the two
# records agree, which is the common case. If tasks-axi is unavailable, the
# guard cannot read the structured record and stays silent. A guard failure
# never changes the drain's exit status - a supervision turn must still present
# its wakes when the backlog tool is having a bad day.
print_record_divergence_section() {
  local diverged task origin key title line shown=0 omitted=0 bound
  local output='' used=0 bytes item_bytes=220 global_bytes=2000

  # A non-positive bound is not a bound (bin/fm-timeout-lib.sh), so a bad
  # override falls back to the default rather than disabling the deadline.
  bound=${FM_DIVERGENCE_TIMEOUT:-20}
  case "$bound" in ''|*[!0-9]*|0) bound=20 ;; esac

  # Bounded, because this runs at the top of every supervision turn: a backlog
  # tool having a bad day must cost the drain a few seconds at worst, never the
  # presentation of the wakes it exists to deliver.
  diverged=$(fm_run_timed "$bound" "$SCRIPT_DIR/fm-captain-hold.sh" diverged 2>/dev/null) || return 0
  [ -n "$diverged" ] || return 0

  while IFS=$(printf '\t') read -r task origin key title; do
    [ -n "$task" ] || continue
    line="$task [key=$key] reads resolved in $origin's status log but is still held for the captain"
    [ -z "$title" ] || line="$line: $title"
    fm_cap_line_var "$line" $((item_bytes - 1))
    line=$FM_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$diverged
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'RECORD DIVERGENCE (answered in the status log, still held in the backlog - nothing was closed automatically):\n' || return 1
  printf '%s' "$output" || return 1
  if [ "$omitted" -gt 0 ]; then
    printf 'RECORD DIVERGENCE: %d more omitted (byte cap)\n' "$omitted" || return 1
  fi
  # Both directions, deliberately. The status resolution is not proof the
  # captain ruled: a call can dissolve, or turn out to have been a question of
  # fact. Reconcile with what actually happened - never by closing on the
  # strength of this line.
  printf 'RECORD DIVERGENCE: reconcile each one - record the captain'"'"'s own words with bin/fm-captain-hold.sh answer <task> --decision-file <path>, or re-open the status decision when that resolution was not the captain'"'"'s word.\n' || return 1
}

print_status_sections() {
  local snapshot=${1:-} fully_presented=${2:-} acknowledged
  if [ -z "$snapshot" ]; then snapshot=$(status_presentation_snapshot "$STATE") || return 1; fi
  [ -n "$snapshot" ] || return 0
  acknowledged=$(status_acknowledge_presented_snapshot "$STATE" "$snapshot" "$fully_presented") || return 1
  print_unread_status_section "$snapshot" || return 1
  print_open_decisions_section "$snapshot" || return 1
  print_record_divergence_section || return 1
  status_commit_presentation_snapshot "$STATE" "$acknowledged"
}

print_status_presentation() {  # [<deduped-raw-rows>]
  local rows=${1:-} lock="$STATE/.status-presentation-lock" snapshot annotation_manifest fully_presented='' rc=0
  fm_lock_acquire_wait "$lock" || return 1
  snapshot=$(status_presentation_snapshot "$STATE") || {
    printf 'STATUS PRESENTATION INCOMPLETE: status snapshot could not be read.\n'
    rc=1
  }
  if [ "$rc" -eq 0 ] && [ -n "$rows" ]; then
    fm_wake_print_annotations "$rows" "$snapshot" || rc=1
    if [ "$rc" -eq 0 ]; then
      annotation_manifest=$(fm_wake_annotation_manifest "$rows") || rc=1
      fully_presented=$(printf '%s\n' "$annotation_manifest" | awk -F '\t' '$2 == "direct" { sub(/\.status$/, "", $1); print $1 }') || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$snapshot" ]; then print_status_sections "$snapshot" "$fully_presented" || rc=1; fi
  fm_lock_release "$lock"
  return "$rc"
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  [ -z "$DRAIN_TMP" ] || rm -f -- "$DRAIN_TMP" 2>/dev/null || true
  [ -z "$DRAIN_VIEW_TMP" ] || rm -f -- "$DRAIN_VIEW_TMP" 2>/dev/null || true
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true
reclaim_stale_branch_grant_locked || exit 1
[ "$ACTOR" != branch ] || require_branch_eligible_rows || exit 1

if [ -n "$ACK_THROUGH" ]; then
  if [ "$ACTOR" = main ]; then
    # Preserve main's original whole-cutoff acknowledgement contract: rows may
    # arrive after presentation but before the printed ack runs, and a direct
    # or replayed main ack still owns every unreserved row through its cutoff.
    # Claim again under the queue lock so those rows cannot be stranded merely
    # because they were not present during the earlier drain. A live branch
    # grant remains excluded by claim_main_rows_locked.
    claim_main_rows_locked || exit 1
  fi
  if [ "$ACTOR" = branch ]; then
    # check-kind rows (inactive-outcome receipts, secondmate stall markers)
    # are never in a branch's eligible snapshot - they are main-only by
    # construction (docs/pi-supervision-branch.md) - so a branch-actor ack
    # never removes one and these scans would find nothing relevant anyway.
    ACK_FINGERPRINTS=
    ACK_NOTICE_FINGERPRINTS=
  else
    if { [ -e "$MAIN_ROWS_FILE" ] || [ -L "$MAIN_ROWS_FILE" ]; } \
      && ! rows_file_valid "$MAIN_ROWS_FILE"; then
      echo "wake drain: main acknowledgement has an invalid presented-row claim" >&2
      exit 1
    fi
    ACK_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-outcome:' "$MAIN_ROWS_FILE") || exit 1
    ACK_NOTICE_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-reconcile:' "$MAIN_ROWS_FILE") || exit 1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if ! acknowledge_inactive_outcomes acknowledge "$ACK_FINGERPRINTS" \
    || ! acknowledge_inactive_outcomes acknowledge-notice "$ACK_NOTICE_FINGERPRINTS"; then
    echo "wake drain: inactive outcome receipt could not be recorded safely" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=true
  DRAIN_TMP=$(mktemp "$STATE/.wake-queue.ack.XXXXXX") || exit 1
  chmod 0600 "$DRAIN_TMP" || exit 1
  if [ "$ACTOR" = branch ]; then
    require_branch_eligible_rows || exit 1
    # Delete a row only when its sequence is <= cutoff AND it is named in the
    # extension's eligible snapshot; every other row - including one whose
    # sequence is below cutoff but not in the snapshot - is kept untouched.
    awk -F '\t' -v cutoff="$ACK_THROUGH" -v seqs="$ELIGIBLE_ROWS_FILE" '
      BEGIN { while ((getline line < seqs) > 0) if (line ~ /^[0-9]+$/) keep[line] = 1 }
      NF < 5 || $2 !~ /^[0-9]+$/ || $2 > cutoff || !($2 in keep) { print }
    ' "$FM_WAKE_QUEUE" > "$DRAIN_TMP" || exit 1
  else
    awk -F '\t' -v cutoff="$ACK_THROUGH" -v seqs="$MAIN_ROWS_FILE" '
      BEGIN { while ((getline line < seqs) > 0) owned[line]=1 }
      NF < 5 || $2 !~ /^[0-9]+$/ || $2 > cutoff || !($2 in owned) { print }
    ' "$FM_WAKE_QUEUE" > "$DRAIN_TMP" || exit 1
    fm_wake_commit_secondmate_stall_receipts_through "$ACK_THROUGH" "$MAIN_ROWS_FILE" || {
      echo "wake drain: secondmate stall receipt could not be recorded safely" >&2
      exit 1
    }
  fi
  if [ ! -s "$DRAIN_TMP" ]; then
    fm_recovery_marker_ack "$RECOVERY_MARKER" "$ACK_GENERATION"
    RECOVERY_ACK_STATUS=$?
    case "$RECOVERY_ACK_STATUS" in
      0) ;;
      3) RECOVERY_ACK_MOVED=true ;;
      *)
        echo "wake drain: recovery episode could not be retired safely; re-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command" >&2
        exit 1
        ;;
    esac
  else
    fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
    RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
    if [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ]; then
      RECOVERY_ACK_MOVED=true
    fi
  fi
  if ! _fm_atomic_replace "$DRAIN_TMP" "$FM_WAKE_QUEUE"; then
    echo "wake drain: acknowledged wakes could not be consumed safely" >&2
    exit 1
  fi
  DRAIN_TMP=
  if [ "$ACTOR" = branch ]; then
    consume_actor_rows_locked "$ELIGIBLE_ROWS_FILE" "$ACK_THROUGH" || exit 1
  else
    consume_actor_rows_locked "$MAIN_ROWS_FILE" "$ACK_THROUGH" || exit 1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if [ "$RECOVERY_ACK_MOVED" = true ]; then
    printf 'wake drain: acknowledged wakes through %s, but a newer recovery episode is pending; re-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command\n' \
      "$ACK_THROUGH" >&2
  fi
  exit 0
fi

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || true
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|announced:downtime:*)
      fm_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
        echo "wake drain: decision recovery could not begin handling safely" >&2
        exit 1
      }
      RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
      RECOVERY_ACK_REQUIRED=true
      ;;
    pending:handling:*|announced:handling:*) RECOVERY_ACK_REQUIRED=true ;;
  esac
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_status_presentation) || true
  if [ "$RECOVERY_ACK_REQUIRED" = true ]; then
    printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation %s\n' "${RECOVERY_MARKER_TOKEN##*:}" >&2
  fi
  assert_watcher_liveness
  exit 0
fi

if [ "$ACTOR" = main ]; then
  if [ -e "$ELIGIBLE_ROWS_FILE" ] || [ -L "$ELIGIBLE_ROWS_FILE" ]; then
    require_branch_eligible_rows || exit 1
  fi
  claim_main_rows_locked || exit 1
  if [ ! -s "$MAIN_ROWS_FILE" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    DRAIN_LOCK_HELD=false
    (print_status_presentation) || true
    assert_watcher_liveness
    exit 0
  fi
fi

fm_recovery_marker_snapshot "$RECOVERY_MARKER" || true
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
if [ -z "$RECOVERY_MARKER_TOKEN" ]; then
  if [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ]; then
    echo "wake drain: durable wakes have invalid recovery state" >&2
    exit 1
  fi
  fm_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: legacy durable wakes could not be adopted safely" >&2
    exit 1
  }
elif [ "${RECOVERY_MARKER_TOKEN%%:*}" = acked ]; then
  fm_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: durable wakes could not enter a fresh recovery generation" >&2
    exit 1
  }
fi
fm_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
  echo "wake drain: durable wakes could not begin handling safely" >&2
  exit 1
}
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN

DRAIN_VIEW_TMP=$(mktemp "$STATE/.wake-queue.actor-view.XXXXXX") || exit 1
if [ "$ACTOR" = branch ]; then
  ACTOR_ROWS_FILE=$ELIGIBLE_ROWS_FILE
else
  ACTOR_ROWS_FILE=$MAIN_ROWS_FILE
fi
awk -F '\t' -v seqs="$ACTOR_ROWS_FILE" '
  BEGIN { while ((getline line < seqs) > 0) keep[line]=1 }
  NF >= 5 && ($2 in keep)
' "$FM_WAKE_QUEUE" > "$DRAIN_VIEW_TMP" || exit 1
RAW_ROWS=$(fm_wake_print_deduped "$DRAIN_VIEW_TMP") || exit "$?"
rm -f -- "$DRAIN_VIEW_TMP" || exit 1
DRAIN_VIEW_TMP=
ACK_THROUGH=$(printf '%s\n' "$RAW_ROWS" | awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }') || exit 1
case "${FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ -n "$RAW_ROWS" ]; then
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
case "$RECOVERY_MARKER_TOKEN" in
  pending:*|announced:*|acked:*) ;;
  *) echo "wake drain: durable wakes have no recovery generation" >&2; exit 1 ;;
esac
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' \
  "$ACK_THROUGH" "${RECOVERY_MARKER_TOKEN##*:}" >&2

(print_status_presentation "$RAW_ROWS") || true
assert_watcher_liveness
exit 0
