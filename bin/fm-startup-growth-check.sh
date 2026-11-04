#!/usr/bin/env bash
# fm-startup-growth-check.sh - daily cheap growth check for startup memory and instruction surfaces.
#
# Usage:
#   fm-startup-growth-check.sh [check]
#   fm-startup-growth-check.sh arm
#   fm-startup-growth-check.sh disarm
#   fm-startup-growth-check.sh --help
#
# `check` evaluates at most once every 86400 seconds, one daily evaluation.
# Polls inside that interval only read this check's small state record and stay
# silent.
#
# A due evaluation uses metadata only: regular-file safety checks plus stat(1)
# byte sizes.  It does not run the startup digest, bootstrap, network checks,
# model calls, repository refreshes, /stow, or full preference/learning
# rereads.  The budget total, its verdict, and its secondmate exception come
# from `bin/fm-startup-memory-budget.sh report`, the single owner of
# config/startup-memory-budget, and are never re-derived here.  data/projects.md
# and data/secondmates.md are printed in full by every session start too, so
# they are watched for prompt growth without entering that budget total.
# The tracked set is the startup entrypoints session start executes directly
# plus the agent instruction files, not every script and library the startup
# path reaches; those bytes are code/instruction size, not LLM prompt cost.
#
# A secondmate home is never notified about the primary-owned
# data/captain-shared.md it cannot edit: the owner suppresses the budget overrun
# it causes alone, and this check suppresses its per-file growth there while
# still recording the observation.
#
# Growth is measured against a retained per-file baseline rather than only
# against the previous evaluation, so accumulation that stays under one day's
# threshold is still caught.  A surface seen for the first time is baselined
# silently, including the first content of an optional file that was absent when
# the check started; an established baseline survives the file disappearing and
# coming back.  Reporting a file rebases its baseline to the reported size, so
# accepted growth then stays silent.  The thresholds are fixed:
#   2048 bytes for tracked startup/instruction files
#   250 estimated tokens, ceil(bytes / 3), for printed startup memory files
# Budget overrun is always meaningful.
#
# A due evaluation also removes the empty temporary records a killed
# evaluation can leave in state/: only files matching its own mint pattern
# that are empty and untouched for an hour, never a record with bytes in it.
#
# `arm` writes state/startup-growth.check.sh and binds its bytes with
# fm-check-register.sh so the existing watcher slow-check cadence invokes the
# daily gate.  `disarm` removes the shim, trust binding, and report record.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CHECK_ID=startup-growth
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.startup-growth-check"
RECORD_SCHEMA_LINE=$'schema\tfm-startup-growth-check-v1'
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
BUDGET_BIN="$SCRIPT_DIR/fm-startup-memory-budget.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '2,48{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'fm-startup-growth-check: %s\n' "$1" >&2
  exit 1
}

now_epoch() {
  case "${FM_STARTUP_GROWTH_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_STARTUP_GROWTH_NOW" ;;
  esac
}

INTERVAL=86400
BYTE_THRESHOLD=2048
TOKEN_THRESHOLD=250
MAX_LINE=1000
ORPHAN_GRACE=3600
ORPHAN_SWEEP_LIMIT=64
PRIMARY_OWNED_MEMORY=
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  PRIMARY_OWNED_MEMORY=data/captain-shared.md
fi

file_size() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# A kill landing between mktemp(1) and the traps that own the temporary record
# leaves an empty scratch file nothing else would ever remove.  A due
# evaluation sweeps those, bounded on every axis: only the mint pattern, only
# empty regular files, only ones untouched for ORPHAN_GRACE seconds, and at
# most ORPHAN_SWEEP_LIMIT per evaluation.  A concurrent evaluation's live
# scratch is minutes younger than that grace, and a scratch carrying any
# record bytes is never a candidate, so neither published baselines nor work in
# flight can be removed here.
sweep_orphan_records() {  # <now>
  local now=$1 scratch mtime swept=0
  for scratch in "$STATE"/.startup-growth-check.??????; do
    [ "$swept" -lt "$ORPHAN_SWEEP_LIMIT" ] || break
    [ -f "$scratch" ] && [ ! -L "$scratch" ] && [ ! -s "$scratch" ] || continue
    mtime=$(file_mtime "$scratch") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mtime)) -ge "$ORPHAN_GRACE" ] || continue
    rm -f -- "$scratch" || true
    swept=$((swept + 1))
  done
}

append_finding() {
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$1
  else
    FINDINGS="$FINDINGS; $1"
  fi
}

stat_surface() {  # <kind> <display-path> <absolute-path> <absence-ok>
  local kind=$1 display=$2 path=$3 absence_ok=$4 bytes tokens prev_baseline baseline delta presence=present
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    bytes=0
    presence=absent
    [ "$absence_ok" = yes ] || append_finding "missing $kind $display"
  elif [ -L "$path" ] || [ ! -f "$path" ]; then
    bytes=0
    presence=unsafe
    append_finding "unsafe $kind $display"
  else
    bytes=$(file_size "$path") || true
    case "$bytes" in
      ''|*[!0-9]*)
        bytes=0
        presence=unreadable
        append_finding "unreadable $kind $display"
        ;;
    esac
  fi

  prev_baseline=$(awk -F '\t' -v p="$display" '$1 == p { print $5; found=1; exit } END { if (!found) print "" }' "$OLD_RECORD" 2>/dev/null || true)
  case "$prev_baseline" in
    ''|*[!0-9]*) prev_baseline= ;;
  esac

  if [ "$presence" != present ]; then
    baseline=${prev_baseline:--}
  elif [ -z "$prev_baseline" ] || [ "$bytes" -le "$prev_baseline" ]; then
    baseline=$bytes
  else
    baseline=$prev_baseline
    delta=$((bytes - baseline))
    case "$kind" in
      memory|printed-memory)
        tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$delta") || tokens=0
        if [ "$tokens" -ge "$TOKEN_THRESHOLD" ]; then
          baseline=$bytes
          [ "$display" = "$PRIMARY_OWNED_MEMORY" ] \
            || append_finding "$kind growth $display +${tokens} estimated_tokens (+${delta} bytes, total ${bytes} bytes)"
        fi
        ;;
      tracked)
        if [ "$delta" -ge "$BYTE_THRESHOLD" ]; then
          append_finding "tracked startup surface growth $display +${delta} bytes (total ${bytes} bytes)"
          baseline=$bytes
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$display" "$kind" "$presence" "$bytes" "$baseline" >> "$NEW_RECORD" || exit 1
}

