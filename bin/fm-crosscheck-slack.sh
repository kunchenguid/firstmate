#!/usr/bin/env bash
# Slack Socket Mode exposure of the crosscheck gate for team engineers (R10).
#
# Usage:
#   fm-crosscheck-slack.sh run [--config <path>] [--keychain-only]
#   fm-crosscheck-slack.sh preflight [--config <path>] [--keychain-only]
#   fm-crosscheck-slack.sh --selftest [<config-path>]
#   fm-crosscheck-slack.sh attest-launch <task-id> <generation> <worktree> <harness> <model> [--account-home <path>] [--config <path>]
#   fm-crosscheck-slack.sh attest-task <task-id> <pr-url> <head-sha> [--config <path>]
#
# Credential sources and service startup requirements are owned by
# docs/crosscheck-slack.md. `--selftest` validates config and the provenance
# key; `preflight` also checks credential loading, without remote authentication.
#
# The interpreter floor and the reason for it are owned by
# bin/fm-crosscheck-python-lib.sh: this listener parses hostile JSON (Slack
# payloads, ledgers) through the same bounded-read layer as the gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-crosscheck-python-lib.sh
. "$SCRIPT_DIR/fm-crosscheck-python-lib.sh"
CROSSCHECK_PYTHON="$(fm_crosscheck_resolve_python)"

case "${1:-}" in
  --selftest)
    shift
    exec "$CROSSCHECK_PYTHON" "$SCRIPT_DIR/fm-crosscheck-slack.py" selftest "$@"
    ;;
  *)
    exec "$CROSSCHECK_PYTHON" "$SCRIPT_DIR/fm-crosscheck-slack.py" "$@"
    ;;
esac
