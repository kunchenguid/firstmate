#!/usr/bin/env bash
# Guarded command owner for per-project GitHub account routing.
# Usage:
#   fm-github-exec.sh validate
#   fm-github-exec.sh validate-all
#   fm-github-exec.sh profile-id --project <name> --repository <path-or-url> [--profile <id>]
#   fm-github-exec.sh exec --project <name> --repository <path-or-url> [--profile <id>] -- <command> [args...]
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
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

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
  [ "${FM_GITHUB_ACTIVE:-}" = 1 ] && [ -n "${FM_GITHUB_PROFILE_ID:-}" ] && [ -n "${FM_GITHUB_REPOSITORY:-}" ] || {
    echo "error: guarded GitHub child has no selected project context" >&2
    return 1
  }
  project=${FM_GITHUB_PROJECT:-}
  repository=$FM_GITHUB_REPOSITORY
  profile=$FM_GITHUB_PROFILE_ID
}

run_no_mistakes_init() {
  local binary context_file context_dir parent fork_repository args=()
  [ -n "$repository" ] || github_exec_usage
  if ! fm_github_enabled; then
    [ -z "$fork_url" ] || args+=(--fork-url "$fork_url")
    (cd "$repository" && command "${FM_NO_MISTAKES_BINARY:-no-mistakes}" init "${args[@]+"${args[@]}"}")
    return
  fi
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
  binary=${FM_NO_MISTAKES_BINARY:-no-mistakes}
  command "$binary" init --help 2>&1 | grep -q -- '--github-context' || {
    echo "error: installed no-mistakes does not support strict per-repository GitHub contexts" >&2
    return 1
  }
  context_dir="$FM_HOME/state/.github-routing-tmp"
  umask 077
  mkdir -p "$context_dir"
  context_file=$(mktemp "$context_dir/no-mistakes.XXXXXX.json")
  trap 'rm -f -- "$context_file"' EXIT HUP INT TERM
  fm_github_no_mistakes_context_file "$context_file" || return 1
  args=(--github-context "$context_file")
  [ -z "$fork_url" ] || args+=(--fork-url "$fork_url")
  (cd "$repository" && command "$binary" init "${args[@]}")
  rm -f -- "$context_file"
  trap - EXIT HUP INT TERM
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
    [ "${#CONTEXT_REST[@]}" -eq 0 ] || github_exec_usage
    fm_github_resolve "$project" "$repository" "$profile"
    [ "$FM_GITHUB_MODE" = strict ] || exit 3
    printf '%s\n' "$FM_GITHUB_PROFILE_ID"
    ;;
  exec)
    parse_context_args "$@"
    [ "${#CONTEXT_REST[@]}" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" "${CONTEXT_REST[@]}"
    ;;
  no-mistakes-init)
    parse_context_args "$@"
    [ "${#CONTEXT_REST[@]}" -eq 0 ] || github_exec_usage
    run_no_mistakes_init
    ;;
  child-git)
    [ "${1:-}" = -- ] || github_exec_usage
    shift
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" git "$@"
    ;;
  child-gh)
    [ "${1:-}" = -- ] || github_exec_usage
    shift
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" gh "$@"
    ;;
  child-gh-axi)
    [ "${1:-}" = -- ] || github_exec_usage
    shift
    child_context
    [ "$#" -gt 0 ] || github_exec_usage
    fm_github_context_command "$project" "$repository" "$profile" gh-axi "$@"
    ;;
  *) github_exec_usage ;;
esac
