#!/usr/bin/env bash
# fm-secondmate-command.sh - move a persistent secondmate between FIRSTMATE
# command (the default) and CAPTAIN command, in both directions, and report
# which state each registered lane is in.
#
# The complete procedure - when to offer a transfer, what to tell the captain,
# how to reconcile a returning lane, and what happens to its queued work - is
# owned by the secondmate-command-transfer skill. This script owns only the
# mechanics and the guards, so a transfer is deterministic and idempotent rather
# than a remembered checklist.
#
# Usage:
#   fm-secondmate-command.sh status [<id>]
#   fm-secondmate-command.sh onramp <id>
#   fm-secondmate-command.sh offramp-request <id>
#   fm-secondmate-command.sh offramp-complete <id> --report <path>
#
# status            Print one COMMAND: line per registered secondmate (or just
#                   <id>), plus a CAPTAIN_COMMAND: summary line for every lane
#                   the captain holds. Exits 3 when a lane's authority and its
#                   home marker disagree, or either carries an unrecognized
#                   value.
# onramp            Firstmate command -> captain command. Runs every guard
#                   below, writes the lane's position record, then transfers.
#                   Already-captain is an idempotent success.
# offramp-request   Ask a captain-commanded lane for the position report the
#                   offramp requires, and record which report path is expected.
#                   Re-requesting reuses an open request's path so a report the
#                   lane is already writing is never orphaned; once that report
#                   exists, a new request asks for a fresh position instead.
# offramp-complete  Captain command -> firstmate command, refused until that
#                   exact report exists and postdates the request.
#
# Onramp guards. Every one is a stop-and-report refusal (exit 4); there is no
# override flag, because each names a state where a silent handover would strand
# a question, a decision, or a running pipeline between two authorities:
#   1. <id> is not a registered secondmate.
#   2. Its home does not validate as a seeded secondmate home.
#   3. Away mode is active - the captain is not present to command a lane.
#   4. Its recorded endpoint is confirmed absent - firstmate does not hand the
#      captain a lane that is not answering; recovery comes first.
#   5. A decision it opened on the parent status channel is still unresolved -
#      the question is addressed to firstmate but would become answerable only
#      by the captain, with no record of the switch.
#   6. A parent pending-reply expectation for it is still open - the same
#      stranding, from the other direction.
#   7. A task in its home is inside a live validation run (a current state
#      sourced from a run-step that has not reached done or failed). One run has
#      one decision authority for its whole length (see ask-user-authority);
#      transferring mid-run splits that authority across two.
#
# Partial-transfer safety: the step that REMOVES an authority always runs before
# the step that GRANTS one, so an interrupted transfer can leave a lane with no
# commander (inert, and reported by `status`) but never with two. Onramp writes
# the registry first; offramp writes the home marker first.
#
# Telling the running lane: both directions finish by sending the lane a
# re-read notice through the narrow FM_SECONDMATE_COMMAND_OPERATIONAL exemption
# in bin/fm-send.sh, because the charter only makes a lane read data/command.md
# at session start and a long-running agent would otherwise keep operating under
# the previous contract until it restarts. The notice asks for no reply, so the
# pending-reply expectation a marked send mints is retired immediately. The
# command record is the authority, so a notice that is not delivered never
# invalidates the transfer: it is reported as TRANSFERRED_NOT_NOTIFIED with exit
# 5, meaning correctly recorded but not yet re-read by the live agent.
#
# Environment: FM_HOME (required in effect), FM_DATA_OVERRIDE, FM_STATE_OVERRIDE.
# FM_SECONDMATE_COMMAND_CREW_STATE_BIN and FM_SECONDMATE_COMMAND_SEND_BIN
# override the current-state reader and the steer path for tests.
# Exit codes: 0 ok, 2 usage, 3 damaged or divergent record, 4 refusal,
# 5 transferred on the record but the live lane was not notified.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-command-lib.sh
. "$SCRIPT_DIR/fm-secondmate-command-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

