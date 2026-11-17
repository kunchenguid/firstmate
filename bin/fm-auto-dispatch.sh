#!/usr/bin/env bash
# fm-auto-dispatch.sh - start queued briefs without a firstmate turn.
#
# The admission queue (bin/fm-admission-queue.sh) retries starts that were
# attempted and held; this script is its sibling one step earlier: a queued
# backlog row whose brief is already written is dispatched by the watcher the
# moment its own gates clear, so brief-to-start no longer waits for a
# firstmate turn (the Miko CI/CD audit: dispatch p90 4.3 h).
#
# Usage:
#   fm-auto-dispatch.sh list    one line per ready row: <id> <start|skip: why>
#   fm-auto-dispatch.sh check   the watcher check (state/auto-dispatch.check.sh):
#                               shadow reports a changed candidate set once;
#                               enforce starts `run` detached, exactly as
#                               bin/fm-reap.sh does for teardown
#   fm-auto-dispatch.sh run     dispatch up to FM_AUTODISPATCH_MAX_STARTS rows now
#   fm-auto-dispatch.sh arm     write state/auto-dispatch.check.sh and bind it
#                               with bin/fm-check-register.sh (bootstrap arms it
#                               every start while config/auto-dispatch exists)
#   fm-auto-dispatch.sh drop <task-id>
#                               forget a failure mark after fixing its cause
#
# Selection. A row must pass every gate below, in this order; the first miss
# is the printed skip reason and the row is left alone:
#   ready      bin/fm-tasks-axi.sh `ready` lists it: queued, no open blockers,
#              no active hold. Every captain hold is excluded there, which is
#              also how money calls stay undispatched (a money call is a
#              captain hold of category money, bin/fm-captain-hold.sh), and a
#              hold with --until keeps the row out until its date gate clears.
#   kind       not secondmate and not captain: persistent homes and
#              captain-class rows are never dispatched here.
#   unstarted  no state/<id>.meta exists; a row with a record is live work.
#   brief      data/<id>/brief.md exists, is readable and non-empty - never a
#              spawn without a brief (bin/fm-dispatch.sh refuses too).
#   filled     the brief carries no {TASK}, {FIRSTMATE_SPEC} or {FILL:...}
#              placeholder; an unfinished scaffold waits for its writer.
#   contract   the brief is a crewmate brief: a "Delivery contract: mode="
#              line (ship) or the SCOUT marker (scout). Anything else, such as
#              a secondmate charter, is not launched from here.
#   project    the row's repo resolves to a directory under this home's
#              projects directory; a missing clone waits for fleet-sync.
#   unparked  no failure mark newer than the brief: a dispatch that ended in
#              anything but a start or a hold is parked for firstmate (one
#              wake row names the reason) and never retried blind; rewriting
#              the brief clears the mark, as does `drop <id>`.
#   pacing    the previous attempt on the row is at least
#              FM_AUTODISPATCH_RETRY_SECS (default 900) old, so a weekly-guard
#              hold costs one resolver read per interval, not one per tick.
#
# Launch. `run` starts at most FM_AUTODISPATCH_MAX_STARTS (default 1) rows per
# pass, oldest-ready first, through bin/fm-dispatch.sh new <id> <project-dir>
# with flags derived only from recorded decisions: the mode, branch prefix,
# base branch and upstream consent from the brief's own contract lines (the
# same lines bin/fm-spawn.sh verifies), --scout for a SCOUT brief, and --yolo
# from the project's registered standing posture (bin/fm-project-mode.sh; a
# per-task deviation is firstmate's to hold or dispatch by hand). Every
# existing guard still owns its verdict unchanged: the resolver's weekly start
# guard and receipts, the capacity and load guard in fm-spawn.sh - whose exit
# 75 parks the start in the admission queue for its own retry - and the
# project delivery mode agreement. Outcomes:
#   started (exit 0)   announced once as a durable `check:` wake row
#   spawn-held (75)    the admission queue owns the retry; no wake
#   resolver-held (3, "status: held")  the weekly guard; retried after the
#                      pacing interval, no wake
#   captain-pick, any other refusal  parked with a failure mark and one wake
#                      row naming the evidence; firstmate relays or fixes
# A row whose task record appeared meanwhile counts as started, never failed.
#
# Mode: config/auto-dispatch holds `shadow` or `enforce`; without the file the
# check prints nothing and nothing is ever dispatched. `shadow` prints the
# candidate set only when it changes, so the rollout week costs one wake per
# change, not per tick. `enforce` dispatches. This default is OFF: launching
# workers spends quota, so the switch is provably safe only where a home has
# turned it on deliberately.
#
# State: state/auto-dispatch-failed/<id> (one-line reason) and
# state/auto-dispatch-attempt/<id> (last attempt epoch), plus the run log
# state/auto-dispatch-run.log and the run lock state/.auto-dispatch-run.lock.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE
# and FM_PROJECTS_OVERRIDE resolve the home like the other bin/ scripts;
# FM_AUTODISPATCH_MAX_STARTS, FM_AUTODISPATCH_RETRY_SECS tune the pass;
# FM_AUTODISPATCH_DISPATCH, FM_AUTODISPATCH_READY and
# FM_AUTODISPATCH_PROJECT_MODE replace their commands for tests only.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DISPATCH="${FM_AUTODISPATCH_DISPATCH:-$SCRIPT_DIR/fm-dispatch.sh}"
READY="${FM_AUTODISPATCH_READY:-$SCRIPT_DIR/fm-tasks-axi.sh}"
PROJECT_MODE="${FM_AUTODISPATCH_PROJECT_MODE:-$SCRIPT_DIR/fm-project-mode.sh}"
FAILED="$STATE/auto-dispatch-failed"
ATTEMPT="$STATE/auto-dispatch-attempt"
LOG="$STATE/auto-dispatch-run.log"
LOCK="$STATE/.auto-dispatch-run.lock"
MAX_STARTS=${FM_AUTODISPATCH_MAX_STARTS:-1}
RETRY_SECS=${FM_AUTODISPATCH_RETRY_SECS:-900}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { echo "fm-auto-dispatch: $*" >&2; exit 1; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

case "$MAX_STARTS" in ''|*[!0-9]*|0) die 'FM_AUTODISPATCH_MAX_STARTS must be a whole number of at least 1' ;; esac
case "$RETRY_SECS" in ''|*[!0-9]*) die 'FM_AUTODISPATCH_RETRY_SECS must be whole seconds' ;; esac

