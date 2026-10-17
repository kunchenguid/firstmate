#!/usr/bin/env bash
# fm-wake-ack.sh - the pending acknowledgement of a pre-drained wake.
#
# A Claude primary's Stop hook (bin/fm-claude-stop-autoarm.sh) drains main's
# wake into the rewake message it delivers, and the acknowledgement that drain
# would have asked main to run is recorded here instead. The next Stop of the
# same session - the end of the handling turn - runs that acknowledgement
# through this script before it arms the next cycle. docs/watcher-continuity.md
# "Pre-drained wakes and the turn-end acknowledgement" owns the contract; this
# header owns the records and the exact commands.
#
# Records, all under the effective state directory (FM_STATE_OVERRIDE, else
# $FM_HOME/state):
#   .wake-ack-pending          the pending record (key=value lines, schema
#                              fm-wake-ack-pending.v1): ack_through,
#                              recovery_generation (empty when no episode needs
#                              acknowledging), receipt, session_id, session_pid,
#                              generation, nonce, recorded_at.
#   .wake-ack-pending.receipt  the staged presentation receipt that
#                              bin/fm-wake-drain.sh --stage wrote for it.
#   .wake-ack-hold             main's keep-open marker: while it exists the next
#                              turn end acknowledges nothing and the wake stays
#                              queued for re-presentation; it is consumed once.
#   wake-ack.log               one line per outcome (epoch, action, detail),
#                              kept to its last 500 lines.
#
# Usage:
#   fm-wake-ack.sh hold [REASON]
#     Keep the current pre-drained wake open past this turn. The next turn end
#     then drops the pending acknowledgement without running it, the queue
#     rows, UNREAD STATUS lines, and BRANCH OUTCOMES stay unacknowledged, and
#     the next drain presents them again.
#   fm-wake-ack.sh void [--claude] [REASON]
#     A prompt-submit hook's entry: a captain prompt (or a steer) reached the
#     session, so any pending acknowledgement belongs to a turn that is over or
#     was interrupted. The record and its receipt are dropped unrun, the hold is
#     consumed, and the wake stays queued. A home with no pending record is a
#     silent no-op; --claude additionally stands down on a payload another host
#     delivered (bin/fm-hook-host-lib.sh). The delivery of the pre-drained wake
#     itself is not such a prompt: an asyncRewake fires UserPromptSubmit with
#     the hook's stderr as its prompt, so a --claude payload whose .prompt
#     carries the pending record's nonce consumes nothing. Always exits 0.
#   fm-wake-ack.sh record --ack-through N --recovery-generation G --receipt PATH
#                         --session-pid PID --generation GEN [--session-id ID]
#     The Stop hook's entry after it committed a rewake: write the pending
#     record atomically with a fresh random nonce, replacing any earlier record
#     whose turn never reached its acknowledgement (its rows were re-presented
#     by this drain), and print the nonce for the rewake banner.
#   fm-wake-ack.sh commit [--session-id ID]
#     The Stop hook's entry at the next turn end. Exactly one caller claims the
#     record (an atomic rename). A record bound to another session id or
#     session-lock pid is voided unrun. A hold voids it unrun and is consumed.
#     Otherwise it runs bin/fm-wake-drain.sh --ack-through N
#     --recovery-generation G --commit-stage RECEIPT (or --commit-stage RECEIPT
#     alone when no episode needs acknowledging) and removes the record.
#     Exit 0 committed, 1 the acknowledgement failed (the record is dropped
#     and the next drain presents the wake again), 3 nothing pending, 4 held,
#     5 voided for a session mismatch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PENDING="$STATE/.wake-ack-pending"
RECEIPT="$STATE/.wake-ack-pending.receipt"
HOLD="$STATE/.wake-ack-hold"
LOG="$STATE/wake-ack.log"

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

log_line() {  # <action> <detail>
  local lines
  [ -d "$STATE" ] || return 0
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$LOG" 2>/dev/null || return 0
  lines=$(awk 'END { print NR }' "$LOG" 2>/dev/null || echo 0)
  if [ "${lines:-0}" -gt 1000 ]; then
    if tail -n 500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null; then
      mv -f "$LOG.tmp.$$" "$LOG" 2>/dev/null || rm -f "$LOG.tmp.$$"
    else
      rm -f "$LOG.tmp.$$"
    fi
  fi
}

