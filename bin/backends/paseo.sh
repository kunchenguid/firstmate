#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo runtime backend (EXPERIMENTAL).
#
# Paseo owns both the agent endpoint and the task worktree. Fresh tasks resolve
# the source path to one existing project, create a worktree workspace under
# that project, then run the agent in the selected workspace. Relaunch validates
# and reuses the recorded workspace and worktree. This adapter uses only the
# CLI's public JSON/status surfaces: logs are timeline output, not a verified
# viewport, and agent liveness remains unverified because Paseo does not expose
# a worker pid through its CLI. Paseo never starts, stops, or restarts its
# daemon here; the daemon must already be reachable.

FM_BACKEND_PASEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_PASEO_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

fm_backend_paseo_tool_check() {
  command -v paseo >/dev/null 2>&1 || { echo "error: backend=paseo selected but the 'paseo' CLI is not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=paseo selected but 'jq' is not installed" >&2; return 1; }
}

fm_backend_paseo_runtime_check() {
  fm_backend_paseo_tool_check || return 1
  paseo daemon status >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'paseo daemon status' failed; start the Paseo daemon outside firstmate" >&2
    return 1
  }
}

fm_backend_paseo_provider() { # <firstmate-harness>
  case "$1" in
    codex|opencode) printf '%s' "$1" ;;
    claude)
      local diagnostic providers
      diagnostic=$(paseo provider diagnostic claude --json 2>&1) || {
        echo "error: Paseo provider claude is not explicitly enabled by the host diagnostic" >&2
        return 1
      }
      if ! printf '%s\n' "$diagnostic" | jq -e '
        type == "object" and .provider == "claude" and
        ((has("enabled") | not) or .enabled == true or
          ((.enabled | type) == "string" and (.enabled | ascii_downcase) == "enabled")) and
        ((has("status") | not) or
          ((.status | type) == "string" and ((.status | ascii_downcase) | IN("ready", "available", "enabled")))) and
        (.diagnostic | type == "string" and
          (split("\n") | any(test("^[[:space:]]*Status:[[:space:]]*(Ready|Available|Enabled)[[:space:]]*$"; "i"))))
      ' >/dev/null 2>&1; then
        echo "error: Paseo provider claude is not explicitly enabled by the host diagnostic" >&2
        return 1
      fi
      providers=$(paseo provider ls --json 2>&1) || {
        echo "error: Paseo provider claude availability could not be verified" >&2
        return 1
      }
      if ! printf '%s\n' "$providers" | jq -e '
        type == "array" and
        ([.[] | select(.provider == "claude" and
          ((.status | type) == "string") and (.status | ascii_downcase) == "available" and
          ((.enabled | type) == "string") and (.enabled | ascii_downcase) == "enabled")] | length) == 1
      ' >/dev/null 2>&1; then
        echo "error: Paseo provider claude is not enabled and available on this host" >&2
        return 1
      fi
      printf claude
      ;;
    *) echo "error: Paseo cannot map unknown firstmate harness '$1' to a provider" >&2; return 1 ;;
  esac
}

