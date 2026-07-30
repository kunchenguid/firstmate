#!/usr/bin/env bash
# fm-launch.sh - the captain's front door: pick a harness, start ONE firstmate
# primary session in this home, and attach to it.
#
# Usage:
#   bin/fm-launch.sh                 render the menu, select, launch, attach
#   bin/fm-launch.sh --print-menu    render the menu and exit 0 (no side effects)
#   bin/fm-launch.sh --verbose       add the launch mechanics on stderr
#   bin/fm-launch.sh --help
#
# This launches a PRIMARY (a firstmate session: no task, no worktree, no brief),
# never a crewmate. bin/fm-spawn.sh remains the only way to start a crewmate,
# scout, or secondmate. Both compose their command from bin/fm-launch-lib.sh, so
# there is exactly one copy of every verified launch command.
#
# THE CONSUMER OBLIGATION, DISCHARGED HERE. bin/fm-launch-lib.sh's header binds
# every consumer that composes a `primary` launch to tell the captain, at launch
# time, that the session runs WITHOUT permission prompts. This launcher
# discharges that with FM_LAUNCH_AUTONOMY_NOTICE below, printed in the menu
# header on every render - before the choice, not after it, so the captain knows
# the posture of the session while they are still choosing it. The obligation
# binds on the POSTURE, not on any particular flag, so this line must survive
# even if every template's flags change. Do not make it conditional, do not move
# it behind --verbose, and do not drop it because one adapter reaches the posture
# structurally rather than through a bypass flag.
#
# WHAT THIS SCRIPT DOES NOT DO, deliberately:
#   - No network, ever, before the menu. Both availability probes are local file
#     reads (`command -v`, and one read of pi's auth record), which is what holds
#     the sub-150ms first-paint target. No catalog fetch, no quota probe, no
#     `pi --list-models` (a subprocess plus JSON parse, ~1s when measured).
#   - No `herdr status` before the menu. The Herdr gate is needed to LAUNCH, not
#     to CHOOSE, so it runs after selection and keeps a socket round trip off the
#     critical path.
#   - No side effects before selection: `q` and Ctrl-C are always clean.
#   - No bin/fm-guard.sh call. That guard reports supervision mechanics to a
#     RUNNING firstmate; this runs before one exists, and its warnings are
#     exactly the mechanics the front door keeps off the captain's screen.
#
# Files, all local to the effective FM_HOME:
#   config/launch-presets.json  optional menu presets; absent means the built-in
#                               five below. Schema: docs/configuration.md.
#   state/.launch-last          the last-used entry id, written atomically
#                               (temp + mv) so a killed launcher can never
#                               corrupt the Enter default.
#   state/.launch.lock          the home-scoped launch lock (bin/fm-wake-lib.sh's
#                               primitives, the same ones bin/fm-spawn.sh uses
#                               for its per-task spawn lock), held from the
#                               reattach check through the launch-line send. See
#                               the launch-lock note above launch_lock_release().
#
# Test seams (documented so the suite does not reach into internals):
#   FM_LAUNCH_PRESETS        override the presets path
#   FM_LAUNCH_PI_AUTH        override pi's auth record path
#   FM_LAUNCH_NO_ATTACH=1    do everything except the final attach
#   FM_LAUNCH_READY_ATTEMPTS bounded shell-prompt poll attempts (default 10)
#   FM_LAUNCH_READY_SLEEP    seconds between those attempts (default 0.3)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

PRESETS="${FM_LAUNCH_PRESETS:-$CONFIG/launch-presets.json}"
PI_AUTH="${FM_LAUNCH_PI_AUTH:-$HOME/.pi/agent/auth.json}"
LAST_USED="$STATE/.launch-last"

# The herdr TAB label for this home's one primary session. The WORKSPACE label
# is already per-home (fm_backend_herdr_workspace_label: "firstmate", or
# "2ndmate-<id>"), so this constant is unambiguous inside it and can never
# collide with a crewmate tab, which is always labeled fm-<task-id>.
PRIMARY_TAB_LABEL="firstmate"

# See THE CONSUMER OBLIGATION above before changing or moving this line.
FM_LAUNCH_AUTONOMY_NOTICE="Sessions start without permission prompts."

VERBOSE=0
PRINT_MENU=0

