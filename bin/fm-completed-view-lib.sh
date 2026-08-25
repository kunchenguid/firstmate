#!/usr/bin/env bash
# fm-completed-view-lib.sh - single owner of completed-task presentation policy,
# configuration, bounded records, sanitized summaries, and Herdr parking state.
#
# The feature is deliberately opt-in. config/herdr-completed-task-views accepts
# only "on" or "off" (absent means off). It is supported only for successful,
# non-forced ordinary task cleanup on the Herdr backend. tmux, Zellij, Orca,
# cmux, unknown backends, unavailable process inspection, malformed state, and
# capacity exhaustion all keep the ordinary cleanup path and create no view.
#
# A successful retained view lives entirely outside the disposable worktree:
#   state/completed-task-views/<task-id>.summary  bounded display text
#   state/completed-task-views/<task-id>.view     exact Herdr identity record
#
# Record format is authoritative here. Version 1 is a pre-create journal with
# no cleanup authority. Version 2 binds the exact home, session, workspace, tab,
# pane, and immutable token-derived label. Labels and tokens remain correlation
# only; dismiss requires the version 2 ids, exact live topology, no registered
# agent, and the Herdr presentation lock. A normal view is retained until an
# explicit dismiss. The hard cap refuses a ninth view rather than evicting an
# existing one, so retention cannot grow without limit and explicit dismissal
# remains the only successful-view removal path.

FM_COMPLETED_VIEW_CONFIG=herdr-completed-task-views
FM_COMPLETED_VIEW_DIR=completed-task-views
FM_COMPLETED_VIEW_LIMIT=8
FM_COMPLETED_VIEW_LIST_LIMIT=32
FM_COMPLETED_VIEW_RECORD_SUFFIX=.view
FM_COMPLETED_VIEW_SUMMARY_SUFFIX=.summary

fm_completed_view_valid_task_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_completed_view_preference() {  # <config-dir>
  local config_dir=${1:-} file value
  [ -n "$config_dir" ] || { printf 'off\n'; return 0; }
  file="$config_dir/$FM_COMPLETED_VIEW_CONFIG"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || {
      echo "warning: $file is not a regular local config file; completed-task views remain off" >&2
      printf 'off\n'
      return 0
    }
  else
    printf 'off\n'
    return 0
  fi
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || value=
  case "$value" in
    on) printf 'on\n' ;;
    off|'') printf 'off\n' ;;
    *)
      echo "warning: $file: unrecognized value \"$value\"; completed-task views remain off (write \"on\" to enable)" >&2
      printf 'off\n'
      ;;
  esac
}

fm_completed_view_backend_supported() {  # <backend>
  case "$1" in
    herdr) return 0 ;;
    tmux|zellij|orca|cmux) return 1 ;;
    *) return 2 ;;
  esac
}

fm_completed_view_directory_path() {  # <state-dir>
  printf '%s/%s' "$1" "$FM_COMPLETED_VIEW_DIR"
}

fm_completed_view_record_path() {  # <state-dir> <task-id>
  printf '%s/%s/%s%s' "$1" "$FM_COMPLETED_VIEW_DIR" "$2" "$FM_COMPLETED_VIEW_RECORD_SUFFIX"
}

fm_completed_view_summary_path() {  # <state-dir> <task-id>
  printf '%s/%s/%s%s' "$1" "$FM_COMPLETED_VIEW_DIR" "$2" "$FM_COMPLETED_VIEW_SUMMARY_SUFFIX"
}

fm_completed_view_directory_ensure() {  # <state-dir>
  local state=$1 dir
  dir=$(fm_completed_view_directory_path "$state")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || {
      echo "warning: completed-task view state path is not a safe directory: $dir" >&2
      return 1
    }
  else
    mkdir -m 700 "$dir" 2>/dev/null || {
      echo "warning: could not create completed-task view state directory: $dir" >&2
      return 1
    }
  fi
  printf '%s' "$dir"
}

