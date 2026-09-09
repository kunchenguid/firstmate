#!/usr/bin/env bash
# Refuse a PR whose changed content came wholesale from a suspect branch.
#
# The script runs against the Git clone at the caller's current directory. It
# fetches the PR head and named branches into private remote-tracking or review
# refs, then performs an ancestry check, a foreign-commit check, and a
# foreign-content check. It never checks out a branch or changes the caller's
# working tree.
#
# Usage: fm-pr-base-check.sh <pr-url> [--base <branch>] [--against <branch>]
#   --base <branch>       PR base branch; otherwise read it from GitHub.
#   --against <branch>    branch whose content must not be used; repeatable;
#                         defaults to main.
#
# A failed ancestry check alone is reported but does not fail. A commit that is
# reachable from an against branch, or a changed file whose PR blob equals an
# against blob and differs from the base blob, fails the check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-pr-base-check.sh <pr-url> [--base <branch>] [--against <branch>]

Checks that a PR did not take commits or changed file content from a foreign
branch. The --against flag can be repeated and defaults to main. The script
uses the Git clone at the current directory and does not change its checkout.
EOF
}

fail_closed() {
  echo "PR base check: ERROR: $1" >&2
  exit 1
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ "$#" -ge 1 ] || { usage; exit 2; }
RAW_URL=$1
shift

BASE_BRANCH=
AGAINST_BRANCHES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || { echo "error: --base requires a branch" >&2; exit 2; }
      [ -z "$BASE_BRANCH" ] || { echo "error: --base may be used only once" >&2; exit 2; }
      BASE_BRANCH=$2
      shift 2
      ;;
    --against)
      [ "$#" -ge 2 ] || { echo "error: --against requires a branch" >&2; exit 2; }
      AGAINST_BRANCHES+=("$2")
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ "${#AGAINST_BRANCHES[@]}" -eq 0 ]; then
  AGAINST_BRANCHES=(main)
fi

if ! fm_pr_url_parse "$RAW_URL" || [ "$FM_PR_PROVIDER" != github ]; then
  fail_closed "cannot parse a GitHub PR URL"
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER

CLONE=$(git rev-parse --show-toplevel 2>/dev/null) \
  || fail_closed "the current directory is not a Git clone"