CREW_STATE_BIN="${FM_SECONDMATE_COMMAND_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SEND_BIN="${FM_SECONDMATE_COMMAND_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

help_text() {
  sed -n '2,71p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

usage() {
  help_text >&2
  exit 2
}

refuse() {  # <message>
  echo "REFUSED: $1" >&2
  exit 4
}

damaged() {  # <message>
  echo "COMMAND_INVALID: $1" >&2
  exit 3
}

stamp_utc() { date -u '+%Y%m%dT%H%M%SZ'; }
iso_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }

file_mtime_epoch() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

# A path that does not exist yet, from a one-second-granularity stamp. Two
# transfers inside the same second are ordinary (a handback re-request, an
# offramp immediately followed by an onramp), and silently reusing one path
# would let a fresh record overwrite the one it is supposed to supersede.
unique_path() {  # <dir> <prefix> <suffix>
  local dir=$1 prefix=$2 suffix=$3 base candidate n=2
  base="$dir/$prefix-$(stamp_utc)"
  candidate="$base$suffix"
  while [ -e "$candidate" ] && [ "$n" -le 999 ]; do
    candidate="$base-$n$suffix"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# Every registered secondmate id, in registry order.
registry_ids() {
  [ -f "$REG" ] || return 0
  sed -n 's/^- \([A-Za-z0-9._-][A-Za-z0-9._-]*\)\([ ].*\)\{0,1\}$/\1/p' "$REG"
}

registry_line() {  # <id>
  [ -f "$REG" ] || return 0
  grep -E "^- $1( |$)" "$REG" 2>/dev/null | tail -1 || true
}

resolve_home() {  # <id>
  secondmate_registry_field "$REG" "$1" home 2>/dev/null || true
}

# Drop an existing "; command: <value>" segment from a registry line, keeping
# every other field and the closing paren exactly as written.
strip_command_field() {  # <line>
  local line=$1 head rest
  case "$line" in
    *'; command:'*) ;;
    *) printf '%s' "$line"; return 0 ;;
  esac
  head=${line%%'; command:'*}
  rest=${line#*'; command:'}
  case "$rest" in
    *';'*) rest=";${rest#*;}" ;;
    *')'*) rest=")${rest#*)}" ;;
    *) rest='' ;;
  esac
  printf '%s%s' "$head" "$rest"
}

# Rewrite <id>'s registry line so it records <token>, atomically. Refuses a line
# that does not end in the documented closing paren rather than mangling a
# registry it cannot parse.
write_registry_command() {  # <id> <token>
  local id=$1 token=$2 line base new tmp cur
  line=$(registry_line "$id")
  [ -n "$line" ] || return 1
  base=$(strip_command_field "$line")
  case "$base" in
    *')') ;;
    *) echo "error: registry line for $id does not end in ')'; refusing to rewrite it" >&2; return 1 ;;
  esac
  new="${base%)}; command: $token)"
  tmp="$REG.command.$$"
  : > "$tmp" || return 1
  while IFS= read -r cur || [ -n "$cur" ]; do
    if [ "$cur" = "$line" ]; then
      printf '%s\n' "$new" >> "$tmp"
    else
      printf '%s\n' "$cur" >> "$tmp"
    fi
  done < "$REG"
  mv -f "$tmp" "$REG" || { rm -f "$tmp"; return 1; }
  return 0
}