fm_completed_view_record_field() {  # <record> <key>
  local record=$1 key=$2 count
  count=$(grep -c "^${key}=" "$record" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$record" 2>/dev/null | cut -d= -f2-
}

# Load and validate either the version 1 pre-create journal or a version 2
# exact parked-view binding. Output lives in FM_COMPLETED_VIEW_RECORD_* globals.
fm_completed_view_record_load() {  # <state-dir> <task-id>
  local state=$1 id=$2 record lines expected_label exact home_abs
  FM_COMPLETED_VIEW_RECORD_VERSION=
  FM_COMPLETED_VIEW_RECORD_PHASE=
  FM_COMPLETED_VIEW_RECORD_TASK_ID=
  FM_COMPLETED_VIEW_RECORD_TOKEN=
  FM_COMPLETED_VIEW_RECORD_HOME=
  FM_COMPLETED_VIEW_RECORD_SESSION=
  FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID=
  FM_COMPLETED_VIEW_RECORD_TAB_ID=
  FM_COMPLETED_VIEW_RECORD_PANE_ID=
  FM_COMPLETED_VIEW_RECORD_LABEL=
  fm_completed_view_valid_task_id "$id" || return 1
  record=$(fm_completed_view_record_path "$state" "$id")
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  lines=$(wc -l < "$record" 2>/dev/null | tr -d '[:space:]')
  FM_COMPLETED_VIEW_RECORD_VERSION=$(fm_completed_view_record_field "$record" version) || return 1
  FM_COMPLETED_VIEW_RECORD_PHASE=$(fm_completed_view_record_field "$record" phase) || return 1
  FM_COMPLETED_VIEW_RECORD_TASK_ID=$(fm_completed_view_record_field "$record" task_id) || return 1
  FM_COMPLETED_VIEW_RECORD_TOKEN=$(fm_completed_view_record_field "$record" token) || return 1
  FM_COMPLETED_VIEW_RECORD_HOME=$(fm_completed_view_record_field "$record" home) || return 1
  FM_COMPLETED_VIEW_RECORD_SESSION=$(fm_completed_view_record_field "$record" session) || return 1
  FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID=$(fm_completed_view_record_field "$record" workspace_id) || return 1
  FM_COMPLETED_VIEW_RECORD_LABEL=$(fm_completed_view_record_field "$record" label) || return 1
  [ "$FM_COMPLETED_VIEW_RECORD_TASK_ID" = "$id" ] || return 1
  [ "${#FM_COMPLETED_VIEW_RECORD_TOKEN}" -eq 22 ] || return 1
  case "$FM_COMPLETED_VIEW_RECORD_TOKEN" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$FM_COMPLETED_VIEW_RECORD_HOME" in /*) ;; *) return 1 ;; esac
  case "$FM_COMPLETED_VIEW_RECORD_HOME" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  for exact in "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID"; do
    case "$exact" in ''|*[!A-Za-z0-9._@%:+-]*) return 1 ;; esac
  done
  expected_label="completed-$id-c-$FM_COMPLETED_VIEW_RECORD_TOKEN"
  [ "$FM_COMPLETED_VIEW_RECORD_LABEL" = "$expected_label" ] || return 1
  case "$FM_COMPLETED_VIEW_RECORD_VERSION:$FM_COMPLETED_VIEW_RECORD_PHASE:$lines" in
    1:creating:8) return 0 ;;
    2:prepared:10|2:parked:10) ;;
    *) return 1 ;;
  esac
  FM_COMPLETED_VIEW_RECORD_TAB_ID=$(fm_completed_view_record_field "$record" tab_id) || return 1
  FM_COMPLETED_VIEW_RECORD_PANE_ID=$(fm_completed_view_record_field "$record" pane_id) || return 1
  for exact in "$FM_COMPLETED_VIEW_RECORD_TAB_ID" "$FM_COMPLETED_VIEW_RECORD_PANE_ID"; do
    case "$exact" in ''|*[!A-Za-z0-9._@%:+-]*) return 1 ;; esac
  done
  home_abs=$(cd "$FM_COMPLETED_VIEW_RECORD_HOME" 2>/dev/null && pwd -P) || return 1
  [ "$home_abs" = "$FM_COMPLETED_VIEW_RECORD_HOME" ]
}

