#!/usr/bin/env bash
# Choose which Claude account (seat) NEW claude workers launch on.
#
# Usage:
#   fm-seat.sh status
#   fm-seat.sh list
#   fm-seat.sh switch <name|default> [--force]
#   fm-seat.sh switch --next [--force]
#   fm-seat.sh probe [<name|default>]
#   fm-seat.sh add <name>
#   fm-seat.sh threshold [<percent>|off]
#   fm-seat.sh threshold-reached
#   fm-seat.sh arm [--interval <secs>] [--stable <n>]
#   fm-seat.sh retire
#
# status     Print the active seat, the configured auto-switch threshold, every
#            live task's OWN recorded seat, so a switch can be read against the
#            workers it did not touch, and every local secondmate home that
#            declines inherited seat settings, with the seat that home is
#            actually on, so a decline is never invisible.
# list       Print every seat with its login state and account identity.
# switch     Point future claude workers at <name>. `default` clears the setting
#            and returns to the ambient login. `--next` rotates to the next
#            logged-in seat after the active one, which is what the threshold
#            watch fires. Rotation covers only named seats under the seats root:
#            the default profile is never a rotation target, because it is the
#            owner's own interactive login and can change account under them.
#            Refuses a seat that is not logged in, because a worker launched
#            there fails on its first message; --force overrides that refusal
#            when the probe itself cannot reach a verdict. After the switch it
#            runs bin/fm-config-push.sh --local-only so this machine's running local
#            secondmate homes take the new seat too, reporting each home, and
#            naming each seat item a declining home skipped and why.
# probe      Report whether a seat is logged in. Exit 0 logged in, 1 not logged
#            in, 2 undecided.
# add        Create an empty profile directory for a new seat and print the exact
#            login command the account owner runs. It never logs in, never reads
#            or writes any credential, and never touches the Keychain.
# threshold  Print, set, or clear the percent-remaining that trips an automatic
#            switch. Absent means no automatic switching.
# threshold-reached
#            The condition predicate: exit 0 when the active seat's remaining
#            quota is at or below the configured threshold, 1 when it is not,
#            and 2 when no threshold is configured or the read failed. Exit 2 is
#            an error to the watch, never a true, so an unreadable quota never
#            switches accounts.
# arm        Register the automatic switch as ONE condition->action watch through
#            bin/fm-procevent-when.sh: condition `threshold-reached`, action
#            `switch --next`. It fires at most once, which is the edge trigger,
#            and it runs on the watcher's existing cycle rather than a daemon of
#            its own. Re-arm after it fires to watch the next crossing.
# retire     Stop that watch.
#
# A switch NEVER disturbs a running worker. It rewrites one config file that only
# a fresh spawn reads; every live task keeps the profile recorded in its own task
# record, and its relaunches and resumes keep reading that record.
#
# A switch reaches every local secondmate home by default, so the machine moves
# together. A home that must spend a different account - one home on a personal
# or client account while the rest run on the team account - declines by placing
# config/claude-seat-local in its OWN config dir; it then keeps its own three
# seat files and runs its own switch, threshold, and arm against itself.
# bin/fm-config-inherit-lib.sh owns that decline for every convergence point.
# bin/fm-seat-lib.sh owns the resolution rules; docs/claude-seats.md owns the
# operator procedure, including what the account owner must do to add a seat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# Secondmate-home discovery and validation, shared with bin/fm-config-push.sh so
# status reports the same homes a switch actually pushes to.
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# login_state <name>
# Print "logged-in", "not-logged-in", or "unknown" for a seat name.
login_state() {
  local name=$1 dir rc
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || { printf 'unknown\n'; return; }
  fi
  dir=$(fm_seat_config_dir "$name")
  fm_seat_logged_in "$dir"
  rc=$?
  case "$rc" in
    0) printf 'logged-in\n' ;;
    1) printf 'not-logged-in\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# all_seats
# Every selectable seat name: the default seat first, then each directory seat.
all_seats() {
  printf '%s\n' "$FM_SEAT_DEFAULT_NAME"
  fm_seat_list
}