fm_backend_paseo_canonical_directory() { # <absolute-path>
  case "${1:-}" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_backend_paseo_json_payload() { # <cli-output>
  printf '%s\n' "$1" | awk 'found || /^[[:space:]]*\{/{found=1; print}'
}

fm_backend_paseo_workspace_text_id() { # <cli-output>
  printf '%s\n' "$1" | sed -n \
    -e 's/.*Created workspace \([^[:space:]]*\).*/\1/p' \
    -e 's/.*Using workspace \([^[:space:]]*\).*/\1/p' | tail -n 1
}

fm_backend_paseo_project_for_source() { # <source-clone>
  local source=$1 source_path listing row project_id project_name project_path project_path_real matches=0 selected_id='' selected_name=''
  source_path=$(fm_backend_paseo_canonical_directory "$source") || {
    printf 'error: cannot resolve Paseo source directory %s\n' "$source" >&2
    return 1
  }
  listing=$(paseo project ls --json 2>&1) || {
    echo "error: Paseo project listing failed; refusing to create a per-task project" >&2
    printf '%s\n' "$listing" >&2
    return 1
  }
  if ! printf '%s\n' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "error: Paseo project listing was not a JSON array; refusing to create a per-task project" >&2
    printf '%s\n' "$listing" >&2
    return 1
  fi
  while IFS=$'\t' read -r project_id project_name project_path; do
    [ -n "$project_id" ] && [ -n "$project_name" ] && [ -n "$project_path" ] || continue
    project_path_real=$(fm_backend_paseo_canonical_directory "$project_path" 2>/dev/null) || continue
    if [ "$project_path_real" = "$source_path" ]; then
      matches=$((matches + 1))
      selected_id=$project_id
      selected_name=$project_name
    fi
  done < <(printf '%s\n' "$listing" | jq -r '.[] | [(.projectId // .id // ""), (.name // ""), (.path // "")] | @tsv' 2>/dev/null)
  if [ "$matches" -ne 1 ]; then
    if [ "$matches" -eq 0 ]; then
      printf 'error: no registered Paseo project matches source path %s; refusing to create a project\n' "$source_path" >&2
    else
      printf 'error: %s Paseo projects match source path %s; refusing ambiguous project reuse\n' "$matches" "$source_path" >&2
    fi
    return 1
  fi
  printf '%s\t%s' "$selected_id" "$selected_name"
}

fm_backend_paseo_workspace_path() { # <workspace-id> <expected-worktree-or-empty> <expected-project-name>
  local workspace_id=$1 expected_path=${2:-} expected_project=${3:-} listing count row returned_id isolation project_name worktree_path expected_real actual_real
  listing=$(paseo workspace ls --json 2>&1) || {
    printf 'error: Paseo workspace listing failed for %s; refusing unsafe workspace reuse\n' "$workspace_id" >&2
    printf '%s\n' "$listing" >&2
    return 1
  }
  if ! printf '%s\n' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'error: Paseo workspace listing for %s was not a JSON array; refusing unsafe workspace reuse\n' "$workspace_id" >&2
    return 1
  fi
  count=$(printf '%s\n' "$listing" | jq -r --arg id "$workspace_id" '[.[] | select(.workspaceId == $id)] | length' 2>/dev/null) || count=0
  if [ "$count" != 1 ]; then
    printf 'error: Paseo workspace %s is not exactly one active workspace; refusing unsafe reuse\n' "$workspace_id" >&2
    return 1
  fi
  row=$(printf '%s\n' "$listing" | jq -r --arg id "$workspace_id" \
    '[.[] | select(.workspaceId == $id)][0] | [(.workspaceId // ""), (.isolation // ""), (.project // ""), (.cwd // .worktreePath // "")] | @tsv' 2>/dev/null) || row=
  IFS=$'\t' read -r returned_id isolation project_name worktree_path <<EOF
$row
EOF
  if [ "$returned_id" != "$workspace_id" ] || [ "$isolation" != worktree ]; then
    printf 'error: Paseo workspace %s is not a worktree workspace; refusing unsafe reuse\n' "$workspace_id" >&2
    return 1
  fi
  if [ -z "$expected_project" ] || [ "$project_name" != "$expected_project" ]; then
    printf 'error: Paseo workspace %s belongs to project %s, not the registered source project %s; refusing unsafe reuse\n' \
      "$workspace_id" "${project_name:-unknown}" "${expected_project:-unknown}" >&2
    return 1
  fi
  actual_real=$(fm_backend_paseo_canonical_directory "$worktree_path") || {
    printf 'error: Paseo workspace %s has no inspectable absolute worktree path; refusing unsafe reuse\n' "$workspace_id" >&2
    return 1
  }
  if [ -n "$expected_path" ]; then
    expected_real=$(fm_backend_paseo_canonical_directory "$expected_path") || {
      printf 'error: recorded Paseo worktree %s is missing or unreadable; refusing workspace reuse\n' "$expected_path" >&2
      return 1
    }
    if [ "$actual_real" != "$expected_real" ]; then
      printf 'error: Paseo workspace %s resolves to %s, not its recorded worktree %s; refusing unsafe reuse\n' \
        "$workspace_id" "$actual_real" "$expected_real" >&2
      return 1
    fi
  fi
  printf '%s' "$worktree_path"
}

fm_backend_paseo_validate_task_worktree() { # <source-clone> <worktree-path>
  local source=$1 worktree=$2 source_path worktree_path source_top worktree_top listing line candidate candidate_real found=0
  source_path=$(fm_backend_paseo_canonical_directory "$source") || {
    printf 'error: Paseo source directory %s is missing or unreadable\n' "$source" >&2
    return 1
  }
  worktree_path=$(fm_backend_paseo_canonical_directory "$worktree") || {
    printf 'error: Paseo worktree %s is missing or unreadable\n' "$worktree" >&2
    return 1
  }
  if [ "$source_path" = "$worktree_path" ]; then
    printf 'error: Paseo returned the source project itself as the task worktree; refusing shared-worktree launch\n' >&2
    return 1
  fi
  source_top=$(git -C "$source_path" rev-parse --show-toplevel 2>/dev/null) || source_top=
  worktree_top=$(git -C "$worktree_path" rev-parse --show-toplevel 2>/dev/null) || worktree_top=
  source_top=$(fm_backend_paseo_canonical_directory "$source_top" 2>/dev/null) || source_top=
  worktree_top=$(fm_backend_paseo_canonical_directory "$worktree_top" 2>/dev/null) || worktree_top=
  if [ "$source_top" != "$source_path" ] || [ "$worktree_top" != "$worktree_path" ]; then
    printf 'error: Paseo path %s is not an isolated Git worktree root for source project %s\n' \
      "$worktree_path" "$source_path" >&2
    return 1
  fi
  listing=$(git -C "$source_path" worktree list --porcelain 2>/dev/null) || {
    printf 'error: cannot inspect Git worktrees for Paseo source %s; refusing launch\n' "$source_path" >&2
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        candidate=${line#worktree }
        candidate_real=$(fm_backend_paseo_canonical_directory "$candidate" 2>/dev/null) || continue
        [ "$candidate_real" = "$worktree_path" ] && found=1
        ;;
    esac
  done <<EOF
$listing
EOF
  if [ "$found" -ne 1 ]; then
    printf 'error: Paseo worktree %s is not registered to source project %s; refusing unsafe reuse\n' \
      "$worktree_path" "$source_path" >&2
    return 1
  fi
  printf '%s' "$worktree_path"
}

fm_backend_paseo_create_task() { # <id> <source-clone> <brief> <harness> <model> <effort> <home-tag> <workspace-id> <worktree-path> [env key=value...]
  local id=$1 source=$2 brief=$3 harness=$4 model=${5:-} effort=${6:-} home_tag=${7:-} workspace_id=${8:-} expected_worktree=${9:-}
  shift 9
  local provider base_ref candidate project_id project_name project_record slug workspace_raw workspace_json created_workspace created_text_id created_worktree
  local worktree_path worktree worktree_real run_raw run_json agent reported_workspace_json reported_workspace_text reported_workspace
  local reported_worktree run_status env_value
  local -a create_args run_args
  fm_backend_paseo_runtime_check || return 1
  provider=$(fm_backend_paseo_provider "$harness") || return 1
  project_record=$(fm_backend_paseo_project_for_source "$source") || return 1
  IFS=$'\t' read -r project_id project_name <<EOF
$project_record
EOF

  if [ -n "$workspace_id" ]; then
    [ -n "$expected_worktree" ] || {
      printf 'error: Paseo task %s has a workspace id but no recorded worktree path; refusing relaunch\n' "$id" >&2
      return 1
    }
    worktree_path=$(fm_backend_paseo_workspace_path "$workspace_id" "$expected_worktree" "$project_name") || return 1
    worktree=$(fm_backend_paseo_validate_task_worktree "$source" "$expected_worktree") || return 1
  else
    base_ref=$(git -C "$source" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$base_ref" ] && ! git -C "$source" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
      base_ref=
    fi
    if [ -z "$base_ref" ]; then
      for candidate in main master; do
        if git -C "$source" rev-parse --verify --quiet "refs/heads/$candidate^{commit}" >/dev/null; then
          base_ref=$candidate
          break
        fi
      done
    fi
    [ -n "$base_ref" ] || base_ref=$(git -C "$source" rev-parse --verify --quiet 'HEAD^{commit}') || {
      echo "error: could not resolve a valid source base for Paseo task $id" >&2
      return 1
    }
    slug="fm-${home_tag}-${id}"
    create_args=(workspace create --isolation worktree --path "$source" --project "$project_id"
      --mode branch-off --new-branch "$slug" --base "$base_ref" --worktree-slug "$slug"
      --json)
    if workspace_raw=$(env -u PASEO_AGENT_ID -u PASEO_WORKSPACE_ID paseo "${create_args[@]}" 2>&1); then
      :
    else
      created_text_id=$(fm_backend_paseo_workspace_text_id "$workspace_raw")
      if [ -n "$created_text_id" ]; then
        printf 'error: Paseo workspace creation failed for task %s after reporting workspace %s; workspace retained for manual reconciliation\n' \
          "$id" "$created_text_id" >&2
      else
        printf 'error: Paseo workspace creation failed for task %s; no per-task project was created\n' "$id" >&2
      fi
      printf '%s\n' "$workspace_raw" >&2
      return 1
    fi
    workspace_json=$(fm_backend_paseo_json_payload "$workspace_raw")
    created_workspace=$(printf '%s\n' "$workspace_json" | jq -r '
      if type == "object" then
        (.workspaceId // .id // .workspace.workspaceId // .workspace.id // (if (.workspace | type) == "string" then .workspace else empty end) // empty)
      else empty end' 2>/dev/null) || created_workspace=
    created_text_id=$(fm_backend_paseo_workspace_text_id "$workspace_raw")
    if [ -n "$created_workspace" ] && [ -n "$created_text_id" ] && [ "$created_workspace" != "$created_text_id" ]; then
      printf 'error: Paseo workspace creation returned conflicting workspace ids for task %s; workspace retained for manual reconciliation\n' "$id" >&2
      printf '%s\n' "$workspace_raw" >&2
      return 1
    fi
    workspace_id=${created_workspace:-$created_text_id}
    if [ -z "$workspace_id" ]; then
      printf 'error: Paseo workspace creation did not return an id for task %s; any created workspace is retained for manual reconciliation\n' "$id" >&2
      printf '%s\n' "$workspace_raw" >&2
      return 1
    fi
    created_worktree=$(printf '%s\n' "$workspace_json" | jq -r '
      if type == "object" then
        (.worktreePath // .worktree.path // (if (.worktree | type) == "string" then .worktree else empty end) // .cwd // .directory // .workspace.directory // empty)
      else empty end' 2>/dev/null) || created_worktree=
    worktree_path=$(fm_backend_paseo_workspace_path "$workspace_id" "$created_worktree" "$project_name") || {
      printf 'error: Paseo workspace %s is retained for manual reconciliation\n' "$workspace_id" >&2
      return 1
    }
    worktree=$(fm_backend_paseo_validate_task_worktree "$source" "$worktree_path") || {
      printf 'error: Paseo workspace %s is retained for manual reconciliation\n' "$workspace_id" >&2
      return 1
    }
  fi

  run_args=(run --background --workspace "$workspace_id" --provider "$provider"
    --label "fm-task=$id" --label "fm-home=$home_tag" --title "fm-${home_tag}-${id}" --json)
  [ -n "$model" ] && [ "$model" != default ] && run_args+=(--model "$model")
  [ -n "$effort" ] && [ "$effort" != default ] && run_args+=(--thinking "$effort")
  case "$provider" in
    opencode) run_args+=(--mode build) ;;
  esac
  for env_value in "$@"; do run_args+=(--env "$env_value"); done
  run_args+=("$brief")
  if run_raw=$(env -u PASEO_AGENT_ID -u PASEO_WORKSPACE_ID paseo "${run_args[@]}" 2>&1); then
    run_status=0
  else
    run_status=$?
  fi
  if [ "$run_status" -ne 0 ]; then
    printf 'error: Paseo run failed for task %s in workspace %s; workspace retained for manual reconciliation\n' \
      "$id" "$workspace_id" >&2
    printf '%s\n' "$run_raw" >&2
    return 1
  fi
  run_json=$(fm_backend_paseo_json_payload "$run_raw")
  agent=$(printf '%s\n' "$run_json" | jq -r 'if type == "object" then (.agentId // .id // empty) else empty end' 2>/dev/null) || agent=
  reported_workspace_json=$(printf '%s\n' "$run_json" | jq -r '
    if type == "object" then
      (.workspaceId // .workspace.id // (if (.workspace | type) == "string" then .workspace else empty end) // empty)
    else empty end' 2>/dev/null) || reported_workspace_json=
  reported_workspace_text=$(fm_backend_paseo_workspace_text_id "$run_raw")
  if [ -n "$reported_workspace_json" ] && [ -n "$reported_workspace_text" ] &&
    [ "$reported_workspace_json" != "$reported_workspace_text" ]; then
    printf 'error: Paseo run returned conflicting workspace identities for task %s; agent %s may need manual reconciliation\n' \
      "$id" "${agent:-unknown}" >&2
    printf '%s\n' "$run_raw" >&2
    return 1
  fi
  reported_workspace=${reported_workspace_json:-$reported_workspace_text}
  if [ -n "$reported_workspace" ] && [ "$reported_workspace" != "$workspace_id" ]; then
    printf 'error: Paseo run selected workspace %s for task %s, not the validated workspace %s; agent %s may need manual reconciliation\n' \
      "$reported_workspace" "$id" "$workspace_id" "${agent:-unknown}" >&2
    printf '%s\n' "$run_raw" >&2
    return 1
  fi
  reported_worktree=$(printf '%s\n' "$run_json" | jq -r '
    if type == "object" then
      (.worktreePath // .worktree.path // (if (.worktree | type) == "string" then .worktree else empty end) // .cwd // empty)
    else empty end' 2>/dev/null) || reported_worktree=
  if [ -n "$reported_worktree" ]; then
    reported_worktree=$(fm_backend_paseo_canonical_directory "$reported_worktree") || {
      printf 'error: Paseo run returned an uninspectable worktree for task %s; agent %s may need manual reconciliation\n' \
        "$id" "${agent:-unknown}" >&2
      printf '%s\n' "$run_raw" >&2
      return 1
    }
    worktree_real=$(fm_backend_paseo_canonical_directory "$worktree") || worktree_real=
    if [ "$reported_worktree" != "$worktree_real" ]; then
      printf 'error: Paseo run returned worktree %s for task %s, not the validated worktree %s; agent %s may need manual reconciliation\n' \
        "$reported_worktree" "$id" "$worktree_real" "${agent:-unknown}" >&2
      printf '%s\n' "$run_raw" >&2
      return 1
    fi
  fi
  [ -n "$agent" ] && [ -n "$workspace_id" ] && [ -n "$worktree" ] || {
    printf 'error: Paseo did not return an agent id for task %s; validated workspace %s and worktree %s are retained\n' \
      "$id" "$workspace_id" "$worktree" >&2
    printf '%s\n' "$run_raw" >&2
    return 1
  }
  printf '%s\t%s\t%s' "$agent" "$workspace_id" "$worktree"
}

fm_backend_paseo_capture() { # <agent-id> <lines>
  local id=$1 lines=${2:-40}
  fm_backend_paseo_tool_check || return 1
  paseo logs "$id" --tail "$lines"
}

fm_backend_paseo_status() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json | jq -r '(.lastStatus // .LastStatus // .status // .Status // .agent.lastStatus // .agent.status // empty) | ascii_downcase' 2>/dev/null
}

fm_backend_paseo_busy_state() {
  case "$(fm_backend_paseo_status "$1" 2>/dev/null || true)" in
    initializing|running|working|busy) printf busy ;;
    idle|closed|completed|failed|canceled|cancelled|stopped|archived) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_paseo_terminal_proof() { # <agent-id>
  case "$(fm_backend_paseo_status "$1" 2>/dev/null || true)" in
    closed|archived) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_paseo_stop_status_proof() { # <agent-id> <timeout> <poll>
  local id=$1 timeout=${2:-30} poll=${3:-0.5} elapsed=0 status
  fm_backend_paseo_tool_check || return 1
  fm_backend_paseo_terminal_proof "$id" && return 0
  paseo stop "$id" >/dev/null 2>&1 || return 1
  while :; do
    status=$(fm_backend_paseo_status "$id" 2>/dev/null || true)
    case "$status" in
      closed|archived) return 0 ;;
      idle) return 1 ;;
    esac
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
}

fm_backend_paseo_archive_agent() {
  fm_backend_paseo_tool_check || return 1
  paseo archive "$1" >/dev/null || return 1
  local timeout=30 poll=0.5 elapsed=0 status
  while :; do
    status=$(fm_backend_paseo_status "$1" 2>/dev/null || true)
    case "$status" in
      closed|archived) return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  echo "error: Paseo archive of agent $1 was not confirmed by native terminal status" >&2
  return 1
}

fm_backend_paseo_send_text_submit() { # <agent-id> <text> ...
  local id=$1 text=$2
  fm_backend_paseo_tool_check || return 1
  paseo send "$id" --no-wait "$text" >/dev/null
}

fm_backend_paseo_send_key() { # <agent-id> <key>
  case "$2" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C) fm_backend_paseo_tool_check && paseo stop "$1" ;;
    *) echo "error: Paseo cannot express key '$2'; only interrupt maps to paseo stop" >&2; return 1 ;;
  esac
}

fm_backend_paseo_kill() { # <agent-id> <workspace-id>
  local agent=$1 workspace=${2:-}
  fm_backend_paseo_archive_agent "$agent" || return 1
  [ -n "$workspace" ] || return 0
  paseo workspace archive "$workspace" >/dev/null
}

fm_backend_paseo_agent_state() { printf unverified; }

fm_backend_paseo_target_exists() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json >/dev/null 2>&1
}
