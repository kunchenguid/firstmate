#!/usr/bin/env bash
# fm-usage-warner.sh - opt-in local threshold warner for Claude usage windows.
#
# Usage:
#   fm-usage-warner.sh [check]
#   fm-usage-warner.sh threshold [<window-id> <percent-left>|<window-id> off]
#   fm-usage-warner.sh notify <summary>
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
# `<percent>` counts percent LEFT, and a window warns when it drops TO OR BELOW
# it. That is the same direction the quota viewer, bin/fm-seat.sh's threshold,
# and every seat setting count, so no two settings here have to be mentally
# inverted against one another. It is NOT the direction this file's directives
# were read in before: they counted percent USED and warned on rising past the
# number. Every line this script prints therefore names both figures - "8% left
# (92% used)" - so a config carried over from the old reading is unmistakable
# the first time it speaks rather than quietly meaning something else. Set them
# through `fm-usage-warner.sh threshold <window-id> <percent-left>` and there is
# nothing to remember; docs/configuration.md owns the schema.
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
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-usage-warner.sh [check]   read Claude usage once and warn only on a new
                                threshold crossing (silent when unconfigured,
                                unchanged, or nothing crossed)
  fm-usage-warner.sh threshold
                               print every configured threshold
  fm-usage-warner.sh threshold <window-id> <percent-left>
                               warn when <window-id> drops to or below that
                                percent LEFT
  fm-usage-warner.sh threshold <window-id> off
                               stop warning on <window-id>
  fm-usage-warner.sh notify <summary>
                               post one notification through this home's single
                                notification path
  fm-usage-warner.sh arm       write and register state/usage-warner.check.sh
  fm-usage-warner.sh disarm    remove the check shim, its trust binding, and
                                the de-dupe record
  fm-usage-warner.sh --help    print this help

Every threshold counts percent LEFT and warns on dropping to or below it, the
same direction bin/fm-seat.sh's threshold counts. Output names both figures.
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

# lookup_value <table> <key> [column]: <table> is newline-separated tab-separated
# rows keyed by their first field; prints that row's <column> (default 2), or
# nothing when <key> is not present.
lookup_value() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v c="${3:-2}" '$1==k{print $c; exit}'
}