usage() {
  cat <<'USAGE'
fm-launch.sh - the captain's front door: pick a harness, start ONE firstmate
primary session in this home, and attach to it.

Usage:
  bin/fm-launch.sh                 render the menu, select, launch, attach
  bin/fm-launch.sh --print-menu    render the menu and exit 0 (no side effects)
  bin/fm-launch.sh --verbose       add the launch mechanics on stderr
  bin/fm-launch.sh --help

Every session this starts runs WITHOUT permission prompts; the menu says so
before you choose. Menu presets and setup: docs/launcher.md.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v) VERBOSE=1 ;;
    --print-menu) PRINT_MENU=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-launch.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

vlog() { [ "$VERBOSE" -eq 1 ] && printf 'fm-launch: %s\n' "$*" >&2 || true; }

# --- presentation -----------------------------------------------------------
#
# Every refusal is at most a few lines: what happened, and the one thing that
# fixes it. Never a stack trace, never a wall of diagnostics - --verbose exists
# for when the captain wants one.

TTY=0
[ -t 0 ] && [ -t 1 ] && TTY=1
DIM=""; RESET=""
if [ "$TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
  DIM=$'\033[2m'; RESET=$'\033[0m'
fi

# refuse <line>...: print an indented refusal and exit non-zero.
refuse() {
  local line
  printf '\n'
  for line in "$@"; do printf '  %s\n' "$line"; done
  exit 1
}

# refuse_at_door <line>...: a refusal reached before the menu was ever drawn, so
# it carries the header the menu would have carried.
refuse_at_door() {
  printf '\n  Firstmate\n'
  refuse "$@"
}

# --- presets ----------------------------------------------------------------
#
# An entry is a record of five fields - id, label, harness, model, effort -
# joined by the ASCII unit separator. NOT by a tab: a tab is IFS whitespace, so
# splitting on one silently COLLAPSES empty fields, and an entry missing its id
# would arrive here looking like a well-formed entry with everything shifted one
# place left. The unit separator is not IFS whitespace, so an empty field stays
# an empty field and the validation below can see it. An entry carries NO
# command. The command comes from launch_template() at launch time,
# which is the whole point: a hand-written launch string has already drifted once
# in a downstream registry (see bin/fm-launch-lib.sh's header).
#
# "default" for model or effort means "let the adapter choose", exactly as
# model_flag_for_harness/effort_flag_for_harness already define it.
#
# The built-in five ship with model="default" on the NATIVE entries on purpose:
# this repo is a shared template, and a pinned model id rots for every home whose
# account cannot reach it. The two Pi-routed entries DO pin a provider-qualified
# model because that string is what selects the provider at all - without it the
# entry is not "Grok via pi", it is just pi.
FM_LAUNCH_US=$'\037'
FM_LAUNCH_BUILTIN_PRESETS=(
  $'claude\037Claude\037claude\037default\037high'
  $'chatgpt-sol\037ChatGPT Sol\037pi\037openai-codex/gpt-5.6-sol\037high'
  $'grok\037Grok\037pi\037xai/grok-4\037high'
  $'codex\037Codex\037codex\037default\037high'
  $'opencode\037OpenCode\037opencode\037default\037default'
)

ENTRIES=()

load_presets() {
  local line
  if [ ! -f "$PRESETS" ]; then
    ENTRIES=("${FM_LAUNCH_BUILTIN_PRESETS[@]}")
    return 0
  fi
  command -v jq >/dev/null 2>&1 \
    || refuse_at_door "Cannot read the menu presets at $PRESETS." \
                      "Install jq, or remove that file to use the built-in menu."
  local parsed
  parsed=$(jq -r '
      if (.entries | type) != "array" then error("entries must be an array") else . end
      | .entries[]
      | [(.id // ""), (.label // ""), (.harness // ""), (.model // "default"), (.effort // "default")]
      | map(tostring)
      | join("\u001f")' "$PRESETS" 2>/dev/null) \
    || refuse_at_door "The menu presets at $PRESETS are not valid." \
                      "Fix the file, or remove it to use the built-in menu."
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # jq renders a missing key as an empty field, so an entry short of its three
    # required keys arrives here looking merely blank. Refuse it rather than
    # rendering an unnamed row that cannot launch.
    entry_split "$line"
    [ -n "$E_ID" ] && [ -n "$E_LABEL" ] && [ -n "$E_HARNESS" ] \
      || refuse_at_door "An entry in $PRESETS is missing its id, label, or harness." \
                        "Give every entry all three, or remove the file to use the built-in menu."
    ENTRIES+=("$line")
  done <<EOF
$parsed
EOF
  [ "${#ENTRIES[@]}" -gt 0 ] \
    || refuse_at_door "The menu presets at $PRESETS define no entries." \
                      "Add one, or remove the file to use the built-in menu."
  # Selection is ONE keypress, so the digits 1-9 are the whole input alphabet.
  # A tenth entry would be visible and unselectable - the mapping would stop
  # being total, which is the property that makes reprompting on a mistyped key
  # safe. Refuse instead of shipping a menu with unreachable rows.
  [ "${#ENTRIES[@]}" -le 9 ] \
    || refuse_at_door "The menu presets at $PRESETS define ${#ENTRIES[@]} entries; 9 is the most one keypress can select." \
                      "Remove the extras, then relaunch."
}

# entry_split <record>: unpack one record into E_ID/E_LABEL/E_HARNESS/E_MODEL/
# E_EFFORT.
#
# Every hot-path helper in this file communicates through globals rather than
# stdout, and none of them may be called through $(...). That is a speed
# contract, not a style preference: first paint is budgeted under 150 ms, a fork
# costs 2-4 ms, and the menu touches these helpers roughly seven times per entry.
# Routing them through command substitution measured 152 ms against a 2 ms bash
# floor - the forks WERE the entire budget.
entry_split() {  # <record>
  local rec=$1 IFS=$FM_LAUNCH_US noglob=0
  # Splitting is not the whole story: each split word would still undergo
  # pathname expansion, so a field carrying * ? or [ could match files in the
  # launcher's cwd and shift every later field. Glob is off for the split and
  # restored to whatever it was - via set -f/+f, never a subshell, per the
  # no-fork contract above.
  case $- in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2086  # deliberate word split on the unit separator via IFS
  set -- $rec
  [ "$noglob" -eq 1 ] || set +f
  E_ID=${1:-}; E_LABEL=${2:-}; E_HARNESS=${3:-}; E_MODEL=${4:-}; E_EFFORT=${5:-}
}

# --- availability probe -----------------------------------------------------
#
# Probed, never declared. An entry is available only when it can actually start
# today, and an entry that cannot stays VISIBLE and dim rather than disappearing,
# so the menu never changes shape under the captain's muscle memory.
#
# Two local reads, no network:
#   native   - the harness binary resolves on PATH. This launcher is the front
#              door, so its PATH is the captain's login PATH.
#   pi-routed - `pi` resolves AND the entry's provider (the part of the model
#              before "/") appears as a key in pi's auth record.
#
# pi's auth record is a flat JSON object keyed by provider id, whose values are
# OAuth objects with fixed field names (type, access, refresh, expires,
# accountId). Matching "<provider>" followed by a colon therefore identifies a
# top-level provider key and cannot collide with a nested field name. Doing it
# with a shell match rather than a jq subprocess is what keeps first paint fast;
# an absent or unreadable record simply means "no providers", which renders the
# entry unavailable with its sign-in line - the honest, fail-closed direction.
# harness_on_path <name>: memoized `command -v`, because a PATH MISS is the
# single most expensive thing the menu does and presets may name one harness
# more than once (the two Pi-routed entries both need `pi`).
#
# Measured on a WSL home whose PATH carries 29 Windows mounts among 40 entries:
# a HIT costs under 2 ms because the lookup stops at the first match, while a
# MISS scans every remaining directory and costs about 55 ms - the built-in
# menu's two uninstalled native entries alone account for ~113 ms of a ~125 ms
# render. Dropping the Windows mounts from PATH and changing nothing else takes
# the same render to ~7 ms, so the sub-150 ms first-paint target is held by
# construction and what remains is 9p directory access, not this file's work.
# Nothing in this file can shorten that without lying about what is installed,
# so the ENFORCED ceiling in tests/fm-launch.test.sh is 500 ms.
HARNESS_PATH_MEMO=""

harness_on_path() {  # <name>
  local h=$1 hit
  case "$HARNESS_PATH_MEMO" in
    *":$h=1:"*) return 0 ;;
    *":$h=0:"*) return 1 ;;
  esac
  if command -v "$h" >/dev/null 2>&1; then hit=1; else hit=0; fi
  HARNESS_PATH_MEMO="$HARNESS_PATH_MEMO:$h=$hit:"
  [ "$hit" -eq 1 ]
}

PI_AUTH_BLOB=""
PI_AUTH_READ=0

pi_auth_load() {
  [ "$PI_AUTH_READ" -eq 0 ] || return 0
  PI_AUTH_READ=1
  PI_AUTH_BLOB=""
  # $(<file) is bash's fork-free file read, unlike $(cat file).
  [ -r "$PI_AUTH" ] && PI_AUTH_BLOB=$(<"$PI_AUTH") || PI_AUTH_BLOB=""
  return 0
}

pi_provider_authed() {  # <provider>
  local provider=$1 re
  pi_auth_load
  [ -n "$PI_AUTH_BLOB" ] || return 1
  # Held in a variable so the provider name interpolates while the rest stays
  # regex: bash 3.2 treats a quoted pattern operand as a literal string.
  re="\"$provider\"[[:space:]]*:"
  [[ $PI_AUTH_BLOB =~ $re ]]
}

# pi_provider_of <model>: sets E_PROVIDER to the provider a pi model string
# selects, or empty when the model carries none (pi then uses its own configured
# default provider).
E_PROVIDER=""
pi_provider_of() {  # <model>
  local model=$1
  E_PROVIDER=""
  case "$model" in
    default|'') return 0 ;;
    */*) E_PROVIDER=${model%%/*} ;;
  esac
}

# probe_entry <record>: sets P_STATUS (ok|unavailable) and P_NOTE - the ONE
# actionable line for an unavailable entry, or the route hint ("via pi") for an
# available Pi-routed one. Requires entry_split to have run for this record.
#
# The two refusal causes launch_template() distinguishes are BOTH reported here,
# with the wording each one owes the captain (bin/fm-launch-lib.sh header):
# a harness with no verified adapter at all is a preset error, while a verified
# harness that simply has no primary shape is fixed by choosing another entry -
# never by reaching for a raw launch command. Deriving cause 2 as "works as a
# crewmate, refuses as a primary" keeps this free of a hardcoded harness name.
P_STATUS=""
P_NOTE=""
probe_entry() {
  local route=""
  P_STATUS=unavailable

  if ! launch_template "$E_HARNESS" primary >/dev/null 2>&1; then
    if launch_template "$E_HARNESS" ship >/dev/null 2>&1; then
      P_NOTE="no primary session - choose another entry"
    else
      P_NOTE="unknown runtime $E_HARNESS - fix the menu presets"
    fi
    return 0
  fi

  # Both members of the pi family are Pi-routed: pi-signed shares pi's auth
  # record, so it gets the same provider probe and route hint. It does NOT
  # share pi's executable - pi-signed is an explicitly selected identity that
  # never falls back to pi (bin/fm-spawn.sh), so the PATH probe below still
  # resolves the entry's own harness name.
  E_PROVIDER=""
  case "$E_HARNESS" in
    pi|pi-signed) route="via pi"; pi_provider_of "$E_MODEL" ;;
  esac

  if ! harness_on_path "$E_HARNESS"; then
    P_NOTE="not installed - install $E_HARNESS"
    return 0
  fi

  if [ -n "$E_PROVIDER" ] && ! pi_provider_authed "$E_PROVIDER"; then
    P_NOTE="$route - sign in: pi /login"
    return 0
  fi

  P_STATUS=ok
  P_NOTE=$route
}

# --- menu render ------------------------------------------------------------

# entry_detail: sets E_DETAIL, the model/effort column, from the current
# entry_split fields. Renders only what is actually pinned - the literal word
# "default" is noise, not information - and shows a plain dash when the adapter
# decides everything.
E_DETAIL=""
entry_detail() {
  E_DETAIL=""
  [ "$E_MODEL" = default ] || E_DETAIL=${E_MODEL##*/}
  if [ "$E_EFFORT" != default ]; then
    [ -n "$E_DETAIL" ] && E_DETAIL="$E_DETAIL · $E_EFFORT" || E_DETAIL=$E_EFFORT
  fi
  [ -n "$E_DETAIL" ] || E_DETAIL="-"
}

