#!/usr/bin/env bash
# Automatically reap terminal crewmate resources through fm-teardown.sh.
#
# `task <id> <pr-merged|scout-done|local-merged>` validates the terminal event,
# reaps an exactly-attributed no-mistakes run when necessary, and delegates all
# endpoint, cleanliness, landing, report, and Treehouse-return proofs to ordinary
# teardown without --force.
#
# `maintenance` recovers pre-metadata Treehouse acquisitions left by a crashed
# spawn. A record is eligible only after an age threshold and exact PID/start-time
# death proof. Recovery installs fail-closed cleanup metadata, then invokes the
# same ordinary teardown proof. Every refusal stays on disk and is printed.
# Usage: fm-auto-reap.sh task <id> <pr-merged|scout-done|local-merged>
#        fm-auto-reap.sh maintenance
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
AUTO_REAP_STALE_SECS=${FM_AUTO_REAP_STALE_SECS:-300}
AUTO_REAP_COMMAND_TIMEOUT=${FM_AUTO_REAP_COMMAND_TIMEOUT:-20}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$SCRIPT_DIR/fm-treehouse-lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"

case "$AUTO_REAP_STALE_SECS:$AUTO_REAP_COMMAND_TIMEOUT" in
  *[!0-9:]*|0:*|*:0)
    echo "error: auto-reap age and command timeouts must be positive integers" >&2
    exit 2
    ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: auto-reap state must be a real directory: $STATE" >&2
  exit 1
}

auto_reap_tool() {  # <override-variable> <default-command>
  local variable=$1 fallback=$2 value
  eval "value=\${$variable:-}"
  if [ -n "$value" ]; then
    [ "${FM_AUTO_REAP_TEST_HOOKS:-}" = firstmate-auto-reap-tests-v1 ] || {
      echo "error: $variable requires the explicit auto-reap test hook" >&2
      return 1
    }
    [ -x "$value" ] || return 1
    printf '%s\n' "$value"
    return 0
  fi
  command -v "$fallback"
}

meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" | tail -1
}

single_meta_value() {  # <file> <key>
  local file=$1 key=$2 values count
  values=$(sed -n "s/^${key}=//p" "$file")
  count=$(printf '%s\n' "$values" | awk 'NF { n++ } END { print n + 0 }')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$values"
}

status_last_verb() {  # <task>
  local last
  last=$(grep -v '^[[:space:]]*$' "$STATE/$1.status" 2>/dev/null | tail -1)
  last=${last%%:*}
  last=${last%%\[key=*}
  printf '%s' "$last" | tr -d '[:space:]'
}

refuse() {
  printf 'auto-reap refused %s: %s\n' "${AUTO_REAP_ID:-maintenance}" "$*" >&2
  return 1
}

log_result() {
  local line=$1 log="$STATE/.auto-reap.log" size tmp
  [ ! -L "$log" ] && { [ ! -e "$log" ] || [ -f "$log" ]; } || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line" >> "$log" 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge 262144 ]; then
    tmp=$(mktemp "$STATE/.auto-reap-log.XXXXXX") || return 0
    tail -n 2000 "$log" > "$tmp" 2>/dev/null && mv "$tmp" "$log" 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
  fi
}

run_capture() {  # <output-variable> <command> [args...]
  local output_variable=$1
  shift
  if fm_run_bounded_capture --combine-stderr "$output_variable" "$AUTO_REAP_COMMAND_TIMEOUT" "$@"; then
    RUN_CAPTURE_STATUS=0
  else
    RUN_CAPTURE_STATUS=$?
  fi
  fm_process_tree_cleanup_verified || {
    echo "error: bounded auto-reap command cleanup could not be verified" >&2
    return 1
  }
  return 0
}

parse_pr_url() {  # <url>
  local url=$1 rest
  case "$url" in
    https://github.com/*/*/pull/[0-9]*) ;;
    *) return 1 ;;
  esac
  rest=${url#https://github.com/}
  PR_OWNER=${rest%%/*}
  rest=${rest#*/}
  PR_REPO=${rest%%/*}
  rest=${rest#*/pull/}
  PR_NUMBER=${rest%%[/?#]*}
  case "$PR_OWNER:$PR_REPO:$PR_NUMBER" in
    *[!A-Za-z0-9._:/-]*|::*|*::*|*:) return 1 ;;
  esac
  case "$PR_NUMBER" in ''|*[!0-9]*) return 1 ;; esac
}

pr_is_merged() {  # <meta>
  local meta=$1 pr gh captured
  pr=$(meta_value "$meta" pr)
  parse_pr_url "$pr" || {
    refuse "recorded PR URL is missing or invalid"
    return 1
  }
  gh=$(auto_reap_tool FM_AUTO_REAP_GH_AXI_BIN gh-axi) || {
    refuse "gh-axi is unavailable"
    return 1
  }
  run_capture captured "$gh" pr view "$PR_NUMBER" -R "$PR_OWNER/$PR_REPO" || return 1
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "gh-axi could not verify PR $PR_NUMBER as merged"
    return 1
  }
  [ "$(printf '%s\n' "$captured" | grep -Ec '^[[:space:]]*state:[[:space:]]*merged[[:space:]]*$')" -eq 1 ] || {
    refuse "PR $PR_NUMBER is not provably merged"
    return 1
  }
}

