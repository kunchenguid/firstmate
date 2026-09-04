#!/usr/bin/env bash
# bin/fm-nm-review-pane.sh - one live no-mistakes review pane per Herdr
# no-mistakes ship task.
#
# Usage:
#   fm-nm-review-pane.sh <task-id>          ensure the review pane exists and
#                                           follows the task's current run
#   fm-nm-review-pane.sh <task-id> --close  close the review pane and retire its
#                                           record (acquires the session lock)
#   . bin/fm-nm-review-pane.sh              load the functions only; nothing
#                                           runs until a function is called
#
# What it does. A no-mistakes ship worker runs `no-mistakes axi run` from its
# task worktree, possibly several times. `no-mistakes attach --run <id>` is the
# TUI that follows one run and needs a TTY. This script owns the pane the
# captain would otherwise split by hand: exactly one Herdr pane to the RIGHT of
# the worker's own pane, in the same tab, whose cwd is the task worktree, and
# which is re-pointed at each new run of that task's branch instead of opening
# more panes. bin/fm-watch.sh calls it on a bounded cadence for every live
# herdr no-mistakes ship task, and bin/fm-spawn.sh calls it once after a
# successful herdr no-mistakes ship spawn so the pane exists before the first
# run. bin/fm-teardown.sh closes the pane through fm_nm_review_pane_close_locked
# while it already holds the named-session presentation lock.
#
# Eligibility (read from state/<id>.meta, bin/fm-spawn.sh's fields): backend=
# herdr, kind absent or ship, mode=no-mistakes, and non-empty herdr_session=,
# herdr_pane_id=, and worktree=. Anything else is not applicable and exits 3
# silently, as does a home that opted out.
#
# Opt-out: local, gitignored config/nm-review-pane. Values are compared with
# whitespace stripped and case ignored: "off" disables the pane for this home,
# an absent file, an empty file, and "on" all enable it, and any other value
# warns once per call and behaves as enabled, because a visual convenience must
# never fail a spawn or a watcher poll. The item is in bin/fm-config-inherit-lib.sh's
# inheritable set, so a primary "off" reaches secondmate homes.
#
# Private record: state/<id>.nm-review-pane, key=value lines, written
# atomically, owned by this script alone:
#   session=<herdr session>   the named session the pane lives in
#   pane=<pane id>            the exact pane id Herdr returned from `pane split`
#   run=<run id>              the run id the pane was last pointed at; empty
#                             while the pane shows the waiting loop
#   viewer=wait|attach        which command this script last started there
# The record never grants task, endpoint, or ownership authority: it names one
# presentation pane and the last run this script asked it to show. A record
# whose pane is structurally gone (pane_not_found) is discarded and the pane is
# recreated; an unreadable presence refuses rather than splitting a second pane.
#
# Current run: `no-mistakes axi status` in the task worktree (bounded by
# bin/fm-nm-run-lib.sh's fm_nm_run_checked, FM_NM_REVIEW_PANE_NM_TIMEOUT seconds,
# default 20). Only the top-level `run:` block counts, and only when its branch
# equals the worktree's current branch; an `other_branch_run:` block, a run list
# without a `run:` block, and an absent no-mistakes CLI all mean "no run yet". A
# failed or timed-out status call is unknown and leaves the pane untouched.
#
# Pointing. The desired viewer is `no-mistakes attach --run <id>` when a run
# exists, otherwise a small shell loop that reprints a waiting line every few
# seconds. When the record already names that exact run and viewer, the call is
# a no-op (the status call is its whole cost). Otherwise the pane is quiesced
# and the viewer is started with `herdr pane run <pane> "<one shell string>"`.
# Quiescing reads `herdr pane process-info --pane <pane>` and acts only on what
# it proves: a foreground `no-mistakes attach` gets `q`, any other foreground
# process (the waiting loop's sleep) gets ctrl+c, an idle shell needs nothing,
# and an unreadable process table refuses to send keys or run anything, so a
# stray key can never be typed into an unknown program. A freshly split pane
# skips quiescing.
#
# Empirical observations (no-mistakes 2026-09-03, Herdr 0.8.2 protocol 20,
# Linux, isolated fm-herdr-lab session):
#   - `no-mistakes attach` with no active run for the repo prints "No active
#     run" and EXITS immediately with status 0, so an idle pane cannot simply
#     run attach once; it runs the waiting loop until a run id exists.
#   - `no-mistakes attach --run <id>` on a FINISHED run (status failed) stays
#     attached, showing the terminal state with a `q quit` footer, until `q`;
#     it does not exit on its own, so re-pointing must detach it explicitly.
#   - `no-mistakes attach --run <unknown-id>` exits 1 with "run not found".
#   - `herdr pane split <pane> --direction right --cwd <dir> --no-focus`
#     returns {"result":{"pane":{"pane_id":...,"tab_id":...}, "type":"pane_info"}}.
#   - `herdr pane run <pane> "<string>"` runs the whole string as one shell
#     command line (a `while ...; do ...; done` loop works).
#   - `herdr pane process-info --pane <pane>` lists the foreground process with
#     name "no-mistakes" and argv ["no-mistakes","attach","--run",<id>] while a
#     viewer is attached; after `q` the shell is the foreground process again;
#     after ctrl+c on the waiting loop the shell is the foreground again.
#
# Closing (teardown or --close): the pane is closed through the adapter's own
# focus-safe fm_backend_herdr_kill_serialized, the same rule ordinary task-pane
# cleanup uses: a close that would empty a non-focused workspace follows the
# focus-preserving plan with the exact prior-tab restore, and the captain's
# active tab keeps the plain confirmed close. The record is removed only after
# the pane's structured presence reads pane_not_found; a present or unknown
# pane retains the record with a warning naming the `--close` rerun. The
# session lock is the caller's responsibility for the _locked entry point
# (fm-teardown.sh already holds it) and is acquired by `--close`.
#
# Exit codes: 0 done or no-op, 1 refused or failed (a warning names why),
# 3 not applicable or opted out (silent).
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE as everywhere
# else; FM_NM_REVIEW_PANE_NM_TIMEOUT (seconds, default 20) bounds the status
# call; FM_NM_REVIEW_PANE_QUIESCE_POLLS (default 10) bounds the detach wait.
set -u

