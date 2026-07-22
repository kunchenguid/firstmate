#!/usr/bin/env bash
# Guarded command owner for per-project GitHub account routing.
# Usage:
#   fm-github-exec.sh validate
#   fm-github-exec.sh validate-all
#   fm-github-exec.sh profile-id --project <name> --repository <path-or-url> [--profile <id>]
#   fm-github-exec.sh exec --project <name> --repository <path-or-url> [--profile <id>] [--pre-register-project] -- <command> [args...]
#   fm-github-exec.sh no-mistakes-init --project <name> --repository <path> [--fork-url <https-url>]
#
# Internal PATH shims use child-git, child-gh, and child-gh-axi. They re-resolve
# the stable profile id against current private config before every ordinary
# descendant invocation. This protects generated FirstMate paths, but is not an
# operating-system sandbox against a process that deliberately invokes another
# absolute executable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
case "${1:-}" in
  child-*)
    [ "${2:-}" = --home ] && [ -n "${3:-}" ] && [ "${4:-}" = -- ] || {
      sed -n '2,12p' "$0" >&2
      exit 2
    }
    FM_HOME=$3
    unset FM_GITHUB_ALLOW_UNREGISTERED_PROJECT FM_GITHUB_CLONE_CAPABILITY FM_GITHUB_CLONE_ROOT
    ;;
  *)
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    unset FM_GITHUB_ACTIVE FM_GITHUB_ALLOW_UNREGISTERED_PROJECT FM_GITHUB_CLONE_CAPABILITY FM_GITHUB_CLONE_ROOT
    unset FM_GITHUB_INVOCATION_CAPABILITY
    ;;
esac
export FM_HOME

# shellcheck source=bin/fm-github-lib.sh
. "$SCRIPT_DIR/fm-github-lib.sh"

github_exec_usage() {
  sed -n '2,12p' "$0" >&2
  exit 2
}

project=
repository=
profile=
fork_url=
pre_register_project=0

parse_context_args() {
  local want=
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$want" in
        project) project=$1 ;;
        repository) repository=$1 ;;
        profile) profile=$1 ;;
        fork) fork_url=$1 ;;
      esac
      want=
      shift
      continue
    fi
    case "$1" in
      --project) want=project ;;
      --project=*) project=${1#--project=} ;;
      --repository) want=repository ;;
      --repository=*) repository=${1#--repository=} ;;
      --profile) want=profile ;;
      --profile=*) profile=${1#--profile=} ;;
      --fork-url) want=fork ;;
      --fork-url=*) fork_url=${1#--fork-url=} ;;
      --pre-register-project) pre_register_project=1 ;;
      --)
        shift
        CONTEXT_REST=("$@")
        [ -z "$want" ] || github_exec_usage
        return 0
        ;;
      *) github_exec_usage ;;
    esac
    shift
  done
  [ -z "$want" ] || github_exec_usage
  CONTEXT_REST=()
}

