#!/usr/bin/env bash
# fm-account-exec.sh — direct (non-supervised) account-isolated launch (Phase 4).
#
# Applies an account's auth isolation to THIS process, then execs the CLI. This
# is the secure path for api-key harnesses (grok/cursor): the key is read from
# the account's key_file into the child's ENVIRONMENT — never onto argv, never
# into a log. Also usable for any direct config-dir launch outside a supervised
# fm-spawn pane.
#
# Usage: fm-account-exec.sh <account> <cli> [args...]
#   e.g. fm-account-exec.sh grok-personal grok -p "summarise this repo"
#        fm-account-exec.sh claude-alt   claude --model opus
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"; export FM_HOME
# shellcheck source=bin/fm-account-env.sh disable=SC1091
. "$SCRIPT_DIR/fm-account-env.sh"

acct=${1:?usage: fm-account-exec.sh <account> <cli> [args...]}; shift
cli=${1:?usage: fm-account-exec.sh <account> <cli> [args...]}; shift || true

# apply_env exports the isolation env (incl. api-key from key_file) into THIS
# shell — it must NOT run in $(...) or the exports die in the subshell. For
# config-dir-flag harnesses it sets FM_ACCT_ARGV_SUFFIX_ARGS to splice into argv.
fm_account_apply_env "$acct" || exit 1
exec "$cli" "${FM_ACCT_ARGV_SUFFIX_ARGS[@]}" "$@"
