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
#   fm-seat.sh threshold [<percent-left>|off]
#   fm-seat.sh destination-min [<percent-left>|off]
#   fm-seat.sh extra-usage [stop|allow <usd>|off]
#   fm-seat.sh threshold-reached
#   fm-seat.sh auto
#   fm-seat.sh arm
#   fm-seat.sh retire
#
# status     Print the active seat, all three automatic-mode settings, whether
#            the watch is armed, whether new Claude dispatch is held right now
#            and why (the same reason bin/fm-spawn.sh prints when it refuses a
#            spawn), every live task's OWN recorded seat, so
#            a switch can be read against the workers it did not touch, and every
#            local secondmate home that declines inherited seat settings, with
#            the seat that home is actually on, so a decline is never invisible.
# list       Print every seat with its login state and account identity.
# switch     Point future claude workers at <name>. `default` clears the setting
#            and returns to the ambient login. `--next` rotates to the next
#            qualifying seat after the active one, which is what the automatic
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
# threshold  TRIGGER. Print, set, or clear the percent LEFT on the ACTIVE seat
#            that trips an automatic switch. Absent means no automatic switching.
# destination-min
#            DESTINATION HEADROOM. Print, set, or clear the percent LEFT a seat
#            must EXCEED to be a switch destination. Absent means the rotation
#            gate is login-only, exactly as it was before this setting existed,
#            and no candidate's quota is read at all.
# extra-usage
#            EXTRA-USAGE POLICY, for when no seat has headroom. `stop` holds new
#            Claude dispatch rather than starting workers that would run on paid
#            extra usage; `allow <usd>` keeps dispatching until the seat's
#            extra-usage spend reaches that dollar cap and holds after it;
#            `off` clears the policy and holds nothing. Absent means no hold of
#            any kind.
# threshold-reached
#            The trigger predicate: exit 0 when the active seat is at or below
#            the configured percent left, 1 when it is not, and 2 when no
#            threshold is configured or the read failed. Exit 2 is an error,
#            never a true, so an unreadable quota never switches accounts.
# auto       One pass of the automatic mode, run by the armed check shim: read
#            the active seat, switch when the trigger is met and a seat with
#            headroom exists, and print one line when firstmate should know.
#            Never run it in a loop of its own; `arm` gives it the watcher's.
# arm        Register `auto` as this home's repeating Claude-seat check through
#            bin/fm-check-register.sh, so it runs on the watcher's existing
#            cadence. It KEEPS watching after a switch rather than firing once:
#            a crossing fires at most once per seat, and the next seat's own
#            crossing fires again with no re-arming by hand.
# retire     Stop that watch and remove its record.
#
# WHAT THE AUTOMATIC MODE CANNOT DO. Firstmate controls which seat a NEW worker
# starts on, and whether new Claude work is dispatched at all. It cannot stop a
# worker that is ALREADY RUNNING from drawing paid extra usage mid-task; that is
# the organisation's Claude admin setting, not something any setting here
# reaches. So `extra-usage stop` means stop STARTING new work, plus a loud
# warning the moment a seat a worker is running on enters extra usage. It is
# never a guarantee of zero spend.
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

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
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
# The arm/retire half rides the same registered check shim every other repeating
# firstmate poll uses; bin/fm-check-shim-lib.sh owns its write, binding, and
# rollback, and needs these two sourced first.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"

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
  local active profile threshold minimum policy reason rows
  active=$(fm_seat_active)
  printf 'active seat for NEW workers: %s\n' "$active"
  profile=$(fm_seat_config_dir "$active")
  printf 'active profile: %s\n' "${profile:-(ambient default login)}"
  printf 'login state: %s\n' "$(login_state "$active")"
  if threshold=$(fm_seat_threshold); then
    printf 'auto-switch trigger: at or below %s%% left on the active seat\n' "$threshold"
  else
    printf 'auto-switch trigger: (unset - no automatic switching)\n'
  fi
  if minimum=$(fm_seat_destination_min); then
    printf 'destination minimum: only switch to a seat above %s%% left\n' "$minimum"
  else
    printf 'destination minimum: (unset - any logged-in seat is a valid destination)\n'
  fi
  if policy=$(fm_seat_extra_usage_policy); then
    case "$policy" in
      stop) printf 'extra-usage policy: stop - hold new Claude dispatch rather than start work on paid extra usage\n' ;;
      *)    printf 'extra-usage policy: allow up to $%s of paid extra usage, then hold\n' "${policy#allow }" ;;
    esac
  else
    printf 'extra-usage policy: (unset - nothing holds Claude dispatch)\n'
  fi
  if fm_check_shim_armed; then
    printf 'auto-switch watch: armed (keeps watching after each switch)\n'
  else
    printf 'auto-switch watch: not armed\n'
  fi
  if reason=$(fm_seat_dispatch_reason "$(fm_seat_dispatch_decision)"); then
    printf 'new Claude dispatch: allowed\n'
  else
    printf 'new Claude dispatch: HELD (bin/fm-spawn.sh --ignore-seat-hold starts one task anyway)\n'
  fi
  printf '%s\n' "$reason" | sed 's/^/  /'
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
#
# DESTINATION HEADROOM. With config/claude-seat-destination-min set, a candidate
# must also read MORE than that percent left, so a switch can never land on a
# seat that is nearly empty. A candidate whose quota gives no verdict is SKIPPED
# rather than guessed at in either direction: an ambiguous read is not evidence
# of headroom, and switching onto it would be the guess this refuses to make.
# With the setting absent no candidate quota is read at all and the gate is
# login-only, byte for byte the behaviour that predates it.
#
# Every rejected candidate is reported on stderr with its reason, so a refusal
# to switch always says which seats were considered and why none qualified.
next_seat() {
  local active seats n i idx name minimum='' remaining
  active=$(fm_seat_active)
  minimum=$(fm_seat_destination_min) || minimum=''
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
    if [ "$(login_state "$name")" != logged-in ]; then
      printf 'seat %s: skipped, not logged in\n' "$name" >&2
      continue
    fi
    if [ -z "$minimum" ]; then
      printf '%s\n' "$name"
      return 0
    fi
    if ! remaining=$(fm_seat_remaining "$(fm_seat_config_dir "$name")"); then
      printf 'seat %s: skipped, its quota could not be read, so its headroom is unknown and this makes no guess\n' "$name" >&2
      continue
    fi
    if jq -en --arg r "$remaining" --arg m "$minimum" \
      '($r | tonumber) > ($m | tonumber)' >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 0
    fi
    printf 'seat %s: skipped, %s%% left is not above the %s%% destination minimum\n' \
      "$name" "$remaining" "$minimum" >&2
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
    name=$(next_seat) || die "no seat under the seats root qualifies as a destination (each skipped seat and its reason is printed above); add and log into a second seat, or lower 'fm-seat.sh destination-min' (docs/claude-seats.md). The default profile is never a rotation target, so switch to it by name if that is what you want"
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

# write_percent_setting <file-name> <label> <value>
# The shared setter behind `threshold` and `destination-min`: both hold one
# percent LEFT, both clear with `off`, and both refuse a value outside 0-100
# rather than clamping it into something the operator did not ask for.
write_percent_setting() {
  local file=$1 label=$2 v=$3 tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$v" = off ]; then
    rm -f "$CONFIG/$file" || die "could not clear the $label"
    printf '%s cleared\n' "$label"
    return 0
  fi
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "$label must be a percent left between 0 and 100, or 'off'"
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 ||
    die "$label must be a percent left between 0 and 100, or 'off'"
  tmp="$CONFIG/.$file.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/$file" || die "could not publish the $label"
  printf '%s: %s%% left\n' "$label" "$v"
}

cmd_threshold() {
  local v=${1-}
  if [ -z "$v" ]; then
    if v=$(fm_seat_threshold); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - no automatic switching)\n'
    return 0
  fi
  write_percent_setting claude-seat-threshold 'auto-switch threshold' "$v"
}