read_record() {  # <file>; sets REC_*
  local line key value
  REC_ACK_THROUGH=''
  REC_GENERATION=''
  REC_RECEIPT=''
  REC_SESSION_ID=''
  REC_SESSION_PID=''
  REC_NONCE=''
  [ "$(sed -n '1p' "$1" 2>/dev/null)" = schema=fm-wake-ack-pending.v1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      ack_through) REC_ACK_THROUGH=$value ;;
      recovery_generation) REC_GENERATION=$value ;;
      receipt) REC_RECEIPT=$value ;;
      session_id) REC_SESSION_ID=$value ;;
      session_pid) REC_SESSION_PID=$value ;;
      nonce) REC_NONCE=$value ;;
    esac
  done < "$1"
  case "$REC_ACK_THROUGH" in ''|*[!0-9]*) return 1 ;; esac
  case "$REC_GENERATION" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

drop_receipt() {
  [ -n "${REC_RECEIPT:-}" ] && rm -f -- "$REC_RECEIPT" 2>/dev/null
  rm -f -- "$RECEIPT" 2>/dev/null || true
}

cmd_hold() {
  local reason=${*:-}
  mkdir -p "$STATE" 2>/dev/null || true
  printf 'held_at=%s\nreason=%s\n' "$(date +%s)" "$reason" > "$HOLD" || {
    echo "fm-wake-ack: the hold marker could not be written" >&2
    exit 1
  }
  log_line hold "${reason:-no reason given}"
  if [ -e "$PENDING" ]; then
    echo "wake acknowledgement held: this turn's end acknowledges nothing, and the next drain presents the wake again"
  else
    echo "wake acknowledgement hold recorded (no pre-drained wake is pending right now; the hold applies to the next one and is consumed once)"
  fi
}

cmd_void() {
  local reason='' claim prompt
  PAYLOAD=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --claude)
        # shellcheck source=bin/fm-hook-host-lib.sh
        . "$SCRIPT_DIR/fm-hook-host-lib.sh"
        PAYLOAD=$(cat 2>/dev/null || true)
        fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
        ;;
      *) reason="$reason${reason:+ }$1" ;;
    esac
    shift
  done
  [ -e "$PENDING" ] || [ -e "$HOLD" ] || exit 0
  if [ -n "$PAYLOAD" ] && [ -f "$PENDING" ] && read_record "$PENDING" && [ -n "$REC_NONCE" ]; then
    prompt=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null) || prompt=$PAYLOAD
    case "$prompt" in
      *"$REC_NONCE"*)
        log_line delivered "ack_through=$REC_ACK_THROUGH: the prompt is this record's own rewake; kept for its turn end"
        exit 0
        ;;
    esac
  fi
  if [ -e "$HOLD" ] || [ -L "$HOLD" ]; then
    rm -f -- "$HOLD"
    log_line hold-consumed "void: ${reason:-prompt}"
  fi
  [ -e "$PENDING" ] || exit 0
  claim="$PENDING.void.$$"
  mv -f -- "$PENDING" "$claim" 2>/dev/null || exit 0
  read_record "$claim" || true
  drop_receipt
  rm -f -- "$claim"
  log_line void "${reason:-prompt}: ack_through=${REC_ACK_THROUGH:-?} recovery_generation=${REC_GENERATION:-} left queued"
  exit 0
}