mode() {
  local m=off
  [ ! -f "$CONFIG/auto-dispatch" ] || read -r m < "$CONFIG/auto-dispatch" || true
  case "$m" in off) printf off ;; enforce) printf enforce ;; *) printf shadow ;; esac
}

announce() {  # <key> <text>
  fm_wake_append check "$1" "check: $2" >/dev/null 2>&1 || true
}

one_line() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300; }

# One "id state kind repo" row per ready line, in the tool's own order.
ready_rows() {
  fm_run_timed 30 "$READY" ready 2>/dev/null | awk -F, '
    $2 == "queued" && $1 != "" && $1 !~ /[\/]/ && $3 != "" && $4 != "" { print $1, $2, $3, $4 }'
}

mark_epoch() {  # <file> -> its mtime epoch, 0 when absent
  [ -f "$1" ] || { printf 0; return 0; }
  stat -c %Y "$1" 2>/dev/null || printf 0
}

brief_value() {  # <brief> <sed-expr>
  sed -n "$2p" "$1" 2>/dev/null | head -n 1
}

# <id> <kind> <repo> -> "start <project-dir> <flag>..." on stdout when every
# gate passes, or "skip: <reason>" (rc 1). Flags are data for cmd_run; they
# are never evaluated as shell text.
verdict() {  # <id> <kind> <repo>
  local id=$1 kind=$2 repo=$3 brief meta project branch mode yolo base consent prefix
  case "$kind" in
    secondmate) printf 'skip: secondmate-class row\n'; return 1 ;;
    captain) printf 'skip: captain-class row\n'; return 1 ;;
  esac
  fm_task_id_creation_valid "$id" || { printf 'skip: unusable task id\n'; return 1; }
  meta="$STATE/$id.meta"
  [ ! -e "$meta" ] || { printf 'skip: already started\n'; return 1; }
  brief="$DATA/$id/brief.md"
  [ -s "$brief" ] && [ -f "$brief" ] && [ ! -L "$brief" ] || { printf 'skip: no written brief\n'; return 1; }
  if grep -q -e '{TASK}' -e '{FIRSTMATE_SPEC}' -e '{FILL:' "$brief"; then
    printf 'skip: brief still has placeholders\n'
    return 1
  fi
  mode=$(brief_value "$brief" 's/^Delivery contract: mode=\([^ ]*\).*$/\1/')
  consent=$(brief_value "$brief" 's/^Delivery contract: mode=[^ ]*.*[[:space:]]upstream-consent=\([^ ]*\).*$/\1/')
  branch=$(brief_value "$brief" 's/^Ship branch: //')
  base=$(brief_value "$brief" 's/^Base branch: //')
  project="$PROJECTS/$repo"
  [ -d "$project" ] || { printf 'skip: no project clone for %s\n' "$repo"; return 1; }
  if [ -f "$FAILED/$id" ] && [ "$(mark_epoch "$FAILED/$id")" -ge "$(mark_epoch "$brief")" ]; then
    printf 'skip: parked for firstmate (%s)\n' "$(one_line "$(head -n 1 "$FAILED/$id" 2>/dev/null)")"
    return 1
  fi
  if [ -f "$ATTEMPT/$id" ]; then
    local attempted age
    attempted=$(head -n 1 "$ATTEMPT/$id" 2>/dev/null)
    is_uint "$attempted" || attempted=0
    age=$(( $(date +%s) - attempted ))
    [ "$age" -lt 0 ] && age=0
    [ "$age" -ge "$RETRY_SECS" ] || { printf 'skip: last attempt %ss ago, next in %ss\n' "$age" "$(( RETRY_SECS - age ))"; return 1; }
  fi
  if grep -q '^This is a SCOUT task' "$brief"; then
    printf 'start %s --scout' "$project"
    [ -n "$base" ] && printf ' --base-branch %s' "$base"
    printf '\n'
    return 0
  fi
  case "$mode" in
    no-mistakes|direct-PR|local-only) ;;
    '') printf 'skip: no delivery contract line\n'; return 1 ;;
    *) printf 'skip: unreadable delivery contract (%s)\n' "$(one_line "$mode")"; return 1 ;;
  esac
  yolo=off
  local posture
  posture=$(fm_run_timed 15 "$PROJECT_MODE" "$repo" 2>/dev/null) || posture=
  case "$posture" in
    *" "*) yolo=${posture##* } ;;
  esac
  case "$yolo" in on|off) ;; *) yolo=off ;; esac
  prefix=
  case "$branch" in
    '') : ;;
    "fm/$id") : ;;
    *"/$id") prefix=${branch%"$id"} ;;
    *) printf 'skip: ship branch %s does not end in the task id\n' "$(one_line "$branch")"; return 1 ;;
  esac
  printf 'start %s --mode %s --yolo %s' "$project" "$mode" "$yolo"
  [ -z "$prefix" ] || printf ' --branch-prefix %s' "$prefix"
  [ -z "$base" ] || printf ' --base-branch %s' "$base"
  [ -z "$consent" ] || printf ' --upstream-consent %s' "$consent"
  printf '\n'
  return 0
}

