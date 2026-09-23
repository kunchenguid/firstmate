#!/usr/bin/env bash
# fm-usage-warner.sh - opt-in local threshold warner for Claude usage windows.
#
# Usage:
#   fm-usage-warner.sh [check]
#   fm-usage-warner.sh arm
#   fm-usage-warner.sh disarm
#   fm-usage-warner.sh --help
#
# A THRESHOLD WARNER, NOT A USAGE VIEWER. quota-axi is the one Claude-quota
# reader this fleet depends on (bin/fm-quota-axi-lib.sh); this script never
# re-implements that read, and never renders a live percentage report. All it
# adds is: run that existing read, and speak once when a configured window
# crosses a configured percentage. `--no-credential-refresh` keeps every call
# strictly read-only; this script never passes `--allow-keychain-prompt` or
# any other credential-refreshing flag.
#
# `check` is the one read with two callers - the watcher, on its normal
# FM_CHECK_INTERVAL cadence once armed, and a human or another script running
# `fm-usage-warner.sh check` directly (for example right before starting an
# expensive task). Both hit this exact function, so this is one program with
# two callers, not two programs. No daemon, and no schedule of its own: the
# periodic half rides the watcher's existing check-shim cadence.
#
# Configuration is opt-in and load-bearing: an unconfigured home sees no
# behaviour change, no new failure mode, and no new hard dependency. Thresholds
# live in config/usage-warner (local, gitignored; docs/usage-warner.md owns the
# schema). `check` stays completely silent when that file is absent or has no
# valid directive, and `arm` refuses outright rather than registering a check
# that would never have anything to warn about.
#
# Warnings reach macOS through Notification Center (`osascript display
# notification`), the same OS-level path firstmate's own away-mode wedge alarm
# resolves to on this platform (bin/fm-supervise-daemon.sh's
# wedge_alarm_via_osascript), so the home keeps one alert mechanism rather than
# two. This script does not source or call into that daemon: production only
# execs the daemon, and the daemon's own library-mode guard defaults its
# notifier seam to "discard" whenever it is sourced instead, specifically so a
# second sourcing consumer can never fire a real notification through it. The
# away-mode config schema and max-defer rate limiting are also specific to
# buffered escalations, not to this feature's own edge-triggered de-dupe. So
# this script posts the identical OS call under its own title instead, which is
# the reusable part of "the same alerting path" without reaching into
# daemon-internal, away-mode-specific state. Notification Center is macOS-only;
# `arm` refuses on any other platform rather than registering a check that can
# never speak.
#
# Edge-triggered with a de-dupe record (state/.usage-warner): a window that
# crosses its configured threshold notifies once, stays quiet while it remains
# at or above that threshold, and re-arms the moment it next reads back below
# threshold (an account-level window's own reset does exactly this). The record
# also remembers the last reported check line so a standing read failure (for
# example quota-axi going missing) is reported once until it changes, the same
# contract bin/fm-mail-check.sh and bin/fm-tool-update-check.sh already use for
# their own standing checks; this script's arm/disarm/shim-write shape follows
# that same established precedent rather than inventing a third one.
#
# Threshold syntax in config/usage-warner: one `<window-id>:<percent>` directive
# per non-empty, non-comment line, split on the LAST colon so a per-model window
# id such as `model:fable` still parses correctly. `<window-id>` is exactly the
# `id` field quota-axi's own `--json` output already uses (`five_hour`,
# `seven_day`, `model:<name>`, ...) - this never invents a second vocabulary for
# what quota-axi already names. `<percent>` is a whole number from 1 to 100. A
# configured window id the account does not return is silently never compared;
# this is a local convenience feature, not a critical monitor, so a stale or
# unavailable id is not treated as a misconfiguration to flag.
#
# What this script never does: install, refresh, or write any credential; read
# or render a live usage report; or make quota-axi a dependency of anything
# beyond this one opt-in feature.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/usage-warner"
RECORD="$STATE/.usage-warner"
RECORD_SCHEMA=fm-usage-warner-v1
CHECK_ID=usage-warner
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
PROVIDER=claude
MAX_LINE=1000

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-usage-warner.sh [check]   read Claude usage once and warn only on a new
                                threshold crossing (silent when unconfigured,
                                unchanged, or nothing crossed)
  fm-usage-warner.sh arm       write and register state/usage-warner.check.sh
  fm-usage-warner.sh disarm    remove the check shim, its trust binding, and
                                the de-dupe record
  fm-usage-warner.sh --help    print this help

