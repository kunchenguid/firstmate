#!/usr/bin/env bash
# Provider abstraction for the source-control host a firstmate project ships to.
#
# firstmate's lifecycle scripts (fm-pr-check, fm-pr-merge, fm-review-diff,
# fm-teardown) do a handful of PR read/act operations themselves: read a PR's
# state and head sha, find a merged PR for a branch, and make a PR head commit
# resolvable locally. This library is the single owner of "how do we talk to the
# PR host" so those scripts never branch on provider individually.
#
# Provider is detected from a URL (fm_scm_provider_of_url) or from a worktree's
# origin remote (fm_scm_provider_of_remote), using the same host tokens
# no-mistakes uses: github.com -> github; dev.azure.com / ssh.dev.azure.com /
# *.visualstudio.com -> ado; anything else -> unknown.
#
# Routing rule (regression-safe): only a provably-ADO provider takes the `az`
# path. github AND unknown both take the exact `gh`/`gh-axi`/git path firstmate
# used before this library existed, so GitHub behaviour is byte-for-byte
# preserved and a non-github, non-ado remote keeps today's fallthrough.
#
# See docs/ado-backend.md for the az command shapes, JSON field names, and the
# fork-PR-for-ADO limitation.
#
# Sourceable (no side effects on source) and runnable as a CLI shim; the
# generated merge-poll state/<id>.check.sh calls back into the CLI form:
#   fm-scm-lib.sh pr-state <provider> <worktree> <pr-url>

# --- provider detection -----------------------------------------------------

fm_scm_provider_of_url() {
  case "$1" in
    *dev.azure.com*|*.visualstudio.com*) echo ado ;;
    *github.com*) echo github ;;
    *) echo unknown ;;
  esac
}

fm_scm_provider_of_remote() {
  local wt=$1 url
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || { echo unknown; return 0; }
  [ -n "$url" ] || { echo unknown; return 0; }
  fm_scm_provider_of_url "$url"
}

# --- PR URL parsing ---------------------------------------------------------
#
# Sets FM_SCM_PROVIDER and, per provider:
#   github: FM_SCM_PR_OWNER, FM_SCM_PR_REPO, FM_SCM_PR_NUMBER
#   ado:    FM_SCM_ADO_ORG_URL, FM_SCM_ADO_PROJECT, FM_SCM_ADO_REPO, FM_SCM_PR_NUMBER
# Returns 0 for a recognized github or ado PR URL, 1 otherwise (and prints the
# legacy error naming both accepted shapes).
# shellcheck disable=SC2034  # FM_SCM_* are outputs consumed by sourcing callers.
fm_scm_parse_pr_url() {
  local url=$1
  FM_SCM_PROVIDER=
  FM_SCM_PR_OWNER=
  FM_SCM_PR_REPO=
  FM_SCM_PR_NUMBER=
  FM_SCM_ADO_ORG_URL=
  FM_SCM_ADO_PROJECT=
  FM_SCM_ADO_REPO=
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    FM_SCM_PR_OWNER="${BASH_REMATCH[1]}"
    FM_SCM_PR_REPO="${BASH_REMATCH[2]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$FM_SCM_PR_OWNER" != *- ]]; then
      FM_SCM_PROVIDER=github
      return 0
    fi
  fi
  if [[ "$url" =~ ^https://dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/([0-9]+)/?$ ]]; then
    FM_SCM_ADO_ORG_URL="https://dev.azure.com/${BASH_REMATCH[1]}"
    FM_SCM_ADO_PROJECT="${BASH_REMATCH[2]}"
    FM_SCM_ADO_REPO="${BASH_REMATCH[3]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[4]}"
    FM_SCM_PROVIDER=ado
    return 0
  fi
  if [[ "$url" =~ ^https://([A-Za-z0-9][A-Za-z0-9-]*)\.visualstudio\.com/([^/]+)/_git/([^/]+)/pullrequest/([0-9]+)/?$ ]]; then
    FM_SCM_ADO_ORG_URL="https://${BASH_REMATCH[1]}.visualstudio.com"
    FM_SCM_ADO_PROJECT="${BASH_REMATCH[2]}"
    FM_SCM_ADO_REPO="${BASH_REMATCH[3]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[4]}"
    FM_SCM_PROVIDER=ado
    return 0
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> or an Azure DevOps https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<number> (got: $url)" >&2
  FM_SCM_PROVIDER=unknown
  return 1
}

_fm_scm_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*) n=${target##*/pull/}; n=${n%%[!0-9]*} ;;
    *"/pullrequest/"*) n=${target##*/pullrequest/}; n=${n%%[!0-9]*} ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# --- state normalizers ------------------------------------------------------

_fm_scm_norm_gh_state() {
  case "$1" in
    MERGED|merged) echo MERGED ;;
    OPEN|open) echo OPEN ;;
    CLOSED|closed) echo CLOSED ;;
    *) echo UNKNOWN ;;
  esac
}

