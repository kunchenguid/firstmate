#!/usr/bin/env bash
# Usage: fm-goal-push.sh run [--dry-run] | tick |
#        eligible <goal>/<item> <task> [--launch <project-dir> <mode> <yolo> <prefix>]
# config/goal-push: shadow (default, logs dispatch/mark proposals) or enforce.
# The watcher calls tick: run every 120s or on a goal/mark, landing, status,
# or cockpit truth change. tick also wakes on reached, uncovered captain
# steps in both modes and stores its scheduling cursor in watcher state.
# eligible is the read-only final guard for goal-originated dispatch and replay.
# The owner home drafts up to three missing local briefs per driven goal per
# pass in enforce; shadow only logs proposals. fm-goal-brief-lib.sh owns draft lint.
# FM_GOAL_PUSH_CAPACITY replaces fm-capacity.sh for lab tests only.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-goal.sh
. "$SCRIPT_DIR/fm-goal.sh"
export FM_HOME="$FM_GOAL_HOME" FM_STATE_OVERRIDE="$FM_GOAL_STATE"
export FM_CONFIG_OVERRIDE="$FM_GOAL_CONFIG" FM_DATA_OVERRIDE="$FM_GOAL_DATA"
STATE=$FM_GOAL_STATE
LOG="$STATE/goal-push.log"
LOCK="$STATE/.goal-push.lock"
CAPACITY=${FM_GOAL_PUSH_CAPACITY:-$SCRIPT_DIR/fm-capacity.sh}
AUTO="$SCRIPT_DIR/fm-auto-dispatch.sh"
ADMISSION="$SCRIPT_DIR/fm-admission-queue.sh"

mode() {
  local value=''
  if [ -f "$FM_GOAL_CONFIG/goal-push" ] && [ ! -L "$FM_GOAL_CONFIG/goal-push" ]; then
    read -r value < "$FM_GOAL_CONFIG/goal-push" || true
  fi
  case "$value" in enforce) printf enforce ;; *) printf shadow ;; esac
}

load_goal() {
  _fm_goal_open_record "$1" "$FM_GOAL_VIEW_STATE" >/dev/null 2>&1 &&
    [ "$FM_GOAL_REC_DRIVE" = driven ] &&
    fm_goal_fold "$1" "$FM_GOAL_VIEW_STATE" "$FM_GOAL_VIEW_DATA" "$(date +%s)"
}

owned() {
  [ "${FM_GOAL_ITEMS_OWNERS[$1]}" = "${FM_GOAL_VIEW_OWNER:-main}" ]
}

startable() {
  owned "$1" && [ "${FM_GOAL_ITEMS_CLASSES[$1]}" = drive ] &&
    _fm_goal_item_startable "$1" "$STATE" "$FM_GOAL_DATA"
}

load_eligible() {
  local binding=$1 task=$2 goal=${1%%/*} item=${1#*/} links
  [ "$goal/$item" = "$binding" ] && fm_goal_id_valid "$goal" && fm_goal_id_valid "$item" || return 1
  [ "$(mode)" = enforce ] && _fm_goal_owner_read_view && load_goal "$goal" || return 1
  ELIGIBLE_INDEX=$(_fm_goal_index_of "$item") || return 1
  [ -n "$task" ] && [ "${FM_GOAL_ITEMS_TASKS[$ELIGIBLE_INDEX]}" = "$task" ] && startable "$ELIGIBLE_INDEX" || return 1
  links=$("$SCRIPT_DIR/fm-goal.sh" launch-links "$task") || return 1
  ! grep -Fqx -- "$task"$'\toff' <<< "$links"
}