cmd_list() {
  local name state account dir active
  active=$(fm_seat_active)
  printf 'seats root: %s\n' "$(fm_seat_root)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir=$(fm_seat_config_dir "$name")
    state=$(login_state "$name")
    account=$(fm_seat_account "$dir" 2>/dev/null) || account=
    printf '%s%s\t%s\t%s\t%s\n' \
      "$([ "$name" = "$active" ] && printf '* ' || printf '  ')" \
      "$name" "$state" "${account:--}" "${dir:-(ambient default login)}"
  done < <(all_seats)
}

# live_task_seats
# One line per task record that still exists, naming the profile that task
# actually launched with. This is the evidence that a switch left running work
# alone, so it reads each task's own record and never re-resolves the config.
live_task_seats() {
  local meta id seat
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    seat=$(sed -n 's/^claude_seat=//p' "$meta" | tail -1)
    printf '%s\t%s\n' "$id" "${seat:-(ambient default login)}"
  done
}

# declining_secondmate_homes
# One tab-separated row per LOCAL secondmate home that declines inherited seat
# settings: id, the seat that home is on, and its path. A decline that produced
# no visible row would be a setting that silently does nothing, which is the one
# failure this opt-out exists to avoid.
# Remote routes never receive seat settings at all, so they are not listed.
declining_secondmate_homes() {
  local id home _window meta
  [ -d "$STATE" ] || return 0
  while IFS='|' read -r id home _window meta; do
    [ -n "$id" ] && [ -n "$home" ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    validate_secondmate_home "$id" "$home" || continue
    fm_config_inherit_seat_optout "$VALIDATED_HOME/config" || continue
    printf '%s\t%s\t%s\n' "$id" "$(fm_seat_active "$VALIDATED_HOME/config")" "$VALIDATED_HOME"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
}

cmd_status() {
  local active profile threshold rows
  active=$(fm_seat_active)
  printf 'active seat for NEW workers: %s\n' "$active"
  profile=$(fm_seat_config_dir "$active")
  printf 'active profile: %s\n' "${profile:-(ambient default login)}"
  printf 'login state: %s\n' "$(login_state "$active")"
  if threshold=$(fm_seat_threshold); then
    printf 'auto-switch threshold: %s%% remaining\n' "$threshold"
  else
    printf 'auto-switch threshold: (unset - no automatic switching)\n'
  fi
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat >/dev/null 2>&1 &&
     [ -f "$STATE/when/$("$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat 2>/dev/null).spec" ]; then
    printf 'auto-switch watch: armed\n'
  else
    printf 'auto-switch watch: not armed\n'
  fi
  printf '\nlive workers keep the seat they launched with:\n'
  rows=$(live_task_seats)
  if [ -z "$rows" ]; then
    printf '  (no task records)\n'
  else
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id seat; do
      printf '  %s\t%s\n' "$id" "$seat"
    done
  fi
  printf '\nlocal secondmate homes declining inherited seats:\n'
  rows=$(declining_secondmate_homes)
  if [ -z "$rows" ]; then
    printf '  (none - every local home takes this seat)\n'
  else
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id seat home; do
      printf '  %s\t%s\t%s\n' "$id" "$seat" "$home"
    done
  fi
}

cmd_probe() {
  local name=${1:-} state
  [ -n "$name" ] || name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$name" || die "invalid seat name: $name"
  fi
  state=$(login_state "$name")
  printf '%s\t%s\n' "$name" "$state"
  case "$state" in
    logged-in) return 0 ;;
    not-logged-in) return 1 ;;
    *) return 2 ;;
  esac
}