_fm_scm_norm_ado_state() {
  case "$1" in
    completed) echo MERGED ;;
    active) echo OPEN ;;
    abandoned) echo CLOSED ;;
    *) echo UNKNOWN ;;
  esac
}

# --- host queries -----------------------------------------------------------

# gh pr view, run inside the worktree when it exists (a bare PR number needs the
# repo cwd; a full URL does not). Prints the -q selection, empty on any failure.
_fm_scm_gh_view() {
  local wt=$1 target=$2 fields=$3 q=$4
  command -v gh >/dev/null 2>&1 || return 0
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    ( cd "$wt" && gh pr view "$target" --json "$fields" -q "$q" 2>/dev/null )
  else
    gh pr view "$target" --json "$fields" -q "$q" 2>/dev/null
  fi
}

# az repos pr show -o json for a PR URL (org from the URL) or a bare number
# (org auto-detected from the worktree's remote via --detect). Empty on failure.
_fm_scm_ado_show() {
  local wt=$1 target=$2 n
  command -v az >/dev/null 2>&1 || return 1
  case "$target" in
    http*://*)
      fm_scm_parse_pr_url "$target" >/dev/null 2>&1 || return 1
      [ "$FM_SCM_PROVIDER" = ado ] || return 1
      az repos pr show --id "$FM_SCM_PR_NUMBER" --org "$FM_SCM_ADO_ORG_URL" --output json 2>/dev/null
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      ( cd "$wt" 2>/dev/null && az repos pr show --id "$n" --detect true --output json 2>/dev/null )
      ;;
  esac
}

# --- normalized PR operations -----------------------------------------------

# Normalized PR state: MERGED|OPEN|CLOSED|UNKNOWN. <target> is a PR URL or,
# for github/unknown, a bare number resolved from the worktree cwd.
fm_scm_pr_state() {
  local provider=$1 wt=$2 target=$3 json status raw
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || { echo UNKNOWN; return 0; }
      json=$(_fm_scm_ado_show "$wt" "$target") || { echo UNKNOWN; return 0; }
      status=$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null)
      _fm_scm_norm_ado_state "$status"
      ;;
    *)
      raw=$(_fm_scm_gh_view "$wt" "$target" state '.state')
      _fm_scm_norm_gh_state "$raw"
      ;;
  esac
}

# PR head commit sha, or empty when unavailable.
fm_scm_pr_head() {
  local provider=$1 wt=$2 target=$3 json
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || return 0
      json=$(_fm_scm_ado_show "$wt" "$target") || return 0
      printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null
      ;;
    *)
      _fm_scm_gh_view "$wt" "$target" headRefOid '.headRefOid'
      ;;
  esac
}