cmd_destination_min() {
  local v=${1-}
  if [ -z "$v" ]; then
    if v=$(fm_seat_destination_min); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - any logged-in seat is a valid destination)\n'
    return 0
  fi
  write_percent_setting claude-seat-destination-min 'destination minimum' "$v"
}

# The extra-usage policy is the one seat setting that is not a percentage, so it
# has its own setter rather than being bent into the percent shape.
cmd_extra_usage() {
  local mode=${1-} amount=${2-} v tmp
  if [ -z "$mode" ]; then
    if v=$(fm_seat_extra_usage_policy); then
      case "$v" in
        stop) printf 'stop - hold new Claude dispatch rather than start work on paid extra usage\n' ;;
        *)    printf 'allow up to $%s of paid extra usage, then hold new Claude dispatch\n' "${v#allow }" ;;
      esac
      return 0
    fi
    printf '(unset - no dispatch hold; new workers launch whatever the quota says)\n'
    return 0
  fi
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  case "$mode" in
    off)
      rm -f "$CONFIG/claude-seat-extra-usage" || die "could not clear the extra-usage policy"
      printf 'extra-usage policy cleared; nothing holds Claude dispatch\n'
      return 0
      ;;
    stop) v=stop ;;
    allow)
      local LC_ALL=C
      [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
        die "'allow' needs a dollar cap, for example: extra-usage allow 25"
      v="allow $amount"
      ;;
    *) die "extra-usage must be 'stop', 'allow <usd>', or 'off'" ;;
  esac
  tmp="$CONFIG/.claude-seat-extra-usage.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat-extra-usage" || die "could not publish the extra-usage policy"
  if [ "$v" = stop ]; then
    printf 'extra-usage policy: stop\n'
    printf 'new Claude workers are held once the active seat has no plan quota left.\n'
    printf 'This stops STARTING new work. It cannot stop a worker already running from\n'
    printf 'drawing extra usage mid-task, so it is not a guarantee of zero spend.\n'
  else
    printf 'extra-usage policy: allow up to $%s, then hold\n' "$amount"
    printf 'Measured against the spend the account itself reports for this seat.\n'
  fi
}

