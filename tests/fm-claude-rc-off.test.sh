#!/usr/bin/env bash
# Exercise managed RC-off policy installation and fail-closed verification.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-claude-rc-off)
POLICY_DIR="$LAB/managed-settings.d"
POLICY="$POLICY_DIR/50-firstmate-remote-control.json"
HELPER="$ROOT/bin/fm-claude-rc-off.sh"

run_helper() {
  FM_SPAWN_NO_GUARD=1 FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR="$POLICY_DIR" "$HELPER" "$@"
}

if FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR="$POLICY_DIR" "$HELPER" verify-policy >/dev/null 2>&1; then
  fail 'test managed path accepted without the test guard'
fi
if run_helper verify-policy >/dev/null 2>&1; then
  fail 'missing managed policy accepted'
fi
pass 'managed policy verification fails closed'

run_helper install-policy >/dev/null
run_helper verify-policy | grep -q 'managed RC-off policy verified' || fail 'installed policy not verified'
jq -e 'type == "object" and .disableRemoteControl == true' "$POLICY" >/dev/null || fail 'installed policy has wrong semantics'
run_helper install-policy >/dev/null
jq -e 'keys == ["disableRemoteControl"] and .disableRemoteControl == true' "$POLICY" >/dev/null || fail 'idempotent install changed policy semantics'
pass 'managed policy installation is semantic and idempotent'

printf '%s\n' '{"disableRemoteControl":false}' > "$POLICY"
if run_helper verify-policy >/dev/null 2>&1; then fail 'disabled managed policy accepted'; fi
printf '%s\n' '{bad' > "$POLICY"
if run_helper verify-policy >/dev/null 2>&1; then fail 'malformed managed policy accepted'; fi
rm -f "$POLICY"
printf '%s\n' '{"disableRemoteControl":true}' > "$LAB/elsewhere.json"
ln -s "$LAB/elsewhere.json" "$POLICY"
if run_helper verify-policy >/dev/null 2>&1; then fail 'symlinked managed policy accepted'; fi
pass 'managed policy verification rejects ineffective and unsafe files'