Thresholds are read from config/usage-warner (local, gitignored).
See docs/usage-warner.md for the schema and docs/examples/usage-warner for a
starting point.
EOF
}

die_usage() {
  printf 'fm-usage-warner: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# The watcher's per check bound, read from this check's own environment because
# the watcher runs the check as a direct child. fm_run_timed counts a whole
# second before it alarms and allows a second of kill grace, so the read bound
# leaves that margin below it, and never exceeds 10 seconds for a single local
# call. A bound that leaves no room is reported as a read not measured.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
READ_TIMEOUT_SECS=$((CHECK_TIMEOUT - 3))
[ "$READ_TIMEOUT_SECS" -le 10 ] || READ_TIMEOUT_SECS=10

# --- config -------------------------------------------------------------
# Prints "<window-id>\t<percent>" once per valid directive in config/usage-warner,
# or nothing at all when the file is absent, empty, or has no valid directive.
# That "nothing" is the opt-in gate every other action checks.
config_thresholds() {
  local line id percent
  [ -f "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    id=${line%:*}
    percent=${line##*:}
    [ "$id" != "$line" ] || continue
    [ -n "$id" ] || continue
    case "$percent" in ''|*[!0-9]*) continue ;; esac
    [ "$percent" -ge 1 ] && [ "$percent" -le 100 ] || continue
    printf '%s\t%s\n' "$id" "$percent"
  done < "$CONFIG"
}

# lookup_value <table> <key>: <table> is newline-separated "key<TAB>value" rows;
# prints the first matching value, or nothing when <key> is not present.
lookup_value() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'
}

# id_in_list <newline-list> <id>: exact-line membership test.
id_in_list() {
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

# --- the one read ---------------------------------------------------------
# On success (exit 0), prints "<window-id>\t<percentUsed>" once per window
# quota-axi returns for $PROVIDER's default account. On failure (exit 1),
# prints one plain-text reason instead - the caller is always invoked through
# command substitution, which runs this function in a subshell, so a side
# channel global would never make it back to the caller; the captured stdout
# is the only channel that does. quota_row is the exact join
# bin/fm-quota-axi-lib.sh's dispatch consumers already use to pick a provider's
# row, so this never invents a second selection rule; an empty lane resolves to
# the default account on a schema-6 snapshot, matching schema 5's single row
# per provider. Account or seat switching is out of scope for this feature, so
# only the default lane is ever read here.
usage_warner_read() {
  local json rc=0 rows
  command -v quota-axi >/dev/null 2>&1 || {
    printf 'quota-axi is not installed\n'
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is not installed\n'
    return 1
  }
  if [ "$READ_TIMEOUT_SECS" -lt 1 ]; then
    printf 'quota-axi read not measured: FM_CHECK_TIMEOUT of %ss leaves no room for a read\n' "$CHECK_TIMEOUT"
    return 1
  fi
  json=$(fm_run_timed "$READ_TIMEOUT_SECS" quota-axi --provider "$PROVIDER" --json --full --no-credential-refresh 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'quota-axi read did not finish within the %ss budget\n' "$READ_TIMEOUT_SECS"
    return 1
  elif [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    printf 'quota-axi read failed\n'
    return 1
  fi
  if ! printf '%s\n' "$json" | fm_quota_json_valid; then
    printf 'quota-axi returned an unexpected response shape\n'
    return 1
  fi
  rows=$(printf '%s\n' "$json" | jq -r --arg provider "$PROVIDER" --arg lane '' "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $provider; $lane) as $row
    | if ($row // null) == null then empty else
        ($row.windows // [])[]
        | select((.percentUsed | type) == "number")
        | select((.id | type) == "string")
        | "\(.id)\t\(.percentUsed)"
      end
  ' 2>/dev/null)
  if [ -z "$rows" ]; then
    printf 'quota-axi returned no usable %s windows\n' "$PROVIDER"
    return 1
  fi
  printf '%s\n' "$rows"
}

# --- notification ---------------------------------------------------------
# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane. The summary is passed as an argv item
# (never interpolated into the AppleScript source) so its text can never break
# the script, matching bin/fm-supervise-daemon.sh's own osascript notifier.
usage_warner_notify() {  # <summary>
  local summary=$1
  command -v osascript >/dev/null 2>&1 || {
    printf 'fm-usage-warner: osascript not found; cannot post a notification\n' >&2
    return 1
  }
  osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Firstmate: Claude usage"' \
    -e 'end run' "$summary" >/dev/null 2>&1
}

# --- de-dupe record -------------------------------------------------------
RECORD_REPORTED=
RECORD_NOTIFIED=

record_read() {
  local line in_notified=0 notified=""
  RECORD_REPORTED=
  RECORD_NOTIFIED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$RECORD_SCHEMA") continue ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
      notified-begin) in_notified=1 ;;
      notified-end) in_notified=0 ;;
      *)
        if [ "$in_notified" -eq 1 ]; then
          notified="${notified}${line}
"
        fi
        ;;
    esac
  done < "$RECORD"
  RECORD_NOTIFIED=${notified%$'\n'}
  return 0
}

record_write() {  # <reported-line> <notified-newline-list>
  local reported=$1 notified=$2 tmp
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(mktemp "$STATE/.fm-usage-warner.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'reported=%s\n' "$reported"
    printf 'notified-begin\n'
    [ -z "$notified" ] || printf '%s\n' "$notified"
    printf 'notified-end\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- check ------------------------------------------------------------------
action_check() {
  local thresholds windows_out status_line="" read_out read_rc=0
  thresholds=$(config_thresholds)
  [ -n "$thresholds" ] || return 0

  record_read

  read_out=$(usage_warner_read)
  read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    status_line="usage-warner: $read_out"
    if [ "$status_line" != "$RECORD_REPORTED" ]; then
      fm_cap_line_var "$status_line" "$MAX_LINE"
      printf '%s\n' "$FM_LINE_CAP_LINE"
    fi
    record_write "$status_line" "$RECORD_NOTIFIED"
    return 0
  fi
  windows_out=$read_out

  local id threshold pct notified_new="" crossed=""
  while IFS=$'\t' read -r id threshold; do
    [ -n "$id" ] || continue
    pct=$(lookup_value "$windows_out" "$id")
    [ -n "$pct" ] || continue
    if awk -v p="$pct" -v t="$threshold" 'BEGIN{exit !(p+0>=t+0)}'; then
      notified_new="${notified_new}${id}
"
      if ! id_in_list "$RECORD_NOTIFIED" "$id"; then
        crossed="${crossed}${id} at ${pct}% (>=${threshold}%); "
      fi
    fi
  done <<< "$thresholds"
  notified_new=${notified_new%$'\n'}

  status_line=""
  if [ -n "$crossed" ]; then
    crossed=${crossed%; }
    status_line="usage-warner: $crossed"
    fm_cap_line_var "$status_line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
    usage_warner_notify "$crossed" || true
  fi
  record_write "$status_line" "$notified_new"
  return 0
}

# --- arm / disarm -----------------------------------------------------------
# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-usage-warner.sh - Claude usage threshold poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-usage-warner.sh") check"
}

# Write the shim the way this repo writes its other trusted check shims
# (bin/fm-mail-check.sh, bin/fm-tool-update-check.sh): guards run before
# anything is written, so a symlink at the shim path is refused instead of
# followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
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
  tmp=$(umask 077; mktemp "$STATE/.fm-usage-warner-check.XXXXXX" 2>/dev/null) || return 1
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

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-usage-warner-check.XXXXXX" 2>/dev/null) || return 1
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
# wakes firstmate about unauthenticated state checks. So a failed or
# interrupted arm never leaves the home holding a shim without a matching trust
# binding: an already-bound shim is put back, otherwise the shim goes.
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
  printf 'fm-usage-warner: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  if [ "$(uname)" != Darwin ]; then
    printf 'fm-usage-warner: Notification Center is only available on macOS; nothing to arm on %s\n' "$(uname)" >&2
    return 1
  fi
  if [ -z "$(config_thresholds)" ]; then
    printf 'fm-usage-warner: no threshold configured at %s\n' "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  local home want
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-usage-warner: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-usage-warner: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-usage-warner: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-usage-warner: could not register %s\n' "$CHECK_SHIM" >&2
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
