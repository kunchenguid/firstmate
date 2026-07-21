#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# bin/fm-pr-lib.sh parses the canonical PR URL for both providers and the
# derived parts drive a provider-specific merge:
#   - GitHub: the owner/repository and PR number are passed to gh-axi pr merge
#     as separate arguments. The merge method defaults to --squash when the
#     caller passes none of --squash, --merge, --rebase, or --method after the
#     optional -- separator; other gh-axi pr merge flags are forwarded.
#   - Bitbucket Data Center: the PR is merged through the 1.0 REST API with
#     curl, which requires BB_TOKEN in the environment. It uses the server's
#     default merge strategy, so --squash/--merge/--rebase/--method are
#     GitHub-only and rejected for DC with no extra args accepted.
# Extra args must not include --repo or -R because the repository comes only
# from the URL (GitHub path).
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra merge args>]
#   GitHub extra args are forwarded to gh-axi pr merge.
#   Bitbucket Data Center takes no extra args and reads BB_TOKEN from the env.
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
# them, but this merge path addresses only GitHub and Bitbucket Data Center.
# A GitLab merge request URL is refused rather than sent to the wrong forge.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != bitbucket-dc ]; }; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
PR_PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Bitbucket Data Center merges through curl with the server's default strategy,
# so it accepts no passthrough flags; the GitHub merge-method flags in particular
# have no DC meaning and must not be silently ignored.
reject_dc_merge_args() {
  [ "$#" -eq 0 ] || {
    echo "error: Bitbucket Data Center merge accepts no flags; it uses the server default strategy, so drop --squash/--merge/--rebase/--method and any other gh-axi-only args" >&2
    return 1
  }
}

# Reject provider-unsupported extra args before any state mutation, mirroring the
# GitHub repo-override guard. The earlier guard refused every other provider, so
# here PR_PROVIDER is github or bitbucket-dc and the else branch is the GitHub path.
if [ "$PR_PROVIDER" = bitbucket-dc ]; then
  reject_dc_merge_args "$@" || exit 1
else
  reject_repo_overrides "$@" || exit 1
fi

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

# fm_pr_dc_json_field <file> <jq-expr>: echo one JSON field with quoting
# stripped (jq -r), or empty on any tool error or missing field. The jq failure
# is absorbed by the trailing || so the call is safe under set -e.
fm_pr_dc_json_field() {
  jq -r "$2 // empty" "$1" 2>/dev/null || printf ''
}

# fm_pr_dc_http <token> <body-file> <method> <url>: write the response body to
# <body-file> and echo the HTTP status code (000 when curl itself fails). A
# transport failure is a merge failure, never a silent skip.
fm_pr_dc_http() {
  local token=$1 body_file=$2 method=$3 url=$4 code
  code=$(curl -sS -X "$method" \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/json' \
    -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null) || code=000
  printf '%s\n' "$code"
}

# fm_pr_merge_dc <token> <host> <owner> <repo> <number>: merge a Bitbucket Data
# Center pull request through the 1.0 REST API. The owner re-derives the REST
# scope from fm-pr-lib's parse convention: a leading '~' marks a personal repo
# (/users/<slug>/) and a bare key marks a project repo (/projects/<KEY>/).
# Returns 0 once the PR reports MERGED (including an already-merged no-op), 1 on
# any fetch or merge failure.
fm_pr_merge_dc() {
  local token=$1 host=$2 owner=$3 repo=$4 number=$5 scope base body version state code merged_state
  case "$owner" in
    '~'*) scope="users/${owner#\~}" ;;
    *) scope="projects/$owner" ;;
  esac
  base="https://$host/rest/api/1.0/$scope/repos/$repo/pull-requests/$number"
  body=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-dc.XXXXXX") || return 1

  code=$(fm_pr_dc_http "$token" "$body" GET "$base")
  case "$code" in
    2[0-9][0-9]) ;;
    *)
      echo "error: Bitbucket Data Center PR fetch failed (HTTP $code)" >&2
      [ -s "$body" ] && cat "$body" >&2
      rm -f "$body"
      return 1
      ;;
  esac
  version=$(fm_pr_dc_json_field "$body" '.version')
  state=$(fm_pr_dc_json_field "$body" '.state')
  if [ -z "$version" ]; then
    echo "error: Bitbucket Data Center PR has no merge version in the response" >&2
    [ -s "$body" ] && cat "$body" >&2
    rm -f "$body"
    return 1
  fi
  if [ "$state" = MERGED ]; then
    echo "already merged: $base"
    rm -f "$body"
    return 0
  fi

  # Atlassian documents PUT .../merge; the fleet instance answers 405 to PUT and
  # requires POST, so retry once on 405 before treating the response as failure.
  code=$(fm_pr_dc_http "$token" "$body" PUT "$base/merge?version=$version")
  if [ "$code" = 405 ]; then
    code=$(fm_pr_dc_http "$token" "$body" POST "$base/merge?version=$version")
  fi
  case "$code" in
    2[0-9][0-9]) ;;
    *)
      echo "error: Bitbucket Data Center merge failed (HTTP $code)" >&2
      [ -s "$body" ] && cat "$body" >&2
      rm -f "$body"
      return 1
      ;;
  esac
  merged_state=$(fm_pr_dc_json_field "$body" '.state')
  if [ "$merged_state" = MERGED ]; then
    echo "merged: $base"
    rm -f "$body"
    return 0
  fi
  echo "error: Bitbucket Data Center merge did not report MERGED state" >&2
  [ -s "$body" ] && cat "$body" >&2
  rm -f "$body"
  return 1
}

if [ "$PR_PROVIDER" = bitbucket-dc ]; then
  if [ -z "${BB_TOKEN:-}" ]; then
    echo "error: BB_TOKEN is required to merge a Bitbucket Data Center PR" >&2
    exit 1
  fi
  fm_pr_merge_dc "$BB_TOKEN" "$PR_HOST" "$PR_OWNER" "$PR_REPO" "$PR_NUMBER"
else
  merge_args=()
  if ! caller_has_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
fi
