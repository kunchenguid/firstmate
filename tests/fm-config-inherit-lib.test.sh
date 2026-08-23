#!/usr/bin/env bash
# Characterization coverage for the inherited-config declaration helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

expected_items=$(cat <<'EOF'
config/crew-dispatch.json
config/model-catalog.json
config/crew-harness
config/backlog-backend
config/backend
config/herdr-presentation-spaces
config/startup-memory-budget
config/trace-context
data/captain-shared.md
EOF
)
[ "$(fm_config_inherit_items)" = "$expected_items" ] \
  || fail "inheritance item declaration changed"

fm_config_inherit_item_session_scoped trace-context \
  || fail "trace-context should be session-scoped"
if fm_config_inherit_item_session_scoped backend; then
  fail "backend should not be session-scoped"
fi

pass "config-inherit-lib exposes the established inherited-item and session-scope contracts"
echo "# fm-config-inherit-lib.test.sh: all assertions passed"