FM_NM_REVIEW_PANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_NM_REVIEW_PANE_CONFIG="nm-review-pane"
FM_NM_REVIEW_PANE_SUFFIX=".nm-review-pane"

# Dependencies are sourced only when their functions are absent, so
# fm-teardown.sh (which already loaded all three) can source this file cheaply.
if ! declare -F fm_backend_source >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$FM_NM_REVIEW_PANE_LIB_DIR/fm-backend.sh"
fi
if ! declare -F fm_nm_run_checked >/dev/null 2>&1; then
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$FM_NM_REVIEW_PANE_LIB_DIR/fm-nm-run-lib.sh"
fi
if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_NM_REVIEW_PANE_LIB_DIR/fm-wake-lib.sh"
fi

fm_nm_review_pane_record_path() {  # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_NM_REVIEW_PANE_SUFFIX"
}

# fm_nm_review_pane_preference <config-dir>: the single owner of
# config/nm-review-pane parsing. Echoes "off" or "on".
fm_nm_review_pane_preference() {  # <config-dir>
  local file="$1/$FM_NM_REVIEW_PANE_CONFIG" value
  [ -e "$file" ] || { printf 'on'; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$value" in
    off) printf 'off' ;;
    ''|on) printf 'on' ;;
    *)
      echo "warning: $file: unrecognized value \"$value\"; the no-mistakes review pane stays enabled (write \"off\" to opt out)" >&2
      printf 'on'
      ;;
  esac
}

