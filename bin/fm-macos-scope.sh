#!/usr/bin/env bash
# fm-macos-scope.sh - decide whether a change requires stock macOS Bash.
#
# Pull requests require macOS when the CI workflow or a path in fm-lint's
# canonical shell inventory changes. New, deleted, or renamed *.sh files in an
# inventory directory also require it; other pull-request paths do not.
# Every non-pull-request event and any indeterminate comparison fails closed to
# required=true. The verdict is written as required=<true|false> on stdout.
#
# Usage: fm-macos-scope.sh <event-name> <base-sha> <head-sha>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

verdict() {
  printf 'stock macOS Bash scope: required=%s (%s)\n' "$1" "$2" >&2
  printf 'required=%s\n' "$1"
  exit 0
}

[ "$#" -eq 3 ] || {
  printf 'usage: fm-macos-scope.sh <event-name> <base-sha> <head-sha>\n' >&2
  exit 2
}

EVENT_NAME=$1
BASE_SHA=$2
HEAD_SHA=$3

if [ "$EVENT_NAME" != pull_request ]; then
  verdict true "event $EVENT_NAME always proves stock macOS Bash"
fi

if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ]; then
  verdict true "missing PR base/head sha; failing closed"
fi

TMP_ROOT=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-macos-scope.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

INVENTORY="$TMP_ROOT/inventory"
INVENTORY_DIRS="$TMP_ROOT/inventory-dirs"
CHANGED="$TMP_ROOT/changed"

bin/fm-lint.sh --list-files > "$INVENTORY"
while IFS= read -r entry; do
  dirname -- "$entry"
done < "$INVENTORY" | sort -u > "$INVENTORY_DIRS"
printf '%s\n' .github/workflows/ci.yml >> "$INVENTORY"

if ! git diff --no-renames --name-only -z "$BASE_SHA...$HEAD_SHA" > "$CHANGED"; then
  printf '::warning::could not diff %s...%s\n' "$BASE_SHA" "$HEAD_SHA" >&2
  verdict true "diff failed; failing closed"
fi

while IFS= read -r -d '' path; do
  if grep -Fxq -- "$path" "$INVENTORY"; then
    verdict true "$path is compatibility-relevant"
  fi
  case "$path" in
    *.sh)
      if grep -Fxq -- "$(dirname -- "$path")" "$INVENTORY_DIRS"; then
        verdict true "$path is compatibility-relevant"
      fi
      ;;
  esac
done < "$CHANGED"

verdict false "no compatibility-relevant path changed"