validate_all() {
  local projects_file projects_dir line name path mode_line mode failed=0
  fm_github_validate_config || return 1
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  projects_file="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md"
  projects_dir="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
  [ -f "$projects_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '* ) ;;
      *) continue ;;
    esac
    name=${line#- }
    name=${name%% *}
    case "$name" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    mode_line=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-project-mode.sh" "$name" 2>/dev/null || printf '%s\n' 'no-mistakes off')
    mode=${mode_line%% *}
    [ "$mode" != local-only ] || continue
    path="$projects_dir/$name"
    [ -d "$path" ] || { echo "GITHUB_ACCOUNTS: project $name has no local clone for route validation"; failed=1; continue; }
    if ! fm_github_activate "$name" "$path"; then
      echo "GITHUB_ACCOUNTS: project $name has no valid GitHub account route"
      failed=1
      continue
    fi
    if ! fm_github_validate_local_config "$path" || ! fm_github_preflight read; then
      echo "GITHUB_ACCOUNTS: project $name failed selected-account access validation"
      failed=1
    fi
  done < "$projects_file"
  return "$failed"
}

child_context() {
  local actual_repository
  [ "${FM_GITHUB_ACTIVE:-}" = 1 ] && [ -n "${FM_GITHUB_PROFILE_ID:-}" ] && [ -n "${FM_GITHUB_REPOSITORY:-}" ] || {
    echo "error: guarded GitHub child has no selected project context" >&2
    return 1
  }
  project=${FM_GITHUB_PROJECT:-}
  repository=$FM_GITHUB_REPOSITORY
  profile=$FM_GITHUB_PROFILE_ID
  if [ -n "${FM_GITHUB_PROJECT_PATH:-}" ] \
    && actual_repository=$(fm_github_repository_toplevel "$PWD" 2>/dev/null) \
    && fm_github_same_repository_copy "$actual_repository" "$FM_GITHUB_PROJECT_PATH"; then
    FM_GITHUB_PROJECT_PATH=$actual_repository
    export FM_GITHUB_PROJECT_PATH
  fi
}

no_mistakes_context_marker_path() {
  local marker_dir key
  marker_dir="$FM_HOME/state/.github-routing-no-mistakes"
  if [ ! -e "$marker_dir" ]; then
    mkdir -m 0700 "$marker_dir" 2>/dev/null || [ -d "$marker_dir" ] || return 1
  fi
  [ -d "$marker_dir" ] && [ ! -L "$marker_dir" ] && [ "$(fm_github_file_mode "$marker_dir")" = 700 ] || return 1
  key=$(fm_github_node - "$repository" <<'NODE'
const crypto = require("node:crypto");
process.stdout.write(crypto.createHash("sha256").update(process.argv[2]).digest("hex"));
NODE
  ) || return 1
  printf '%s/%s.json\n' "$marker_dir" "$key"
}

run_no_mistakes_init() {
  local match_existing=${1:-initialize} captured_binding=${2:-} run_id=${3:-} run_branch=${4:-}
  local binary context_file binding_file context_dir marker parent fork_repository args=()
  [ -n "$repository" ] || github_exec_usage
  if ! fm_github_enabled; then
    binary=${FM_NO_MISTAKES_BINARY:-${FM_GITHUB_NO_MISTAKES_BINARY:-}}
    [ -n "$binary" ] || binary=$(command -v no-mistakes 2>/dev/null || true)
    [ -n "$binary" ] && [ -x "$binary" ] || { echo "error: no-mistakes command not found" >&2; return 1; }
    [ -z "$fork_url" ] || args+=(--fork-url "$fork_url")
    (cd "$repository" && command "$binary" init "${args[@]+"${args[@]}"}")
    return
  fi
  binary=$(fm_github_resolve_no_mistakes_binary 2>/dev/null || true)
  [ -n "$binary" ] && [ -f "$binary" ] && [ -x "$binary" ] || {
    echo "error: no-mistakes command not found" >&2
    return 1
  }
  fm_github_activate "$project" "$repository" "$profile" || return 1
  fm_github_validate_local_config "$repository" || return 1
  fm_github_preflight read || return 1
  if [ -z "$fork_url" ] && [ -n "$FM_GITHUB_FORK_OWNER" ]; then
    parent=${FM_GITHUB_REPOSITORY#github.com/}
    fork_url="https://github.com/$FM_GITHUB_FORK_OWNER/${parent#*/}.git"
  fi
  if [ -n "$fork_url" ]; then
    fork_repository=$(fm_github_repository_allowed "$fork_url") || {
      echo "error: configured no-mistakes fork is not the selected profile fork for this repository" >&2
      return 1
    }
    fm_github_preflight write "$fork_repository" || return 1
  else
    fm_github_preflight write || return 1
  fi
  [ -n "$FM_GITHUB_COMMIT_NAME" ] && [ -n "$FM_GITHUB_COMMIT_EMAIL" ] || {
    echo "error: profile $FM_GITHUB_PROFILE_ID needs commit_identity before no-mistakes initialization" >&2
    return 1
  }
  command "$binary" init --help 2>&1 | grep -q -- '--github-context' || {
    echo "error: installed no-mistakes does not support strict per-repository GitHub contexts" >&2
    return 1
  }
  context_dir="$FM_HOME/state/.github-routing-tmp"
  umask 077
  mkdir -p "$context_dir" || return 1
  context_file=$(mktemp "$context_dir/no-mistakes.XXXXXX") || return 1
  binding_file=$(mktemp "$context_dir/no-mistakes-binding.XXXXXX") || { rm -f "$context_file" 2>/dev/null || true; return 1; }
  trap "rm -f -- $(fm_github_shell_quote "$context_file") $(fm_github_shell_quote "$binding_file")" EXIT HUP INT TERM
  fm_github_no_mistakes_context_file "$context_file" || return 1
  fm_github_node - "$context_file" "$binding_file" "$fork_url" <<'NODE' || return 1
const fs = require("node:fs");
const [contextFile, bindingFile, forkUrl] = process.argv.slice(2);
const binding = {context: JSON.parse(fs.readFileSync(contextFile, "utf8")), fork_url: forkUrl};
fs.writeFileSync(bindingFile, `${JSON.stringify(binding, null, 2)}\n`, {mode: 0o600});
NODE
  [ -s "$binding_file" ] || return 1
  marker=$(no_mistakes_context_marker_path) || return 1
  if [ "$match_existing" = match ]; then
    if ! { [ -n "$run_id" ] && [ -n "$run_branch" ] \
      && [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(fm_github_file_mode "$marker")" = 600 ] \
      && fm_github_node - "$marker" "$binding_file" "$run_id" "$run_branch" <<'NODE'
const fs = require("node:fs");
const [markerFile, bindingFile, runId, branch] = process.argv.slice(2);
const marker = JSON.parse(fs.readFileSync(markerFile, "utf8"));
const binding = JSON.parse(fs.readFileSync(bindingFile, "utf8"));
if (marker.version !== 1 || marker.run_id !== runId || marker.branch !== branch
  || JSON.stringify(marker.binding) !== JSON.stringify(binding)) process.exit(1);
NODE
    }; then
      echo "error: active no-mistakes run is bound to a stale GitHub routing context" >&2
      return 1
    fi
  fi
  args=(--github-context "$context_file")
  [ -z "$fork_url" ] || args+=(--fork-url "$fork_url")
  (cd "$repository" && command "$binary" init "${args[@]}") || return 1
  if [ -n "$captured_binding" ]; then
    cp "$binding_file" "$captured_binding" && chmod 0600 "$captured_binding" || return 1
  fi
  rm -f -- "$context_file" "$binding_file"
  trap - EXIT HUP INT TERM
}

no_mistakes_run_details() {
  local binary=$1 output current_branch current_head run_head
  NM_RUN_ID= NM_RUN_BRANCH= NM_RUN_STATUS= NM_RUN_HEAD= NM_RUN_STATE=inactive
  output=$(cd "$repository" && LC_ALL=C command "$binary" axi status 2>/dev/null) || return 2
  NM_RUN_ID=$(printf '%s\n' "$output" | sed -n 's/^  id: //p' | head -1)
  NM_RUN_BRANCH=$(printf '%s\n' "$output" | sed -n 's/^  branch: //p' | head -1)
  NM_RUN_STATUS=$(printf '%s\n' "$output" | sed -n 's/^  status: //p' | head -1)
  NM_RUN_HEAD=$(printf '%s\n' "$output" | sed -n 's/^  head: //p' | head -1)
  [ -n "$NM_RUN_ID" ] && [ -n "$NM_RUN_BRANCH" ] && [ -n "$NM_RUN_STATUS" ] && [ -n "$NM_RUN_HEAD" ] || return 1
  current_branch=$(command "$FM_GITHUB_GIT_BINARY" -C "$repository" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  current_head=$(command "$FM_GITHUB_GIT_BINARY" -C "$repository" rev-parse HEAD 2>/dev/null) || return 1
  [ "$NM_RUN_BRANCH" = "$current_branch" ] || return 2
  run_head=$(command "$FM_GITHUB_GIT_BINARY" -C "$repository" rev-parse "$NM_RUN_HEAD^{commit}" 2>/dev/null) || return 2
  [ "$current_head" = "$run_head" ] \
    || command "$FM_GITHUB_GIT_BINARY" -C "$repository" merge-base --is-ancestor "$current_head" "$run_head" 2>/dev/null \
    || return 2
  case "$NM_RUN_STATUS" in
    running|fixing|ci|awaiting_approval|fix_review) NM_RUN_STATE=active ;;
    completed|failed|cancelled) NM_RUN_STATE=inactive ;;
    *) return 1 ;;
  esac
  return 0
}

record_no_mistakes_binding() {
  local binding=$1 run_id=$2 branch=$3 marker marker_tmp
  marker=$(no_mistakes_context_marker_path) || return 1
  { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } || { [ -f "$marker" ] && [ ! -L "$marker" ]; } || return 1
  marker_tmp=$(mktemp "${marker%/*}/.context.XXXXXX") || return 1
  if ! fm_github_node - "$binding" "$marker_tmp" "$run_id" "$branch" <<'NODE'
const fs = require("node:fs");
const [bindingFile, markerFile, runId, branch] = process.argv.slice(2);
const marker = {version: 1, run_id: runId, branch, binding: JSON.parse(fs.readFileSync(bindingFile, "utf8"))};
fs.writeFileSync(markerFile, `${JSON.stringify(marker, null, 2)}\n`, {mode: 0o600});
NODE
  then
    rm -f "$marker_tmp" 2>/dev/null || true
    return 1
  fi
  chmod 0600 "$marker_tmp" && mv -f "$marker_tmp" "$marker"
}

run_no_mistakes_command() {
  local marker lock capture= arg has_intent=0 prior_id= command_status=0 detail_status
  FM_GITHUB_NO_MISTAKES_BINARY=$(fm_github_resolve_no_mistakes_binary 2>/dev/null || true)
  [ -n "$FM_GITHUB_NO_MISTAKES_BINARY" ] && [ -f "$FM_GITHUB_NO_MISTAKES_BINARY" ] && [ -x "$FM_GITHUB_NO_MISTAKES_BINARY" ] || {
    echo "error: no-mistakes command not found" >&2
    return 1
  }
  if [ "${1:-}" = axi ] && { [ "${2:-}" = run ] || [ "${2:-}" = respond ]; }; then
    [ -n "${FM_GITHUB_PROJECT_PATH:-}" ] && [ -d "$FM_GITHUB_PROJECT_PATH" ] || {
      echo "error: strict no-mistakes refresh requires the configured project or task copy" >&2
      return 1
    }
    repository=$FM_GITHUB_PROJECT_PATH
    marker=$(no_mistakes_context_marker_path) || return 1
    lock="${marker%.json}.lock"
    fm_github_lock_acquire "$lock" 100 || { echo "error: no-mistakes routing operation is already in progress" >&2; return 1; }
    if no_mistakes_run_details "$FM_GITHUB_NO_MISTAKES_BINARY"; then detail_status=0; else detail_status=$?; fi
    if [ "$detail_status" -eq 1 ]; then
      fm_github_lock_release || true
      echo "error: cannot determine the current no-mistakes run identity" >&2
      return 1
    fi
    if [ "$detail_status" -eq 0 ]; then prior_id=$NM_RUN_ID; fi
    if [ "${2:-}" = respond ] || { [ "$detail_status" -eq 0 ] && [ "$NM_RUN_STATE" = active ]; }; then
      [ "$detail_status" -eq 0 ] && [ "$NM_RUN_STATE" = active ] || {
        fm_github_lock_release || true
        echo "error: no active current-branch no-mistakes run is available" >&2
        return 1
      }
      run_no_mistakes_init match "" "$NM_RUN_ID" "$NM_RUN_BRANCH" || { fm_github_lock_release || true; return 1; }
    else
      if [ "${2:-}" = run ]; then
        for arg in "$@"; do
          case "$arg" in --intent|--intent=*) has_intent=1 ;; esac
        done
        [ "$has_intent" -eq 1 ] || {
          echo "error: first strict no-mistakes run requires a new-run intent before binding GitHub routing" >&2
          fm_github_lock_release || true
          return 1
        }
        mkdir -p "$FM_HOME/state/.github-routing-tmp" || { fm_github_lock_release || true; return 1; }
        capture=$(mktemp "$FM_HOME/state/.github-routing-tmp/no-mistakes-captured.XXXXXX") || { fm_github_lock_release || true; return 1; }
        run_no_mistakes_init initialize "$capture" || { rm -f "$capture"; fm_github_lock_release || true; return 1; }
      fi
    fi
    if (cd "$repository" && command "$FM_GITHUB_NO_MISTAKES_BINARY" "$@"); then
      command_status=0
    else
      command_status=$?
    fi
    if [ -n "$capture" ]; then
      if no_mistakes_run_details "$FM_GITHUB_NO_MISTAKES_BINARY"; then detail_status=0; else detail_status=$?; fi
      if [ "$detail_status" -ne 0 ] || [ "$NM_RUN_ID" = "$prior_id" ]; then
        rm -f "$capture"
        fm_github_lock_release || true
        echo "error: no-mistakes did not establish an attributable new current-branch run" >&2
        return 1
      fi
      record_no_mistakes_binding "$capture" "$NM_RUN_ID" "$NM_RUN_BRANCH" || { rm -f "$capture"; fm_github_lock_release || true; return 1; }
      rm -f "$capture"
    fi
    fm_github_lock_release || return 1
    return "$command_status"
  fi
  command "$FM_GITHUB_NO_MISTAKES_BINARY" "$@"
}