# next_seat
# The seat after the active one, in list order, that is logged in. Rotation
# wraps, and the active seat is never chosen, so a rotation with no other
# logged-in seat refuses rather than pretending to switch.
#
# Rotation covers ONLY named seats under the seats root. The default profile is
# deliberately excluded: it is the account owner's own interactive login, it
# changes under them whenever they sign in somewhere else, and nothing here can
# tell which account it currently holds. An automatic switch must not land
# workers on a store whose identity moved without anyone asking. `switch
# default` stays available as an explicit, manual choice.
#
# The seat set is read fresh from the seats root on every call, so this never
# assumes which seats exist or that any particular one is present.
next_seat() {
  local active seats n i idx name
  active=$(fm_seat_active)
  mapfile -t seats < <(fm_seat_list)
  n=${#seats[@]}
  [ "$n" -gt 0 ] || return 1
  idx=-1
  for i in "${!seats[@]}"; do
    [ "${seats[$i]}" = "$active" ] && idx=$i
  done
  for ((i = 1; i <= n; i++)); do
    name=${seats[$(((idx + i) % n))]}
    [ "$name" != "$active" ] || continue
    if [ "$(login_state "$name")" = logged-in ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# write_active <name>
# Replace config/claude-seat atomically, or remove it for the default seat. This
# is the whole of a switch: one file that only a fresh spawn ever reads.
write_active() {
  local name=$1 tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$name" = "$FM_SEAT_DEFAULT_NAME" ]; then
    rm -f "$CONFIG/claude-seat" || die "could not clear $CONFIG/claude-seat"
    return 0
  fi
  tmp="$CONFIG/.claude-seat.$$"
  printf '%s\n' "$name" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat" || die "could not publish $CONFIG/claude-seat"
}

cmd_switch() {
  local name='' force=0 rotate=0 prior state dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next) rotate=1; shift ;;
      --force) force=1; shift ;;
      -*) usage ;;
      *) [ -z "$name" ] || usage; name=$1; shift ;;
    esac
  done
  if [ "$rotate" -eq 1 ]; then
    [ -z "$name" ] || usage
    name=$(next_seat) || die "no other logged-in seat under the seats root to rotate to; add and log into a second seat first (docs/claude-seats.md). The default profile is never a rotation target, so switch to it by name if that is what you want"
  fi
  [ -n "$name" ] || usage
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$name" || die "invalid seat name: $name"
    dir=$(fm_seat_dir "$name") || die "seat '$name' does not resolve to a profile directory"
    # A missing profile probes as undecided, which --force would cross; refuse
    # it outright so a typo cannot point every new worker at nothing.
    [ -d "$dir" ] || die "seat '$name' has no profile directory at $dir; run 'fm-seat.sh add $name' first"
  fi
  prior=$(fm_seat_active)
  if [ "$name" = "$prior" ]; then
    printf 'seat unchanged: %s\n' "$name"
    return 0
  fi
  state=$(login_state "$name")
  case "$state" in
    logged-in) ;;
    not-logged-in)
      # A hard refusal: this profile has no credentials, so every worker sent
      # there would fail on its first message. --force cannot override a proven
      # negative, only an undecided probe.
      die "seat '$name' is not logged in; run 'fm-seat.sh add $name' for the owner's login steps (docs/claude-seats.md)"
      ;;
    *)
      [ "$force" -eq 1 ] || die "could not confirm seat '$name' is logged in (quota read gave no verdict); re-run with --force to switch anyway"
      ;;
  esac
  write_active "$name"
  printf 'switched: %s -> %s\n' "$prior" "$name"
  printf 'applies to NEW claude workers only; running workers keep their own seat\n'
  propagate_to_secondmates
}

# propagate_to_secondmates
# Carry the switch to this machine's live secondmate homes through the one
# existing convergence, bin/fm-config-push.sh, which reports every home as
# updated, unchanged, skipped, or failed. Remote routes never receive seat
# settings (bin/fm-config-inherit-lib.sh). A failed push never undoes the
# primary's switch; it is reported, and the push can be re-run on its own.
propagate_to_secondmates() {
  if FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-config-push.sh" --local-only; then
    return 0
  fi
  printf 'warning: seat switched here, but not every secondmate home was updated (see above); those homes keep spawning on their previous seat until bin/fm-config-push.sh --local-only succeeds\n' >&2
}

cmd_add() {
  local name=$1 dir
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "'$FM_SEAT_DEFAULT_NAME' names the ambient login, not a seat directory; choose another name"
  fm_seat_name_valid "$name" || die "invalid seat name: $name"
  dir=$(fm_seat_dir "$name") || die "seat '$name' does not resolve to a profile directory"
  mkdir -p "$dir" || die "could not create $dir"
  chmod 700 "$dir" 2>/dev/null || true
  printf 'seat profile directory: %s\n' "$dir"
  printf '\n'
  printf 'This created an empty profile directory and nothing else. No credential\n'
  printf 'was read, copied, or written, and the Keychain was not touched.\n'
  printf '\n'
  printf 'The account owner now logs this seat in, personally, in a terminal:\n'
  printf '\n'
  printf '  CLAUDE_CONFIG_DIR=%s claude\n' "$dir"
  printf '\n'
  printf 'then runs /login inside that session and signs in as the account this\n'
  printf 'seat should bill to. Claude Code stores those credentials under a\n'
  printf 'Keychain entry derived from this directory path, so they never mix with\n'
  printf 'the default login. Confirm with:\n'
  printf '\n'
  printf '  bin/fm-seat.sh probe %s\n' "$name"
  printf '\n'
  printf 'and then make it the active seat with:\n'
  printf '\n'
  printf '  bin/fm-seat.sh switch %s\n' "$name"
}