# Write the derived per-home marker: the copy the lane itself reads at session
# start. The registry stays the authority.
write_home_marker() {  # <home> <token> <position-pointer>
  local home=$1 token=$2 note=$3 marker tmp
  marker=$(fm_secondmate_command_marker_path "$home")
  mkdir -p "$(dirname "$marker")" 2>/dev/null || return 1
  tmp="$marker.tmp.$$"
  {
    printf '# Command state\n\n'
    printf 'command: %s\n' "$token"
    printf 'recorded: %s\n' "$(iso_utc)"
    printf 'position: %s\n\n' "$note"
    printf 'The primary firstmate writes this file; it is read-only here.\n'
    printf 'The authority is the command field on this lane in the primary home secondmate registry.\n'
    printf 'Never edit this file to change who commands this lane - a lane cannot transfer itself.\n'
    printf 'Under command: firstmate there is no captain in this pane: never address the captain, and route every report to the main firstmate.\n'
    printf 'Under command: captain the captain reads this pane himself: address him directly, and do not wait on the main firstmate for decisions that are now his.\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  return 0
}

# --- status -----------------------------------------------------------------

cmd_status() {  # [<id>]
  local want=${1:-} id home reg_state marker_state rc found=0 bad=0
  for id in $(registry_ids); do
    [ -z "$want" ] || [ "$want" = "$id" ] || continue
    found=1
    home=$(resolve_home "$id")
    rc=0
    reg_state=$(fm_secondmate_command_state "$id" "$REG") || rc=$?
    [ "$rc" -eq 0 ] || bad=1
    [ -n "$reg_state" ] || reg_state=unreadable
    if [ -z "$home" ]; then
      marker_state=unknown
    else
      rc=0
      marker_state=$(fm_secondmate_command_marker_state "$home") || rc=$?
      if [ "$rc" -eq 1 ]; then
        marker_state=absent
      fi
      [ -n "$marker_state" ] || marker_state=invalid
    fi
    printf 'COMMAND: %s command=%s marker=%s home=%s\n' "$id" "$reg_state" "$marker_state" "${home:-unknown}"
    if [ "$reg_state" = captain ]; then
      printf 'CAPTAIN_COMMAND: %s is under captain command; firstmate does not steer it, route work into it, or retire it.\n' "$id"
    fi
    if ! marker_agrees "$reg_state" "$marker_state"; then
      bad=1
      printf 'COMMAND_DIVERGENCE: %s registry=%s marker=%s - the registry is authoritative; reconcile before acting on this lane.\n' \
        "$id" "$reg_state" "$marker_state"
    fi
  done
  if [ -n "$want" ] && [ "$found" -eq 0 ]; then
    refuse "$want is not a registered secondmate in $REG"
  fi
  [ "$bad" -eq 0 ] || exit 3
  return 0
}

# An absent marker agrees with firstmate command: every lane seeded before
# command transfer existed has no marker, and that is the ordinary state. An
# unresolvable home cannot be compared, so it is not reported as divergence.
marker_agrees() {  # <registry-state> <marker-state>
  case "$2" in
    unknown) return 0 ;;
    absent) [ "$1" = firstmate ] ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

# --- shared preflight -------------------------------------------------------

require_registered() {  # <id>
  [ -f "$REG" ] || refuse "no secondmate registry at $REG"
  [ -n "$(registry_line "$1")" ] || refuse "$1 is not a registered secondmate in $REG"
}

# Sets VALIDATED_LANE_HOME. Calls refuse directly (never inside a command
# substitution) so a refusal exits the script rather than a subshell.
VALIDATED_LANE_HOME=""
require_valid_home() {  # <id>
  local id=$1 home
  home=$(resolve_home "$id")
  [ -n "$home" ] || refuse "$id has no home: field in $REG"
  validate_secondmate_home "$id" "$home" || refuse "$id home '$home' does not validate: $VALIDATION_ERROR"
  VALIDATED_LANE_HOME="$VALIDATED_HOME"
}

# Echoes "backend=<b> window=<w> agent=<state>"; returns 1 only on CONFIRMED
# absence. An unreadable or unverified probe is not proof, so it does not refuse.
endpoint_note() {  # <id>
  local id=$1 meta window backend target agent
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    printf 'backend=unknown window=none agent=no-record'
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  if [ -z "$window" ]; then
    printf 'backend=%s window=none agent=no-window' "$backend"
    return 1
  fi
  agent=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent=unreadable
  printf 'backend=%s window=%s agent=%s' "$backend" "$window" "$agent"
  case "$agent" in
    dead|missing) return 1 ;;
  esac
  return 0
}

# Deliver one infrastructure message to <id> through the exempted steer path.
#
# A marked secondmate send always creates a durable pending-reply expectation,
# but a command-state notice asks for no reply, so the expectation it minted is
# retired immediately. Left open it would be indistinguishable from a stranded
# question: the watcher would chase it, and onramp guard 6 would refuse the next
# transfer forever over an artifact the transfer machinery created itself.
# Returns non-zero when delivery was not confirmed.
send_operational_notice() {  # <id> <message>
  local id=$1 msg=$2 before after corr rc=0
  before=$(open_pending_replies_for "$id")
  FM_SECONDMATE_COMMAND_OPERATIONAL="$id" "$SEND_BIN" "$id" "$msg" >/dev/null 2>&1 || rc=$?
  after=$(open_pending_replies_for "$id")
  for corr in $after; do
    case " $before " in *" $corr "*) continue ;; esac
    fm_pending_reply_retire_unanswered "$STATE" "$corr" notice || true
  done
  return "$rc"
}