# The TRIGGER half of the automatic switch. It reads the SAME quota surface the
# rest of the fleet reads (quota-axi), against the profile a new worker on the
# active seat would get, and never opens a poll loop of its own.
cmd_threshold_reached() {
  local threshold name dir remaining
  threshold=$(fm_seat_threshold) || return 2
  name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || return 2
  fi
  dir=$(fm_seat_config_dir "$name")
  # fm_seat_remaining owns which windows bound a worker with no specific model
  # and returns 1 for anything it could not read, so an ambiguous quota stays an
  # error here and never becomes a true that would switch accounts.
  remaining=$(fm_seat_remaining "$dir") || return 2
  jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1
}

# --- automatic mode ----------------------------------------------------------
# The de-dupe record. `fired=<seat>` names the seat a switch last landed on, so
# a destination that itself sits below the trigger is not switched away from
# on the very next poll; a switch rewrites it to the new seat, so that seat's
# OWN later crossing fires again with nothing to re-arm by hand.
# `blocked=<seat>` names the seat whose crossing has already been reported as
# having nowhere to go, or as a switch that failed. It silences only that
# report: every later poll still looks for a destination, so a candidate whose
# window resets is switched to at once. Both clear the moment the active seat
# reads back above the threshold.
# It also carries `extra=<seats>`, the set of seats last seen drawing paid extra
# usage, so that warning fires on ENTRY rather than on every poll for as long as
# the spend lasts.
AUTO_RECORD="$STATE/.claude-seat-auto"

auto_record_get() {
  [ -f "$AUTO_RECORD" ] || return 1
  sed -n "s/^$1=//p" "$AUTO_RECORD" 2>/dev/null | tail -1
}

# auto_record_set <key> <value>
# Replace one field, preserving the others. The record is small and rewritten
# whole, so a partial write can never leave a half-updated record behind.
auto_record_set() {
  local key=$1 value=$2 fired blocked extra tmp
  fired=$(auto_record_get fired) || fired=''
  blocked=$(auto_record_get blocked) || blocked=''
  extra=$(auto_record_get extra) || extra=''
  case "$key" in
    fired) fired=$value ;;
    blocked) blocked=$value ;;
    extra) extra=$value ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-seat-auto.XXXXXX" 2>/dev/null) || return 1
  { printf 'fired=%s\n' "$fired"; printf 'blocked=%s\n' "$blocked"; printf 'extra=%s\n' "$extra"; } > "$tmp" ||
    { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$AUTO_RECORD" || { rm -f -- "$tmp"; return 1; }
}