action=${1:-}
[ "$#" -gt 0 ] || github_exec_usage
shift
case "$action" in
  validate)
    [ "$#" -eq 0 ] || github_exec_usage
    fm_github_validate_config
    ;;
  validate-all)
    [ "$#" -eq 0 ] || github_exec_usage
    validate_all
    ;;
  profile-id)
    parse_context_args "$@"
    [ "${#CONTEXT_REST[@]}" -eq 0 ] && [ "$pre_register_project" -eq 0 ] || github_exec_usage
    fm_github_resolve "$project" "$repository" "$profile"
    [ "$FM_GITHUB_MODE" = strict ] || exit 3
    printf '%s\n' "$FM_GITHUB_PROFILE_ID"
    ;;
  exec)
    FM_GITHUB_ALLOW_UNREGISTERED_PROJECT=0
    FM_GITHUB_CLONE_CAPABILITY=
    FM_GITHUB_CLONE_ROOT=
    export FM_GITHUB_ALLOW_UNREGISTERED_PROJECT FM_GITHUB_CLONE_CAPABILITY FM_GITHUB_CLONE_ROOT
    parse_context_args "$@"
    [ "${#CONTEXT_REST[@]}" -gt 0 ] || github_exec_usage
    if [ "$pre_register_project" -eq 1 ]; then
      FM_GITHUB_ALLOW_UNREGISTERED_PROJECT=1
      FM_GITHUB_CLONE_CAPABILITY=project
      export FM_GITHUB_ALLOW_UNREGISTERED_PROJECT FM_GITHUB_CLONE_CAPABILITY
    fi
    fm_github_context_command "$project" "$repository" "$profile" "${CONTEXT_REST[@]}"
    ;;
  no-mistakes-init)
    parse_context_args "$@"
    [ "${#CONTEXT_REST[@]}" -eq 0 ] && [ "$pre_register_project" -eq 0 ] || github_exec_usage
    run_no_mistakes_init initialize
    ;;
  child-git)
    [ "${1:-}" = --home ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] || github_exec_usage
    shift 3
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    if fm_github_validate_capability gh-repo-clone "$FM_GITHUB_GH_BINARY"; then
      FM_GITHUB_CLONE_CAPABILITY=gh-project
      FM_GITHUB_CLONE_ROOT="$FM_HOME/projects"
      export FM_GITHUB_CLONE_CAPABILITY FM_GITHUB_CLONE_ROOT
    fi
    fm_github_context_command "$project" "$repository" "$profile" git "$@"
    ;;
  child-gh)
    [ "${1:-}" = --home ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] || github_exec_usage
    shift 3
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    if fm_github_validate_capability gh-axi-preregister "$FM_GITHUB_GH_AXI_BINARY"; then
      FM_GITHUB_ALLOW_UNREGISTERED_PROJECT=1
      export FM_GITHUB_ALLOW_UNREGISTERED_PROJECT
    fi
    if [ "${1:-}" = api ]; then
      fm_github_internal_gh_api_command "$project" "$repository" "$profile" "$@"
    else
      fm_github_context_command "$project" "$repository" "$profile" gh "$@"
    fi
    ;;
  child-gh-axi)
    [ "${1:-}" = --home ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] || github_exec_usage
    shift 3
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" gh-axi "$@"
    ;;
  child-no-mistakes)
    [ "${1:-}" = --home ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] || github_exec_usage
    shift 3
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    run_no_mistakes_command "$@"
    ;;
  child-exec)
    [ "${1:-}" = --home ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] || github_exec_usage
    shift 3
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" "$@"
    ;;
  *) github_exec_usage ;;
esac
