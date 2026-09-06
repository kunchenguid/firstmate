#!/usr/bin/env bash
# fm-mail-check.sh - recurring received-mail poll as a standing watcher check.
#
# Usage:
#   fm-mail-check.sh [check]
#   fm-mail-check.sh arm
#   fm-mail-check.sh disarm
#   fm-mail-check.sh --help
#
# `check` runs the mail poll from this home (sourcing the same .env and using
# the same inbox state as fm-mail.sh itself) and prints one line only when
# something is wrong, so it composes with the existing watcher state-check
# contract instead of needing a schedule of its own. A successful poll prints
# nothing: each new message is already surfaced directly by the poll as a
# durable `check: mail <uid>` wake, so a healthy cadence has nothing to repeat.
#
# `arm` writes state/mail.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its normal
# FM_CHECK_INTERVAL cadence and turns its one line into a `check:` wake.
# `disarm` removes the shim, its trust binding, and the report record.
#
# Mail configuration is read from the home's own .env by the poll, so arming
# needs no configuration of its own. An home that is armed before its .env has
# the four FM_MAIL_* values is reported once for the missing value until the
# .env is fixed, which makes a partially configured channel a wake instead of
# a silent gap.
#
# Reporting is by difference against the last reported state stored in
# state/.mail-check: a poll that keeps failing reports its line once, and a
# poll that changes the story reports the change. A poll that comes back
# healthy clears the record, so the next failure is news again.
#
# The poll must finish inside the watcher's per-check bound
# (FM_CHECK_TIMEOUT, default 30, read from this check's own environment
# because the watcher runs it as a direct child). The internal budget
# FM_MAIL_CHECK_BUDGET (default 15, valid 5..25) is cut down to whatever fits
# inside that bound before the poll starts. A poll that does not finish is a
# real condition, so the budget is enforced rather than assumed: a timed-out
# poll reports one line naming the budget instead of leaving the check silent.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.mail-check"
CHECK_ID=mail
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
MAIL_BIN="$SCRIPT_DIR/fm-mail.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-mail-check-v1
MAX_LINE=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-mail-check.sh [check]   run the received-mail poll, silent on success
  fm-mail-check.sh arm       write and register state/mail.check.sh
  fm-mail-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-mail-check.sh --help    print this help

Mail configuration (FM_MAIL_USER, FM_MAIL_PASS, FM_IMAP_HOST, FM_SMTP_HOST,
FM_IMAP_PORT, FM_SMTP_PORT) is read from <FM_HOME>/.env by fm-mail.sh.
See docs/configuration.md "Mail plane" for the schema.
EOF
}

die_usage() {
  printf 'fm-mail-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

record_epoch_now() {
  case "${FM_MAIL_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_MAIL_CHECK_NOW" ;;
  esac
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac

BUDGET_SECS=${FM_MAIL_CHECK_BUDGET:-15}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-mail-check: FM_MAIL_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -lt 5 ] || [ "$BUDGET_SECS" -gt 25 ]; then
  printf 'fm-mail-check: FM_MAIL_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
  exit 2
fi

# fm_run_timed counts a whole second before it alarms, so the budget has to fit
# inside the watcher's own bound with the alarm and kill margins left over.
BUDGET_MAX=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_SECS=$BUDGET_MAX
fi

# One poll summary, built only from the poll's own combined output. The
# poll's own "fm-mail: ..." diagnostics name the missing setup value, the
# missing python3, or the failure precisely, so they are preferred to a raw
# python backtrace; success-wake lines are skipped because a fail-closed poll
# may already have printed them; anything else is summarized rather than
# dropped, and an empty failure gets a truth-stating fallback.
poll_summary() {
  local rc=$1 out=$2 line
  line=$(printf '%s\n' "$out" | sed -n '/^fm-mail: woke for /d; s/^fm-mail: //p' | head -n 1)
  if [ -z "$line" ]; then
    line=$(printf '%s\n' "$out" | sed -n '/^fm-mail: woke for /d; /^$/d; p' | head -n 1)
  fi
  if [ -z "$line" ]; then
    line="poll failed (rc=$rc)"
  fi
  printf '%s\n' "$line"
}

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

action_check() {
  local out rc line
  mkdir -p "$STATE" || return 1
  if [ ! -x "$MAIL_BIN" ]; then
    line="fm-mail.sh is missing next to this check ($MAIL_BIN)"
  else
    out=$(fm_run_timed "$BUDGET_SECS" "$MAIL_BIN" poll 2>&1) || rc=$?
    if [ "${rc:-0}" -eq 124 ]; then
      line="poll did not finish within the ${BUDGET_SECS}s budget"
    elif [ "${rc:-0}" -ne 0 ]; then
      line=$(poll_summary "$rc" "$out")
    else
      line=
    fi
  fi
  record_read
  # Report before recording, so a record that cannot be written costs a
  # repeated report rather than a lost one. The record keeps the whole line so
  # the news key and the printed report never diverge.
  if [ -n "$line" ] && [ "$line" != "$RECORD_REPORTED" ]; then
    fm_cap_line_var "mail: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$line" || true
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-mail-check.sh - received-mail poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-mail-check.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-mail-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-mail-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-mail-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -x "$MAIL_BIN" ]; then
    printf 'fm-mail-check: the mail plane is missing at %s; cannot arm\n' "$MAIL_BIN" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-mail-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-mail-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-mail-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-mail-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac