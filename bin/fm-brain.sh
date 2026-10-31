#!/usr/bin/env bash
# Private explicit-corpus wiki and derived structural graph.
# Usage: FM_HOME=<owner-home> fm-brain.sh status|check|build <project>
#        FM_HOME=<owner-home> fm-brain.sh complete <project> --unit <id> --summary <json-file>
#        FM_HOME=<owner-home> fm-brain.sh complete-task <project> --unit <id>
#        FM_HOME=<owner-home> fm-brain.sh query <project> <literal-label-term>
# Python 3 standard library only; no Graphify dependency or model calls.
# --help and docs/configuration.md own the input and storage contracts.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-brain.py" "$@"
