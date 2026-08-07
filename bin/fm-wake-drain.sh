#!/usr/bin/env bash
# Present durable watcher wake records, optionally acknowledge handled records,
# annotate validated signal status keys, then assert liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=
RECOVERY_MARKER="$STATE/.watcher-down"
RECOVERY_MARKER_TOKEN=
RECOVERY_ACK_REQUIRED=false
ACK_THROUGH=
ACK_GENERATION=
ACK_FINGERPRINTS=
ACK_NOTICE_FINGERPRINTS=

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

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's model-aware alarm and FM_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# persistent-watcher models, the guard also requires the live identity-matched
# watcher. Never let a guard hiccup change the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# Mark presentation-stage inactive terminal outcomes only after the handling
# turn has completed and before this acknowledgement consumes its queue rows.
# The helper ignores non-presentation and legacy keys, so this is a narrow
# receipt path rather than a second interpretation of general check wakes.
inactive_outcome_fingerprints() { # <sequence> <key-prefix>
  local cutoff=$1 prefix=$2 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = check ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$cutoff" ] || continue
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

# Print pre-formatted rows read on stdin under <header>, truncating any over-long
# row and dropping rows past the section's global byte cap. Prints NOTHING at all
# when stdin holds no row, which is the common case for both sections below.
print_capped_section() {  # <header> <omitted-label> <item-bytes> <global-bytes>
  local header=$1 label=$2 item_bytes=$3 global_bytes=$4
  local line output='' used=0 shown=0 omitted=0 bytes

  while IFS= read -r line; do
    [ -n "$line" ] || continue
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
  done

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf '%s\n' "$header"
  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    printf '%s: %d more omitted (byte cap)\n' "$label" "$omitted"
  fi
}

# Emit one row per still-open needs-decision/blocked, fleet-wide, folded from the
# durable status logs by fm-classify-lib.sh's status_open_decisions fold (via its
# cursor-backed scan_open_decisions_incremental wrapper) rather than from the
# latest-line annotations above, so a decision buried under later unrelated
# appends cannot be silently missed. Runs on every drain - including the
# empty-queue fast path - because the decision can still be open even when
# nothing new is queued for its task this turn. The incremental wrapper bounds
# this scan's cost to bytes appended to each task's status log since the LAST
# drain, not that log's whole lifetime, while still never dropping an old buried
# decision (see fm-classify-lib.sh's "incremental (cursor-backed) open-decisions
# fold"). The same single pass fills <anomaly-sink> for the section below.
print_open_decision_rows() {  # <anomaly-sink>
  local open task key verb note line

  open=$(scan_open_decisions_incremental "$STATE" "$1") || return 0
  [ -n "$open" ] || return 0

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    printf '%s %s: %s\n' "$line" "$verb" "$note"
  done <<EOF
$open
EOF
}

# Emit one row per status line the fold above refused or had to repair. These
# are writer bugs on a safety surface: a refused line looks closed to whoever
# wrote it while the open set keeps crying wolf, and a close for a key nothing
# opened is the only trace that the OPENING line was filed under another key.
# Reporting them here makes the bad writer visible on the next wake instead of
# after the next lost decision. Because the incremental fold reads each appended
# line exactly once, each anomaly is reported once, not on every drain.
print_anomaly_rows() {  # <anomaly-sink>
  local sink=$1 task kind key line

  [ -s "$sink" ] || return 0
  while IFS=$(printf '\t') read -r task kind key line; do
    [ -n "$kind" ] || continue
    case "$kind" in
      malformed)
        printf '%s NOT APPLIED - the line does not match <verb> [tokens]: <note>: %s\n' \
          "$task" "$line"
        ;;
      misplaced-key)
        printf '%s applied to [key=%s] - the key token belongs BEFORE the colon: %s\n' \
          "$task" "$key" "$line"
        ;;
      unmatched-close)
        printf '%s closes [key=%s], which was never opened - the opening line likely named another key: %s\n' \
          "$task" "$key" "$line"
        ;;
    esac
  done < "$sink"
}

