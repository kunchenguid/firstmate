#!/usr/bin/env bash
# Restricted account-task public-interface tests with synthetic account trees,
# tools, Unix sockets and crash points. Never contacts SSH, a model or a backend.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 is required'; exit 0; }
python3 -I "$ROOT/tests/fm-account-task.test.py" "$ROOT"
pass "restricted account-task protocol, identity, replay, control and rollback"
