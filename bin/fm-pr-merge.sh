#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub or Gitea/Forgejo PR URL is parsed by
# bin/fm-pr-lib.sh and the derived owner/repository and PR number are passed
# to gh-axi (GitHub) or tea (Gitea/Forgejo) as separate arguments. GitLab merge
# request URLs still parse, for the watcher, but this path still refuses them:
# no owner/repository pair can address GitLab's arbitrary-depth namespace, so
# merging a merge request stays a deliberate manual step.
#
# Merge method defaults to a squash merge when the caller passes no explicit
# merge-method flag after the optional -- separator: --squash, --merge,
# --rebase, or --method(=...) for GitHub, --style(=...)/-s for Gitea/Forgejo.
# Extra args must not override the repository or, for Gitea/Forgejo, the tea
# login, because both come only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still refuses them: no owner/repository pair can address
# GitLab's arbitrary-depth namespace, so merging a merge request stays a
# deliberate manual step until GitLab merge parity is a separate change.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != gitea ]; }; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_github_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_has_gitea_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --style|--style=*|-s) return 0 ;;
    esac
  done
  return 1
}

# The repository must come only from the validated URL, for both providers,
# and for Gitea/Forgejo the tea login (which instance is addressed) must too.
reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*|-r|-r?*|--login|--login=*|-l|-l?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# tea addresses a self-hosted instance through a configured login rather than
# through the URL, so the login whose own host matches the validated record's
# host is picked here, exactly as bin/fm-pr-poll.sh picks it for polling. Any
# ambiguity or missing login is a real blocker here, unlike the silent poll,
# because merging is a deliberate action with one clear point to report it.
gitea_login_for_host() {
  local target=$1 logins name login_url lhost login matches
  login=
  matches=0
  logins=$(tea login list -o csv 2>/dev/null) || return 1
  [ -n "$logins" ] || return 1
  while IFS=, read -r name login_url _rest; do
    [ -n "$name" ] || continue
    lhost=${login_url#http://}
    lhost=${lhost#https://}
    lhost=${lhost%%/*}
    lhost=${lhost%%:*}
    case "$lhost" in
      *[A-Z]*) lhost=$(printf '%s' "$lhost" | tr '[:upper:]' '[:lower:]') ;;
    esac
    if [ "$lhost" = "$target" ]; then
      matches=$((matches + 1))
      login=$name
    fi
  done < <(printf '%s\n' "$logins" | tail -n +2)
  [ "$matches" -eq 1 ] && [ -n "$login" ] || return 1
  printf '%s\n' "$login"
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$PROVIDER" = github ]; then
  merge_args=()
  if ! caller_has_github_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
else
  if ! command -v tea >/dev/null 2>&1; then
    echo "error: merging a Gitea/Forgejo pull request requires tea on PATH" >&2
    exit 1
  fi
  GITEA_LOGIN=$(gitea_login_for_host "$HOST") || {
    echo "error: could not resolve exactly one tea login for $HOST" >&2
    exit 1
  }
  merge_args=()
  if ! caller_has_gitea_merge_method "$@"; then
    merge_args=(--style squash)
  fi
  tea pulls merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --login "$GITEA_LOGIN" \
    "${merge_args[@]+"${merge_args[@]}"}" "$@"
fi