eligible() {
  local binding=$1 task=$2 launch=${3:-} remaining brief="$FM_GOAL_DATA/$2/brief.md"
  if [ "$launch" = --launch ]; then
    remaining=$(headroom) && [ "$remaining" -gt 0 ] || return 1
  fi
  load_eligible "$binding" "$task" || return 1
  [ ! -L "$FM_GOAL_DATA" ] && [ ! -L "${brief%/*}" ] && [ ! -L "$brief" ] && [ -f "$brief" ] && [ -r "$brief" ] || return 1
  if [ -n "${FM_GOAL_PUSH_BRIEF:-}" ] && [ "$(fm_pr_sha256 "$brief")" != "$FM_GOAL_PUSH_BRIEF" ]; then
    printf 'queued goal draft changed; review the brief and drop the saved admission before retrying\n' >&2
    return 1
  fi
  if fm_goal_is_draft "$brief"; then
    _fm_goal_draft_check "$ELIGIBLE_INDEX" "$brief" >&2 || return 1
    if [ "$launch" = --launch ]; then
      [ "$4" -ef "$FM_GOAL_DRAFT_CLONE" ] && [ "$5" = "$FM_GOAL_DRAFT_MODE" ] &&
        [ "$6" = "$FM_GOAL_DRAFT_YOLO" ] && [ "$7" = "$FM_GOAL_DRAFT_PREFIX" ] || return 1
    fi
  elif fm_goal_brief_token < "$brief" >/dev/null; then
    return 1
  fi
}

log() { printf '%s %s %s\n' "$now" "$run_mode" "$*" >> "$LOG"; }

# Every attempted launch spends one slot even if held. Re-sample before the
# next attempt; the initial budget also bounds a lagging host sample.
headroom() {
  local budget
  budget=$("$CAPACITY" --start-budget 2>/dev/null) || return 1
  case "$budget" in [0-3]) printf '%s\n' "$budget" ;; *) return 1 ;; esac
}

# Only the canonical, validated local landing notification is positive proof.
# The URL is taken from the matching task identity, not a status message.
landed_pr() {
  local task=$1
  fm_pr_metadata_identity_parse "$STATE/$task.meta" &&
    fm_pr_poll_merge_already_notified "$STATE" "$task" "$FM_PR_META_PROVIDER" \
      "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" &&
    printf '%s\n' "$FM_PR_META_URL"
}

still_driven() (
  _fm_goal_open_record "$1" "$FM_GOAL_VIEW_STATE" >/dev/null 2>&1 && [ "$FM_GOAL_REC_DRIVE" = driven ]
)

mark() {
  local goal=$1 i=$2 next=$3 note=$4 item=${FM_GOAL_ITEMS_IDS[$2]}
  log "mark $goal/$item $next: $note"
  [ "$run_mode" = enforce ] && [ "$(mode)" = enforce ] || return 1
  FM_GOAL_PUSH_EXPECT="${FM_GOAL_ITEMS_OWNERS[$i]}:${FM_GOAL_M_STATES[$i]}:${FM_GOAL_M_ATS[$i]}" \
    "$SCRIPT_DIR/fm-goal.sh" mark "$goal" "$item" "$next" -- "$note" >/dev/null
}

# Both brief and stale-wait wakes target this home's owner. Repeat a stale
# observation at most hourly, even if the watcher has already drained it.
notice() {
  local key=$1 msg=$2 stamp="$STATE/goal-push-asks/$1" last
  [ ! -L "${stamp%/*}" ] && [ ! -L "$stamp" ] || return 0
  last=$(fm_path_mtime "$stamp" 2>/dev/null) || last=0
  [ "$((now - last))" -ge 3600 ] || return 0
  log "$msg"
  [ "$run_mode" = enforce ] && [ "$(mode)" = enforce ] || return 0
  mkdir -p "${stamp%/*}" && fm_wake_append check "goal-push:$key" "check: $msg" && touch "$stamp"
}

