#!/usr/bin/env bash
# Exercise managed RC-off default installation and honest preflight checks.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-claude-rc-off)
POLICY_DIR="$LAB/managed-settings.d"
POLICY="$POLICY_DIR/50-firstmate-remote-control.json"
HELPER="$ROOT/bin/fm-claude-rc-off.sh"
mkdir -p "$LAB/bin"
cat > "$LAB/bin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${RC_VERSION:-2.1.263 (Claude Code)}"
fi
SH
chmod +x "$LAB/bin/claude"

run_helper() {
  PATH="$LAB/bin:$PATH" FM_SPAWN_NO_GUARD=1 \
    FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR="$POLICY_DIR" "$HELPER" "$@"
}

if PATH="$LAB/bin:$PATH" FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR="$POLICY_DIR" \
  "$HELPER" check-default >/dev/null 2>&1; then
  fail 'test managed path accepted without the test guard'
fi
if run_helper check-default >/dev/null 2>&1; then
  fail 'missing managed default accepted'
fi
pass 'managed default preflight fails closed when its fragment is absent'

run_helper install-policy >/dev/null
out=$(run_helper check-default)
assert_contains "$out" 'best-effort managed RC-off default present' 'preflight omitted best-effort status'
assert_contains "$out" 'effective state unverified' 'preflight falsely implied effective verification'
jq -e 'type == "object" and .disableRemoteControl == true' "$POLICY" >/dev/null || fail 'installed policy has wrong semantics'
run_helper install-policy >/dev/null
jq -e 'keys == ["disableRemoteControl"] and .disableRemoteControl == true' "$POLICY" >/dev/null || fail 'idempotent install changed policy semantics'
pass 'managed default installation is semantic and explicitly best-effort'

if RC_VERSION='2.1.127 (Claude Code)' run_helper check-default >/dev/null 2>&1; then
  fail 'unsupported Claude version accepted'
fi
if RC_VERSION='vendor changed banner' run_helper check-default >/dev/null 2>&1; then
  fail 'unrecognized Claude version accepted'
fi
pass 'managed default preflight rejects unsupported Claude versions'

printf '%s\n' '{"disableRemoteControl":false}' > "$POLICY_DIR/99-later-managed.json"
out=$(run_helper check-default)
assert_contains "$out" 'effective state unverified' 'later override was falsely reported as effectively disabled'
pass 'preflight stays honest when a later managed fragment can override it'

printf '%s\n' '{"disableRemoteControl":false}' > "$POLICY"
if run_helper check-default >/dev/null 2>&1; then fail 'disabled Firstmate fragment accepted'; fi
printf '%s\n' '{bad' > "$POLICY"
if run_helper check-default >/dev/null 2>&1; then fail 'malformed Firstmate fragment accepted'; fi
rm -f "$POLICY"
printf '%s\n' '{"disableRemoteControl":true}' > "$LAB/elsewhere.json"
ln -s "$LAB/elsewhere.json" "$POLICY"
if run_helper check-default >/dev/null 2>&1; then fail 'symlinked Firstmate fragment accepted'; fi
pass 'managed default preflight rejects invalid and unsafe fragments'