# pad <var> <text> <width>: set <var> to <text> left-aligned to <width> COLUMNS.
# printf's %-Ns pads by BYTES, which misaligns every row whose detail carries a
# multi-byte separator, so the width is computed from bash's character count.
pad() {  # <var> <text> <width>
  local fill="" short=$(( $3 - ${#2} ))
  [ "$short" -gt 0 ] && printf -v fill '%*s' "$short" ''
  printf -v "$1" '%s%s' "$2" "$fill"
}

STATUSES=()
NOTES=()

probe_all() {
  local rec
  STATUSES=(); NOTES=()
  for rec in "${ENTRIES[@]}"; do
    entry_split "$rec"
    probe_entry
    STATUSES+=("$P_STATUS")
    NOTES+=("$P_NOTE")
  done
}

# default_index: the entry Enter takes. The last-used entry when it is still
# available, otherwise the first available entry, otherwise none (0). A stale or
# now-unavailable last-used entry must never become an Enter that cannot launch.
DEFAULT_INDEX=0
DEFAULT_MARK="← default"

resolve_default() {
  local last="" i
  DEFAULT_INDEX=0
  DEFAULT_MARK="← default"
  if [ -r "$LAST_USED" ]; then
    IFS=$' \t\n' read -r last < "$LAST_USED" || last=""
  fi
  if [ -n "$last" ]; then
    for i in "${!ENTRIES[@]}"; do
      entry_split "${ENTRIES[$i]}"
      if [ "$E_ID" = "$last" ] && [ "${STATUSES[$i]}" = ok ]; then
        DEFAULT_INDEX=$((i + 1))
        DEFAULT_MARK="← last"
        return 0
      fi
    done
  fi
  for i in "${!ENTRIES[@]}"; do
    if [ "${STATUSES[$i]}" = ok ]; then
      DEFAULT_INDEX=$((i + 1))
      return 0
    fi
  done
}

render_menu() {
  local i n note row padded_label padded_detail default_label=""
  printf '\n  Firstmate\n'
  printf '  %s\n\n' "$FM_LAUNCH_AUTONOMY_NOTICE"
  for i in "${!ENTRIES[@]}"; do
    n=$((i + 1))
    entry_split "${ENTRIES[$i]}"
    entry_detail
    [ "$n" -eq "$DEFAULT_INDEX" ] && default_label=$E_LABEL
    note=${NOTES[$i]}
    [ "$n" -eq "$DEFAULT_INDEX" ] && note=${note:+"$note   "}$DEFAULT_MARK
    pad padded_label "$E_LABEL" 18
    pad padded_detail "$E_DETAIL" 22
    row="  $n  $padded_label $padded_detail $note"
    # Trailing spaces are noise in a captured menu; strip them.
    row=${row%"${row##*[![:space:]]}"}
    if [ "${STATUSES[$i]}" = ok ]; then
      printf '%s\n' "$row"
    else
      printf '%s%s%s\n' "$DIM" "$row" "$RESET"
    fi
  done
  if [ "$DEFAULT_INDEX" -gt 0 ]; then
    printf '\n  ⏎ %s   1-%d select   q quit\n' "$default_label" "${#ENTRIES[@]}"
  else
    printf '\n  nothing is available yet   1-%d select   q quit\n' "${#ENTRIES[@]}"
  fi
}

# --- selection --------------------------------------------------------------
#
# One keypress selects AND launches; Enter takes the default; q quits clean.
#
# An invalid key redraws the prompt with an inline "?" and waits. That is a
# deliberate divergence from firstmate's refuse-don't-reprompt law, and only for
# a TTY: that law is right for a SCRIPTED selection, where a wrong value must
# fail loudly rather than be guessed, and wrong for a human who mistyped a key at
# their own front door. Determinism is preserved either way - the input alphabet
# is closed and the mapping is total; only the response to invalid input differs.
# Non-TTY stdin keeps the original behavior exactly: one line, no reprompt.

SELECTED=0

prompt_line() {  # <suffix>
  printf '\r\033[K› %s' "$1"
}

select_entry_tty() {
  local key n status
  while :; do
    prompt_line ""
    IFS= read -rsn1 key || { printf '\n'; exit 1; }
    case "$key" in
      q|Q) printf '\r\033[K'; exit 0 ;;
      '') n=$DEFAULT_INDEX ;;
      [0-9]) n=$key ;;
      *) prompt_line "?"; continue ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "${#ENTRIES[@]}" ]; then
      prompt_line "?"
      continue
    fi
    status=${STATUSES[$((n - 1))]}
    if [ "$status" != ok ]; then
      prompt_line "$n  ${NOTES[$((n - 1))]}"
      continue
    fi
    printf '\r\033[K› %s\n' "$n"
    SELECTED=$n
    return 0
  done
}