ORIGIN_URL=$(git -C "$CLONE" remote get-url origin 2>/dev/null) \
  || fail_closed "the Git clone has no origin remote"

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Every branch and the PR head come from origin, so origin must be the same
# repository the PR URL names. A local clone path carries no forge identity to
# compare and is left to the branch and PR head fetches to reject.
verify_origin_repo() {
  local url=$1 host path
  case "$url" in
    file://*|/*|./*|../*|~*) return 0 ;;
    *://*)
      path=${url#*://}
      host=${path%%/*}
      case "$path" in
        */*) path=${path#*/} ;;
        *) path= ;;
      esac
      ;;
    *:*)
      host=${url%%:*}
      path=${url#*:}
      ;;
    *) return 0 ;;
  esac
  host=${host#*@}
  host=${host%%:*}
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  [ "$(lowercase "$host")" = github.com ] \
    || fail_closed "origin is not the PR repository: $url"
  [ "$(lowercase "$path")" = "$(lowercase "$PR_OWNER/$PR_REPO")" ] \
    || fail_closed "origin is not the PR repository: $url"
}

verify_origin_repo "$ORIGIN_URL"

valid_branch() {
  local branch=$1
  [ -n "$branch" ] || return 1
  case "$branch" in
    origin/*|-*) return 1 ;;
  esac
  git -C "$CLONE" check-ref-format --branch "$branch" >/dev/null 2>&1
}

fetch_branch() {
  local branch=$1
  valid_branch "$branch" || fail_closed "invalid branch name: $branch"
  git -C "$CLONE" fetch --quiet origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 \
    || fail_closed "cannot fetch branch: $branch"
  git -C "$CLONE" rev-parse --verify --quiet \
    "refs/remotes/origin/$branch^{commit}" >/dev/null \
    || fail_closed "branch does not resolve after fetch: $branch"
}

if [ -z "$BASE_BRANCH" ]; then
  API_OUTPUT=$(gh-axi api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
    --template '{{.base.ref}}' 2>/dev/null) \
    || fail_closed "cannot determine the PR base branch from GitHub"
  BASE_BRANCH=$(printf '%s\n' "$API_OUTPUT" | sed -n 's/^  body: //p')
  if [ -z "$BASE_BRANCH" ]; then
    [ "$(printf '%s\n' "$API_OUTPUT" | wc -l | tr -d ' ')" = 1 ] \
      || fail_closed "GitHub returned an unreadable PR base branch"
    BASE_BRANCH=$API_OUTPUT
  fi
  case "$BASE_BRANCH" in
    \"*\") BASE_BRANCH=${BASE_BRANCH#\"}; BASE_BRANCH=${BASE_BRANCH%\"} ;;
  esac
fi

valid_branch "$BASE_BRANCH" || fail_closed "invalid PR base branch: $BASE_BRANCH"
fetch_branch "$BASE_BRANCH"

UNIQUE_AGAINST_BRANCHES=()
for branch in "${AGAINST_BRANCHES[@]}"; do
  valid_branch "$branch" || fail_closed "invalid against branch: $branch"
  duplicate=false
  for existing in "${UNIQUE_AGAINST_BRANCHES[@]:-}"; do
    [ "$existing" = "$branch" ] && duplicate=true
  done
  if [ "$duplicate" = false ]; then
    UNIQUE_AGAINST_BRANCHES+=("$branch")
    fetch_branch "$branch"
  fi
done

PR_HEAD_REF="refs/fm-pr-base-check/pull/$PR_NUMBER/head"
PR_HEAD_REF_WRITTEN=false
FILE_LIST_TMP=
cleanup() {
  local rc=$?
  [ -z "$FILE_LIST_TMP" ] || rm -f -- "$FILE_LIST_TMP" || true
  if [ "$PR_HEAD_REF_WRITTEN" = true ]; then
    git -C "$CLONE" update-ref -d "$PR_HEAD_REF" >/dev/null 2>&1 || true
  fi
  return "$rc"
}
trap cleanup EXIT

PR_HEAD_REF_WRITTEN=true
git -C "$CLONE" fetch --quiet origin \
  "+refs/pull/$PR_NUMBER/head:$PR_HEAD_REF" >/dev/null 2>&1 \
  || fail_closed "cannot fetch PR head: $URL"
git -C "$CLONE" rev-parse --verify --quiet "$PR_HEAD_REF^{commit}" >/dev/null \
  || fail_closed "fetched PR head does not resolve: $URL"

BASE_REF="refs/remotes/origin/$BASE_BRANCH"
PR_HEAD=$(git -C "$CLONE" rev-parse --verify "$PR_HEAD_REF^{commit}") \
  || fail_closed "cannot resolve the fetched PR head"

if git -C "$CLONE" merge-base --is-ancestor "$BASE_REF" "$PR_HEAD_REF" >/dev/null 2>&1; then
  ANCESTRY="base is an ancestor of PR head"
else
  ancestry_rc=$?
  [ "$ancestry_rc" -eq 1 ] \
    || fail_closed "cannot determine whether the base is an ancestor of the PR head"
  ANCESTRY="base is not an ancestor of PR head"
fi

COMMIT_LINES=$(git -C "$CLONE" log --format='%H%x09%s' "$BASE_REF..$PR_HEAD_REF" 2>/dev/null) \
  || fail_closed "cannot list PR commits"
FOREIGN_COMMITS=()
while IFS=$'\t' read -r commit subject; do
  [ -n "${commit:-}" ] || continue
  for index in "${!UNIQUE_AGAINST_BRANCHES[@]}"; do
    against_branch=${UNIQUE_AGAINST_BRANCHES[$index]}
    against_ref="refs/remotes/origin/$against_branch"
    if git -C "$CLONE" merge-base --is-ancestor "$commit" "$against_ref" >/dev/null 2>&1; then
      FOREIGN_COMMITS+=("$commit"$'\t'"$subject"$'\t'"$against_branch")
      break
    else
      against_rc=$?
      [ "$against_rc" -eq 1 ] \
        || fail_closed "cannot compare commit $commit with branch $against_branch"
    fi
  done
done <<<"$COMMIT_LINES"

FILE_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-pr-base-check.XXXXXX") \
  || fail_closed "cannot create a temporary file list"
git -C "$CLONE" diff --name-only -z "$BASE_REF...$PR_HEAD_REF" >"$FILE_LIST_TMP" \
  || fail_closed "cannot list changed PR files"

FOREIGN_CONTENT=()
blob_id() {
  local ref=$1 path=$2 blob
  if ! git -C "$CLONE" cat-file -e "$ref:$path" 2>/dev/null; then
    printf '%s\n' MISSING
    return 0
  fi
  blob=$(git -C "$CLONE" rev-parse --verify "$ref:$path" 2>/dev/null) || return 1
  [ "$(git -C "$CLONE" cat-file -t "$blob" 2>/dev/null)" = blob ] || return 1
  printf '%s\n' "$blob"
}

while IFS= read -r -d '' path; do
  pr_blob=$(blob_id "$PR_HEAD_REF" "$path") \
    || fail_closed "cannot determine the PR blob for file: $path"
  # A path the PR deletes has no blob to attribute to an against branch, and
  # the MISSING sentinel must never compare equal to another absent path.
  [ "$pr_blob" != MISSING ] || continue
  base_blob=$(blob_id "$BASE_REF" "$path") \
    || fail_closed "cannot determine the base blob for file: $path"
  for index in "${!UNIQUE_AGAINST_BRANCHES[@]}"; do
    against_branch=${UNIQUE_AGAINST_BRANCHES[$index]}
    against_ref="refs/remotes/origin/$against_branch"
    against_blob=$(blob_id "$against_ref" "$path") \
      || fail_closed "cannot determine the $against_branch blob for file: $path"
    if [ "$pr_blob" = "$against_blob" ] && [ "$pr_blob" != "$base_blob" ]; then
      FOREIGN_CONTENT+=("$path"$'\t'"$against_branch"$'\t'"$pr_blob"$'\t'"$base_blob")
      break
    fi
  done
done <"$FILE_LIST_TMP"

if [ "${#FOREIGN_COMMITS[@]}" -gt 0 ] || [ "${#FOREIGN_CONTENT[@]}" -gt 0 ]; then
  printf 'PR base check: FAIL (base=%s, pr-head=%s)\n' "$BASE_BRANCH" "$PR_HEAD"
  printf 'ancestry: %s\n' "$ANCESTRY"
  for evidence in "${FOREIGN_COMMITS[@]:-}"; do
    [ -n "$evidence" ] || continue
    IFS=$'\t' read -r commit subject against_branch <<<"$evidence"
    printf 'foreign commit: %s %s (reachable from %s)\n' \
      "$commit" "$subject" "$against_branch"
  done
  for evidence in "${FOREIGN_CONTENT[@]:-}"; do
    [ -n "$evidence" ] || continue
    IFS=$'\t' read -r path against_branch pr_blob base_blob <<<"$evidence"
    printf 'foreign content: %s appears taken from %s (PR blob %s equals %s and differs from base blob %s)\n' \
      "$path" "$against_branch" "$pr_blob" "$against_branch" "$base_blob"
  done
  exit 1
fi

printf 'PR base check: PASS (base=%s, pr-head=%s)\n' "$BASE_BRANCH" "$PR_HEAD"
printf 'ancestry: %s\n' "$ANCESTRY"
