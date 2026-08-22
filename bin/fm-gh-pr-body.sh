#!/usr/bin/env bash
# fm-gh-pr-body.sh - REST owner for GitHub pull-request body create/update.
#
# gh pr edit currently fails on some hosts because the CLI always queries
# repository.pullRequest.projectCards over GraphQL (Projects classic sunset).
# REST PATCH/POST avoids that path and is the supported way for no-mistakes to
# publish the signed pipeline body atomically with PR open or on later updates.
#
# Usage:
#   fm-gh-pr-body.sh set-body --repo <owner/repo> --number <n> --body-file <path>
#   fm-gh-pr-body.sh create --repo <owner/repo> --head <branch> --title <text>
#                         [--base <branch>] --body-file <path>
#   fm-gh-pr-body.sh publish --repo <owner/repo> --head <branch> --title <text>
#                          [--base <branch>] --body-file <path>
#
# publish creates a PR when none exists for --head, otherwise updates the
# existing PR body and title in one REST call so the signed body is visible
# before the opened webhook snapshot goes stale.
#
# Requires gh on PATH for authentication only (gh api).
set -eu

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh is required on PATH"
}

parse_repo() {
  local repo=$1
  case "$repo" in
    */*) REPO_OWNER=${repo%%/*}; REPO_NAME=${repo#*/} ;;
    *) die "invalid repository: $repo" ;;
  esac
}

read_body_file() {
  local file=$1
  [ -n "$file" ] || die "--body-file is required"
  [ -f "$file" ] || die "body file not found: $file"
  [ ! -L "$file" ] || die "body file must not be a symlink: $file"
  BODY_FILE=$file
}

gh_api_json() {
  local method=$1 endpoint=$2 body_file=$3
  if [ -n "$body_file" ]; then
    gh api -X "$method" "$endpoint" --input "$body_file"
  else
    gh api -X "$method" "$endpoint"
  fi
}

find_pr_number_for_head() {
  local repo=$1 head=$2
  gh pr list --repo "$repo" --head "$head" --state all --json number --jq '.[0].number // empty' 2>/dev/null
}

cmd_set_body() {
  local repo="" number="" title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --number) number=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --body-file) read_body_file "$2"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$repo" ] || die "--repo is required"
  [ -n "$number" ] || die "--number is required"
  [ -n "${BODY_FILE:-}" ] || die "--body-file is required"
  require_gh
  parse_repo "$repo"
  local payload
  payload=$(mktemp)
  if [ -n "$title" ]; then
    python3 - "$BODY_FILE" "$title" "$payload" <<'PY'
import json
import pathlib
import sys

body = pathlib.Path(sys.argv[1]).read_text()
title = sys.argv[2]
out = pathlib.Path(sys.argv[3])
out.write_text(json.dumps({"body": body, "title": title}))
PY
  else
    python3 - "$BODY_FILE" "$payload" <<'PY'
import json
import pathlib
import sys

body = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
out.write_text(json.dumps({"body": body}))
PY
  fi
  gh_api_json PATCH "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${number}" "$payload"
  rm -f "$payload"
}

cmd_create() {
  local repo="" head="" base="main" title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --head) head=$2; shift 2 ;;
      --base) base=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --body-file) read_body_file "$2"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$repo" ] || die "--repo is required"
  [ -n "$head" ] || die "--head is required"
  [ -n "$title" ] || die "--title is required"
  [ -n "${BODY_FILE:-}" ] || die "--body-file is required"
  require_gh
  parse_repo "$repo"
  local payload
  payload=$(mktemp)
  python3 - "$BODY_FILE" "$title" "$head" "$base" "$payload" <<'PY'
import json
import pathlib
import sys

body = pathlib.Path(sys.argv[1]).read_text()
payload = {
    "title": sys.argv[2],
    "head": sys.argv[3],
    "base": sys.argv[4],
    "body": body,
}
pathlib.Path(sys.argv[5]).write_text(json.dumps(payload))
PY
  gh_api_json POST "repos/${REPO_OWNER}/${REPO_NAME}/pulls" "$payload"
  rm -f "$payload"
}

cmd_publish() {
  local repo="" head="" base="main" title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --head) head=$2; shift 2 ;;
      --base) base=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --body-file) read_body_file "$2"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$repo" ] || die "--repo is required"
  [ -n "$head" ] || die "--head is required"
  [ -n "$title" ] || die "--title is required"
  [ -n "${BODY_FILE:-}" ] || die "--body-file is required"
  require_gh
  local number
  number=$(find_pr_number_for_head "$repo" "$head" || true)
  if [ -n "$number" ]; then
    cmd_set_body --repo "$repo" --number "$number" --title "$title" --body-file "$BODY_FILE"
  else
    cmd_create --repo "$repo" --head "$head" --base "$base" --title "$title" --body-file "$BODY_FILE"
  fi
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    set-body) cmd_set_body "$@" ;;
    create) cmd_create "$@" ;;
    publish) cmd_publish "$@" ;;
    -h|--help|"") usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