# One "<id> <verdict>" line per ready row.
verdicts() {
  local id kind repo v
  while read -r id kind repo; do
    [ -n "${id:-}" ] || continue
    v=$(verdict "$id" "$kind" "$repo")
    printf '%s %s\n' "$id" "$v"
  done < <(ready_rows | cut -d' ' -f1,3,4)
}

cmd_list() { verdicts; }

# Dispatch one row; prints one outcome line. Never trusts dispatch output as
# shell text: only its exit status and grepped evidence lines are read.
dispatch_one() {  # <id> <project-dir> <flag>...
  local id=$1 project=$2 out rc reason pick
  shift 2
  mkdir -p "$ATTEMPT" "$FAILED" 2>/dev/null || die 'cannot create the auto-dispatch state directories'
  date +%s > "$ATTEMPT/$id" 2>/dev/null || true
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$DISPATCH" new "$id" "$project" "$@" < /dev/null 2>&1) || rc=$?
  case "$rc" in
    0)
      rm -f -- "$ATTEMPT/$id" "$FAILED/$id"
      announce "auto-dispatch-started:$id" "auto-dispatch: started $id from its queued brief (resolver receipt and spawn admission gated the launch)"
      printf 'started %s\n' "$id"
      return 0
      ;;
    75)
      rm -f -- "$ATTEMPT/$id"
      printf 'held %s: spawn admission held the start; the admission queue retries it\n' "$id"
      return 0
      ;;
  esac
  if [ -e "$STATE/$id.meta" ]; then
    rm -f -- "$ATTEMPT/$id" "$FAILED/$id"
    printf 'started %s (the task record appeared during the launch)\n' "$id"
    return 0
  fi
  pick=$(printf '%s\n' "$out" | grep -m1 'pick:')
  if [ "$rc" -eq 3 ] && printf '%s\n' "$out" | grep -q 'status: held'; then
    printf 'wait %s: the weekly start guard held every candidate; retried after %ss\n' "$id" "$RETRY_SECS"
    return 0
  fi
  reason="dispatch exit $rc: $(one_line "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)")"
  printf '%s\n' "$reason" > "$FAILED/$id" 2>/dev/null || true
  announce "auto-dispatch-needs-firstmate:$id" \
    "auto-dispatch: $id parked for firstmate: $reason${pick:+; $pick}; fix and run bin/fm-auto-dispatch.sh drop $id, or hold the row"
  printf 'parked %s: %s\n' "$id" "$(one_line "$reason")"
  return 0
}

