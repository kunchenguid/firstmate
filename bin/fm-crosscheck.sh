#!/usr/bin/env bash
# Run or verify the independent exact-head crosscheck ledger for a task PR.
#
# Usage:
#   fm-crosscheck.sh run <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh verify <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh merge <task-id> <full GitHub PR URL> <reviewed SHA> <method>
#
# `run` is intentionally independent of no-mistakes so both reviews can be in
# flight together once a PR exists. `verify` is the merge-gate operation: it
# re-reads live GitHub state, requires the latest attempt for that exact head
# and claims document to be clear, and prints only the reviewed SHA.
# `merge` repeats that verification and is the sole entrypoint to the private
# exact-SHA GitHub merge primitive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

exec python3 "$SCRIPT_DIR/fm-crosscheck.py" "$@"