select_entry_pipe() {
  local line n
  IFS=$' \t\n' read -r line || line=""
  case "$line" in
    q|Q) exit 0 ;;
    # EOF and a blank line REFUSE here rather than taking the default. Enter
    # taking the default is a convenience for a human at a keyboard; for a
    # scripted caller the same silence would mean `fm-launch.sh < /dev/null`
    # starts a real unattended session nobody chose. A scripted selection must
    # be explicit - that is the refuse-don't-reprompt law this path preserves.
    '') refuse "No selection was made." "Choose 1-${#ENTRIES[@]}, or q to quit." ;;
    # A 0-prefixed number must refuse HERE: it would pass the decimal range
    # check below (`test` parses 08 as eight) and then reach $((n - 1)), where
    # bash parses the leading zero as octal and dies under set -eu instead of
    # refusing with guidance like every other invalid input.
    0[0-9]) refuse "'$line' is not one of the menu choices." "Choose 1-${#ENTRIES[@]}, or q to quit." ;;
    [0-9]|[0-9][0-9]) n=$line ;;
    *) refuse "'$line' is not one of the menu choices." "Choose 1-${#ENTRIES[@]}, or q to quit." ;;
  esac
  if [ "$n" -lt 1 ] || [ "$n" -gt "${#ENTRIES[@]}" ]; then
    refuse "There is no menu entry $n." "Choose 1-${#ENTRIES[@]}, or q to quit."
  fi
  if [ "${STATUSES[$((n - 1))]}" != ok ]; then
    entry_split "${ENTRIES[$((n - 1))]}"
    refuse "$E_LABEL is not available: ${NOTES[$((n - 1))]}."
  fi
  printf '› %s\n' "$n"
  SELECTED=$n
}

