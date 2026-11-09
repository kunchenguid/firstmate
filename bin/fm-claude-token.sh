#!/usr/bin/env bash
# Load a declared Claude OAuth token into one command's environment.
#
# Usage: fm-claude-token.sh exec <credential-source-file> -- <command> [args...]
#
# The source file uses bin/fm-credential-source-lib.sh's declaration schema
# and names only a credential location. The token is read into this process,
# exported to the command it replaces, and never placed in argv, a file, or
# this helper's output.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-credential-source-lib.sh
. "$SCRIPT_DIR/fm-credential-source-lib.sh"

usage() {
  printf '%s\n' 'usage: fm-claude-token.sh exec <credential-source-file> -- <command> [args...]' >&2
  exit 2
}

refuse() {
  printf 'error: Claude token source %s: %s\n' "$1" "$2" >&2
  exit 3
}

[ "${1:-}" = exec ] || usage
[ "$#" -ge 4 ] || usage
shift
SOURCE_FILE=$1
shift
[ "${1:-}" = -- ] || usage
shift
[ "$#" -gt 0 ] || usage
case "$1" in -*) usage ;; esac

problem=$(fm_credsrc_check "$SOURCE_FILE" claude) || refuse "$SOURCE_FILE" "malformed declaration: $problem"
source=$(fm_credsrc_field "$SOURCE_FILE" claude source)
fm_credsrc_supported "$source" || refuse "$SOURCE_FILE" "source $source is not supported on this host"
TOKEN=$(fm_credsrc_read "$SOURCE_FILE" claude)
rc=$?
if [ "$rc" -ne 0 ]; then
  if fm_timed_out "$rc"; then
    refuse "$SOURCE_FILE" "source $source did not answer in time"
  fi
  refuse "$SOURCE_FILE" "source $source is unavailable"
fi
[ "${#TOKEN}" -ge 1 ] && [ "${#TOKEN}" -le 4096 ] && [[ "$TOKEN" =~ ^[A-Za-z0-9._~:/+=-]+$ ]] ||
  refuse "$SOURCE_FILE" "does not contain one valid OAuth token"
export CLAUDE_CODE_OAUTH_TOKEN=$TOKEN
unset TOKEN
exec env "$@"