# Tell the live lane its command state just changed, so a long-running agent
# switches contract now instead of at its next session start. The command record
# is the authority and is already written when this runs, so a failed nudge is
# reported as "correctly recorded, not yet re-read" - never as a lane that
# already knows.
COMMAND_NUDGE_MESSAGE_PREFIX='Your command state changed - re-read data/command.md in your own home now and follow it from this message on'
command_nudge_message() {  # <token>
  case "$1" in
    captain)
      printf '%s: the captain now commands this lane, so address him directly in this pane and stop routing your reports through the main firstmate.' \
        "$COMMAND_NUDGE_MESSAGE_PREFIX"
      ;;
    *)
      printf '%s: the main firstmate commands this lane again, so never address the captain from this pane and route every report back through the main firstmate.' \
        "$COMMAND_NUDGE_MESSAGE_PREFIX"
      ;;
  esac
}

# Open parent pending-reply expectations for <id>: created and not yet resolved.
open_pending_replies_for() {  # <id>
  local id=$1 dir rec task resolved
  dir=$(fm_pending_reply_dir "$STATE")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "${rec##*/}" in .*) continue ;; esac
    task=$(fm_pending_reply_get "$rec" task_id)
    [ "$task" = "$id" ] || continue
    resolved=$(fm_pending_reply_get "$rec" resolved_epoch)
    [ -z "$resolved" ] || continue
    printf '%s\n' "${rec##*/}"
  done
  return 0
}

# One line per task in the lane's own home whose CURRENT state is a live
# validation run: a run-step-sourced state that has not reached done or failed.
# bin/fm-crew-state.sh owns that reconciliation; this only reads its verdict.
live_validation_runs_in() {  # <home>
  local home=$1 meta cid line state src
  [ -d "$home/state" ] || return 0
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    cid=$(basename "$meta" .meta)
    line=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$home/state" \
      "$CREW_STATE_BIN" "$cid" 2>/dev/null) || continue
    case "$line" in state:*) ;; *) continue ;; esac
    state=${line#state: }; state=${state%% *}
    src=${line#*source: }; src=${src%% *}
    [ "$src" = run-step ] || continue
    case "$state" in done|failed) continue ;; esac
    printf '%s\t%s\n' "$cid" "$line"
  done
  return 0
}

# --- onramp -----------------------------------------------------------------

