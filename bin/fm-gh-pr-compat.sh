#!/usr/bin/env bash
# fm-gh-pr-compat.sh - gh-compatible wrapper for PR body create/update.
#
# Delegates every subcommand to the real gh binary except `gh pr create` and
# `gh pr edit` body mutations, which route through bin/fm-gh-pr-body.sh so
# no-mistakes can publish the signed body without the broken projectCards
# GraphQL path. Prepend this script to PATH as `gh` before starting the
# no-mistakes daemon when gh pr edit fails with Projects classic errors.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY_HELPER="$SCRIPT_DIR/fm-gh-pr-body.sh"

real_gh() {
  if [ -n "${FM_GH_PR_COMPAT_REAL_GH:-}" ]; then
    printf '%s\n' "$FM_GH_PR_COMPAT_REAL_GH"
    return
  fi
  command -v gh
}

die() {
  echo "error: $*" >&2
  exit 1
}

handle_pr_edit() {
  local repo="" number="" title="" body="" body_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo|-R) repo=$2; shift 2 ;;
      --title|-t) title=$2; shift 2 ;;
      --body|-b) body=$2; shift 2 ;;
      --body-file|-F)
        body_file=$2
        shift 2
        ;;
      -h|--help)
        exec "$(real_gh)" pr edit "$@"
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$number" ]; then
          number=$1
          shift
        elif [[ "$1" == https://* ]] && [ -z "$number" ]; then
          number=$(gh pr view "$1" --json number --jq .number)
          shift
        else
          die "fm-gh-pr-compat.sh: unsupported gh pr edit argument: $1"
        fi
        ;;
    esac
  done
  [ -n "$repo" ] || repo=${GH_REPO:-}
  [ -n "$repo" ] || die "gh pr edit requires --repo or GH_REPO"
  [ -n "$number" ] || die "gh pr edit requires a PR number or URL"
  local tmp
  tmp=$(mktemp)
  if [ -n "$body_file" ]; then
    cp "$body_file" "$tmp"
  elif [ -n "$body" ]; then
    printf '%s' "$body" > "$tmp"
  else
    die "gh pr edit requires --body or --body-file"
  fi
  local args=(--repo "$repo" --number "$number" --body-file "$tmp")
  if [ -n "$title" ]; then
    args+=(--title "$title")
  fi
  "$BODY_HELPER" set-body "${args[@]}"
  rm -f "$tmp"
}

handle_pr_create() {
  local repo="" head="" base="" title="" body="" body_file=""
  if [ "$#" -eq 0 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
    exec "$(real_gh)" pr create "$@"
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo|-R) repo=$2; shift 2 ;;
      --head|-H) head=$2; shift 2 ;;
      --base|-B) base=$2; shift 2 ;;
      --title|-t) title=$2; shift 2 ;;
      --body|-b) body=$2; shift 2 ;;
      --body-file|-F) body_file=$2; shift 2 ;;
      *) die "fm-gh-pr-compat.sh: unsupported gh pr create argument: $1" ;;
    esac
  done
  [ -n "$repo" ] || repo=${GH_REPO:-}
  [ -n "$repo" ] || die "gh pr create requires --repo or GH_REPO"
  [ -n "$head" ] || head=$(git branch --show-current 2>/dev/null || true)
  [ -n "$head" ] || die "gh pr create requires --head or a current branch"
  [ -n "$title" ] || die "gh pr create requires --title"
  local tmp
  tmp=$(mktemp)
  if [ -n "$body_file" ]; then
    cp "$body_file" "$tmp"
  elif [ -n "$body" ]; then
    printf '%s' "$body" > "$tmp"
  else
    die "gh pr create requires --body or --body-file"
  fi
  "$BODY_HELPER" publish \
    --repo "$repo" \
    --head "$head" \
    ${base:+--base "$base"} \
    --title "$title" \
    --body-file "$tmp"
  rm -f "$tmp"
}

main() {
  if [ "$#" -lt 2 ]; then
    exec "$(real_gh)" "$@"
  fi
  case "$1" in
    pr)
      case "$2" in
        edit) shift 2; handle_pr_edit "$@" ;;
        create) shift 2; handle_pr_create "$@" ;;
        *) exec "$(real_gh)" pr "$2" "${@:3}" ;;
      esac
      ;;
    *)
      exec "$(real_gh)" "$@"
      ;;
  esac
}

main "$@"
