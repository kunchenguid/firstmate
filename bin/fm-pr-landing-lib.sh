#!/usr/bin/env bash
# fm-pr-landing-lib.sh - the single owner of "can this machine merge into the
# repository that hosts this pull request?".
#
# Sourced, never executed.
#
# A pull request raised against a read-only upstream is a legitimate thing to
# open and push; what it is not is a landing path. Treating one as a landing
# path - arming its merge poll, or reporting it as a pull request awaiting a
# merge decision - asks the captain for a merge nobody here can perform. This
# library answers that one question so no caller has to re-derive it, and so
# the answer never comes from a hardcoded repository name: a second fork, or a
# rename, must not silently turn the guard off.
#
#   fm_pr_landing_resolve <provider> <host> <path>
#       Sets FM_PR_LANDING_VERDICT and FM_PR_LANDING_DETAIL. Always returns 0;
#       the verdict is the result. Verdicts:
#         mergeable    the forge reports the viewer can push to that repository,
#                      which is what merging a pull request there requires.
#         unmergeable  the forge reports the viewer cannot.
#         unreachable  the forge could not answer: the CLI is absent, the call
#                      failed or timed out, or the reply was not a boolean.
#         unchecked    this provider has no viewer-permission source this
#                      library is verified against (see the gitlab note below).
#
#   fm_pr_landing_fork_hint <worktree>
#       Prints the GitHub owner/repository the worktree pushes to, when its
#       origin resolves to one and it is not the repository already named.
#       Prints nothing otherwise. This is the fork: firstmate's crewmates push
#       their branch to origin, and `gh pr create` defaults the pull request to
#       origin's PARENT, which is exactly how work lands upstream by accident.
#
#   fm_pr_landing_refusal <path> <fork-hint>
#       Prints the one-line refusal naming where the work has to land instead.
#
# Provider coverage is deliberately asymmetric, and the asymmetry is a coverage
# fact rather than a policy one. GitHub's REST repository object carries the
# viewer's own permissions, so `gh-axi api` answers the question directly and
# the answer is verified against the real forge. GitLab has no equally direct
# answer: a member's numeric access level does not by itself decide whether a
# merge request can be merged, because a project's merge access is separately
# configurable per protected branch. Guessing a threshold would ship an
# unverified rule, so gitlab returns "unchecked" and callers leave that path
# exactly as it was rather than refusing on an answer this library did not get.
#
# FM_PR_LANDING_TIMEOUT bounds the forge call (default 20 seconds); the caller
# must have sourced fm-timeout-lib.sh.
set -u

FM_PR_LANDING_VERDICT=
FM_PR_LANDING_DETAIL=

fm_pr_landing_timeout() {
  local bound=${FM_PR_LANDING_TIMEOUT:-20}
  case "$bound" in ''|*[!0-9]*|0) bound=20 ;; esac
  printf '%s\n' "$bound"
}

# GitHub requires push access to merge a pull request, so `.permissions.push` is
# the field that answers the question. Only the exact booleans are trusted: any
# other reply - an error page, an empty body, a null from a response with no
# permissions object - is an answer we did not get, not a permissive one.
fm_pr_landing_github() {  # <path>
  local path=$1 out rc=0
  if ! command -v gh-axi >/dev/null 2>&1; then
    FM_PR_LANDING_VERDICT=unreachable
    FM_PR_LANDING_DETAIL='gh-axi is not on PATH'
    return 0
  fi
  out=$(fm_run_timed "$(fm_pr_landing_timeout)" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh-axi api "/repos/$path" --jq .permissions.push 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    FM_PR_LANDING_VERDICT=unreachable
    FM_PR_LANDING_DETAIL='the forge did not answer within the time limit'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    FM_PR_LANDING_VERDICT=unreachable
    FM_PR_LANDING_DETAIL='the forge could not be queried'
    return 0
  fi
  case "$out" in
    true)
      FM_PR_LANDING_VERDICT=mergeable
      FM_PR_LANDING_DETAIL='the forge reports write access'
      ;;
    false)
      FM_PR_LANDING_VERDICT=unmergeable
      FM_PR_LANDING_DETAIL='the forge reports no write access'
      ;;
    *)
      FM_PR_LANDING_VERDICT=unreachable
      FM_PR_LANDING_DETAIL='the forge did not report a permission'
      ;;
  esac
}

fm_pr_landing_resolve() {  # <provider> <host> <path>
  local provider=${1-} host=${2-} path=${3-}
  FM_PR_LANDING_VERDICT=
  FM_PR_LANDING_DETAIL=
  case "$provider" in
    github)
      if [ "$host" != github.com ] || [ -z "$path" ]; then
        FM_PR_LANDING_VERDICT=unreachable
        FM_PR_LANDING_DETAIL='the pull request identity was not addressable'
        return 0
      fi
      fm_pr_landing_github "$path"
      ;;
    gitlab)
      FM_PR_LANDING_VERDICT=unchecked
      FM_PR_LANDING_DETAIL='no verified viewer-permission source for this forge'
      ;;
    *)
      # Both are read by the callers listed in this header, never inside it.
      # shellcheck disable=SC2034
      FM_PR_LANDING_VERDICT=unreachable
      # shellcheck disable=SC2034
      FM_PR_LANDING_DETAIL='unknown forge'
      ;;
  esac
}

# Accepts the ssh and https origin spellings git itself writes. The slug is
# validated against the same GitHub owner/repository shape the URL parser
# enforces, so a hint can never smuggle arbitrary text into a refusal line.
fm_pr_landing_fork_hint() {  # <worktree> [<pr-path>]
  local wt=${1-} pr_path=${2-} url slug
  local LC_ALL=C
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  case "$url" in
    *github.com[:/]*) slug=${url##*github.com} ; slug=${slug#[:/]} ;;
    *) return 0 ;;
  esac
  slug=${slug%.git}
  slug=${slug%/}
  [[ "$slug" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})$ ]] || return 0
  [ "$slug" != "$pr_path" ] || return 0
  printf '%s\n' "$slug"
}

fm_pr_landing_refusal() {  # <pr-path> <fork-hint>
  local path=${1-} fork=${2-}
  if [ -n "$fork" ]; then
    printf 'error: %s cannot be merged from this machine; land this work on %s instead\n' \
      "$path" "$fork"
  else
    printf 'error: %s cannot be merged from this machine; land this work on the fork this project pushes to instead\n' \
      "$path"
  fi
}
