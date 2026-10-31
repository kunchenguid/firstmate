#!/usr/bin/env bash
# fm-progress-sweep.sh - which of this home's backlog items are orphaned.
#
# Every backlog item that should be progressing - In flight, or Queued and
# dispatchable now - must at every moment carry exactly one typed reason it is
# not progressing. An item with none is an orphan, and firstmate must act on it.
# This command is the single owner of that predicate: the watcher's heartbeat
# (bin/fm-watch.sh) turns each orphan into a `check: progress-orphan` wake, and
# the turn-end guard (bin/fm-turnend-guard.sh) refuses to let a primary turn
# end idle while one exists.
#
# It is a pure read of structured state only, and never parses prose:
#   - this home's backlog rows, through bin/fm-tasks-axi.sh `list` and `ready`
#     (state, kind, repo, blocked, held, hold_kind - never a title or body);
#   - state/<id>.meta (kind, yolo, remote_host, the recorded endpoint);
#   - the current-state verb from bin/fm-crew-state.sh (FM_CREW_STATE_BIN
#     overrides it, as for bin/fm-classify-lib.sh);
#   - the status-log folds bin/fm-classify-lib.sh owns (the declared-wait line
#     and the latest event's verb);
#   - captain holds, which are backlog holds of kind captain;
#   - the project-capacity declaration (bin/fm-project-capacity-lib.sh), the
#     away-posture spend cap (bin/fm-afk-contract.sh), and, only when
#     config/lane-capacity exists, the lane count and host headroom from
#     bin/fm-capacity.sh's plain report. That report never reads the
#     quota-provider perspective, so the sweep makes no network call;
#   - file modification times of the status log, task record, and steering
#     inbox, which bound the grace window.
# It writes nothing.
#
# Typed reasons an In-flight row is progressing, checked in this order:
#   blocked-by      an open blocked-by edge on an open item
#   hold-<kind>     an active backlog hold (hold-captain for a captain hold;
#                   plain hold for a dated hold with no kind)
#   paused          the status log's current declared paused: wait
#   captain-held    the status log's verified captain-held transfer
#   grace           under FM_PROGRESS_GRACE_SECS (default 600) since the newest
#                   of the status log, the task record, or a steering-inbox
#                   message - so a just-answered worker has time to restart
#   working         bin/fm-crew-state.sh reports the worker working from a
#                   run step or the pane (never from the status log alone)
#   paused          bin/fm-crew-state.sh reports a paused run step or pane
#   idle-watched    a live, idle worker whose latest event is not terminal;
#                   stale-pane supervision in bin/fm-watch.sh owns that one
# Orphan reasons for an In-flight row, past every typed reason above:
#   no-task-record  the backlog says In flight but state/<id>.meta is absent
#   worker-dead     the recorded endpoint is gone, or none is recorded
#                   (worker-dead-after-done when its latest event is done:
#                   finished work nobody has landed)
#   ready-to-land   the finished work is within firstmate's merge authority
#                   (the task record says yolo=on)
#   finished-needs-landing-call
#                   finished work whose landing needs the captain's word
#   terminal-<verb> the worker is idle on a done, blocked, needs-decision, or
#                   failed event that nobody answered within the grace window
# A Queued row that `tasks-axi ready` lists (unblocked, unheld, no active date
# gate) is progressing only while capacity is genuinely full:
#   away-capacity-full     the away-posture spend cap is reached
#   lane-capacity-full     bin/fm-capacity.sh reports free_lanes=0: the
#                          config/lane-capacity cap is reached or a host
#                          headroom constraint holds
#   project-capacity-full  the project's declared capacity is reached
# otherwise it is the orphan queued-ready. A capacity read that fails or
# cannot be determined never counts as full.
#
# Rows owned by secondmate homes are out of scope: only this home's backlog is
# read, and a row or task record of kind secondmate, or a task record naming a
# remote_host, is skipped. A teardown or merge refusal is never an orphan to
# clear by force; the guard and wake text say so, and the clearing action for
# it is a captain hold.
#
# Home resolution: FM_STATE_OVERRIDE, else $FM_HOME/state. The data and config
# directories are FM_DATA_OVERRIDE and FM_CONFIG_OVERRIDE, else the state
# directory's siblings, so a caller that names only a state directory never
# reads another home's backlog. A home with no data directory, or whose
# config/backlog-backend selects manual editing, has no structured rows.
#
# Usage: fm-progress-sweep.sh [--all]
# Output: one TAB-separated line per row, `orphan<TAB><id><TAB><reason>`; with
# --all, progressing rows are also printed as `progressing<TAB><id><TAB><reason>`.
# Exit 0 when the sweep completed (orphans or not), 1 when a structured source
# could not be read (the reason is on stderr), 2 on bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOME_DIR=$(dirname "$STATE")
DATA="${FM_DATA_OVERRIDE:-$HOME_DIR/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$HOME_DIR/projects}"
GRACE=${FM_PROGRESS_GRACE_SECS:-600}
case "$GRACE" in ''|*[!0-9]*) GRACE=600 ;; esac
ALL=0

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'usage: %s [--all]\n' "$(basename "$0")" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