reap_no_mistakes_run() {  # <meta>
  local meta=$1 worktree branch nm captured run_branch run_id run_status outcome runs_output row status rest row_branch
  [ "$(meta_value "$meta" mode)" = no-mistakes ] || return 0
  worktree=$(meta_value "$meta" worktree)
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = "fm/$AUTO_REAP_ID" ] || {
    refuse "no-mistakes run attribution requires exact branch fm/$AUTO_REAP_ID"
    return 1
  }
  nm=$(auto_reap_tool FM_AUTO_REAP_NO_MISTAKES_BIN no-mistakes) || {
    refuse "no-mistakes is unavailable for exact run reaping"
    return 1
  }
  if run_capture captured env -C "$worktree" "$nm" axi status; then :; else return 1; fi
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "no-mistakes status could not be inspected safely"
    return 1
  }
  run_branch=$(printf '%s\n' "$captured" | sed -n 's/^[[:space:]]*branch:[[:space:]]*//p' | head -1)
  run_branch=${run_branch#\"}
  run_branch=${run_branch%\"}
  if [ "$run_branch" = "$branch" ]; then
    run_id=$(printf '%s\n' "$captured" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -1)
    run_id=${run_id#\"}
    run_id=${run_id%\"}
    run_status=$(printf '%s\n' "$captured" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)
    run_status=${run_status#\"}
    run_status=${run_status%\"}
    outcome=$(printf '%s\n' "$captured" | sed -n 's/^[[:space:]]*outcome:[[:space:]]*//p' | head -1)
    outcome=${outcome#\"}
    outcome=${outcome%\"}
    [ -n "$run_id" ] || {
      refuse "matching no-mistakes run has no exact run ID"
      return 1
    }
    if [ -z "$outcome" ] && [ "$run_status" != completed ] \
      && [ "$run_status" != cancelled ] && [ "$run_status" != failed ]; then
      if run_capture captured "$nm" axi abort --run "$run_id"; then :; else return 1; fi
      [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
        refuse "failed to cancel exact no-mistakes run $run_id"
        return 1
      }
      log_result "cancelled no-mistakes run $run_id for $AUTO_REAP_ID"
    fi
    return 0
  fi
  if run_capture runs_output env -C "$worktree" "$nm" runs --limit 200; then :; else return 1; fi
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "cross-branch no-mistakes attribution could not be inspected"
    return 1
  }
  while IFS= read -r row; do
    row=$(printf '%s' "$row" | sed 's/^[[:space:]]*//')
    [ -n "$row" ] || continue
    status=${row%%[[:space:]]*}
    rest=${row#"$status"}
    rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
    row_branch=${rest%%[[:space:]]*}
    [ "$row_branch" = "$branch" ] || continue
    case "$status" in
      running)
        refuse "branch still has an active no-mistakes run but its exact run ID is unavailable"
        return 1
        ;;
    esac
    return 0
  done <<EOF
$runs_output
EOF
}

run_teardown() {  # <task>
  local task=$1 teardown output
  teardown=$(auto_reap_tool FM_AUTO_REAP_TEARDOWN_BIN fm-teardown.sh 2>/dev/null || true)
  [ -n "$teardown" ] || teardown="$SCRIPT_DIR/fm-teardown.sh"
  if output=$("$teardown" "$task" 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    log_result "auto-reaped $task"
    printf 'auto-reaped %s\n' "$task"
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  refuse "ordinary teardown refused; retained endpoint/worktree metadata"
}

reap_task() {  # <task> <trigger>
  local id=$1 trigger=$2 meta kind mode
  AUTO_REAP_ID=$id
  fm_account_valid_id "$id" || refuse "invalid task id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || refuse "task metadata is unavailable"
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(meta_value "$meta" mode)
  [ -z "$(meta_value "$meta" x_request)" ] || refuse "X-linked tasks require their final follow-up before teardown"
  [ "$kind" != secondmate ] || refuse "persistent secondmates are never auto-reaped"
  [ "$(status_last_verb "$id")" = "done" ] || refuse "last task status is not terminal done"
  case "$trigger:$kind:$mode" in
    pr-merged:ship:local-only) refuse "local-only tasks cannot use a PR-merged trigger" ;;
    pr-merged:ship:*)
      [ "${AUTO_REAP_PR_VERIFIED:-0}" = 1 ] || pr_is_merged "$meta" || return 1
      ;;
    scout-done:scout:*) ;;
    local-merged:ship:local-only) ;;
    *) refuse "trigger $trigger does not match kind=$kind mode=${mode:-no-mistakes}" ;;
  esac
  reap_no_mistakes_run "$meta" || return 1
  run_teardown "$id"
}

path_age() {
  local path=$1 mtime
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$path" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$path" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$(( $(date +%s) - mtime ))"
}

recover_acquisition() {  # <record>
  local record=$1 id project holder recorded_worktree worktree snapshot owner_state lock tmp find_status absence_status
  local recorded_home home_real generation tasktmp tasktmp_phase endpoint_phase backend endpoint_window
  local tmux_window_id tmux_session_target herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id
  local zellij_session zellij_tab_id zellij_pane_id cmux_workspace_id cmux_surface_id
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  [ "$(path_age "$record")" -ge "$AUTO_REAP_STALE_SECS" ] || return 0
  AUTO_REAP_ID=${record##*/.worktree-acquire-}
  AUTO_REAP_ID=${AUTO_REAP_ID%.pending}
  if fm_account_lock_owner_state "$record"; then owner_state=0; else owner_state=$?; fi
  case "$owner_state" in
    0) return 0 ;;
    1) ;;
    2)
      refuse "stale acquisition owner liveness is indeterminate"
      return 0
      ;;
    *)
      refuse "stale acquisition owner record is malformed"
      return 0
      ;;
  esac
  id=$(single_meta_value "$record" id) || {
    refuse "stale acquisition record has invalid task identity"
    return 0
  }
  if [ "$id" != "$AUTO_REAP_ID" ] || ! fm_account_valid_id "$id"; then
    refuse "stale acquisition filename does not match its task identity"
    return 0
  fi
  project=$(single_meta_value "$record" project) || {
    refuse "stale acquisition record has invalid project"
    return 0
  }
  holder=$(single_meta_value "$record" holder) || {
    refuse "stale acquisition record has invalid lease holder"
    return 0
  }
  [ "$holder" = "firstmate-$id" ] || {
    refuse "stale acquisition lease holder does not match task"
    return 0
  }
  recorded_home=$(single_meta_value "$record" home) || {
    refuse "stale acquisition record has missing or malformed FM_HOME ownership"
    return 0
  }
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 0
  [ "$recorded_home" = "$home_real" ] || {
    refuse "stale acquisition record belongs to a different canonical FM_HOME"
    return 0
  }
  generation=$(single_meta_value "$record" generation_id) || {
    refuse "stale acquisition record has missing or malformed generation ownership"
    return 0
  }
  tasktmp=$(single_meta_value "$record" tasktmp) || {
    refuse "stale acquisition record has missing or malformed task temp ownership"
    return 0
  }
  fm_account_task_tmp_is_current "$id" "$tasktmp" "$generation" || {
    refuse "stale acquisition task temp path does not match its exact generation"
    return 0
  }
  tasktmp_phase=$(single_meta_value "$record" tasktmp_phase) || {
    refuse "stale acquisition record has missing or malformed task temp phase"
    return 0
  }
  case "$tasktmp_phase" in
    not-created|created) ;;
    *) refuse "stale acquisition record has invalid task temp phase"; return 0 ;;
  esac
  endpoint_phase=$(single_meta_value "$record" endpoint_phase) || {
    refuse "stale acquisition record has missing or malformed endpoint phase"
    return 0
  }
  case "$endpoint_phase" in
    not-created|creating|created) ;;
    *) refuse "stale acquisition record has invalid endpoint phase"; return 0 ;;
  esac
  backend=$(single_meta_value "$record" backend) || {
    refuse "stale acquisition record has missing or malformed backend"
    return 0
  }
  case "$backend" in tmux|herdr|zellij|cmux) ;; *) refuse "stale acquisition record has unsupported backend"; return 0 ;; esac
  if [ "$endpoint_phase" = not-created ]; then
    if grep -Eq '^(window|tmux_window_id|tmux_session_target|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|zellij_session|zellij_tab_id|zellij_pane_id|cmux_workspace_id|cmux_surface_id)=.+' "$record"; then
      refuse "never-created endpoint phase contains endpoint identity"
      return 0
    fi
    endpoint_window=
  elif [ "$endpoint_phase" = created ]; then
    endpoint_window=$(single_meta_value "$record" window) || {
      refuse "created endpoint phase has no exact window identity"
      return 0
    }
    case "$backend" in
      tmux)
        tmux_window_id=$(single_meta_value "$record" tmux_window_id) || { refuse "created tmux endpoint has no stable window id"; return 0; }
        tmux_session_target=$(single_meta_value "$record" tmux_session_target) || { refuse "created tmux endpoint has no scoped session target"; return 0; }
        [ "$endpoint_window" = "$tmux_session_target" ] || { refuse "created tmux endpoint identities disagree"; return 0; }
        ;;
      herdr)
        herdr_session=$(single_meta_value "$record" herdr_session) || { refuse "created Herdr endpoint has no session identity"; return 0; }
        herdr_workspace_id=$(single_meta_value "$record" herdr_workspace_id) || { refuse "created Herdr endpoint has no workspace identity"; return 0; }
        herdr_tab_id=$(single_meta_value "$record" herdr_tab_id) || { refuse "created Herdr endpoint has no tab identity"; return 0; }
        herdr_pane_id=$(single_meta_value "$record" herdr_pane_id) || { refuse "created Herdr endpoint has no pane identity"; return 0; }
        [ "$endpoint_window" = "$herdr_session:$herdr_pane_id" ] || { refuse "created Herdr endpoint identities disagree"; return 0; }
        ;;
      zellij)
        zellij_session=$(single_meta_value "$record" zellij_session) || { refuse "created Zellij endpoint has no session identity"; return 0; }
        zellij_tab_id=$(single_meta_value "$record" zellij_tab_id) || { refuse "created Zellij endpoint has no tab identity"; return 0; }
        zellij_pane_id=$(single_meta_value "$record" zellij_pane_id) || { refuse "created Zellij endpoint has no pane identity"; return 0; }
        [ "$endpoint_window" = "$zellij_session:$zellij_pane_id" ] || { refuse "created Zellij endpoint identities disagree"; return 0; }
        ;;
      cmux)
        cmux_workspace_id=$(single_meta_value "$record" cmux_workspace_id) || { refuse "created cmux endpoint has no workspace identity"; return 0; }
        cmux_surface_id=$(single_meta_value "$record" cmux_surface_id) || { refuse "created cmux endpoint has no surface identity"; return 0; }
        [ "$endpoint_window" = "$cmux_workspace_id:$cmux_surface_id" ] || { refuse "created cmux endpoint identities disagree"; return 0; }
        ;;
    esac
  fi
  snapshot=$(cat "$record") || return 0
  lock=$(fm_account_lifecycle_lock_acquire "$STATE" "$id") || {
    refuse "could not serialize stale acquisition recovery"
    return 0
  }
  if [ "$(cat "$record" 2>/dev/null || true)" != "$snapshot" ]; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    refuse "stale acquisition record changed during recovery"
    return 0
  fi
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    refuse "task metadata exists; retained stale acquisition for operator reconciliation"
    return 0
  fi
  if [ "$endpoint_phase" = creating ]; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    refuse "endpoint creation phase is ambiguous; retained stale acquisition for exact endpoint reconciliation"
    return 0
  fi
  if [ "$tasktmp_phase" = not-created ]; then
    if [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; then
      fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
      refuse "not-created task temp phase has a task temp root; retained stale acquisition"
      return 0
    fi
  elif { [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; } \
    && { [ ! -d "$tasktmp" ] || [ -L "$tasktmp" ]; }; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    refuse "created task temp phase has an unsafe root; retained stale acquisition"
    return 0
  fi
  recorded_worktree=$(sed -n 's/^worktree=//p' "$record" | tail -1)
  if [ -n "$recorded_worktree" ]; then
    worktree=$(fm_checkout_trusted_dir "$recorded_worktree" 2>/dev/null || true)
    [ -n "$worktree" ] && fm_treehouse_require_task_lease "$worktree" "$holder" >/dev/null 2>&1 || worktree=
  else
    worktree=
  fi
  if [ -z "$worktree" ]; then
    if worktree=$(fm_treehouse_find_task_lease "$project" "$holder" 2>/dev/null); then
      find_status=0
    else
      find_status=$?
    fi
    if [ "$find_status" -eq 2 ]; then
      if fm_treehouse_prove_task_lease_absent "$recorded_worktree" "$holder" >/dev/null 2>&1; then
        absence_status=0
      else
        absence_status=$?
      fi
      if [ "$absence_status" -eq 0 ]; then
        if [ "$tasktmp_phase" = created ]; then
          fm_account_safe_remove_task_tmp "$id" "$tasktmp" "$generation" || {
            fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
            refuse "Treehouse lease is absent but task temp ownership is unsafe or ambiguous; retained stale acquisition"
            return 0
          }
        fi
        rm -f "$record"
        fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
        log_result "cleared owner-dead acquisition $id after proving it owns no Treehouse lease"
        printf 'auto-reap cleared %s: owner is dead and no Treehouse lease exists\n' "$id"
        return 0
      fi
      fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
      if [ "$absence_status" -eq 2 ]; then
        log_result "CORRUPT authoritative Treehouse lease state retained owner-dead acquisition $id"
        refuse "CORRUPT authoritative Treehouse lease state; retained stale acquisition" || true
        return 0
      fi
      log_result "retained owner-dead acquisition $id because Treehouse lease absence could not be proven"
      refuse "retained stale acquisition because Treehouse lease absence could not be proven" || true
      return 0
    fi
  fi
  [ -n "$worktree" ] || {
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    refuse "exact stranded Treehouse lease is not uniquely provable"
    return 0
  }
  tmp=$(mktemp "$STATE/.$id.meta.auto-reap.XXXXXX") || {
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    return 0
  }
  {
    printf 'window=%s\n' "$endpoint_window"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf 'harness=unknown\nkind=ship\n'
    printf 'mode=%s\n' "$(single_meta_value "$record" mode 2>/dev/null || printf no-mistakes)"
    printf 'yolo=%s\n' "$(single_meta_value "$record" yolo 2>/dev/null || printf off)"
    printf 'tasktmp=%s\ntasktmp_phase=%s\nmodel=default\neffort=default\n' "$tasktmp" "$tasktmp_phase"
    printf 'generation_id=%s\n' "$generation"
    printf 'backend=%s\n' "$backend"
    if [ "$endpoint_phase" = not-created ]; then
      printf 'direct_spawn_endpoint=not-created\n'
    else
      case "$backend" in
        tmux)
          printf 'tmux_window_id=%s\ntmux_session_target=%s\n' "$tmux_window_id" "$tmux_session_target"
          ;;
        herdr)
          printf 'herdr_session=%s\nherdr_workspace_id=%s\n' "$herdr_session" "$herdr_workspace_id"
          printf 'herdr_tab_id=%s\nherdr_pane_id=%s\n' "$herdr_tab_id" "$herdr_pane_id"
          ;;
        zellij)
          printf 'zellij_session=%s\nzellij_tab_id=%s\nzellij_pane_id=%s\n' "$zellij_session" "$zellij_tab_id" "$zellij_pane_id"
          ;;
        cmux)
          printf 'cmux_workspace_id=%s\ncmux_surface_id=%s\n' "$cmux_workspace_id" "$cmux_surface_id"
          ;;
      esac
    fi
    printf 'direct_spawn_cleanup=pending\nrollback_pending=1\n'
  } > "$tmp"
  mv "$tmp" "$STATE/$id.meta" || {
    rm -f "$tmp"
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    return 0
  }
  fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || {
    refuse "failed to release recovery lifecycle lock"
    return 0
  }
  if run_teardown "$id"; then
    rm -f "$record"
  fi
}