fm_completed_view_atomic_write() {  # <target> ; content on stdin
  local target=$1 dir tmp
  dir=${target%/*}
  tmp=$(mktemp "$dir/.completed-view.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target"
}

fm_completed_view_publish_attempt() {  # <state> <id> <token> <home> <session> <workspace> <label>
  local state=$1 id=$2 token=$3 home=$4 session=$5 workspace=$6 label=$7 record dir tmp
  dir=$(fm_completed_view_directory_ensure "$state") || return 1
  record=$(fm_completed_view_record_path "$state" "$id")
  if [ -e "$record" ] || [ -L "$record" ]; then
    echo "warning: completed-task view record already exists for $id" >&2
    return 1
  fi
  tmp=$(mktemp "$dir/.${id}.view.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'phase=creating\n'
    printf 'task_id=%s\n' "$id"
    printf 'token=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'label=%s\n' "$label"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp"
    echo "warning: completed-task view record appeared concurrently for $id" >&2
    return 1
  fi
  rm -f "$tmp"
}

fm_completed_view_publish_bound() {  # <state> <id> <phase> <token> <home> <session> <workspace> <tab> <pane> <label>
  local state=$1 id=$2 phase=$3 token=$4 home=$5 session=$6 workspace=$7 tab=$8 pane=$9 label=${10}
  local record
  record=$(fm_completed_view_record_path "$state" "$id")
  {
    printf 'version=2\n'
    printf 'phase=%s\n' "$phase"
    printf 'task_id=%s\n' "$id"
    printf 'token=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'label=%s\n' "$label"
  } | fm_completed_view_atomic_write "$record"
}

fm_completed_view_count() {  # <state-dir>
  local state=$1 dir entry count=0
  dir=$(fm_completed_view_directory_path "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf '0\n'; return 0; }
  for entry in "$dir"/*"$FM_COMPLETED_VIEW_RECORD_SUFFIX"; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

fm_completed_view_safe_reference() {  # <value> <max-bytes>
  local value=$1 max=$2 bytes
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  bytes=$(printf '%s' "$value" | wc -c | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$max" ]
}

fm_completed_view_write_summary() {  # <state> <id> <kind> <pr-url> <report-path> <head> <validation>
  local state=$1 id=$2 kind=$3 pr_url=$4 report=$5 head=$6 validation=$7 path outcome
  fm_completed_view_valid_task_id "$id" || return 1
  case "$kind" in
    ship) outcome='Ship task completed.' ;;
    scout) outcome='Scout investigation completed.' ;;
    *) return 1 ;;
  esac
  if ! fm_completed_view_safe_reference "$pr_url" 2048 \
    || { [ -n "$pr_url" ] && [[ ! "$pr_url" =~ ^https://[^[:space:]]+$ ]]; }; then
    pr_url=
  fi
  if ! fm_completed_view_safe_reference "$report" 2048; then report=; fi
  case "$report" in ''|/*) ;; *) report= ;; esac
  case "$head" in ''|*[!0-9a-f]*) head= ;; esac
  case "${#head}" in 40|64) ;; *) head= ;; esac
  case "$validation" in
    checks-green) validation='Checks green.' ;;
    tests-passed) validation='Tests passed.' ;;
    validation-passed) validation='Validation passed.' ;;
    *) validation='Not recorded.' ;;
  esac
  path=$(fm_completed_view_summary_path "$state" "$id")
  {
    printf 'FIRSTMATE - COMPLETED TASK\n\n'
    printf 'Task: %s\n' "$id"
    printf 'Outcome: %s\n' "$outcome"
    [ -z "$pr_url" ] || printf 'PR: %s\n' "$pr_url"
    [ -z "$report" ] || printf 'Report: %s\n' "$report"
    [ -z "$head" ] || printf 'Delivered head: %s\n' "$head"
    printf 'Validation: %s\n' "$validation"
    printf '\nThis is a bounded static summary; terminal scrollback was not retained.\n'
    printf 'Dismiss: bin/fm-completed-view.sh dismiss %s\n' "$id"
  } | fm_completed_view_atomic_write "$path" || return 1
  [ "$(wc -c < "$path" | tr -d '[:space:]')" -le 4096 ] || {
    rm -f "$path"
    return 1
  }
}

fm_completed_view_live_identity_matches() {  # <session> <workspace> <tab> <pane> <label>
  local session=$1 workspace=$2 tab=$3 pane=$4 label=$5 pane_info tab_info
  pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$pane_info" | jq -e \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result.pane.pane_id == $pane
      and .result.pane.tab_id == $tab
      and .result.pane.workspace_id == $workspace
    ' >/dev/null 2>&1 || return 1
  tab_info=$(fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null) || return 1
  printf '%s' "$tab_info" | jq -e \
    --arg tab "$tab" --arg workspace "$workspace" --arg label "$label" '
      .result.tab.tab_id == $tab
      and .result.tab.workspace_id == $workspace
      and .result.tab.label == $label
    ' >/dev/null 2>&1 || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" = no-agent ]
}

fm_completed_view_source_identity_matches() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 info
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result.pane.pane_id == $pane
      and .result.pane.tab_id == $tab
      and .result.pane.workspace_id == $workspace
    ' >/dev/null 2>&1
}

# Prepare one view while the caller holds both the completed-view lock and the
# exact named-session Herdr presentation lock. Return 0 when prepared/reused,
# 2 for a mutation-free fallback, and 1 when an ambiguous mutation requires the
# caller to preserve the task for inspection. Output identity is in globals.
fm_completed_view_prepare() {  # <state> <id> <kind> <session> <workspace> <source-tab> <source-pane> <pr> <report> <head> <validation>
  local state=$1 id=$2 kind=$3 session=$4 workspace=$5 source_tab=$6 source_pane=$7
  local pr_url=$8 report=$9 head=${10} validation=${11}
  local dir record summary home token label count before out tab pane command i cwd
  FM_COMPLETED_VIEW_PREPARED=0
  FM_COMPLETED_VIEW_REUSED=0
  FM_COMPLETED_VIEW_PHASE=
  FM_COMPLETED_VIEW_SESSION=
  FM_COMPLETED_VIEW_WORKSPACE_ID=
  FM_COMPLETED_VIEW_TAB_ID=
  FM_COMPLETED_VIEW_PANE_ID=
  fm_completed_view_valid_task_id "$id" || return 2
  dir=$(fm_completed_view_directory_ensure "$state") || return 2
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 2
  record=$(fm_completed_view_record_path "$state" "$id")
  summary=$(fm_completed_view_summary_path "$state" "$id")
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 2
  if [ -e "$record" ] || [ -L "$record" ]; then
    if ! fm_completed_view_record_load "$state" "$id" \
      || [ "$FM_COMPLETED_VIEW_RECORD_VERSION" != 2 ] \
      || [ "$FM_COMPLETED_VIEW_RECORD_HOME" != "$home" ] \
      || [ "$FM_COMPLETED_VIEW_RECORD_SESSION" != "$session" ] \
      || [ "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID" != "$workspace" ] \
      || [ ! -f "$summary" ] || [ -L "$summary" ] \
      || ! fm_completed_view_live_identity_matches \
        "$session" "$workspace" "$FM_COMPLETED_VIEW_RECORD_TAB_ID" \
        "$FM_COMPLETED_VIEW_RECORD_PANE_ID" "$FM_COMPLETED_VIEW_RECORD_LABEL"; then
      echo "error: completed-task view state for $id is ambiguous; preserving the task and retained state for inspection" >&2
      return 1
    fi
    FM_COMPLETED_VIEW_PREPARED=1
    FM_COMPLETED_VIEW_REUSED=1
    FM_COMPLETED_VIEW_PHASE=$FM_COMPLETED_VIEW_RECORD_PHASE
    FM_COMPLETED_VIEW_SESSION=$session
    FM_COMPLETED_VIEW_WORKSPACE_ID=$workspace
    FM_COMPLETED_VIEW_TAB_ID=$FM_COMPLETED_VIEW_RECORD_TAB_ID
    FM_COMPLETED_VIEW_PANE_ID=$FM_COMPLETED_VIEW_RECORD_PANE_ID
    return 0
  fi
  count=$(fm_completed_view_count "$state") || return 2
  if [ "$count" -ge "$FM_COMPLETED_VIEW_LIMIT" ]; then
    echo "warning: completed-task view limit ($FM_COMPLETED_VIEW_LIMIT) reached; continuing ordinary cleanup without retaining $id" >&2
    return 2
  fi
  fm_completed_view_source_identity_matches "$session" "$workspace" "$source_tab" "$source_pane" || {
    echo "warning: completed-task view source identity is unavailable for $id; continuing ordinary cleanup" >&2
    return 2
  }
  token=$(fm_backend_herdr_projection_id) || {
    echo "warning: could not generate completed-task view identity for $id; continuing ordinary cleanup" >&2
    return 2
  }
  label="completed-$id-c-$token"
  fm_completed_view_write_summary "$state" "$id" "$kind" "$pr_url" "$report" "$head" "$validation" || {
    echo "warning: could not write the bounded completed-task summary for $id; continuing ordinary cleanup" >&2
    return 2
  }
  fm_completed_view_publish_attempt "$state" "$id" "$token" "$home" "$session" "$workspace" "$label" || {
    rm -f "$summary"
    return 2
  }
  before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: completed-task view creation could not capture exact focus for $id; preserving its creation journal" >&2
    return 1
  }
  if ! out=$(fm_backend_herdr_cli "$session" tab create \
      --workspace "$workspace" --cwd "$dir" --label "$label" --no-focus 2>/dev/null); then
    fm_backend_herdr_projection_focus_restore "$session" "$before" "completed-task tab create" || true
    echo "error: completed-task view creation failed ambiguously for $id; preserving its creation journal" >&2
    return 1
  fi
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab" ] || [ -z "$pane" ]; then
    fm_backend_herdr_projection_focus_restore "$session" "$before" "completed-task tab create" || true
    echo "error: completed-task view creation returned incomplete identity for $id; preserving its creation journal" >&2
    return 1
  fi
  fm_completed_view_publish_bound "$state" "$id" prepared "$token" "$home" "$session" "$workspace" "$tab" "$pane" "$label" || {
    fm_backend_herdr_projection_focus_restore "$session" "$before" "completed-task tab create" || true
    echo "error: completed-task view identity could not be published for $id; preserving its creation journal" >&2
    return 1
  }
  fm_backend_herdr_projection_focus_restore "$session" "$before" "completed-task tab create" || {
    echo "warning: completed-task view creation did not preserve exact focus for $id; removing its exact prepared pane" >&2
    if fm_completed_view_remove_exact "$state" "$id" >/dev/null 2>&1; then
      return 2
    fi
    echo "error: focus restoration failed and the exact completed-task pane could not be safely removed for $id" >&2
    return 1
  }
  command="printf '\\033[2J\\033[H'; cat -- '$id$FM_COMPLETED_VIEW_SUMMARY_SUFFIX'; while :; do sleep 86400; done"
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$command" >/dev/null 2>&1; then
    echo "warning: completed-task static renderer did not start for $id; removing its exact prepared pane" >&2
    fm_completed_view_remove_exact "$state" "$id" >/dev/null 2>&1 && return 2
    echo "error: completed-task static renderer failed and its pane could not be safely removed for $id" >&2
    return 1
  fi
  i=0
  while [ "$i" -lt 20 ]; do
    cwd=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null \
      | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null) || cwd=
    [ "$cwd" != "$dir" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$cwd" != "$dir" ] \
    || ! fm_completed_view_live_identity_matches "$session" "$workspace" "$tab" "$pane" "$label"; then
    echo "warning: completed-task static renderer could not be verified outside the worktree for $id; removing its exact prepared pane" >&2
    if fm_completed_view_remove_exact "$state" "$id" >/dev/null 2>&1; then
      return 2
    fi
    echo "error: unverified completed-task view could not be safely removed for $id" >&2
    return 1
  fi
  FM_COMPLETED_VIEW_PREPARED=1
  FM_COMPLETED_VIEW_PHASE=prepared
  FM_COMPLETED_VIEW_SESSION=$session
  FM_COMPLETED_VIEW_WORKSPACE_ID=$workspace
  FM_COMPLETED_VIEW_TAB_ID=$tab
  FM_COMPLETED_VIEW_PANE_ID=$pane
  return 0
}

fm_completed_view_mark_parked() {  # <state> <task-id>
  local state=$1 id=$2
  fm_completed_view_record_load "$state" "$id" || return 1
  [ "$FM_COMPLETED_VIEW_RECORD_VERSION" = 2 ] || return 1
  [ "$FM_COMPLETED_VIEW_RECORD_PHASE" = prepared ] || [ "$FM_COMPLETED_VIEW_RECORD_PHASE" = parked ] || return 1
  [ "$FM_COMPLETED_VIEW_RECORD_PHASE" = parked ] && return 0
  fm_completed_view_publish_bound "$state" "$id" parked \
    "$FM_COMPLETED_VIEW_RECORD_TOKEN" "$FM_COMPLETED_VIEW_RECORD_HOME" \
    "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID" \
    "$FM_COMPLETED_VIEW_RECORD_TAB_ID" "$FM_COMPLETED_VIEW_RECORD_PANE_ID" \
    "$FM_COMPLETED_VIEW_RECORD_LABEL"
}

# Remove one exact prepared or parked view while its named-session presentation
# lock is held. A dead pane permits record retirement; a present pane must still
# match every bound id and label and have no registered agent before exact close.
fm_completed_view_remove_exact() {  # <state> <task-id>
  local state=$1 id=$2 record summary presence
  record=$(fm_completed_view_record_path "$state" "$id")
  summary=$(fm_completed_view_summary_path "$state" "$id")
  fm_completed_view_record_load "$state" "$id" || return 1
  [ "$FM_COMPLETED_VIEW_RECORD_VERSION" = 2 ] || return 1
  presence=$(fm_backend_herdr_pane_presence_state \
    "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_PANE_ID")
  case "$presence" in
    dead) ;;
    present)
      fm_completed_view_live_identity_matches \
        "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID" \
        "$FM_COMPLETED_VIEW_RECORD_TAB_ID" "$FM_COMPLETED_VIEW_RECORD_PANE_ID" \
        "$FM_COMPLETED_VIEW_RECORD_LABEL" || return 1
      fm_backend_herdr_projection_close_pane_focus_preserving \
        "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_PANE_ID" no-agent || true
      [ "$(fm_backend_herdr_pane_presence_state \
        "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_PANE_ID")" = dead ] || return 1
      ;;
    *) return 1 ;;
  esac
  rm -f "$record" "$summary"
}

fm_completed_view_list() {  # <state-dir>
  local state=$1 dir record id count=0 presence
  dir=$(fm_completed_view_directory_path "$state")
  printf 'TASK\tPHASE\tSESSION\tWORKSPACE\tTAB\tPANE\tPRESENCE\tSUMMARY_FILE\n'
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  export LC_ALL=C
  for record in "$dir"/*"$FM_COMPLETED_VIEW_RECORD_SUFFIX"; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$FM_COMPLETED_VIEW_LIST_LIMIT" ]; then
      printf '...\ttruncated\t-\t-\t-\t-\t-\t-\n'
      break
    fi
    id=${record##*/}
    id=${id%"$FM_COMPLETED_VIEW_RECORD_SUFFIX"}
    if ! fm_completed_view_valid_task_id "$id"; then
      printf '<invalid-name>\tinvalid\t-\t-\t-\t-\tunknown\t-\n'
      continue
    fi
    if ! fm_completed_view_record_load "$state" "$id"; then
      printf '%s\tinvalid\t-\t-\t-\t-\tunknown\t%s%s\n' "$id" "$id" "$FM_COMPLETED_VIEW_SUMMARY_SUFFIX"
      continue
    fi
    if [ "$FM_COMPLETED_VIEW_RECORD_VERSION" = 1 ]; then
      printf '%s\tcreating\t%s\t%s\t-\t-\tunknown\t%s%s\n' \
        "$id" "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID" \
        "$id" "$FM_COMPLETED_VIEW_SUMMARY_SUFFIX"
      continue
    fi
    presence=$(fm_backend_herdr_pane_presence_state \
      "$FM_COMPLETED_VIEW_RECORD_SESSION" "$FM_COMPLETED_VIEW_RECORD_PANE_ID")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$FM_COMPLETED_VIEW_RECORD_PHASE" "$FM_COMPLETED_VIEW_RECORD_SESSION" \
      "$FM_COMPLETED_VIEW_RECORD_WORKSPACE_ID" "$FM_COMPLETED_VIEW_RECORD_TAB_ID" \
      "$FM_COMPLETED_VIEW_RECORD_PANE_ID" "$presence" \
      "$id$FM_COMPLETED_VIEW_SUMMARY_SUFFIX"
  done
}