# fm_nm_review_pane_eligible <meta>: 0 when the task qualifies, setting
# FM_NM_REVIEW_SESSION, FM_NM_REVIEW_WORKER_PANE, and FM_NM_REVIEW_WORKTREE.
fm_nm_review_pane_eligible() {  # <meta>
  local meta=$1 kind
  FM_NM_REVIEW_SESSION=
  FM_NM_REVIEW_WORKER_PANE=
  FM_NM_REVIEW_WORKTREE=
  [ -f "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ -z "$kind" ] || [ "$kind" = ship ] || return 1
  [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || return 1
  FM_NM_REVIEW_SESSION=$(fm_meta_get "$meta" herdr_session)
  FM_NM_REVIEW_WORKER_PANE=$(fm_meta_get "$meta" herdr_pane_id)
  FM_NM_REVIEW_WORKTREE=$(fm_meta_get "$meta" worktree)
  [ -n "$FM_NM_REVIEW_SESSION" ] && [ -n "$FM_NM_REVIEW_WORKER_PANE" ] && [ -n "$FM_NM_REVIEW_WORKTREE" ]
}

# fm_nm_review_pane_record_read <record>: sets FM_NM_REVIEW_REC_SESSION,
# FM_NM_REVIEW_REC_PANE, FM_NM_REVIEW_REC_RUN, FM_NM_REVIEW_REC_VIEWER (all
# empty when the record is absent).
fm_nm_review_pane_record_read() {  # <record>
  FM_NM_REVIEW_REC_SESSION=$(fm_meta_get "$1" session)
  FM_NM_REVIEW_REC_PANE=$(fm_meta_get "$1" pane)
  FM_NM_REVIEW_REC_RUN=$(fm_meta_get "$1" run)
  FM_NM_REVIEW_REC_VIEWER=$(fm_meta_get "$1" viewer)
}

fm_nm_review_pane_record_write() {  # <record> <session> <pane> <run> <viewer>
  local record=$1 tmp
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'session=%s\n' "$2"
    printf 'pane=%s\n' "$3"
    printf 'run=%s\n' "$4"
    printf 'viewer=%s\n' "$5"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

# fm_nm_review_pane_current_run <worktree>: print "<run-id>" for the current
# branch's active or most recent run and return 0; print nothing and return 0
# when no run exists yet; return 1 when the answer is unknown (status call
# failed or timed out).
fm_nm_review_pane_current_run() {  # <worktree>
  local wt=$1 timeout=${FM_NM_REVIEW_PANE_NM_TIMEOUT:-20} out block id branch head_branch
  command -v no-mistakes >/dev/null 2>&1 || return 0
  out=$(fm_nm_run_checked "$wt" "$timeout" axi status) || return 1
  block=$(printf '%s\n' "$out" | sed -n '/^run:[[:space:]]*$/,/^[^[:space:]]/p' | sed '1d;$d')
  [ -n "$block" ] || return 0
  id=$(fm_nm_strip_quotes "$(fm_nm_field "$block" id)")
  [ -n "$id" ] || return 0
  branch=$(fm_nm_strip_quotes "$(fm_nm_field "$block" branch)")
  head_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -n "$branch" ] && [ -n "$head_branch" ] && [ "$head_branch" != HEAD ] && [ "$branch" != "$head_branch" ]; then
    return 0
  fi
  printf '%s' "$id"
}

# fm_nm_review_pane_foreground <session> <pane>: classify the pane's
# foreground as shell|viewer|other|unknown from `pane process-info` alone.
fm_nm_review_pane_foreground() {  # <session> <pane>
  local session=$1 pane=$2 info verdict
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || { printf 'unknown'; return 0; }
  verdict=$(printf '%s' "$info" | jq -r --arg pane "$pane" '
    .result.process_info
    | select(type == "object" and .pane_id == $pane)
    | if (.shell_pid | type) != "number" or (.foreground_process_group_id | type) != "number" then "unknown"
      elif .foreground_process_group_id == .shell_pid then "shell"
      elif ([.foreground_processes[]? | select((.name // "") == "no-mistakes" and ((.argv // []) | index("attach")) != null)] | length) > 0 then "viewer"
      else "other" end
  ' 2>/dev/null) || verdict=
  case "$verdict" in
    shell|viewer|other) printf '%s' "$verdict" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_nm_review_pane_quiesce <session> <pane>: return the pane to an idle shell
# by detaching a viewer (`q`) or interrupting the waiting loop (ctrl+c). 0 once
# the shell is the foreground; 1 when the foreground stays unknown or busy
# after the bounded budget, in which case nothing else may be sent.
fm_nm_review_pane_quiesce() {  # <session> <pane>
  local session=$1 pane=$2 polls=${FM_NM_REVIEW_PANE_QUIESCE_POLLS:-10} attempt=0 fg
  while :; do
    fg=$(fm_nm_review_pane_foreground "$session" "$pane")
    case "$fg" in
      shell) return 0 ;;
      viewer) fm_backend_herdr_cli "$session" pane send-keys "$pane" q >/dev/null 2>&1 || return 1 ;;
      other) fm_backend_herdr_cli "$session" pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || return 1 ;;
      *) return 1 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$polls" ] || break
    sleep "${FM_NM_REVIEW_PANE_QUIESCE_SLEEP:-0.3}"
  done
  [ "$(fm_nm_review_pane_foreground "$session" "$pane")" = shell ]
}

# fm_nm_review_pane_viewer_command <worktree> <task-id> <run-id>: the one shell
# string `pane run` executes. Empty run id means the waiting loop.
fm_nm_review_pane_viewer_command() {  # <worktree> <task-id> <run-id>
  local wt=$1 id=$2 run=$3 q_wt q_id q_run
  q_wt=$(printf '%q' "$wt")
  if [ -n "$run" ]; then
    q_run=$(printf '%q' "$run")
    printf 'cd %s && no-mistakes attach --run %s' "$q_wt" "$q_run"
  else
    q_id=$(printf '%q' "$id")
    printf "cd %s && while :; do clear; printf 'firstmate: waiting for the first no-mistakes run of %%s ...\\\\n' %s; sleep 5; done" "$q_wt" "$q_id"
  fi
}

# fm_nm_review_pane_ensure <state-dir> <config-dir> <task-id>: the ensure entry
# point. Exit-code contract in the header.
fm_nm_review_pane_ensure() {  # <state-dir> <config-dir> <task-id>
  local state=$1 config=$2 id=$3 meta record lock fresh=0 pane presence run desired_viewer cmd rc=0
  meta="$state/$id.meta"
  record=$(fm_nm_review_pane_record_path "$state" "$id")
  fm_nm_review_pane_eligible "$meta" || return 3
  [ "$(fm_nm_review_pane_preference "$config")" = on ] || return 3
  fm_backend_source herdr || return 1
  fm_backend_herdr_tool_check || return 1
  lock="$state/.$id$FM_NM_REVIEW_PANE_SUFFIX.lock"
  fm_lock_try_acquire "$lock" || return 0
  fm_nm_review_pane_record_read "$record"
  pane=$FM_NM_REVIEW_REC_PANE
  if [ -n "$pane" ]; then
    presence=$(fm_backend_herdr_pane_presence_state "$FM_NM_REVIEW_SESSION" "$pane")
    case "$presence" in
      present) ;;
      dead)
        rm -f "$record"
        pane=
        FM_NM_REVIEW_REC_RUN=
        FM_NM_REVIEW_REC_VIEWER=
        ;;
      *)
        echo "warning: no-mistakes review pane $pane for $id has ambiguous presence; leaving it alone" >&2
        fm_lock_release "$lock"
        return 1
        ;;
    esac
  fi
  if [ -z "$pane" ]; then
    if [ "$(fm_backend_herdr_pane_presence_state "$FM_NM_REVIEW_SESSION" "$FM_NM_REVIEW_WORKER_PANE")" != present ]; then
      echo "warning: worker pane $FM_NM_REVIEW_WORKER_PANE for $id is not present; not creating a review pane" >&2
      fm_lock_release "$lock"
      return 1
    fi
    pane=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane split "$FM_NM_REVIEW_WORKER_PANE" \
      --direction right --cwd "$FM_NM_REVIEW_WORKTREE" --no-focus 2>/dev/null \
      | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || pane=
    if [ -z "$pane" ]; then
      echo "warning: herdr pane split for $id returned no pane id; no review pane was created" >&2
      fm_lock_release "$lock"
      return 1
    fi
    fresh=1
    if ! fm_nm_review_pane_record_write "$record" "$FM_NM_REVIEW_SESSION" "$pane" "" ""; then
      echo "warning: no-mistakes review pane record for $id could not be written; pane $pane exists without a record" >&2
      fm_lock_release "$lock"
      return 1
    fi
  fi
  if ! run=$(fm_nm_review_pane_current_run "$FM_NM_REVIEW_WORKTREE"); then
    if [ "$fresh" = 1 ]; then
      run=
    else
      fm_lock_release "$lock"
      return 0
    fi
  fi
  if [ -n "$run" ]; then desired_viewer="attach"; else desired_viewer="wait"; fi
  if [ "$fresh" = 0 ] && [ "$FM_NM_REVIEW_REC_RUN" = "$run" ] && [ "$FM_NM_REVIEW_REC_VIEWER" = "$desired_viewer" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  if [ "$fresh" = 0 ] && ! fm_nm_review_pane_quiesce "$FM_NM_REVIEW_SESSION" "$pane"; then
    echo "warning: no-mistakes review pane $pane for $id could not be returned to its shell; not re-pointing it this time" >&2
    fm_lock_release "$lock"
    return 1
  fi
  cmd=$(fm_nm_review_pane_viewer_command "$FM_NM_REVIEW_WORKTREE" "$id" "$run")
  if fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_nm_review_pane_record_write "$record" "$FM_NM_REVIEW_SESSION" "$pane" "$run" "$desired_viewer" || rc=1
  else
    echo "warning: herdr pane run failed for the no-mistakes review pane of $id" >&2
    rc=1
  fi
  fm_lock_release "$lock"
  return "$rc"
}

# fm_nm_review_pane_close_locked <state-dir> <task-id>: close the recorded pane
# and retire the record. The caller holds the named-session presentation lock.
# 0 when no record exists or the pane is confirmed gone and the record removed;
# 1 when the record is retained.
fm_nm_review_pane_close_locked() {  # <state-dir> <task-id>
  local state=$1 id=$2 record presence
  record=$(fm_nm_review_pane_record_path "$state" "$id")
  [ -e "$record" ] || [ -L "$record" ] || return 0
  fm_nm_review_pane_record_read "$record"
  if [ -z "$FM_NM_REVIEW_REC_SESSION" ] || [ -z "$FM_NM_REVIEW_REC_PANE" ]; then
    echo "warning: no-mistakes review pane record for $id is malformed; retaining it for inspection at $record" >&2
    return 1
  fi
  fm_backend_source herdr || return 1
  presence=$(fm_backend_herdr_pane_presence_state "$FM_NM_REVIEW_REC_SESSION" "$FM_NM_REVIEW_REC_PANE")
  if [ "$presence" = present ]; then
    fm_backend_herdr_kill_serialized "$FM_NM_REVIEW_REC_SESSION" "$FM_NM_REVIEW_REC_PANE" || true
    presence=$(fm_backend_herdr_pane_presence_state "$FM_NM_REVIEW_REC_SESSION" "$FM_NM_REVIEW_REC_PANE")
  fi
  if [ "$presence" = dead ]; then
    rm -f "$record"
    return 0
  fi
  echo "warning: no-mistakes review pane $FM_NM_REVIEW_REC_PANE for $id is not confirmed gone; retaining its record - rerun bin/fm-nm-review-pane.sh $id --close once the pane can be closed" >&2
  return 1
}

# fm_nm_review_pane_close <state-dir> <task-id>: the --close entry point;
# acquires the named-session presentation lock around the close.
fm_nm_review_pane_close() {  # <state-dir> <task-id>
  local state=$1 id=$2 record lock_path attempt=0 rc
  record=$(fm_nm_review_pane_record_path "$state" "$id")
  [ -e "$record" ] || [ -L "$record" ] || return 0
  fm_nm_review_pane_record_read "$record"
  fm_backend_source herdr || return 1
  fm_backend_herdr_tool_check || return 1
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$FM_NM_REVIEW_REC_SESSION") || {
    echo "warning: herdr session presentation lock path is unavailable; refusing an unlocked review pane close for $id" >&2
    return 1
  }
  while ! fm_lock_try_acquire "$lock_path"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      echo "warning: herdr session presentation lock is contended; refusing an unlocked review pane close for $id" >&2
      return 1
    fi
    sleep 0.1
  done
  fm_nm_review_pane_close_locked "$state" "$id"
  rc=$?
  fm_lock_release "$lock_path" || true
  return "$rc"
}

fm_nm_review_pane_main() {
  local id="" close=0 arg
  for arg in "$@"; do
    case "$arg" in
      --close) close=1 ;;
      -h|--help)
        sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
        return 0
        ;;
      -*) echo "error: unknown option $arg" >&2; return 1 ;;
      *)
        [ -z "$id" ] || { echo "error: exactly one task id is accepted" >&2; return 1; }
        id=$arg
        ;;
    esac
  done
  [ -n "$id" ] || { echo "usage: fm-nm-review-pane.sh <task-id> [--close]" >&2; return 1; }
  case "$id" in
    */*|.*|'') echo "error: invalid task id $id" >&2; return 1 ;;
  esac
  FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_NM_REVIEW_PANE_LIB_DIR/.." && pwd)}}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  if [ "$close" = 1 ]; then
    fm_nm_review_pane_close "$STATE" "$id"
  else
    fm_nm_review_pane_ensure "$STATE" "$CONFIG" "$id"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_nm_review_pane_main "$@"
fi
