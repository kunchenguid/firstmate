#!/usr/bin/env bash
# Shared capability boundary for a ship task's captured completion policy.
#
# `verified-production` is supported only when the task will publish a GitHub
# pull request through the existing path that records `pr_head=`. The provider
# is resolved by GitHub's own CLI from the project repository, then passed
# through fm-pr-lib.sh's canonical provider parser. Origin-string shapes are not
# provider authority: an implicit GitLab project and an unsupported GitHub
# Enterprise URL both fail this positive check.
#
# Callers source fm-pr-lib.sh before this file.

fm_completion_policy_supported() { # <policy> <mode> <project-dir> <registered-forge> <caller>
  local policy=$1 mode=$2 project=$3 forge=$4 caller=$5 repo_url

  case "$policy" in
    landed) return 0 ;;
    verified-production) ;;
    *)
      echo "error: $caller: unknown completion policy '$policy'" >&2
      return 1
      ;;
  esac

  case "$mode" in
    no-mistakes|direct-PR) ;;
    *)
      echo "error: $caller: completion=verified-production requires the GitHub PR delivery path that records an immutable reviewed head; mode=${mode:-none} cannot supply that evidence identity" >&2
      return 1
      ;;
  esac
  [ "$forge" = none ] || {
    echo "error: $caller: completion=verified-production requires the GitHub PR delivery path that records an immutable reviewed head; forge=${forge:-unknown} cannot supply that evidence identity" >&2
    return 1
  }
  if [ ! -d "$project" ] || ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $caller: completion=verified-production cannot verify the project's GitHub PR delivery capability at $project" >&2
    return 1
  fi
  command -v gh >/dev/null 2>&1 || {
    echo "error: $caller: completion=verified-production requires gh to verify the GitHub PR delivery path that records pr_head" >&2
    return 1
  }
  repo_url=$(
    unset GH_REPO
    cd "$project" && gh repo view --json url -q .url 2>/dev/null
  ) || {
    echo "error: $caller: completion=verified-production is supported only when gh resolves this project as a GitHub repository whose PR path records pr_head" >&2
    return 1
  }
  fm_pr_url_parse "$repo_url/pull/1" && [ "$FM_PR_PROVIDER" = github ] || {
    echo "error: $caller: completion=verified-production is supported only for the canonical GitHub PR delivery path that records pr_head" >&2
    return 1
  }
}

fm_completion_policy_pr_head_valid() { # <policy> <provider> <head>
  local policy=$1 provider=$2 head=$3
  [ "$policy" != verified-production ] && return 0
  [ "$provider" = github ] || return 1
  [ "${#head}" -eq 40 ] || return 1
  case "$head" in *[!0-9a-f]*) return 1 ;; esac
}
