#!/usr/bin/env bash
# fm-claude-token-exec.sh - run a command with a `claude setup-token` token in
# its environment, so a Claude worker on a declared setup-token account never
# carries the token as an argument, in a staged launch file, or in any record.
#
# Usage: fm-claude-token-exec.sh <token-file> <command> [args...]
#
# Reads <token-file>, refuses (one message naming the file and the reason,
# never its content) unless it is an existing owner-only file holding one
# token, exports CLAUDE_CODE_OAUTH_TOKEN for the command alone, and execs it.
# Used by bin/fm-spawn.sh for a `token:` entry of config/claude-accounts and by
# the sign-in check in bin/fm-worker-account-lib.sh, which owns the parsing and
# the refusals. docs/configuration.md "Several Claude accounts" owns the
# contract.
set +x
set -u

if [ "$#" -lt 2 ]; then
  echo "usage: fm-claude-token-exec.sh <token-file> <command> [args...]" >&2
  exit 2
fi
tokenfile=$1
shift

# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

token=$(fm_worker_account_token_load "$tokenfile")
rc=$?
if [ "$rc" -ne 0 ]; then
  fm_worker_account_token_refusal "$rc" "$tokenfile"
  exit 1
fi
CLAUDE_CODE_OAUTH_TOKEN=$token
export CLAUDE_CODE_OAUTH_TOKEN
unset token
exec env "$@"