write_record_atomically() {
  local tmp=$1 dest=$2 state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$state_device" || return 1
  mv -f -- "$tmp" "$dest"
}

record_usable() {
  local line
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r line < "$RECORD" || return 1
  [ "$line" = "$RECORD_SCHEMA_LINE" ]
}

read_last_eval() {
  record_usable || return 0
  awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$RECORD" 2>/dev/null || true
}

check_due() {
  local now last age
  now=$(now_epoch)
  last=$(read_last_eval)
  case "$last" in
    ''|*[!0-9]*) printf '%s\n' "$now"; return 0 ;;
  esac
  age=$((now - last))
  if [ "$age" -lt 0 ] || [ "$age" -ge "$INTERVAL" ]; then
    printf '%s\n' "$now"
    return 0
  fi
  return 1
}

evaluate_budget() {
  local report line reason valid=yes budget='' total='' status='' exception=''
  if ! report=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    "$BUDGET_BIN" report 2>&1); then
    reason=${report##*startup-memory-budget: }
    append_finding "startup memory budget unavailable owner=bin/fm-startup-memory-budget.sh reason=${reason//$'\n'/ }"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      effective_budget_tokens=*) budget=${line#*=} ;;
      total_estimated_tokens=*) total=${line#*=} ;;
      budget_status=*) status=${line#*=} ;;
      exception=*) exception=${line#*=} ;;
    esac
  done < <(printf '%s\n' "$report")
  case "$budget:$total" in
    *[!0-9:]*|:*|*:) valid=no ;;
  esac
  case "$status" in
    within-budget|over-budget) ;;
    *) valid=no ;;
  esac
  case "$exception" in
    ''|primary-owned-shared-file-alone-exceeds-budget) ;;
    *) valid=no ;;
  esac
  if [ "$valid" = no ]; then
    append_finding "startup memory budget unavailable owner=bin/fm-startup-memory-budget.sh reason=unparseable report"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' memory_budget "$budget" "$total" "$status" "$exception" >> "$NEW_RECORD" || exit 1
  [ "$status" = over-budget ] && [ -z "$exception" ] || return 0
  append_finding "startup memory budget overrun total_estimated_tokens=$total budget=$budget owner=bin/fm-startup-memory-budget.sh"
}

run_check() {
  local now reported_previous
  if ! now=$(check_due); then
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  sweep_orphan_records "$now"
  OLD_RECORD=$RECORD
  record_usable || OLD_RECORD=/dev/null
  reported_previous=$(awk -F '\t' '$1 == "reported" { print substr($0, index($0, "\t") + 1); exit }' "$OLD_RECORD" 2>/dev/null || true)
  NEW_RECORD=$(mktemp "$STATE/.startup-growth-check.XXXXXX") || exit 1
  trap 'rm -f -- "${NEW_RECORD:-}"' EXIT
  trap 'rm -f -- "${NEW_RECORD:-}"; exit 1' HUP INT TERM
  FINDINGS=
  printf '%s\n' "$RECORD_SCHEMA_LINE" > "$NEW_RECORD" || exit 1
  printf '%s\t%s\n' last_eval "$now" >> "$NEW_RECORD" || exit 1

  stat_surface tracked AGENTS.md "$FM_ROOT/AGENTS.md" no
  stat_surface tracked CLAUDE.md "$FM_ROOT/CLAUDE.md" yes
  stat_surface tracked bin/fm-session-start.sh "$FM_ROOT/bin/fm-session-start.sh" no
  stat_surface tracked bin/fm-bootstrap.sh "$FM_ROOT/bin/fm-bootstrap.sh" no
  stat_surface tracked bin/fm-supervision-instructions.sh "$FM_ROOT/bin/fm-supervision-instructions.sh" no
  stat_surface printed-memory data/projects.md "$DATA_DIR/projects.md" yes
  stat_surface printed-memory data/secondmates.md "$DATA_DIR/secondmates.md" yes
  stat_surface memory data/captain.md "$DATA_DIR/captain.md" yes
  stat_surface memory data/captain-shared.md "$DATA_DIR/captain-shared.md" yes
  stat_surface memory data/learnings.md "$DATA_DIR/learnings.md" yes

  evaluate_budget

  if [ -n "$FINDINGS" ]; then
    if [ "$FINDINGS" != "$reported_previous" ]; then
      fm_cap_line "startup-growth: $FINDINGS" "$MAX_LINE"
    fi
    printf '%s\t%s\n' reported "$FINDINGS" >> "$NEW_RECORD" || exit 1
  fi
  write_record_atomically "$NEW_RECORD" "$RECORD" || fail "could not publish report record"
  NEW_RECORD=
}

SHIM_TMP=
ARM_BACKUP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.startup-growth-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.startup-growth-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-startup-growth-check.sh") check")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    run_check
    ;;
  arm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
