# shellcheck shell=bash
# Shared overnight "quiet hours" blackout predicate for firstmate autonomous
# supervision.
# Usage: . bin/fm-blackout-lib.sh ; fm_in_blackout && ...
#
# OFF BY DEFAULT. With no local config the feature is a COMPLETE NO-OP: every
# consumer (fm-watch.sh, fm-watch-arm.sh, fm-guard.sh, the away-mode daemon)
# behaves exactly as it did before this feature existed. It is enabled per-home by
# a LOCAL, GITIGNORED config file, config/blackout.env, mirroring config/x-mode.env
# (see docs/examples/blackout.env). Because every consumer sources THIS lib and the
# lib loads that config, enablement stays consistent across the watcher, the arm,
# the guard, and recovery without each having to source it separately.
#
# The watcher PROCESS is effectively free: it blocks in bash and makes no model
# calls. The real cost is that every time the watcher WAKES firstmate it starts a
# full LLM turn (tokens). When enabled, the captain wants ZERO autonomous wakes
# overnight, so the blackout MUST be enforced in code - a directive alone cannot
# prevent a wake, because by the time firstmate is woken the tokens are spent.
#
# Window: the blackout is [FM_BLACKOUT_START_HOUR:00, FM_BLACKOUT_END_HOUR:00) in
# FM_BLACKOUT_TZ. Defaults are 18:00-05:00 America/New_York, so the ACTIVE
# (supervising) window is 05:00-18:00. Using TZ for the computation means EST/EDT
# and DST transitions are handled automatically by the system tz database.
#
# Evening-extend override (bin/fm-blackout-extend.sh): while an override epoch in
# state/blackout-override is in the FUTURE we stay ACTIVE even past the start hour;
# a past override is ignored (auto-expiry) so it never lingers into the next day.
#
# This gates ONLY autonomous polling/wakes and away-mode injections. It NEVER
# gates firstmate's response to a message from the captain.
#
# Config precedence (highest first): explicit environment variable > config file >
# baked-in default. An injectable "current time" (FM_BLACKOUT_NOW_EPOCH) makes the
# predicate unit-testable without waiting on the real clock; it is consulted only
# when set.

# Exit code the watcher (fm-watch.sh) uses to tell its parent arm
# (fm-watch-arm.sh) that it stopped because it crossed into the blackout window,
# distinct from a wake (exit 0) or an error (exit 1). The arm catches it and
# schedules resumption WITHOUT a token-costing wake. Sourced by both scripts so
# they agree on the value.
# shellcheck disable=SC2034 # Read by fm-watch.sh / fm-watch-arm.sh after sourcing.
FM_BLACKOUT_EXIT_CODE=93

FM_BLACKOUT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The operational home / state dir for this instance, resolved the same way the
# other libs resolve them so the config and override files are found consistently.
fm_blackout_home() {
  printf '%s' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_BLACKOUT_LIB_DIR/.." && pwd)}}"
}
fm_blackout_state() {
  printf '%s' "${FM_STATE_OVERRIDE:-$(fm_blackout_home)/state}"
}

# Load config/blackout.env for any of the four config vars not already set in the
# environment (explicit env wins over the file). Read in an isolated subshell so a
# user config line cannot leak unrelated variables into ours.
fm_blackout_load_config() {
  local cfg="${FM_BLACKOUT_CONFIG:-$(fm_blackout_home)/config/blackout.env}"
  [ -f "$cfg" ] || return 0
  local line _en _sh _eh _tz
  line=$(
    # shellcheck disable=SC1090
    . "$cfg" >/dev/null 2>&1
    printf '%s\t%s\t%s\t%s' \
      "${FM_BLACKOUT_ENABLED-}" "${FM_BLACKOUT_START_HOUR-}" \
      "${FM_BLACKOUT_END_HOUR-}" "${FM_BLACKOUT_TZ-}"
  )
  IFS=$'\t' read -r _en _sh _eh _tz <<EOF
$line
EOF
  [ -z "${FM_BLACKOUT_ENABLED+x}" ]    && [ -n "$_en" ] && export FM_BLACKOUT_ENABLED="$_en"
  [ -z "${FM_BLACKOUT_START_HOUR+x}" ] && [ -n "$_sh" ] && export FM_BLACKOUT_START_HOUR="$_sh"
  [ -z "${FM_BLACKOUT_END_HOUR+x}" ]   && [ -n "$_eh" ] && export FM_BLACKOUT_END_HOUR="$_eh"
  [ -z "${FM_BLACKOUT_TZ+x}" ]         && [ -n "$_tz" ] && export FM_BLACKOUT_TZ="$_tz"
  return 0
}

