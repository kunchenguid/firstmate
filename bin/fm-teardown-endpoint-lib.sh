#!/usr/bin/env bash
# Endpoint phase owned by fm-teardown.sh, under its lease/control/meta locks.
# state/<id>.cleanup.json is the sole cleanup receipt: v1 task/spawn/goal
# binding, exact launch journal hash, and independent phase postconditions.
# No operation in this file returns a directory, releases a slot, resets git,
# traverses/kills processes by path, removes task metadata, or closes a whole
# workspace. v1/v2 projection journals retain legacy-identity-unproven.
# A confirmed close is never repeated; structured absence is verified again.

# Narrow replay hook for the existing backlog-close owner, which already
# validated the task generation under its metadata lock. No endpoint calls.
fm_teardown_cleanup_record_closed() {
  local STATE=$1 ID=$2 DATA=$3 lifecycle ENDPOINT_GENERATION ENDPOINT_GOAL ENDPOINT_RECEIPT
  # shellcheck source=bin/fm-task-lifecycle-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-task-lifecycle-lib.sh"
  lifecycle=$(fm_task_lifecycle read "$ID") || return 1
  ENDPOINT_GENERATION=$(printf '%s' "$lifecycle" | jq -r '.execution_generation')
  ENDPOINT_GOAL=$(printf '%s' "$lifecycle" | jq -r '.goal_revision')
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  teardown_endpoint_receipt record_close confirmed backlog-paired-resource-record-retained
}

teardown_endpoint_receipt() { # <phase> <pending|confirmed|retained> <reason>
  local phase=$1 status=$2 reason=$3 tmp
  tmp=$(umask 077; mktemp "$STATE/.${ID}.cleanup.XXXXXX") || return 1
  if [ -e "$ENDPOINT_RECEIPT" ] || [ -L "$ENDPOINT_RECEIPT" ]; then
    if ! fm_task_lifecycle cleanup-read "$ID" > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
  else
    jq -n --arg id "$ID" --arg generation "$ENDPOINT_GENERATION" --argjson goal "$ENDPOINT_GOAL" \
      '{schema:"fm-task-cleanup.v1",task_id:$id,spawn_gen:$generation,goal_revision:$goal,phases:{}}' > "$tmp"
  fi
  local updated
  updated=$(jq --arg phase "$phase" --arg status "$status" --arg reason "$reason" \
    '.phases[$phase]={state:$status,reason_code:$reason}' "$tmp") || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$updated" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ENDPOINT_RECEIPT" || return 1
  fm_task_lifecycle link-cleanup "$ID" >/dev/null
}

teardown_endpoint_refuse() { # <phase> <reason>
  teardown_endpoint_receipt "$1" retained "$2" || return 1
  printf 'REFUSED: endpoint cleanup %s: %s; directory and task records retained\n' "$ID" "$2" >&2
  return 1
}

teardown_endpoint_backlog() {
  local rc=0 marker
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$(fm_meta_get "$META" kind)" || rc=$?
  case "$rc" in
    1) teardown_endpoint_receipt record_close retained "$FM_BACKLOG_TRANSITION_SKIP"; return $? ;;
    0) ;;
    *) teardown_endpoint_refuse record_close backlog-capability-unavailable; return 1 ;;
  esac
  marker=$(fm_backlog_close_marker_path "$STATE" "$ID") || return 1
  teardown_endpoint_receipt record_close pending backlog-close || return 1
  fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$ENDPOINT_GENERATION" --cleanup-only || return 1
  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" || {
    teardown_endpoint_refuse record_close backlog-close-pending; return 1;
  }
  teardown_endpoint_receipt record_close confirmed backlog-paired-resource-record-retained
}

