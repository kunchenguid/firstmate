#!/usr/bin/env bash
# Slack Socket Mode exposure of the crosscheck gate for team engineers (R10).
#
# Usage:
#   fm-crosscheck-slack.sh run [--config <path>]
#   fm-crosscheck-slack.sh --selftest [<config-path>]
#
# `run` starts the resident Socket Mode listener; it refuses to start when
# any token environment variable named by $FM_HOME/config/crosscheck-slack.json
# is unset, naming the exact variable (the ready-to-flip posture).
# `--selftest` validates the config shape and exits without touching Slack.
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