emit() {  # <orphan|progressing> <id> <reason>
  [ "$1" = orphan ] || [ "$ALL" -eq 1 ] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# Seconds since the newest grace anchor: the status log, the task record, or
# any steering-inbox message (pending or handled). 999999 when none exists.
newest_anchor_age() {  # <id>
  local id=$1 path age best=999999
  for path in "$STATE/$id.status" "$STATE/$id.meta" "$STATE/$id.inbox"/*.msg "$STATE/$id.inbox"/handled/*.msg; do
    [ -e "$path" ] || continue
    age=$(fm_path_age "$path")
    [ "$age" -lt "$best" ] && best=$age
  done
  printf '%s\n' "$best"
}

# The current-state verb from bin/fm-crew-state.sh, or unknown. Only the
# leading `state: <verb> · source: <source>` tokens are read; the detail prose
# never is. working and paused count only from a live source (run-step or
# pane): a status-log working or paused is the last event, not the current
# state.
crew_state_verb() {  # <id>
  local line verb src
  line=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 "${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}" "$1" 2>/dev/null) || true
  case "$line" in state:\ *) ;; *) printf 'unknown\n'; return ;; esac
  verb=${line#state: }; verb=${verb%% *}
  src=${line#* · source: }; src=${src%% *}
  case "$verb:$src" in
    working:run-step|working:pane|paused:run-step|paused:pane) printf '%s\n' "$verb" ;;
    working:*|paused:*) printf 'unknown\n' ;;
    parked:*|done:*|blocked:*|failed:*|unknown:*) printf '%s\n' "$verb" ;;
    *) printf 'unknown\n' ;;
  esac
}

endpoint_alive() {  # <meta>
  local meta=$1 backend target id
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  id=$(basename "$meta" .meta)
  fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1
}

# Read the rows of the one tasks-axi table labelled <label>; any other table in
# the listing (such as `ready`'s never-dispatchable ready_public_followups) is
# skipped. Prints `<id>\t<kind>\t<repo>\t<tail...>` where <tail> is the last
# <n> comma-separated fields; the title in between is never read.
listing_rows() {  # <label> <tail-field-count>
  awk -v label="$1" -v n="$2" '
    index($0, label "[") == 1 { inrows = 1; next }
    inrows && /^  [^ ]/ {
      line = substr($0, 3)
      c = split(line, f, ",")
      if (c < 4 + n) next
      gsub(/"/, "", f[1]); gsub(/"/, "", f[3]); gsub(/"/, "", f[4])
      out = f[1] "\t" f[3] "\t" f[4]
      for (i = c - n + 1; i <= c; i++) { v = f[i]; gsub(/"/, "", v); out = out "\t" v }
      print out
      next
    }
    { inrows = 0 }
  '
}

tasks_axi() {
  FM_DATA_OVERRIDE="$DATA" FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"
}

[ -d "$DATA" ] || exit 0
fm_backlog_backend_manual "$CONFIG" && exit 0

if ! inflight_out=$(tasks_axi list --state in_flight --fields blocked,held,hold_kind --limit 100000 2>&1); then
  printf 'fm-progress-sweep: cannot read In-flight backlog rows: %s\n' "$(printf '%s\n' "$inflight_out" | sed -n '1p')" >&2
  exit 1
fi
if ! ready_out=$(tasks_axi ready 2>&1); then
  printf 'fm-progress-sweep: cannot read dispatchable Queued rows: %s\n' "$(printf '%s\n' "$ready_out" | sed -n '1p')" >&2
  exit 1
fi

# --- In flight ----------------------------------------------------------------
while IFS=$'\t' read -r id kind _repo blocked held hold_kind; do
  [ -n "$id" ] || continue
  [ "$kind" != secondmate ] || continue
  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  fi
  if [ "$blocked" = yes ]; then emit progressing "$id" blocked-by; continue; fi
  if [ "$held" = yes ]; then
    case "$hold_kind" in ''|-) emit progressing "$id" hold ;; *) emit progressing "$id" "hold-$hold_kind" ;; esac
    continue
  fi
  wait_line=$(status_declared_wait_line "$STATE/$id.status")
  if status_is_captain_held "$wait_line"; then emit progressing "$id" captain-held; continue; fi
  if status_is_paused "$wait_line"; then emit progressing "$id" paused; continue; fi
  if [ "$(newest_anchor_age "$id")" -lt "$GRACE" ]; then emit progressing "$id" grace; continue; fi
  if [ ! -f "$meta" ]; then emit orphan "$id" no-task-record; continue; fi
  verb=$(crew_state_verb "$id")
  case "$verb" in
    working) emit progressing "$id" working; continue ;;
    paused) emit progressing "$id" paused; continue ;;
  esac
  last=$(last_status_line "$STATE/$id.status")
  if ! endpoint_alive "$meta"; then
    if [ "$(status_line_verb "$last")" = "done" ]; then
      emit orphan "$id" worker-dead-after-done
    else
      emit orphan "$id" worker-dead
    fi
    continue
  fi
  if [ "$verb" = "done" ]; then
    if [ "$(fm_meta_get "$meta" yolo)" = on ]; then
      emit orphan "$id" ready-to-land
    else
      emit orphan "$id" finished-needs-landing-call
    fi
    continue
  fi
  if status_is_terminal_verb "$last"; then
    emit orphan "$id" "terminal-$(status_line_verb "$last")"
    continue
  fi
  emit progressing "$id" idle-watched
done < <(printf '%s\n' "$inflight_out" | listing_rows tasks 3)

# --- Queued and dispatchable now ------------------------------------------------
away_full=0
if [ -f "$STATE/.afk-contract" ] \
  && FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1 \
  && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = away ]; then
  cap=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" field spend_max_concurrent_workers 2>/dev/null || true)
  live=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" live-workers 2>/dev/null || true)
  case "$cap:$live" in
    *[!0-9:]*|:*|*:) ;;
    *) [ "$cap" -gt 0 ] && [ "$live" -ge "$cap" ] && away_full=1 ;;
  esac
fi

lane_full=0
if [ -e "$CONFIG/lane-capacity" ] \
  && cap_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" "$SCRIPT_DIR/fm-capacity.sh" 2>/dev/null); then
  case "${cap_out%%$'\n'*}" in "capacity: free_lanes=0 "*) lane_full=1 ;; esac
fi

# 0 when <repo>'s declared machine capacity is reached. An undeclared,
# unreadable, or unmatched declaration is not "full": an unreadable one refuses
# every spawn, which firstmate must hear about rather than have masked here.
project_full() {  # <repo>
  local repo=$1 cfg dir lock
  [ -n "$repo" ] && [ "$repo" != - ] || return 1
  cfg=$(fm_project_capacity_config_dir "$HOME_DIR" "$CONFIG" 2>/dev/null) || return 1
  fm_project_capacity_lookup "$cfg" "$repo" || return 1
  [ -n "$FM_PROJECT_CAPACITY" ] || return 1
  dir="$PROJECTS/$repo"
  [ -d "$dir" ] || return 1
  dir=$(CDPATH='' cd -- "$dir" && pwd -P) || return 1
  lock=$(fm_treehouse_project_lock_path "$dir" 2>/dev/null) || return 1
  fm_project_capacity_occupants "$lock" "$dir" "$STATE" "" || return 1
  [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -ge "$FM_PROJECT_CAPACITY" ]
}

while IFS=$'\t' read -r id kind repo _title; do
  [ -n "$id" ] || continue
  [ "$kind" != secondmate ] || continue
  if [ "$away_full" -eq 1 ]; then emit progressing "$id" away-capacity-full; continue; fi
  if [ "$lane_full" -eq 1 ]; then emit progressing "$id" lane-capacity-full; continue; fi
  if project_full "$repo"; then emit progressing "$id" project-capacity-full; continue; fi
  emit orphan "$id" queued-ready
done < <(printf '%s\n' "$ready_out" | listing_rows ready 1)

exit 0