# id_in_list <newline-list> <id>: exact-line membership test.
id_in_list() {
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

# --- the one read ---------------------------------------------------------
# On success (exit 0), prints "<window-id>\t<percentLeft>\t<percentUsed>" once
# per window quota-axi returns for $PROVIDER's default account. quota-axi
# reports each window as percent USED, so percent LEFT is its complement and
# both are carried through together: the comparison uses percent left, and every
# line printed names both so the direction can never be misread.
# On failure (exit 1), prints one plain-text reason instead - the caller is always invoked through
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
        | "\(.id)\t\(100 - .percentUsed)\t\(.percentUsed)"
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

  local id threshold left used notified_new="" crossed=""
  while IFS=$'\t' read -r id threshold; do
    [ -n "$id" ] || continue
    left=$(lookup_value "$windows_out" "$id")
    [ -n "$left" ] || continue
    used=$(lookup_value "$windows_out" "$id" 3)
    # A window is crossed once it has dropped TO OR BELOW the configured percent
    # left. It stays crossed while it remains there and re-arms the moment it
    # reads back above, which is exactly what a window's own reset does.
    if awk -v p="$left" -v t="$threshold" 'BEGIN{exit !(p+0<=t+0)}'; then
      notified_new="${notified_new}${id}
"
      if ! id_in_list "$RECORD_NOTIFIED" "$id"; then
        crossed="${crossed}${id} at ${left}% left (${used}% used), threshold ${threshold}% left; "
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

# --- threshold setter -------------------------------------------------------
# The setter exists so a threshold is settable the same way bin/fm-seat.sh's is,
# rather than needing an operator to know this file's path and line format. It
# rewrites one directive and leaves every other line, including comments,
# exactly as it found them.
config_write_threshold() {  # <window-id> <percent-left|off>
  local id=$1 value=$2 tmp seen=0 line lid
  case "$id" in ''|*[[:space:]]*) printf 'fm-usage-warner: invalid window id: %s\n' "$id" >&2; return 1 ;; esac
  if [ "$value" != off ]; then
    case "$value" in ''|*[!0-9]*) printf 'fm-usage-warner: percent left must be a whole number from 1 to 100, or "off"\n' >&2; return 1 ;; esac
    { [ "$value" -ge 1 ] && [ "$value" -le 100 ]; } ||
      { printf 'fm-usage-warner: percent left must be a whole number from 1 to 100, or "off"\n' >&2; return 1; }
  fi
  mkdir -p "$(dirname "$CONFIG")" || return 1
  tmp=$(umask 077; mktemp "$(dirname "$CONFIG")/.fm-usage-warner-config.XXXXXX" 2>/dev/null) || return 1
  if [ -f "$CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      lid=${line%:*}
      lid="${lid#"${lid%%[![:space:]]*}"}"
      lid="${lid%"${lid##*[![:space:]]}"}"
      if [ "$lid" = "$id" ] && [ "${line%:*}" != "$line" ]; then
        seen=1
        [ "$value" = off ] || printf '%s:%s\n' "$id" "$value" >> "$tmp"
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$CONFIG"
  fi
  if [ "$seen" -eq 0 ] && [ "$value" != off ]; then
    printf '%s:%s\n' "$id" "$value" >> "$tmp"
  fi
  if ! mv -f -- "$tmp" "$CONFIG"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

action_threshold() {
  local id=${1-} value=${2-} rows row_id row_pct
  if [ -z "$id" ]; then
    rows=$(config_thresholds)
    if [ -z "$rows" ]; then
      printf '(unset - no window is watched, so this home warns about nothing)\n'
      return 0
    fi
    printf '%s\n' "$rows" | while IFS=$'\t' read -r row_id row_pct; do
      printf '%s\t%s%% left (warns once at or below %s%% left, which is %s%% used)\n' \
        "$row_id" "$row_pct" "$row_pct" "$((100 - row_pct))"
    done
    return 0
  fi
  [ -n "$value" ] || die_usage 'threshold <window-id> needs a percent left, or "off"'
  config_write_threshold "$id" "$value" || return 1
  if [ "$value" = off ]; then
    printf 'threshold cleared: %s\n' "$id"
  else
    printf 'threshold: %s at %s%% left (which is %s%% used)\n' "$id" "$value" "$((100 - value))"
  fi
  return 0
}

# --- notify -----------------------------------------------------------------
# This home's ONE notification path, exposed as an action so another firstmate
# feature can speak through it instead of opening a second alert mechanism.
# bin/fm-seat.sh's automatic mode uses it to warn the moment a seat a worker is
# already running on enters paid extra usage.
action_notify() {
  local summary=${1-}
  [ -n "$summary" ] || die_usage 'notify needs a summary'
  usage_warner_notify "$summary"
}

# --- arm / disarm -----------------------------------------------------------
# bin/fm-check-shim-lib.sh owns the shim write, trust binding, rollback, and
# removal; this script owns only when arming is refused.
FM_CHECK_SHIM_ID=$CHECK_ID
FM_CHECK_SHIM_LABEL=fm-usage-warner

action_arm() {
  if [ "$(uname)" != Darwin ]; then
    printf 'fm-usage-warner: Notification Center is only available on macOS; nothing to arm on %s\n' "$(uname)" >&2
    return 1
  fi
  if [ -z "$(config_thresholds)" ]; then
    printf 'fm-usage-warner: no threshold configured at %s\n' "$CONFIG" >&2
    return 1
  fi
  fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-usage-warner.sh" check || return 1
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  fm_check_shim_disarm "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  threshold) shift; action_threshold "${1-}" "${2-}" ;;
  notify) shift; action_notify "${1-}" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
