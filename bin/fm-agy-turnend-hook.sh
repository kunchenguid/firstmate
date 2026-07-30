#!/usr/bin/env bash
# Signal one Agy crewmate turn boundary through a Firstmate task token.
#
# Usage:
#   <Stop payload JSON> | fm-agy-turnend-hook.sh <auth-dir> <token> <workspace>
#
# fm-spawn.sh creates the private registry entry, a worktree pointer, and one
# task-local hooks.json that invokes this script with exact bindings.
# Every refusal is silent and exits zero because a wake signal must never block
# or alter the Agy turn that emitted it.
set +e
exec 2>/dev/null
trap 'printf "{}\n"' EXIT

[ "$#" -eq 3 ] || exit 0
AUTH_DIR=$1
EXPECTED_TOKEN=$2
EXPECTED_WORKSPACE=$3

case "$EXPECTED_TOKEN" in
  fm.????????????) ;;
  *) exit 0 ;;
esac
case "$EXPECTED_TOKEN" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ -d "$AUTH_DIR" ] && [ ! -L "$AUTH_DIR" ] || exit 0
[ -d "$EXPECTED_WORKSPACE" ] && [ ! -L "$EXPECTED_WORKSPACE" ] || exit 0

PAYLOAD=
IFS= read -r PAYLOAD || [ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
WORKSPACE=$(printf '%s' "$PAYLOAD" | jq -er '
  select(type == "object")
  | .workspacePaths
  | select(type == "array" and length == 1)
  | .[0]
  | select(type == "string" and length > 0)
' 2>/dev/null) || exit 0
[ "$WORKSPACE" = "$EXPECTED_WORKSPACE" ] || exit 0

POINTER="$WORKSPACE/.fm-agy-turnend"
[ -f "$POINTER" ] && [ ! -L "$POINTER" ] || exit 0
FIRST=
IFS= read -r -n 256 FIRST < "$POINTER" 2>/dev/null || [ -n "$FIRST" ] || exit 0
[ "$FIRST" = "token=$EXPECTED_TOKEN" ] || exit 0

AUTH_FILE="$AUTH_DIR/$EXPECTED_TOKEN"
[ -f "$AUTH_FILE" ] && [ ! -L "$AUTH_FILE" ] || exit 0
TARGET=$(sed -n '1p' "$AUTH_FILE" 2>/dev/null) || exit 0
case "$TARGET" in
  /*.turn-ended) ;;
  *) exit 0 ;;
esac
TARGET_PARENT=$(CDPATH='' cd -- "$(dirname -- "$TARGET")" 2>/dev/null && pwd -P) || exit 0
AUTH_PARENT=$(CDPATH='' cd -- "$AUTH_DIR/.." 2>/dev/null && pwd -P) || exit 0
[ "$TARGET_PARENT" = "$AUTH_PARENT" ] || exit 0
[ ! -L "$TARGET" ] || exit 0
[ ! -e "$TARGET" ] || [ -f "$TARGET" ] || exit 0

touch -- "$TARGET" 2>/dev/null || true
exit 0