# Print both per-drain fold sections from one status-log pass.
print_decision_sections() {
  local sink open_rows
  sink="$STATE/.decision-anomalies.$(fm_current_pid)"

  rm -f "$sink"
  open_rows=$(print_open_decision_rows "$sink")
  if [ -n "$open_rows" ]; then
    printf '%s\n' "$open_rows" | print_capped_section \
      'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):' \
      'OPEN DECISIONS' 220 4000
    # Answerer-closes hint, printed at exactly the moment an answer gets written:
    # the send that answers a listed decision also closes it, so closure never
    # depends on the busy worker writing a matching resolved line (contract:
    # bin/fm-send.sh header).
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
  fi
  print_anomaly_rows "$sink" | print_capped_section \
    'STATUS LINE ANOMALIES (decision lines that did not classify as written - fix the writer):' \
    'STATUS LINE ANOMALIES' 300 2000
  rm -f "$sink"
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  [ -z "$DRAIN_TMP" ] || rm -f -- "$DRAIN_TMP" 2>/dev/null || true
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

if [ -n "$ACK_THROUGH" ]; then
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  if [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ]; then
    echo "wake drain: recovery generation is stale or could not be acknowledged safely" >&2
    exit 1
  fi
  ACK_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-outcome:') || exit 1
  ACK_NOTICE_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH" 'inactive-reconcile:') || exit 1
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if ! acknowledge_inactive_outcomes acknowledge "$ACK_FINGERPRINTS" \
    || ! acknowledge_inactive_outcomes acknowledge-notice "$ACK_NOTICE_FINGERPRINTS"; then
    echo "wake drain: inactive outcome receipt could not be recorded safely" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=true
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  if [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ]; then
    echo "wake drain: recovery generation changed while recording inactive outcome receipts" >&2
    exit 1
  fi
  DRAIN_TMP=$(mktemp "$STATE/.wake-queue.ack.XXXXXX") || exit 1
  chmod 0600 "$DRAIN_TMP" || exit 1
  awk -F '\t' -v cutoff="$ACK_THROUGH" '
    NF < 5 || $2 !~ /^[0-9]+$/ || $2 > cutoff { print }
  ' "$FM_WAKE_QUEUE" > "$DRAIN_TMP" || exit 1
  if [ ! -s "$DRAIN_TMP" ]; then
    if ! fm_recovery_marker_ack "$RECOVERY_MARKER" "$ACK_GENERATION"; then
      echo "wake drain: recovery generation is stale or could not be acknowledged safely" >&2
      exit 1
    fi
  fi
  if ! _fm_atomic_replace "$DRAIN_TMP" "$FM_WAKE_QUEUE"; then
    echo "wake drain: acknowledged wakes could not be consumed safely" >&2
    exit 1
  fi
  DRAIN_TMP=
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  exit 0
fi

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || true
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:downtime:*)
      fm_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
        echo "wake drain: decision recovery could not begin handling safely" >&2
        exit 1
      }
      RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
      RECOVERY_ACK_REQUIRED=true
      ;;
    pending:handling:*) RECOVERY_ACK_REQUIRED=true ;;
  esac
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_decision_sections) || true
  if [ "$RECOVERY_ACK_REQUIRED" = true ]; then
    printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation %s\n' "${RECOVERY_MARKER_TOKEN##*:}" >&2
  fi
  assert_watcher_liveness
  exit 0
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

RAW_ROWS=$(fm_wake_print_deduped "$FM_WAKE_QUEUE") || exit "$?"
ACK_THROUGH=$(awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }' "$FM_WAKE_QUEUE") || exit 1
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
  pending:*|acked:*) ;;
  *) echo "wake drain: durable wakes have no recovery generation" >&2; exit 1 ;;
esac
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' \
  "$ACK_THROUGH" "${RECOVERY_MARKER_TOKEN##*:}" >&2

(fm_wake_print_annotations "$RAW_ROWS") || true
(print_decision_sections) || true
assert_watcher_liveness
exit 0