cmd_threshold() {
  local v=${1-} tmp
  if [ -z "$v" ]; then
    if v=$(fm_seat_threshold); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - no automatic switching)\n'
    return 0
  fi
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$v" = off ]; then
    rm -f "$CONFIG/claude-seat-threshold" || die "could not clear the threshold"
    printf 'auto-switch threshold cleared\n'
    return 0
  fi
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "threshold must be a percent between 0 and 100, or 'off'"
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 ||
    die "threshold must be a percent between 0 and 100, or 'off'"
  tmp="$CONFIG/.claude-seat-threshold.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat-threshold" || die "could not publish the threshold"
  printf 'auto-switch threshold: %s%% remaining\n' "$v"
}

# The condition half of the automatic switch. It reads the SAME quota surface
# the rest of the fleet reads (quota-axi), against the profile a new worker on
# the active seat would get, and never opens a poll loop of its own: the
# when-runner owns cadence.
cmd_threshold_reached() {
  local threshold name dir out remaining
  threshold=$(fm_seat_threshold) || return 2
  command -v quota-axi >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || return 2
  fi
  dir=$(fm_seat_config_dir "$name")
  # Exit status is ignored for the same reason fm_seat_logged_in ignores it: an
  # unavailable provider still prints the report that says so, and that report
  # is what decides. Unreadable output stays an error, never a true.
  out=$(CLAUDE_CONFIG_DIR="$dir" quota-axi --provider claude --no-credential-refresh --full --json 2>/dev/null </dev/null || true)
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 2
  # The tightest remaining percentage across the active seat's ACCOUNT-level
  # scopes (all_models/all_products), read through the same quota_effective the
  # dispatch chooser uses. A model- or product-only window does not count: it
  # constrains only workers on that model. An exhausted runway counts as reached
  # even when no percentage is readable; no applicable row, or anything else
  # unreadable, is an error, never a true.
  remaining=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_effective(quota_row(.; "claude"; ""); "default")
    | if (.runway.status // "") == "exhausted_now" then "0"
      elif .status == "known" and (.effectivePercentRemaining | type) == "number"
      then (.effectivePercentRemaining | tostring)
      else "error"
      end
  ' 2>/dev/null) || return 2
  [ -n "$remaining" ] && [ "$remaining" != error ] || return 2
  jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1
}

cmd_arm() {
  local interval=300 stable=2 threshold
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ -n "${2-}" ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      --stable) [ -n "${2-}" ] || die "--stable needs a value"; stable=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  threshold=$(fm_seat_threshold) ||
    die "no auto-switch threshold configured; set one with 'fm-seat.sh threshold <percent>' first"
  next_seat >/dev/null ||
    die "no other logged-in seat under the seats root to rotate to, so an automatic switch would have nowhere to go; add and log into a second seat first (docs/claude-seats.md). The default profile is never a rotation target"
  "$SCRIPT_DIR/fm-procevent-when.sh" arm claude-seat \
    --interval "$interval" --stable "$stable" \
    --condition "$SCRIPT_DIR/fm-seat.sh" threshold-reached \
    --action "$SCRIPT_DIR/fm-seat.sh" switch --next || exit 1
  printf 'armed: automatic switch at %s%% remaining\n' "$threshold"
  printf 'fires once; re-arm after it fires to watch the next crossing\n'
}

cmd_retire() {
  "$SCRIPT_DIR/fm-procevent-when.sh" retire claude-seat
}

case "${1-}" in
  status)            shift; cmd_status "$@" ;;
  list)              shift; cmd_list "$@" ;;
  switch)            shift; cmd_switch "$@" ;;
  probe)             shift; cmd_probe "${1-}" ;;
  add)               shift; [ -n "${1-}" ] || usage; cmd_add "$1" ;;
  threshold)         shift; cmd_threshold "${1-}" ;;
  threshold-reached) shift; cmd_threshold_reached ;;
  arm)               shift; cmd_arm "$@" ;;
  retire)            shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