cmd_record() {
  local ack_through='' generation='' receipt='' session_id='' session_pid='' claim_gen='' nonce tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ack-through) ack_through=${2:-}; shift ;;
      --recovery-generation) generation=${2:-}; shift ;;
      --receipt) receipt=${2:-}; shift ;;
      --session-id) session_id=${2:-}; shift ;;
      --session-pid) session_pid=${2:-}; shift ;;
      --generation) claim_gen=${2:-}; shift ;;
      *) echo "fm-wake-ack: unknown record argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$ack_through" in ''|*[!0-9]*) echo "fm-wake-ack: record needs a numeric --ack-through" >&2; exit 2 ;; esac
  case "$generation" in *[!A-Za-z0-9._-]*) echo "fm-wake-ack: invalid --recovery-generation" >&2; exit 2 ;; esac
  [ -n "$receipt" ] && [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    || { echo "fm-wake-ack: record needs an existing --receipt" >&2; exit 2; }
  case "$session_pid" in ''|*[!0-9]*) echo "fm-wake-ack: record needs a numeric --session-pid" >&2; exit 2 ;; esac
  [ -n "$claim_gen" ] || { echo "fm-wake-ack: record needs the hook --generation" >&2; exit 2; }
  case "$session_id" in *[!A-Za-z0-9._:-]*) session_id= ;; esac
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$nonce" in ''|*[!0-9a-f]*) echo "fm-wake-ack: no random nonce could be read" >&2; exit 1 ;; esac
  nonce="wake-ack-$nonce"
  if [ -e "$PENDING" ] && read_record "$PENDING"; then
    log_line replaced "earlier record ack_through=$REC_ACK_THROUGH never reached its turn end; its rows were re-presented"
    [ "$REC_RECEIPT" = "$receipt" ] || drop_receipt
  fi
  tmp=$(mktemp "$STATE/.wake-ack-pending.tmp.XXXXXX") || exit 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; exit 1; }
  {
    printf 'schema=fm-wake-ack-pending.v1\n'
    printf 'ack_through=%s\n' "$ack_through"
    printf 'recovery_generation=%s\n' "$generation"
    printf 'receipt=%s\n' "$receipt"
    printf 'session_id=%s\n' "$session_id"
    printf 'session_pid=%s\n' "$session_pid"
    printf 'generation=%s\n' "$claim_gen"
    printf 'nonce=%s\n' "$nonce"
    printf 'recorded_at=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f -- "$tmp"; exit 1; }
  mv -f -- "$tmp" "$PENDING" || { rm -f -- "$tmp"; exit 1; }
  log_line record "ack_through=$ack_through recovery_generation=$generation session_pid=$session_pid"
  printf '%s\n' "$nonce"
}

cmd_commit() {
  local session_id='' claim lock_pid rc=0 out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id) session_id=${2:-}; shift ;;
      *) echo "fm-wake-ack: unknown commit argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$session_id" in *[!A-Za-z0-9._:-]*) session_id= ;; esac
  [ -e "$PENDING" ] || exit 3
  claim="$PENDING.commit.$$"
  mv -f -- "$PENDING" "$claim" 2>/dev/null || exit 3
  if ! read_record "$claim"; then
    log_line void "malformed pending record dropped"
    drop_receipt
    rm -f -- "$claim"
    exit 5
  fi
  lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  if [ -n "$session_id" ] && [ -n "$REC_SESSION_ID" ] && [ "$session_id" != "$REC_SESSION_ID" ]; then
    log_line void "session id changed ($REC_SESSION_ID -> $session_id); ack_through=$REC_ACK_THROUGH left queued"
    drop_receipt
    rm -f -- "$claim"
    exit 5
  fi
  if [ "$lock_pid" != "$REC_SESSION_PID" ]; then
    log_line void "session lock changed ($REC_SESSION_PID -> ${lock_pid:-none}); ack_through=$REC_ACK_THROUGH left queued"
    drop_receipt
    rm -f -- "$claim"
    exit 5
  fi
  if [ -e "$HOLD" ] || [ -L "$HOLD" ]; then
    rm -f -- "$HOLD"
    log_line held "ack_through=$REC_ACK_THROUGH recovery_generation=$REC_GENERATION left queued; hold consumed"
    drop_receipt
    rm -f -- "$claim"
    exit 4
  fi
  if [ -n "$REC_GENERATION" ]; then
    out=$(FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" --ack-through "$REC_ACK_THROUGH" \
      --recovery-generation "$REC_GENERATION" --commit-stage "$REC_RECEIPT" 2>&1) || rc=$?
  elif [ -f "$REC_RECEIPT" ]; then
    out=$(FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" --commit-stage "$REC_RECEIPT" 2>&1) || rc=$?
  else
    out=
  fi
  drop_receipt
  rm -f -- "$claim"
  if [ "$rc" -eq 0 ]; then
    log_line committed "ack_through=$REC_ACK_THROUGH recovery_generation=$REC_GENERATION${out:+; $(printf '%s' "$out" | tr '\n' ' ')}"
    exit 0
  fi
  log_line failed "ack_through=$REC_ACK_THROUGH recovery_generation=$REC_GENERATION rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
  exit 1
}

case "${1:-}" in
  hold) shift; cmd_hold "$@" ;;
  void) shift; cmd_void "$@" ;;
  record) shift; cmd_record "$@" ;;
  commit) shift; cmd_commit "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