maintenance() {
  local record meta id kind mode probe_status
  for record in "$STATE"/.worktree-acquire-*.pending; do
    [ -e "$record" ] || continue
    recover_acquisition "$record"
  done
  # Backstop terminal events even when a task-specific check or turn-end signal
  # was missed while no watcher was running. An ordinary open PR is expected and
  # stays silent; once GitHub proves merged, every subsequent refusal is surfaced.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_account_valid_id "$id" || continue
    [ "$(status_last_verb "$id")" = "done" ] || continue
    [ -z "$(meta_value "$meta" x_request)" ] || continue
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    mode=$(meta_value "$meta" mode)
    case "$kind:$mode" in
      scout:*)
        reap_task "$id" scout-done
        ;;
      ship:local-only)
        # The approved merge action calls auto-reap synchronously. Do not probe
        # an unapproved local branch as if it were a terminal merge.
        ;;
      ship:*)
        [ -n "$(meta_value "$meta" pr)" ] || continue
        AUTO_REAP_ID=$id
        if pr_is_merged "$meta" >/dev/null 2>&1; then
          probe_status=0
        else
          probe_status=$?
        fi
        [ "$probe_status" -eq 0 ] || continue
        AUTO_REAP_PR_VERIFIED=1 reap_task "$id" pr-merged
        ;;
    esac
  done
}

case "${1:-}" in
  task)
    [ "$#" -eq 3 ] || { echo "usage: fm-auto-reap.sh task <id> <trigger>" >&2; exit 2; }
    reap_task "$2" "$3"
    ;;
  maintenance)
    [ "$#" -eq 1 ] || { echo "usage: fm-auto-reap.sh maintenance" >&2; exit 2; }
    maintenance
    ;;
  *)
    echo "usage: fm-auto-reap.sh task <id> <trigger> | maintenance" >&2
    exit 2
    ;;
esac