teardown_endpoint_directory_observation() {
  local path other count=0 dirty
  path=$(fm_meta_get "$META" worktree)
  ENDPOINT_DIRECTORY_RESULT=retained-independent-directory-guards
  if [ -z "$path" ]; then ENDPOINT_DIRECTORY_RESULT=retained-directory-unrecorded
  elif [ ! -e "$path" ] && [ ! -L "$path" ]; then ENDPOINT_DIRECTORY_RESULT=directory-already-missing
  else
    # References describe why directory work is deferred, not pane ownership.
    for other in "$STATE"/*.meta; do
      [ "$other" != "$META" ] && [ -f "$other" ] && [ ! -L "$other" ] || continue
      count=$((count + 1))
      [ "$count" -le 1000 ] || break
      if [ "$(fm_meta_get "$other" worktree)" = "$path" ]; then
        ENDPOINT_DIRECTORY_RESULT=retained-shared-reference
        break
      fi
    done
    if [ "$ENDPOINT_DIRECTORY_RESULT" = retained-independent-directory-guards ]; then
      dirty=$(fm_run_timed 2 env GIT_OPTIONAL_LOCKS=0 git -C "$path" status --porcelain --untracked-files=normal 2>/dev/null) || dirty=unverified
      if [ "$dirty" = unverified ]; then ENDPOINT_DIRECTORY_RESULT=retained-directory-unverified
      elif [ -n "$dirty" ]; then ENDPOINT_DIRECTORY_RESULT=retained-dirty
      fi
    fi
  fi
  teardown_endpoint_receipt directory_return retained "$ENDPOINT_DIRECTORY_RESULT"
}

teardown_endpoint_identity() {
  local info process start other count=0
  ENDPOINT_IDENTITY_REASON=terminal-identity-changed
  [ "$(fm_meta_get "$META" spawn_gen)" = "$ENDPOINT_GENERATION" ] || return 1
  # Another durable claimant is ambiguity, even if its task label is stale.
  # Bound the inspection and never acquire deletion authority from a path.
  for other in "$STATE"/*.meta; do
    [ "$other" != "$META" ] || continue
    [ -e "$other" ] || [ -L "$other" ] || continue
    count=$((count + 1))
    [ "$count" -le 1000 ] || { ENDPOINT_IDENTITY_REASON=claim-scan-bound; return 1; }
    [ -f "$other" ] && [ ! -L "$other" ] || { ENDPOINT_IDENTITY_REASON=unsafe-other-claim; return 1; }
    if [ "$(fm_meta_get "$other" herdr_session)" = "$ENDPOINT_SESSION" ] && \
       [ "$(fm_meta_get "$other" herdr_pane_id)" = "$ENDPOINT_PANE" ]; then
      ENDPOINT_IDENTITY_REASON=duplicate-endpoint-claim; return 1
    fi
  done
  [ "$(fm_task_lifecycle cleanup-binding "$ID")" = "$ENDPOINT_JOURNAL_HASH" ] || return 1
  [ "$(fm_backend_herdr_session_instance "$ENDPOINT_SESSION")" = "$ENDPOINT_INSTANCE" ] || return 1
  info=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" pane get "$ENDPOINT_PANE" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$ENDPOINT_PANE" --arg ws "$ENDPOINT_WORKSPACE" \
    --arg tab "$ENDPOINT_TAB" --arg terminal "$ENDPOINT_TERMINAL" \
    '.result.pane | .pane_id==$pane and .workspace_id==$ws and .tab_id==$tab and .terminal_id==$terminal' >/dev/null || return 1
  process=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" pane process-info --pane "$ENDPOINT_PANE" 2>/dev/null) || return 1
  printf '%s' "$process" | jq -e --arg pane "$ENDPOINT_PANE" --argjson pid "$ENDPOINT_SHELL" \
    '.result.process_info | .pane_id==$pane and .shell_pid==$pid' >/dev/null || return 1
  start=$(LC_ALL=C ps -p "$ENDPOINT_SHELL" -o lstart=) || return 1
  [ "$start" = "$ENDPOINT_SHELL_START" ]
}

teardown_endpoint_phase() { # <expected-spawn-gen>; leaves durable metadata intact
  local expected=$1 lifecycle journal lock before after before_ws after_ws siblings focus agent pane_status
  # shellcheck source=bin/fm-task-lifecycle-lib.sh
  . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
  lifecycle=$(fm_task_lifecycle read "$ID") || return 1
  printf '%s' "$lifecycle" | jq -e '.disposition=="accepted" or .disposition=="archived"' >/dev/null || {
    echo 'REFUSED: endpoint cleanup requires semantic acceptance or explicit archive' >&2; return 1;
  }
  ENDPOINT_GENERATION=$(printf '%s' "$lifecycle" | jq -r '.execution_generation')
  ENDPOINT_GOAL=$(printf '%s' "$lifecycle" | jq -r '.goal_revision')
  [ -n "$expected" ] && [ "$expected" = "$ENDPOINT_GENERATION" ] && \
    [ "$(fm_meta_get "$META" spawn_gen)" = "$expected" ] || return 1
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  teardown_endpoint_directory_observation || return 1
  teardown_endpoint_receipt record_close retained endpoint-only-keeps-records || return 1
  fm_task_lifecycle link-cleanup "$ID" >/dev/null || return 1
  [ "$(fm_meta_get "$META" kind)" != secondmate ] || { teardown_endpoint_refuse pane_close unsupported-secondmate; return 1; }
  [ "$(fm_meta_get "$META" backend)" = herdr ] || { teardown_endpoint_refuse pane_close unsupported-backend; return 1; }
  fm_backend_validate_task_endpoint "$META" "$ID" || { teardown_endpoint_refuse pane_close metadata-identity-invalid; return 1; }
  fm_backend_source herdr || return 1
  journal="$STATE/$ID.herdr-presentation"
  if ! fm_backend_herdr_projection_journal_snapshot "$journal" "$ID" || \
     [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" != 3 ]; then
    teardown_endpoint_refuse pane_close legacy-identity-unproven; return 1
  fi
  [ "$FM_BACKEND_HERDR_JOURNAL_SPAWN_GEN" = "$expected" ] && \
    [ "$FM_BACKEND_HERDR_JOURNAL_HOME" = "$(cd "$FM_HOME" && pwd -P)" ] || {
      teardown_endpoint_refuse pane_close launch-generation-mismatch; return 1;
    }
  ENDPOINT_SESSION=$FM_BACKEND_HERDR_JOURNAL_SESSION
  ENDPOINT_WORKSPACE=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID
  ENDPOINT_TAB=$FM_BACKEND_HERDR_JOURNAL_TAB_ID
  ENDPOINT_PANE=$FM_BACKEND_HERDR_JOURNAL_PANE_ID
  ENDPOINT_TERMINAL=$FM_BACKEND_HERDR_JOURNAL_TERMINAL_ID
  ENDPOINT_INSTANCE=$FM_BACKEND_HERDR_JOURNAL_SESSION_INSTANCE
  ENDPOINT_SHELL=$FM_BACKEND_HERDR_JOURNAL_SHELL_PID
  ENDPOINT_SHELL_START=$FM_BACKEND_HERDR_JOURNAL_SHELL_START
  ENDPOINT_JOURNAL_HASH=$(fm_task_lifecycle cleanup-binding "$ID") || {
    teardown_endpoint_refuse pane_close launch-binding-changed; return 1;
  }
  local binding_tmp
  binding_tmp=$(umask 077; mktemp "$STATE/.${ID}.cleanup-binding.XXXXXX") || return 1
  jq --arg sha "$ENDPOINT_JOURNAL_HASH" '.journal_sha256=$sha' "$ENDPOINT_RECEIPT" > "$binding_tmp" \
    && mv -f "$binding_tmp" "$ENDPOINT_RECEIPT" || return 1
  fm_task_lifecycle link-cleanup "$ID" >/dev/null || return 1
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$ENDPOINT_SESSION:$ENDPOINT_PANE" ] || {
    teardown_endpoint_refuse pane_close endpoint-binding-mismatch; return 1;
  }
  lock=$(fm_backend_herdr_presentation_session_lock_path "$ENDPOINT_SESSION") || {
    teardown_endpoint_refuse pane_close session-unreadable; return 1;
  }
  fm_lock_try_acquire "$lock" || { teardown_endpoint_refuse pane_close presentation-lock-contended; return 1; }
  ENDPOINT_SESSION_LOCK=$lock
  [ "$(fm_backend_herdr_presentation_session_lock_path "$ENDPOINT_SESSION")" = "$lock" ] && \
    [ "$(fm_backend_herdr_session_instance "$ENDPOINT_SESSION")" = "$ENDPOINT_INSTANCE" ] || {
    teardown_endpoint_refuse pane_close session-instance-changed; return 1;
  }
  pane_status=$(fm_backend_herdr_pane_presence_state "$ENDPOINT_SESSION" "$ENDPOINT_PANE")
  case "$pane_status" in
    dead)
      if ! fm_task_lifecycle cleanup-read "$ID" | jq -e '.phases.agent_exit.state=="confirmed"' >/dev/null; then
        teardown_endpoint_receipt agent_exit retained agent-state-unknown || return 1
      fi
      teardown_endpoint_receipt pane_close confirmed already-absent || return 1
      ;;
    present)
      teardown_endpoint_identity || { teardown_endpoint_refuse pane_close "$ENDPOINT_IDENTITY_REASON"; return 1; }
      fm_backend_herdr_projection_target_tab_mutation_allowed "$ENDPOINT_SESSION" "$ENDPOINT_TAB" || {
        teardown_endpoint_refuse agent_exit focused-or-unverified-target-tab; return 1;
      }
      # Undelivered outcomes and real decisions remain gates before mutation.
      if [ "$(fm_meta_get "$META" kind)" = scout ]; then
        if [ ! -f "$DATA/$ID/report.md" ] || \
          ! "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null; then
          teardown_endpoint_refuse pane_close completion-gate-pending; return 1;
        fi
      fi
      "$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$ID" || {
        teardown_endpoint_refuse pane_close parent-result-undelivered; return 1;
      }
      agent=$(fm_backend_herdr_pane_agent_state "$ENDPOINT_SESSION" "$ENDPOINT_PANE")
      case "$agent" in
        live) teardown_endpoint_receipt agent_exit pending graceful-control-exit || return 1; return 11 ;;
        dead|no-agent|stale-agent) ;; # Strict idle-shell proof below remains mandatory.
        *) teardown_endpoint_refuse agent_exit agent-state-unknown; return 1 ;;
      esac
      [ "$(fm_backend_herdr_pane_idle_shell_pid "$ENDPOINT_SESSION" "$ENDPOINT_PANE")" = "$ENDPOINT_SHELL" ] || {
        teardown_endpoint_refuse pane_close active-or-unknown-processes; return 1;
      }
      teardown_endpoint_receipt agent_exit confirmed agent-stopped || return 1
      before=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" pane list) || return 1
      before_ws=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" workspace list) || return 1
      siblings=$(printf '%s' "$before" | jq -ce --arg pane "$ENDPOINT_PANE" \
        '.result.panes | select(type=="array") | map(select(.pane_id!=$pane) | {pane_id,terminal_id,tab_id,workspace_id,focused}) | sort_by(.pane_id)') || return 1
      focus=$(printf '%s' "$before_ws" | jq -ce '[.result.workspaces[] | select(.focused==true) | {workspace_id,active_tab_id}]') || return 1
      local snapshot_tmp
      snapshot_tmp=$(mktemp "$STATE/.${ID}.cleanup-snapshot.XXXXXX") || return 1
      jq --argjson siblings "$siblings" --argjson focus "$focus" \
        --arg terminal "$ENDPOINT_TERMINAL" --arg instance "$ENDPOINT_INSTANCE" \
        '.pre_close={siblings:$siblings,focus:$focus,terminal:$terminal,instance:$instance}' \
        "$ENDPOINT_RECEIPT" > "$snapshot_tmp" && mv -f "$snapshot_tmp" "$ENDPOINT_RECEIPT" || return 1
      teardown_endpoint_receipt pane_close pending exact-pane-close || return 1
      teardown_endpoint_identity && \
        [ "$(fm_backend_herdr_pane_idle_shell_pid "$ENDPOINT_SESSION" "$ENDPOINT_PANE")" = "$ENDPOINT_SHELL" ] || {
        teardown_endpoint_refuse pane_close identity-changed-before-close; return 1;
      }
      fm_backend_herdr_projection_close_pane_focus_preserving "$ENDPOINT_SESSION" "$ENDPOINT_PANE" || {
        teardown_endpoint_refuse pane_close close-refused-or-unknown; return 1;
      }
      fm_backend_herdr_endpoint_confirmed_gone "$ENDPOINT_SESSION:$ENDPOINT_PANE" || {
        teardown_endpoint_refuse pane_close absence-unconfirmed; return 1;
      }
      teardown_endpoint_receipt pane_close confirmed exact-pane-absent || return 1
      after=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" pane list) || return 1
      after_ws=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" workspace list) || return 1
      [ "$(printf '%s' "$after" | jq -c '[.result.panes[] | {pane_id,terminal_id,tab_id,workspace_id,focused}] | sort_by(.pane_id)')" = "$siblings" ] && \
        [ "$(printf '%s' "$after_ws" | jq -c '[.result.workspaces[] | select(.focused==true) | {workspace_id,active_tab_id}]')" = "$focus" ] || {
        teardown_endpoint_refuse workspace_remove unrelated-resource-changed; return 1;
      }
      ;;
    *) teardown_endpoint_refuse pane_close presence-unknown; return 1 ;;
  esac
  # Replay verifies the persisted pre-close snapshot as well. A crash after
  # close must not turn an unverified unrelated-resource change into success.
  if jq -e '.pre_close != null' "$ENDPOINT_RECEIPT" >/dev/null; then
    after=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" pane list) || return 1
    after_ws=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" workspace list) || return 1
    siblings=$(jq -c '.pre_close.siblings' "$ENDPOINT_RECEIPT")
    focus=$(jq -c '.pre_close.focus' "$ENDPOINT_RECEIPT")
    [ "$(printf '%s' "$after" | jq -c '[.result.panes[] | {pane_id,terminal_id,tab_id,workspace_id,focused}] | sort_by(.pane_id)')" = "$siblings" ] && \
      [ "$(printf '%s' "$after_ws" | jq -c '[.result.workspaces[] | select(.focused==true) | {workspace_id,active_tab_id}]')" = "$focus" ] || {
      teardown_endpoint_refuse workspace_remove unrelated-resource-changed; return 1;
    }
  fi
  after_ws=$(fm_backend_herdr_cli "$ENDPOINT_SESSION" workspace list) || return 1
  if printf '%s' "$after_ws" | jq -e --arg ws "$ENDPOINT_WORKSPACE" \
    '.result.workspaces | select(type=="array") | all(.workspace_id!=$ws)' >/dev/null; then
    teardown_endpoint_receipt workspace_remove confirmed workspace-absent || return 1
    printf 'workspace removed: %s; directory=%s; report retained\n' "$ID" "$ENDPOINT_DIRECTORY_RESULT"
  elif printf '%s' "$after_ws" | jq -e --arg ws "$ENDPOINT_WORKSPACE" \
    '.result.workspaces | select(type=="array") | any(.workspace_id==$ws)' >/dev/null; then
    teardown_endpoint_receipt workspace_remove retained mixed-workspace || return 1
    printf 'task pane removed: %s; mixed workspace retained; directory=%s; report retained\n' "$ID" "$ENDPOINT_DIRECTORY_RESULT"
  else
    teardown_endpoint_refuse workspace_remove presence-unknown; return 1
  fi
  teardown_endpoint_backlog
}