# The master switch. Truthy = anything except unset, empty, 0, false, no, off
# (case-insensitive), mirroring the truthiness the rest of firstmate uses.
fm_blackout_enabled() {
  fm_blackout_load_config
  case "$(printf '%s' "${FM_BLACKOUT_ENABLED:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Current epoch, honoring the injectable clock (FM_BLACKOUT_NOW_EPOCH) so both the
# hour computation and the override comparison use one consistent "now" in tests.
fm_blackout_now_epoch() {
  local now=${FM_BLACKOUT_NOW_EPOCH:-}
  case "$now" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$now" ;;
  esac
}

# Portable "hour of day in <tz> at <epoch>": macOS (BSD) date takes -r <epoch>;
# GNU date takes -d @<epoch> (its -r means a reference file's mtime). Detect once.
if [ "$(uname)" = Darwin ]; then
  _fm_hour_at_epoch() { TZ="$1" date -r "$2" +%H 2>/dev/null; }
else
  _fm_hour_at_epoch() { TZ="$1" date -d "@$2" +%H 2>/dev/null; }
fi

# fm_blackout_hour: current hour (0-23) in the blackout timezone. Echoes a decimal
# integer; falls back to 12 (mid-active) if date fails, so a broken clock can never
# wedge supervision into a permanent blackout.
fm_blackout_hour() {
  local tz=${FM_BLACKOUT_TZ:-America/New_York} h
  h=$(_fm_hour_at_epoch "$tz" "$(fm_blackout_now_epoch)")
  case "$h" in
    ''|*[!0-9]*) echo 12; return ;;
  esac
  # 10# forces base-10 so "08"/"09" are not misread as invalid octal.
  printf '%d\n' "$((10#$h))"
}

# The active evening-extend override epoch, or empty. A non-numeric or PAST epoch
# is ignored (auto-expiry), so only a future extension is honored.
fm_blackout_override_epoch() {
  local f ov now
  f="$(fm_blackout_state)/blackout-override"
  [ -f "$f" ] || return 0
  ov=$(cat "$f" 2>/dev/null || true)
  case "$ov" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now=$(fm_blackout_now_epoch)
  [ "$ov" -gt "$now" ] || return 0
  printf '%s\n' "$ov"
}

# fm_in_blackout: returns 0 (true) when supervision should be suppressed right now.
# Off by default (disabled => never blackout). An active future override keeps us
# ACTIVE even past the start hour. Otherwise the window test: the default wraps
# midnight (18 >= 5), so "hour >= start OR hour < end"; a non-wrapping window
# (start < end) uses "start <= hour < end".
fm_in_blackout() {
  fm_blackout_enabled || return 1
  [ -n "$(fm_blackout_override_epoch)" ] && return 1
  local start=${FM_BLACKOUT_START_HOUR:-18} end=${FM_BLACKOUT_END_HOUR:-5} h
  case "$start" in ''|*[!0-9]*) start=18 ;; esac
  case "$end" in ''|*[!0-9]*) end=5 ;; esac
  h=$(fm_blackout_hour)
  if [ "$start" -le "$end" ]; then
    [ "$h" -ge "$start" ] && [ "$h" -lt "$end" ]
  else
    [ "$h" -ge "$start" ] || [ "$h" -lt "$end" ]
  fi
}
