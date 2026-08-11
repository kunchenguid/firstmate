#!/usr/bin/env bash
# Account registry + resolution/validation test (Phase 4, Task 10).
# Run from ~/firstmate:  bash tests/federation/test_accounts.sh
# Exercises: resolve returns per-account config_dir; unknown fails; api-key
# exposes key_file; validate accepts a good account and rejects unknown harness,
# wrong env-for-harness, and a foreign-home path (cross-uid safety).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FM_HOME="$(pwd)"; export FM_HOME
# shellcheck source=bin/fm-accounts-lib.sh disable=SC1091
. bin/fm-accounts-lib.sh
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d); export FM_ACCOUNTS_FILE="$TMP/accounts.json"
P1="$TMP/p1"; P2="$TMP/p2"; mkdir -p "$P1" "$P2"

cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "claude-personal": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$P1","scopes":["backend"]},
  "claude-work":     {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$P2","scopes":["web"]},
  "grok-personal":   {"provider":"xai","harness":"grok","isolation":"api-key-env","env":"GROK_API_KEY","key_file":"$P1/grok.key","scopes":["research"]}
}
JSON

# 1. resolve returns config_dir (field 5) per account
r1=$(fm_account_resolve claude-personal); cd1=$(printf '%s' "$r1" | cut -f5)
r2=$(fm_account_resolve claude-work);     cd2=$(printf '%s' "$r2" | cut -f5)
{ [ "$cd1" = "$P1" ] && [ "$cd2" = "$P2" ]; } && ok "resolve returns per-account config_dir" || bad "resolve config_dir (got '$cd1' / '$cd2')"

# 2. resolve unknown fails
if fm_account_resolve nope >/dev/null 2>&1; then bad "unknown account resolved (should fail)"; else ok "unknown account fails"; fi

# 3. api-key account exposes key_file (field 6)
rg=$(fm_account_resolve grok-personal); kf=$(printf '%s' "$rg" | cut -f6)
[ "$kf" = "$P1/grok.key" ] && ok "api-key resolve exposes key_file" || bad "key_file (got '$kf')"

# 4. validate: good account passes
fm_account_validate claude-personal >/dev/null 2>&1 && ok "validate accepts good account" || bad "validate good account"

# 5. validate: unknown harness rejected
cat > "$FM_ACCOUNTS_FILE" <<JSON
{ "bad": {"provider":"x","harness":"foobar","isolation":"config-dir-env","env":"X","config_dir":"$P1"} }
JSON
fm_account_validate bad >/dev/null 2>&1 && bad "unknown harness passed validate" || ok "unknown harness rejected"

# 6. validate: wrong env-for-harness rejected
cat > "$FM_ACCOUNTS_FILE" <<JSON
{ "c": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"WRONG_ENV","config_dir":"$P1"} }
JSON
fm_account_validate c >/dev/null 2>&1 && bad "wrong env-for-harness passed validate" || ok "wrong env-for-harness rejected"

# 7. validate: foreign-home path refused (cross-uid safety)
FOREIGN_USER="not-$(id -un)"
cat > "$FM_ACCOUNTS_FILE" <<JSON
{ "f": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"/home/someoneelse/.claude"} }
JSON
fm_account_validate f >/dev/null 2>&1 && bad "foreign-home path passed validate" || ok "foreign-home path refused"

cat > "$FM_ACCOUNTS_FILE" <<JSON
{ "f": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"/Users/$FOREIGN_USER/.claude"} }
JSON
fm_account_validate f >/dev/null 2>&1 && bad "macOS foreign-home path passed validate" || ok "macOS foreign-home path refused"

rm -rf "$TMP"
echo "-----"; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