# warn_extra_usage_entry
# The loud half of the stop policy. Firstmate cannot stop a running worker from
# drawing paid extra usage, so the next best thing is to say so the moment it
# starts: every seat a live task is running on is checked, and one notification
# goes out through the home's single notification path
# (bin/fm-usage-warner.sh notify) naming the seats now spending. Reported on
# stdout too, because that line is what wakes firstmate.
warn_extra_usage_entry() {
  local meta seat label task_seats='' out spending='' summary previous
  [ -d "$STATE" ] || return 0
  # Only a CLAUDE task's recorded profile is a Claude seat. A task on any other
  # harness records no seat and reads no Claude profile, so including it would
  # check the ambient store on that task's behalf and report a seat it never
  # spends. An empty recorded seat on a claude task is the ambient default,
  # which that worker really does spend, so it stays in.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = claude ] || continue
    seat=$(sed -n 's/^claude_seat=//p' "$meta" | tail -1)
    task_seats="${task_seats}${seat}
"
  done
  task_seats=$(printf '%s' "$task_seats" | sort -u)
  [ -n "$task_seats" ] || return 0
  previous=$(auto_record_get extra) || previous=''
  # A seat whose read gave no verdict, including one the pass ran out of time
  # for, keeps its previous state rather than reading as having left extra
  # usage, so a slow read can never re-arm the warning and wake twice.
  while IFS= read -r seat; do
    label=${seat:-default profile}
    if out=$(fm_seat_quota_json "$seat"); then
      fm_seat_in_extra_usage_from "$out" || continue
    else
      case " $previous " in *" $label "*) ;; *) continue ;; esac
    fi
    spending="${spending}${label} "
  done <<< "$task_seats"
  spending=${spending% }
  [ "$spending" != "$previous" ] || return 0
  auto_record_set extra "$spending"
  # Only entry speaks. A seat that leaves extra usage updates the record
  # silently, which is what re-arms the warning for its next entry.
  [ -n "$spending" ] || return 0
  summary="Claude seat in paid extra usage: $spending"
  printf 'claude-seat: %s (a worker already running keeps this seat; only the account admin setting stops it drawing extra usage)\n' "$summary"
  "$SCRIPT_DIR/fm-usage-warner.sh" notify "$summary" >/dev/null 2>&1 || true
}

# One pass of the automatic mode. Prints a line ONLY when firstmate should know,
# and is otherwise completely silent, because it runs on the watcher's cadence
# and every line it prints becomes a wake.
#
# The watcher kills a check that outlives FM_CHECK_TIMEOUT, so the pass sets a
# read deadline a few seconds inside it (the margin bin/fm-usage-warner.sh
# leaves) that every quota read it makes respects, and runs the trigger and
# switch before the extra-usage scan, so that scan can never spend the switch's
# budget. A read the deadline cuts short gives no verdict, like any other
# unreadable quota.
cmd_auto() {
  local threshold policy check_timeout
  threshold=$(fm_seat_threshold) || return 0
  check_timeout=${FM_CHECK_TIMEOUT:-30}
  case "$check_timeout" in
    ''|*[!0-9]*|0) check_timeout=30 ;;
  esac
  FM_SEAT_READ_DEADLINE=$(($(date +%s) + check_timeout - 3))
  export FM_SEAT_READ_DEADLINE
  policy=$(fm_seat_extra_usage_policy) || policy=''
  auto_trigger "$threshold" "$policy"
  [ -z "$policy" ] || warn_extra_usage_entry
}