write_position_record() {  # <id> <home> <endpoint-note>; echoes the record path
  local id=$1 home=$2 endpoint=$3 record dir meta cid line
  dir="$DATA/$id"
  mkdir -p "$dir"
  record=$(unique_path "$dir" command-position .md)
  {
    printf '# Command position record - %s\n\n' "$id"
    printf 'Recorded %s, at the transfer from firstmate command to captain command.\n' "$(iso_utc)"
    printf 'This is the lane position the captain inherits, written down rather than reconstructed.\n\n'
    printf '## Registry line\n\n    %s\n\n' "$(registry_line "$id")"
    printf '## Home\n\n    %s\n\n' "$home"
    printf '## Endpoint\n\n    %s\n\n' "$endpoint"
    printf '## Parent status events (last 20)\n\n'
    if [ -f "$STATE/$id.status" ]; then
      tail -20 "$STATE/$id.status" | sed 's/^/    /'
    else
      printf '    (no status file)\n'
    fi
    printf '\n## Open decisions on the parent channel\n\n'
    printf '    none - the onramp refuses while any is open\n\n'
    printf '## Work under way in the lane home\n\n'
    if [ -d "$home/state" ]; then
      for meta in "$home"/state/*.meta; do
        [ -f "$meta" ] || continue
        cid=$(basename "$meta" .meta)
        printf '### %s\n\n' "$cid"
        sed 's/^/    /' "$meta"
        line=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$home/state" \
          "$CREW_STATE_BIN" "$cid" 2>/dev/null) || line='(current state unreadable)'
        printf '\n    current state: %s\n\n' "$line"
      done
    fi
    printf '## Lane backlog headers\n\n'
    if [ -f "$home/data/backlog.md" ]; then
      grep -E '^(#|- \[)' "$home/data/backlog.md" | sed 's/^/    /' || true
    else
      printf '    ABSENT\n'
    fi
  } > "$record"
  printf '%s' "$record"
}

cmd_onramp() {  # <id>
  local id=$1 state rc home endpoint open pending runs record
  require_registered "$id"
  rc=0
  state=$(fm_secondmate_command_state "$id" "$REG") || rc=$?
  [ "$rc" -ne 2 ] || damaged "$id carries an unrecognized command value in $REG; repair the registry line before transferring"
  if [ "$state" = captain ]; then
    echo "ALREADY: $id is already under captain command"
    return 0
  fi
  require_valid_home "$id"
  home=$VALIDATED_LANE_HOME
  [ ! -e "$STATE/.afk" ] || refuse "away mode is active; a lane cannot be handed to a captain who is not present"

  endpoint=$(endpoint_note "$id") \
    || refuse "$id endpoint is confirmed absent ($endpoint); recover the lane before handing it over"

  open=$(status_open_decisions "$STATE/$id.status")
  [ -z "$open" ] \
    || refuse "$id has an unresolved decision on the parent channel: $(printf '%s' "$open" | cut -f1,2 | tr '\n' ' '); resolve it before transferring"

  pending=$(open_pending_replies_for "$id")
  [ -z "$pending" ] \
    || refuse "$id has an open request from firstmate still awaiting its answer ($(printf '%s' "$pending" | tr '\n' ' ')); close it before transferring"

  runs=$(live_validation_runs_in "$home")
  [ -z "$runs" ] \
    || refuse "$id has a live validation run: $(printf '%s' "$runs" | cut -f1 | tr '\n' ' '); one run has one decision authority for its whole length"

  record=$(write_position_record "$id" "$home" "$endpoint")

  # Remove firstmate's authority before granting the captain's, so an interrupted
  # transfer can never leave two commanders.
  write_registry_command "$id" captain || refuse "could not record captain command for $id in $REG"
  if ! write_home_marker "$home" captain "$record"; then
    printf 'COMMAND_DIVERGENCE: %s registry=captain marker=unwritten - firstmate has stopped commanding this lane, but the lane has not been told. Repair %s before the captain uses it.\n' \
      "$id" "$(fm_secondmate_command_marker_path "$home")" >&2
    exit 3
  fi
  if send_operational_notice "$id" "$(command_nudge_message captain)"; then
    printf 'TRANSFERRED: %s firstmate -> captain (position: %s)\n' "$id" "$record"
    return 0
  fi
  printf 'TRANSFERRED_NOT_NOTIFIED: %s firstmate -> captain (position: %s) - the transfer is recorded and firstmate has stopped commanding this lane, but the running agent was not told and still believes it is under firstmate command until it re-reads %s. Deliver the notice, or restart the lane, before the captain relies on this pane.\n' \
    "$id" "$record" "$(fm_secondmate_command_marker_path "$home")" >&2
  return 5
}

# --- offramp ----------------------------------------------------------------

handback_record_path() { printf '%s/%s.command-handback' "$STATE" "$1"; }

cmd_offramp_request() {  # <id>
  local id=$1 home report rec msg prior
  require_registered "$id"
  fm_secondmate_command_is_captain "$id" "$REG" \
    || refuse "$id is not under captain command; there is nothing to hand back"
  require_valid_home "$id"
  home=$VALIDATED_LANE_HOME
  rec=$(handback_record_path "$id")
  mkdir -p "$STATE"
  # Re-requesting while an answer is still outstanding must not move the target:
  # a second request that minted a fresh path would orphan a report the lane was
  # already writing to the first one. Reuse the open request until it is answered;
  # once the report exists, a new request deliberately asks for a fresh position.
  prior=""
  if [ -f "$rec" ]; then
    prior=$(sed -n 's/^report=//p' "$rec" | tail -1)
    [ -n "$prior" ] && [ ! -e "$prior" ] || prior=""
  fi
  if [ -n "$prior" ]; then
    report="$prior"
  else
    report=$(unique_path "$home/data" command-handback .md)
    {
      printf 'requested_epoch=%s\n' "$(now_epoch)"
      printf 'requested_iso=%s\n' "$(iso_utc)"
      printf 'report=%s\n' "$report"
    } > "$rec"
  fi
  msg="Command handback requested: write your full position report to $report - what changed under captain command, what is under way, what is unresolved, and anything the main firstmate must know before it resumes supervising you - then append a status line pointing at that file."
  if FM_SECONDMATE_COMMAND_OPERATIONAL="$id" "$SEND_BIN" "$id" "$msg" >/dev/null 2>&1; then
    printf 'HANDBACK_REQUESTED: %s report=%s\n' "$id" "$report"
    return 0
  fi
  printf 'HANDBACK_REQUEST_UNDELIVERED: %s report=%s - the request is on record but delivery was not confirmed; deliver it before completing the handback.\n' \
    "$id" "$report" >&2
  exit 4
}

cmd_offramp_complete() {  # <id> <report-path>
  local id=$1 report=$2 rec expected requested mtime home corr
  require_registered "$id"
  fm_secondmate_command_is_captain "$id" "$REG" \
    || refuse "$id is not under captain command; there is nothing to hand back"
  rec=$(handback_record_path "$id")
  [ -f "$rec" ] \
    || refuse "no handback request on record for $id; run offramp-request first so the lane reports its own position"
  expected=$(sed -n 's/^report=//p' "$rec" | tail -1)
  requested=$(sed -n 's/^requested_epoch=//p' "$rec" | tail -1)
  [ "$report" = "$expected" ] \
    || refuse "the position report must be the one this lane was asked for ($expected), not $report"
  [ -s "$report" ] \
    || refuse "the position report at $report is missing or empty; firstmate does not resume supervising a lane whose position it has not read"
  mtime=$(file_mtime_epoch "$report")
  [ -n "$mtime" ] || refuse "cannot read the modification time of $report"
  [ "$mtime" -ge "${requested:-0}" ] \
    || refuse "the position report at $report predates the handback request; it describes the lane before the captain finished with it"

  require_valid_home "$id"
  home=$VALIDATED_LANE_HOME
  # Remove the captain's channel before restoring firstmate's authority.
  write_home_marker "$home" firstmate "$report" \
    || refuse "could not tell $id it is back under firstmate command"
  if ! write_registry_command "$id" firstmate; then
    printf 'COMMAND_DIVERGENCE: %s registry=captain marker=firstmate - the lane has stopped addressing the captain but firstmate has not resumed command. Repair %s.\n' \
      "$id" "$REG" >&2
    exit 3
  fi
  rm -f "$rec"
  # The position report IS the answer to the handback request, delivered as a
  # document rather than on the status channel. Close that expectation here:
  # left open it would keep the watcher chasing an answered question and would
  # permanently refuse the next onramp at guard 6.
  for corr in $(open_pending_replies_for "$id"); do
    fm_pending_reply_retire_unanswered "$STATE" "$corr" document || true
  done
  if send_operational_notice "$id" "$(command_nudge_message firstmate)"; then
    printf 'TRANSFERRED: %s captain -> firstmate (position report: %s)\n' "$id" "$report"
    return 0
  fi
  printf 'TRANSFERRED_NOT_NOTIFIED: %s captain -> firstmate (position report: %s) - firstmate commands this lane again on the record, but the running agent was not told and still believes the captain reads this pane until it re-reads %s. Deliver the notice, or restart the lane, before steering it.\n' \
    "$id" "$report" "$(fm_secondmate_command_marker_path "$home")" >&2
  return 5
}

# --- dispatch ---------------------------------------------------------------

[ $# -ge 1 ] || usage
SUB=$1
shift

case "$SUB" in
  status)
    [ $# -le 1 ] || usage
    cmd_status "${1:-}"
    ;;
  onramp)
    [ $# -eq 1 ] || usage
    cmd_onramp "$1"
    ;;
  offramp-request)
    [ $# -eq 1 ] || usage
    cmd_offramp_request "$1"
    ;;
  offramp-complete)
    [ $# -eq 3 ] || usage
    [ "$2" = --report ] || usage
    cmd_offramp_complete "$1" "$3"
    ;;
  -h|--help|help)
    help_text
    ;;
  *)
    usage
    ;;
esac