# --- launch -----------------------------------------------------------------

# remember_choice <id>: atomic temp + mv, so a launcher killed mid-write leaves
# the previous default intact rather than a truncated file.
remember_choice() {  # <id>
  local id=$1 tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp="$LAST_USED.tmp.$$"
  printf '%s\n' "$id" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$LAST_USED" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# The launch lock closes the reattach guard's startup window. Between this
# launcher's tab creation and the harness TUI registering as a herdr agent, the
# new primary's pane still reads no-agent, so an unlocked second launch would
# pass live_primary_pane and then have fm_backend_herdr_create_task replace the
# just-started tab as a husk, silently killing it. The lock - not any pane
# state - is what distinguishes "no agent YET, a launch is in flight" from "no
# agent because that session died": a dead session's launcher no longer holds
# it, so crash-husk replacement on the next launch stays intact. It is held
# from before the reattach check through the launch-line send and released on
# every exit path by the EXIT trap; attach() releases it explicitly because
# exec never reaches that trap. A killed launcher cannot wedge the home:
# fm_lock_try_acquire reclaims a lock whose recorded pid is dead.
LAUNCH_LOCK=""
LAUNCH_LOCK_HELD=0

launch_lock_release() {
  if [ "$LAUNCH_LOCK_HELD" = 1 ]; then
    LAUNCH_LOCK_HELD=0
    fm_lock_release "$LAUNCH_LOCK" || true
  fi
}
trap launch_lock_release EXIT

# herdr_gate: Herdr is MANDATORY and there is no silent fallback to a bare
# shell. Absence is this launcher's own condition and gets the front door's
# wording; every other verdict belongs to fm_backend_herdr_version_check, whose
# message carries the protocol numbers and is relayed rather than restated.
herdr_gate() {
  local out
  command -v herdr >/dev/null 2>&1 \
    || refuse "Herdr is required and was not found." \
              "Install it (https://herdr.dev), then relaunch."
  if ! out=$(fm_backend_herdr_version_check 2>&1); then
    refuse "Herdr is required and this one cannot be used." "${out#error: }"
  fi
}

# live_primary_pane: the pane of a primary already running in this home, or
# empty. Read-only, and skipped entirely when no herdr server is up - if nothing
# is running, nothing can be reattached to. Reattach is checked BEFORE any create
# so a second launch can never leave two primaries contending for this home's
# session lock. Returns non-zero when herdr stops answering mid-check; the
# caller must then FAIL CLOSED - proceeding would create a second primary in
# exactly the race this guard exists to prevent.
live_primary_pane() {  # <session>
  local session=$1 running wsid tab pane
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = true ] || return 0
  wsid=$(fm_backend_herdr_workspace_find "$session")
  [ -n "$wsid" ] || return 0
  tab=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null \
    | jq -r --arg want "$PRIMARY_TAB_LABEL" '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null | head -1)
  [ -n "$tab" ] || return 0
  pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab") || return 1
  [ -n "$pane" ] || return 0
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" = live ] || return 0
  printf '%s' "$pane"
}