# Combined normalized state and head in one host round-trip: "STATE\tHEAD".
# Returns non-zero when the host lookup fails, so a caller can fall back.
fm_scm_pr_state_head() {
  local provider=$1 wt=$2 target=$3 json status head raw state
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || return 1
      json=$(_fm_scm_ado_show "$wt" "$target") || return 1
      [ -n "$json" ] || return 1
      status=$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null)
      head=$(printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null)
      printf '%s\t%s\n' "$(_fm_scm_norm_ado_state "$status")" "$head"
      ;;
    *)
      raw=$(_fm_scm_gh_view "$wt" "$target" state,headRefOid '.state + "\t" + .headRefOid') || return 1
      [ -n "$raw" ] || return 1
      state=${raw%%$'\t'*}
      head=${raw#*$'\t'}
      [ "$state" != "$raw" ] || return 1
      printf '%s\t%s\n' "$(_fm_scm_norm_gh_state "$state")" "$head"
      ;;
  esac
}

# Merged PR number whose source branch is <branch>, or non-zero when none is
# found or any lookup fails (fail-safe: caller treats it as "no PR").
fm_scm_pr_number_for_branch() {
  local provider=$1 wt=$2 branch=$3 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  case "$provider" in
    ado)
      command -v az >/dev/null 2>&1 || return 1
      command -v jq >/dev/null 2>&1 || return 1
      out=$( cd "$wt" 2>/dev/null && az repos pr list --source-branch "refs/heads/$branch" --status completed --detect true --output json 2>/dev/null ) || return 1
      n=$(printf '%s' "$out" | jq -r '.[0].pullRequestId // empty' 2>/dev/null)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
    *)
      out=$( cd "$wt" 2>/dev/null && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
      n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
  esac
}

# Ensure <commit> exists locally in <wt>, fetching by the provider's mechanism
# (github refs/pull/<n>/head; ado the PR source branch). Returns 0 iff the
# object is present afterwards.
fm_scm_ensure_commit_object() {
  local provider=$1 wt=$2 target=$3 commit=$4 n json ref
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  case "$provider" in
    ado)
      json=$(_fm_scm_ado_show "$wt" "$target") || return 1
      command -v jq >/dev/null 2>&1 || return 1
      ref=$(printf '%s' "$json" | jq -r '.sourceRefName // empty' 2>/dev/null)
      [ -n "$ref" ] || return 1
      git -C "$wt" fetch --quiet origin "$ref" >/dev/null 2>&1 || return 1
      git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
      git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
      ;;
  esac
}

# Resolve the PR head to a locally-resolvable commit sha for diffing: the
# recorded head when it already resolves, else fetch the PR head and echo the
# resolved sha. Non-zero when the head cannot be resolved (caller warns and
# falls back to the local branch).
fm_scm_resolve_pr_head_commit() {
  local provider=$1 wt=$2 target=$3 recorded=$4 n resolved json head ref
  if [ -n "$recorded" ] && git -C "$wt" cat-file -e "$recorded^{commit}" 2>/dev/null; then
    printf '%s' "$recorded"
    return 0
  fi
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || return 1
      json=$(_fm_scm_ado_show "$wt" "$target") || return 1
      head=$(printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null)
      ref=$(printf '%s' "$json" | jq -r '.sourceRefName // empty' 2>/dev/null)
      [ -n "$head" ] || return 1
      if git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null; then
        printf '%s' "$head"
        return 0
      fi
      [ -n "$ref" ] || return 1
      git -C "$wt" fetch --quiet origin "$ref" >/dev/null 2>&1 || return 1
      git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null || return 1
      printf '%s' "$head"
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
      resolved=$(git -C "$wt" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
      [ -n "$resolved" ] || return 1
      printf '%s' "$resolved"
      ;;
  esac
}

# --- CLI shim ---------------------------------------------------------------

fm_scm_main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    provider-of-url) fm_scm_provider_of_url "${1:-}" ;;
    provider-of-remote) fm_scm_provider_of_remote "${1:-}" ;;
    pr-state) fm_scm_pr_state "${1:-}" "${2:-}" "${3:-}" ;;
    pr-head) fm_scm_pr_head "${1:-}" "${2:-}" "${3:-}" ;;
    pr-number-for-branch) fm_scm_pr_number_for_branch "${1:-}" "${2:-}" "${3:-}" ;;
    *)
      echo "usage: fm-scm-lib.sh {provider-of-url|provider-of-remote|pr-state|pr-head|pr-number-for-branch} ..." >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_scm_main "$@"
fi