reconcile() {
  local goal=$1 i=$2 task=${FM_GOAL_ITEMS_TASKS[$2]} state=${FM_GOAL_M_STATES[$2]}
  local pr line verdict since ref age
  case "$state" in
    running)
      [ ! -L "$STATE/$task.meta" ] || return 1
      if [ -n "$task" ] && [ -e "$STATE/$task.meta" ]; then
        [ -f "$STATE/$task.meta" ] || return 1
        _fm_goal_item_orphaned_running "$i" "$STATE" "$FM_GOAL_DATA" || return 1
        verdict=${_FM_GOAL_CREW_STATE_VERDICTS["$STATE|$task"]:-unknown}
        if [ "$verdict" = 'done' ]; then
          pr=$(landed_pr "$task") || return 1
          mark "$goal" "$i" 'done' "landed $pr"
          return
        fi
        [ "$verdict" = failed ] || return 1
      fi
      mark "$goal" "$i" open 'orphaned: task missing or failed'
      ;;
    waiting)
      since=${FM_GOAL_M_ATS[$i]:-$FM_GOAL_REC_STARTED_EPOCH}
      ref=${FM_GOAL_M_ONS[$i]-}
      age=$((now - since))
      case "$ref" in
        '') [ "$age" -ge 1800 ] || return 1 ;;
        external:*) [ "$age" -ge 3600 ] || return 1 ;;
        *) return 1 ;; # Explicit wait resolution belongs to the goal grammar.
      esac
      still_driven "$goal" || return 1
      line="$goal/${FM_GOAL_ITEMS_IDS[$i]}"
      # Hash the binding and occurrence rather than using item names as paths.
      notice "wait-$(printf '%s\n%s\n' "$line" "$since" | cksum | tr ' ' '-')" "goal wait is stale: $line (${age}s); review or clear the wait"
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Write privately, then link the complete brief without replacing an owner's
# work. Both the stage and destination are on the task data filesystem.
publish_draft() (
  local binding=$1 task=$2 body=$3 dir="$FM_GOAL_DATA/$2" stage
  [ -d "$FM_GOAL_DATA" ] && [ ! -L "$FM_GOAL_DATA" ] && [ ! -L "$dir" ] || exit 1
  stage=$(mktemp -d "$FM_GOAL_DATA/.goal-draft.XXXXXX") || exit 1
  trap 'rm -f -- "$stage/brief.md"; rmdir -- "$stage"' EXIT
  printf '%s\n' "$body" > "$stage/brief.md" || exit 1
  load_eligible "$binding" "$task" && [ ! -e "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ] || exit 1
  _fm_goal_draft_check "$ELIGIBLE_INDEX" "$stage/brief.md" >/dev/null || exit 1
  [ ! -L "$FM_GOAL_DATA" ] && [ ! -L "$dir" ] && mkdir -p -- "$dir" && ln -- "$stage/brief.md" "$dir/"
)

draft_brief() {
  local i=$1 binding=$2 task=$3 body brief="$FM_GOAL_DATA/$3/brief.md"
  if [ -e "$brief" ] || [ -L "$brief" ] || [ -L "${brief%/*}" ]; then
    log "cannot draft $binding: unsafe or existing brief path"
    return 1
  fi
  if ! body=$(_fm_goal_draft_render "$i"); then
    log "cannot draft $binding: $body"
    return 1
  fi
  if [ "$run_mode" = shadow ]; then
    log "would draft $binding ($task)"
    return 0
  fi
  if ! publish_draft "$binding" "$task" "$body"; then
    log "cannot draft $binding: eligibility or brief path changed, or write failed"
    return 1
  fi
  log "drafted $binding ($task)"
  "$SCRIPT_DIR/fm-task-milestones.sh" stamp "$STATE/$task.status" brief -- 'drafted by goal pusher' || true
}

# Track reached, uncovered episodes only. A covered/cleared observation
# removes the episode, allowing a future episode to ring without an hourly nag.
captain_notices() {
  local file="$STATE/.goal-push-captain" goals audit count prior='' next='' tmp status kind binding episode row
  [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
  goals=$(FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-goal.sh" export --driven | jq -ec '.goals') || return 1
  audit=$(printf '%s\n' "$goals" | "$SCRIPT_DIR/../tools/cockpit/cockpit-sync.sh" \
    --goal-home "$FM_HOME" --state "$FM_GOAL_VIEW_STATE" --captain-waiting --goal-items-stdin) || return 1
  count=$(awk '$1 == "MISSING" {n++} END {print n+0}' <<< "$audit")
  [ "$goals" = '[]' ] || log "captain_missing=$count"
  if [ "$command" != tick ]; then
    [ "$run_mode" = enforce ] && [ "$(mode)" = enforce ] || return 0
  fi
  [ ! -f "$file" ] || prior=$(<"$file")
  while IFS=$'\t' read -r status kind binding episode; do
    [ "$status" = MISSING ] && [ "$kind" = goal ] && [ -n "$episode" ] || continue
    row="$binding $episode"
    if grep -Fxq -- "$row" <<< "$prior" || {
      still_driven "${binding%%/*}" && fm_wake_append check "goal-push:captain:$binding" \
        "check: captain item NOT on cockpit: $binding"; }; then
      next="${next:+$next$'\n'}$row"
    fi
  done <<< "$audit"
  [ "$prior" != "$next" ] || return 0
  tmp=$(mktemp "$STATE/.goal-push-captain.XXXXXX") || return 1
  if ! printf '%s\n' "$next" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

run_pass() {
  local run_mode=$1 now path goal i changed task binding brief result budget=-1 remaining queued links drafts
  local briefs='' ready='' held='' off='' listed=0
  now=$(date +%s)
  while IFS= read -r path; do
    goal=${path##*/}; goal=${goal%.goal}
    load_goal "$goal" || continue
    changed=0
    for ((i=0; i<FM_GOAL_ITEM_COUNT; i++)); do
      owned "$i" && [ "${FM_GOAL_ITEMS_CLASSES[$i]}" = drive ] || continue
      reconcile "$goal" "$i" && changed=1
    done
    [ "$changed" -eq 0 ] || load_goal "$goal" || continue
    drafts=0
    for ((i=0; i<FM_GOAL_ITEM_COUNT; i++)); do
      startable "$i" || continue
      task=${FM_GOAL_ITEMS_TASKS[$i]}
      binding="$goal/${FM_GOAL_ITEMS_IDS[$i]}"
      brief="$FM_GOAL_DATA/$task/brief.md"
      if [ -z "$task" ] || { [ ! -e "$STATE/$task.meta" ] &&
         { [ ! -f "$brief" ] || [ ! -s "$brief" ] || [ -L "$brief" ]; }; }; then
        # Cap deferrals wait for the next pass.
        if [ "$drafts" -ge 3 ]; then
          log "defer draft $binding: per-goal cap reached"
          continue
        fi
        if ! draft_brief "$i" "$binding" "$task"; then
          briefs="$briefs $binding"
          continue
        fi
        drafts=$((drafts + 1))
        [ "$run_mode" = enforce ] || continue
        listed=0 # The broker's earlier snapshot could not see this brief.
      fi
      [ ! -e "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ] || continue
      if [ -f "$brief" ] && [ ! -L "$brief" ] && [ ! -L "${brief%/*}" ] && fm_goal_is_draft "$brief"; then
        if ! result=$(_fm_goal_draft_check "$i" "$brief"); then
          log "hold $binding ($task): $result"
          briefs="$briefs $binding"
          continue
        fi
      fi
      if [ "$listed" -eq 0 ]; then
        links=$("$SCRIPT_DIR/fm-goal.sh" launch-links) || return 1
        ready=$("$AUTO" list | awk '$2 == "start" {print $1}')
        held=$("$ADMISSION" list --goal-push | awk '$2 == "held" {print $1, $3}')
        off=$(awk '$2 == "off" {print $1}' <<< "$links")
        listed=1
      fi
      ! grep -Fxq -- "$task" <<< "$off" || continue
      queued=0
      if grep -Fxq -- "$task $binding" <<< "$held"; then queued=1
      elif ! grep -Fxq -- "$task" <<< "$ready"; then continue
      fi
      if [ "$budget" -ne 0 ]; then
        remaining=$(headroom) || remaining=0
        [ "$budget" -ge 0 ] || budget=$remaining
        [ "$remaining" -gt 0 ] || budget=0
      fi
      if [ "$budget" -le 0 ]; then
        log "hold $binding ($task): no remaining start headroom"
        continue
      fi
      budget=$((budget - 1))
      log "start $binding ($task)"
      [ "$run_mode" = enforce ] || continue
      if [ "$queued" -eq 1 ]; then
        result=$("$ADMISSION" retry --goal-task "$task" --max-starts 1) || true
      else
        result=$(FM_GOAL_PUSH_BINDING="$binding" "$AUTO" run --goal-task "$task") || true
      fi
      [ -z "$result" ] || log "$result"
      case "$result" in
        "started $task"*|"admission: started $task")
          mark "$goal" "$i" running "started $task through routed admission" || true ;;
      esac
    done
  done < <(fm_goal_active_records "$FM_GOAL_VIEW_STATE" --driven 2>/dev/null)
  local current=''
  local -a bindings=()
  read -r -a bindings <<< "$briefs"
  for binding in ${bindings[@]+"${bindings[@]}"}; do
    if still_driven "${binding%%/*}"; then current="$current $binding"; fi
  done
  [ -z "$current" ] || notice "briefs-$(printf '%s\n' "$current" | cksum | tr ' ' '-')" "goal briefs needed:$current"
  captain_notices || log 'captain cockpit audit failed'
}

# One cheap metadata batch per watcher poll; content and status notes are not
# copied. Marks and drive switches also appear in the mate's parent view.
event_key() {
  local dir="$FM_GOAL_VIEW_STATE/goals" f
  local -a paths=()
  [ ! -L "$dir" ] || return 1
  for f in "$dir"/*.goal; do
    [ -f "$f" ] && [ ! -L "$f" ] && paths+=("$f")
  done
  [ "${#paths[@]}" -gt 0 ] || return 1
  for f in "$dir"/*.marks "$STATE"/*.pr-poll-merge-notified "$STATE"/*.status \
           "$FM_GOAL_VIEW_STATE/${FM_GOAL_VIEW_OWNER:-main}.status" "$FM_GOAL_CONFIG/goal-push" \
           "$FM_GOAL_VIEW_STATE/cockpit-truth.json" "$FM_GOAL_VIEW_STATE"/cockpit-truth.*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] && paths+=("$f")
  done
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%N:%i:%m:%z' "${paths[@]}"
  else
    stat -c '%n:%i:%y:%s' -- "${paths[@]}"
  fi | cksum
}

case "${1:-}" in
  eligible)
    shift
    [ "$#" -eq 2 ] || { [ "$#" -eq 7 ] && [ "$3" = --launch ]; } || exit 2
    eligible "$@"; exit $? ;;
  tick) [ "$#" -eq 1 ] || exit 2 ;;
  run) [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --dry-run ]; } || exit 2 ;;
  -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
  *) exit 2 ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L "$LOG" ] || exit 1
_fm_goal_owner_read_view || { printf 'goal push not checked: owner or parent home is not reachable\n' >&2; exit 1; }
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK"' EXIT
if [ "$1" = tick ]; then
  tick_file="$STATE/.goal-push-tick"
  [ ! -L "$tick_file" ] || exit 1
  key=$(event_key) || exit 0
  epoch=$(date +%s)
  last=0 old_key=''
  if [ -f "$tick_file" ]; then read -r last old_key < "$tick_file" || true; fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$key" = "$old_key" ] && [ "$((epoch - last))" -lt 120 ]; then exit 0; fi
  printf '%s %s\n' "$epoch" "$key" > "$tick_file"
fi
command=$1
run_mode=$(mode)
[ "${2:-}" != --dry-run ] || run_mode=shadow
run_pass "$run_mode"