# attach <session>: `herdr session attach <NAME>` is the verified attach form.
# Empirical, herdr 0.7.1: `herdr session --help` lists an `attach` subcommand
# ("Attach to a session"), and `herdr session attach --help` reports exactly
# `Usage: herdr session attach <NAME>` with a single required NAME argument.
# The exec replaces this process, so the EXIT trap can never run past it; the
# launch lock is released explicitly first.
attach() {  # <session>
  local session=$1
  if [ -n "${FM_LAUNCH_NO_ATTACH:-}" ]; then
    vlog "attach suppressed by FM_LAUNCH_NO_ATTACH"
    return 0
  fi
  launch_lock_release
  exec herdr session attach "$session"
}

# wait_for_prompt <target>: a bounded deadline poll for the pane's shell prompt,
# never a bare sleep. It gates on the SHELL, not on the agent, so the attach
# lands well before the model's first token. Exhaustion refuses with the attempt
# count and creates nothing further; it never proceeds hopefully.
wait_for_prompt() {  # <target>
  local target=$1 attempts=${FM_LAUNCH_READY_ATTEMPTS:-10} nap=${FM_LAUNCH_READY_SLEEP:-0.3} i out
  for i in $(seq 1 "$attempts"); do
    out=$(fm_backend_herdr_capture "$target" 5 2>/dev/null) || out=""
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      vlog "shell prompt ready after attempt $i"
      return 0
    fi
    sleep "$nap"
  done
  return 1
}