cmd_run() {
  local mode started=0 id v
  mode=$(mode)
  [ "$mode" = enforce ] || die 'run dispatches only in enforce mode (config/auto-dispatch)'
  mkdir "$LOCK" 2>/dev/null || { printf 'auto-dispatch: a run is already in progress\n'; return 0; }
  # shellcheck disable=SC2064 # expand the lock path now
  trap "rmdir -- $(printf '%q' "$LOCK") 2>/dev/null" EXIT
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  while read -r id v; do
    [ -n "${id:-}" ] || continue
    [ "$started" -lt "$MAX_STARTS" ] || break
    case "$v" in
      'start '*)
        v=${v#start }
        # shellcheck disable=SC2086 # verdict output is flag words, never evaluated
        dispatch_one "$id" $v
        started=$((started + 1))
        ;;
    esac
  done < <(verdicts)
}

# The check the watcher runs: shadow reports a changed candidate set once;
# enforce hands the work to a detached run whose events wake on their own.
cmd_check() {
  local m snapshot
  m=$(mode)
  [ "$m" != off ] || return 0
  if [ "$m" = enforce ]; then
    if verdicts | grep -q 'start ' && [ ! -d "$LOCK" ]; then
      ( setsid "$0" run > "$LOG" 2>&1 < /dev/null & ) 2>/dev/null
    fi
    return 0
  fi
  snapshot=$(verdicts | awk '$2 == "start"' | sort)
  if [ "$snapshot" != "$(cat "$STATE/.auto-dispatch-shadow" 2>/dev/null)" ]; then
    printf '%s\n' "$snapshot" > "$STATE/.auto-dispatch-shadow"
    [ -z "$snapshot" ] || printf 'auto-dispatch (shadow, nothing started): %s dispatchable row(s): %s. Write enforce to config/auto-dispatch to start them automatically.\n' \
      "$(printf '%s\n' "$snapshot" | wc -l)" "$(printf '%s\n' "$snapshot" | paste -sd'; ' -)"
  fi
}

cmd_arm() {
  local staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state directory unavailable'
  staged=$(umask 077; mktemp "$STATE/.auto-dispatch-check.XXXXXX") || die 'could not stage the check'
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "export FM_PROJECTS_OVERRIDE=$(printf '%q' "$PROJECTS")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-auto-dispatch.sh") check" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/auto-dispatch.check.sh" || die 'could not write state/auto-dispatch.check.sh'
  "$SCRIPT_DIR/fm-check-register.sh" auto-dispatch
}

cmd_drop() {
  [ "$#" -eq 1 ] || die 'drop needs one task id'
  fm_task_id_creation_valid "$1" || die "invalid task id '$1'"
  rm -f -- "$FAILED/$1" "$ATTEMPT/$1"
}

case "${1:-}" in
  list) cmd_list ;;
  check) cmd_check ;;
  run) cmd_run ;;
  arm) cmd_arm ;;
  drop) shift; cmd_drop "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