# auto_trigger <threshold> <policy>
# The trigger and switch half of one automatic pass.
auto_trigger() {
  local threshold=$1 policy=$2 active dir remaining target fired blocked out
  active=$(fm_seat_active)
  dir=$(fm_seat_config_dir "$active")
  if ! remaining=$(fm_seat_remaining "$dir"); then
    # Silent: an unreadable quota is a transient condition on a poll that runs
    # every cycle, and reporting it on each one would be noise, not a wake.
    # Nothing is switched on it either, which is the part that matters.
    return 0
  fi
  if ! jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
    auto_record_set fired ''
    auto_record_set blocked ''
    return 0
  fi
  fired=$(auto_record_get fired) || fired=''
  [ "$fired" != "$active" ] || return 0
  blocked=$(auto_record_get blocked) || blocked=''
  if target=$(next_seat 2>/dev/null); then
    # Re-invoked as a subprocess so a refusal inside the switch ends that call
    # rather than this poll, and with this home's own resolution forwarded so
    # the switch lands in the home the watcher is polling for.
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-seat.sh" switch "$target" 2>&1); then
      auto_record_set fired "$target"
      auto_record_set blocked ''
      printf 'claude-seat: switched from %s at %s%% left to %s; new workers launch there\n' \
        "$active" "$remaining" "$target"
      return 0
    fi
    [ "$blocked" != "$active" ] || return 0
    auto_record_set blocked "$active"
    printf 'claude-seat: %s is at %s%% left and the switch to %s failed: %s\n' \
      "$active" "$remaining" "$target" "$(printf '%s' "$out" | tail -1)"
    return 0
  fi
  [ "$blocked" != "$active" ] || return 0
  auto_record_set blocked "$active"
  case "$policy" in
    stop)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; new Claude work will be held once this seat'\''s plan quota runs out, rather than started on paid extra usage. A worker already running is not stopped.\n' \
        "$active" "$remaining" ;;
    allow\ *)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; once this seat'\''s plan quota runs out, new Claude work continues on paid extra usage up to $%s, then will be held.\n' \
        "$active" "$remaining" "${policy#allow }" ;;
    *)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; no extra-usage policy is set, so nothing is held.\n' \
        "$active" "$remaining" ;;
  esac
}

# --- arm / retire ------------------------------------------------------------
# The watch is a registered check shim rather than the one-shot condition-action
# primitive bin/fm-procevent-when.sh provides, because that primitive fires at
# most once by design and this watch must keep running: after a switch, the seat
# it moved to has its own crossing to catch, and an operator should not have to
# re-arm between them. The action it takes is the safe, reversible half of this
# script - it rewrites one config line that only a fresh spawn reads, and never
# touches a running worker - so it is the deterministic subset a repeating poll
# may carry out on its own. bin/fm-check-shim-lib.sh owns the write and binding.
FM_CHECK_SHIM_ID=claude-seat
FM_CHECK_SHIM_LABEL=fm-seat

cmd_arm() {
  local threshold
  # Clear any older one-shot registration first, so a home upgrading from it
  # ends with one watch rather than two firing on the same crossing.
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire claude-seat >/dev/null 2>&1 || true
  fi
  threshold=$(fm_seat_threshold) ||
    die "no auto-switch threshold configured; set one with 'fm-seat.sh threshold <percent-left>' first"
  next_seat >/dev/null 2>&1 ||
    die "no seat under the seats root qualifies as a destination right now, so an automatic switch would have nowhere to go; add and log into a second seat, or lower 'fm-seat.sh destination-min' (docs/claude-seats.md). The default profile is never a rotation target"
  fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-seat.sh" auto || exit 1
  printf 'armed: automatic switch at %s%% left on the active seat\n' "$threshold"
  printf 'keeps watching after each switch; one crossing fires at most once per seat\n'
}

cmd_retire() {
  fm_check_shim_disarm "$AUTO_RECORD"
  # A home armed before the watch became a repeating check still carries the
  # older one-shot condition-action registration, which nothing else would ever
  # clear. Retiring both is what makes `retire` mean "stop watching" on any home
  # rather than only on a freshly armed one. It is a no-op when none exists.
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire claude-seat >/dev/null 2>&1 || true
  fi
  printf 'retired: the automatic Claude seat watch\n'
}

case "${1-}" in
  status)            shift; cmd_status "$@" ;;
  list)              shift; cmd_list "$@" ;;
  switch)            shift; cmd_switch "$@" ;;
  probe)             shift; cmd_probe "${1-}" ;;
  add)               shift; [ -n "${1-}" ] || usage; cmd_add "$1" ;;
  threshold)         shift; cmd_threshold "${1-}" ;;
  destination-min)   shift; cmd_destination_min "${1-}" ;;
  extra-usage)       shift; cmd_extra_usage "${1-}" "${2-}" ;;
  threshold-reached) shift; cmd_threshold_reached ;;
  auto)              shift; cmd_auto ;;
  arm)               shift; cmd_arm "$@" ;;
  retire)            shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