launch_entry() {  # <record>
  local rec=$1 session container seeded ids tab pane
  local template modelflag effortflag launch target
  entry_split "$rec"
  entry_detail

  printf '  %s · %s\n' "$E_LABEL" "$E_DETAIL"

  fm_backend_source herdr || refuse "The Herdr runtime could not be loaded." "Reinstall firstmate, then relaunch."
  # The lock primitives. Sourced here, after selection, because fm-wake-lib.sh
  # creates $STATE at source time and nothing may touch the home before a choice.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  herdr_gate
  session=$(fm_backend_herdr_session)

  LAUNCH_LOCK="$STATE/.launch.lock"
  fm_lock_try_acquire "$LAUNCH_LOCK" \
    || refuse "Another launch is already starting a session here." \
              "Wait for it to finish, then reattach or retry."
  LAUNCH_LOCK_HELD=1

  pane=$(live_primary_pane "$session") \
    || refuse "Herdr could not confirm whether a session is already running here." \
              "Retry, or run with --verbose."
  if [ -n "$pane" ]; then
    if [ "$TTY" -eq 1 ]; then
      printf '\n  A firstmate session is already running here.\n'
      printf '  r reattach   q quit '
      local key
      IFS= read -rsn1 key || key=q
      printf '\n'
      case "$key" in
        r|R|'') attach "$session"; return 0 ;;
        *) exit 0 ;;
      esac
    fi
    refuse "A firstmate session is already running here." \
           "Attach to it, or close it before starting another."
  fi

  template=$(launch_template "$E_HARNESS" primary) \
    || refuse "$E_LABEL cannot start a firstmate session." "Choose another entry."
  modelflag=$(model_flag_for_harness "$E_HARNESS" "$E_MODEL")
  effortflag=$(effort_flag_for_harness "$E_HARNESS" "$E_EFFORT")
  launch=${template//__MODELFLAG__/$modelflag}
  launch=${launch//__EFFORTFLAG__/$effortflag}
  # An unset flag placeholder leaves one trailing space (bin/fm-launch-lib.sh
  # header); cosmetic in a shell command, trimmed here.
  launch=${launch%"${launch##*[![:space:]]}"}
  # The pane's shell is a child of the herdr SERVER, which this launcher may
  # itself have started - so it can inherit this process's overrides. Clear them
  # and pin FM_HOME explicitly, the same shape bin/fm-spawn.sh uses to launch a
  # firstmate primary in a secondmate home.
  launch="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$(shell_quote "$FM_HOME") $launch"
  vlog "launch: $launch"

  fm_backend_herdr_server_ensure "$session" \
    || refuse "The Herdr server did not start." "Retry, or run with --verbose."
  container=$(fm_backend_herdr_container_ensure "$FM_HOME") \
    || refuse "The Herdr workspace for this home could not be prepared." "Retry, or run with --verbose."
  seeded=${container#*$'\t'}
  container=${container%%$'\t'*}
  ids=$(fm_backend_herdr_create_task "$container" "$PRIMARY_TAB_LABEL" "$FM_HOME" "$seeded") \
    || refuse "The firstmate session could not be created." "Retry, or run with --verbose."
  tab=${ids%% *}
  pane=${ids##* }
  target="$session:$pane"
  vlog "workspace=$container tab=$tab pane=$pane"

  wait_for_prompt "$target" \
    || refuse "The session did not start within ${FM_LAUNCH_READY_ATTEMPTS:-10} attempts." \
              "Retry, or run with --verbose."

  # One line, one round trip: `clear` wipes both the echoed command itself and
  # any shell banner in the fresh pane, and the agent starts in its place - so
  # the first thing on screen after the attach repaint is firstmate's greeting.
  fm_backend_herdr_send_literal "$target" "clear && $launch" \
    || refuse "The session could not be started in its pane." "Retry, or run with --verbose."
  fm_backend_herdr_send_key "$target" Enter \
    || refuse "The session could not be started in its pane." "Retry, or run with --verbose."

  remember_choice "$E_ID"
  fm_backend_herdr_cli "$session" tab focus "$tab" >/dev/null 2>&1 || true
  attach "$session"
}

# --- main -------------------------------------------------------------------

[ -d "$FM_HOME" ] \
  || refuse_at_door "No firstmate home at $FM_HOME." "Set FM_HOME, or finish setup, then relaunch."

# Sourcing fm-backend.sh here is a local file read - it touches no herdr
# socket, so the no-network, no-`herdr status` promises above hold. It is
# needed at the door because the launcher only ever starts a Herdr session:
# a home explicitly configured for another backend would get a primary that
# fm-send/fm-watch/fm-spawn cannot see and that the reattach guard cannot
# find, so the incoherence must refuse before the menu, not after a choice.
# Only the EXPLICIT setting (FM_BACKEND, then config/backend) is checked;
# auto-detection reflects the terminal this command runs in, not the home's
# configuration, and the session this launcher creates runs inside Herdr.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

BACKEND_CONFIGURED=$(fm_backend_configured_name)
if [ -n "$BACKEND_CONFIGURED" ] && [ "$BACKEND_CONFIGURED" != herdr ]; then
  if [ -n "${FM_BACKEND:-}" ]; then
    refuse_at_door "FM_BACKEND selects the $BACKEND_CONFIGURED backend, and this launcher only starts Herdr sessions." \
                   "Unset FM_BACKEND (or set it to herdr), then relaunch."
  fi
  refuse_at_door "This home's config/backend selects $BACKEND_CONFIGURED, and this launcher only starts Herdr sessions." \
                 "Set config/backend to herdr (or remove it), then relaunch."
fi

# shellcheck source=bin/fm-launch-lib.sh
. "$SCRIPT_DIR/fm-launch-lib.sh"

load_presets
probe_all
resolve_default
render_menu

[ "$PRINT_MENU" -eq 1 ] && exit 0

if [ "$TTY" -eq 1 ]; then
  select_entry_tty
else
  select_entry_pipe
fi

launch_entry "${ENTRIES[$((SELECTED - 1))]}"
