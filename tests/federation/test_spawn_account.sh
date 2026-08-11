#!/usr/bin/env bash
# --account axis test (Phase 4, Task 11). Run from ~/firstmate:
#   bash tests/federation/test_spawn_account.sh
# Exercises: supervised-spawn account isolation for each config-dir method,
# api-key refusal (no secret on argv), unknown-account refusal, and the wrapper
# handing canonical harness/model/effort args plus isolation env to fm-spawn.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FM_HOME="$(pwd)"; export FM_HOME
# shellcheck source=bin/fm-account-env.sh disable=SC1091
. bin/fm-account-env.sh
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d); export FM_ACCOUNTS_FILE="$TMP/accounts.json"
CD="$TMP/cd"; mkdir -p "$CD"
CD_SPACE="$TMP/cd with spaces"; mkdir -p "$CD_SPACE"
CD_WEIRD="$TMP/cd dir; touch $TMP/pwned_dir #"; mkdir -p "$CD_WEIRD"
echo "sk-fake-not-a-real-key" > "$TMP/grok.key"

cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "claude-alt": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$CD","scopes":["backend"]},
  "claude-weird": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$CD_WEIRD","scopes":["backend"]},
  "codex-x":    {"provider":"openai","harness":"codex","isolation":"config-dir-env","env":"CODEX_HOME","config_dir":"$CD","scopes":["backend"]},
  "cline-x":    {"provider":"anthropic","harness":"cline","isolation":"config-dir-flag","flag":"--config","config_dir":"$CD","scopes":["web"]},
  "cline-space": {"provider":"anthropic","harness":"cline","isolation":"config-dir-flag","flag":"--config","config_dir":"$CD_SPACE","scopes":["web"]},
  "grok-x":     {"provider":"xai","harness":"grok","isolation":"api-key-env","env":"GROK_API_KEY","key_file":"$TMP/grok.key","scopes":["research"]}
}
JSON

# 1. config-dir-env prepares a verified harness plus env isolation
fm_account_prepare_supervised_spawn claude-alt >/dev/null 2>&1
{ [ "$FM_ACCOUNT_SUPERVISED_HARNESS" = claude ] \
  && [ "${FM_SPAWN_ACCOUNT_ENV_NAME:-}" = CLAUDE_CONFIG_DIR ] \
  && [ "${FM_SPAWN_ACCOUNT_ENV_VALUE:-}" = "$CD" ] \
  && [ -z "${FM_SPAWN_ACCOUNT_ARGV_FLAG:-}" ]; } \
  && ok "prepare supervised config-dir-env (claude)" || bad "prepare claude env isolation"

# 2. codex uses CODEX_HOME through the same canonical harness path
fm_account_prepare_supervised_spawn codex-x >/dev/null 2>&1
{ [ "$FM_ACCOUNT_SUPERVISED_HARNESS" = codex ] \
  && [ "${FM_SPAWN_ACCOUNT_ENV_NAME:-}" = CODEX_HOME ] \
  && [ "${FM_SPAWN_ACCOUNT_ENV_VALUE:-}" = "$CD" ]; } \
  && ok "prepare codex (CODEX_HOME)" || bad "prepare codex env isolation"

# 3. config-dir-flag prepares an argv isolation pair, not a raw launch command
fm_account_prepare_supervised_spawn cline-x >/dev/null 2>&1
{ [ "$FM_ACCOUNT_SUPERVISED_HARNESS" = cline ] \
  && [ "${FM_SPAWN_ACCOUNT_ARGV_FLAG:-}" = --config ] \
  && [ "${FM_SPAWN_ACCOUNT_ARGV_VALUE:-}" = "$CD" ] \
  && [ -z "${FM_SPAWN_ACCOUNT_ENV_NAME:-}" ]; } \
  && ok "prepare config-dir-flag (cline)" || bad "prepare cline argv isolation"

# 4. config-dir-flag preserves paths with whitespace as one value
fm_account_prepare_supervised_spawn cline-space >/dev/null 2>&1
{ [ "$FM_ACCOUNT_SUPERVISED_HARNESS" = cline ] \
  && [ "${FM_SPAWN_ACCOUNT_ARGV_FLAG:-}" = --config ] \
  && [ "${FM_SPAWN_ACCOUNT_ARGV_VALUE:-}" = "$CD_SPACE" ]; } \
  && ok "prepare config-dir-flag path with spaces" || bad "prepare cline-space argv isolation"

# 5. api-key refusal (rc==2, no spawn isolation exported)
fm_account_prepare_supervised_spawn grok-x >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 2 ] \
  && [ -z "${FM_SPAWN_ACCOUNT_ENV_NAME:-}" ] \
  && [ -z "${FM_SPAWN_ACCOUNT_ARGV_FLAG:-}" ]; } \
  && ok "api-key supervised spawn refused (no key on argv)" || bad "api-key refusal (rc=$rc)"

# 6. unknown account refused
fm_account_prepare_supervised_spawn nope >/dev/null 2>&1 && bad "unknown account prepared" || ok "unknown account refused"

# 7. wrapper hands canonical harness args to fm-spawn (stub captures argv/env)
STUB="$TMP/spawn-stub.sh"
cat > "$STUB" <<'S'
#!/usr/bin/env bash
: > "$FM_STUB_OUT"
printf 'env_name=%s\n' "${FM_SPAWN_ACCOUNT_ENV_NAME:-}" >> "$FM_STUB_OUT"
printf 'env_value=%s\n' "${FM_SPAWN_ACCOUNT_ENV_VALUE:-}" >> "$FM_STUB_OUT"
printf 'argv_flag=%s\n' "${FM_SPAWN_ACCOUNT_ARGV_FLAG:-}" >> "$FM_STUB_OUT"
printf 'argv_value=%s\n' "${FM_SPAWN_ACCOUNT_ARGV_VALUE:-}" >> "$FM_STUB_OUT"
for a in "$@"; do printf 'arg=%s\n' "$a" >> "$FM_STUB_OUT"; done
S
chmod +x "$STUB"
FM_STUB_OUT="$TMP/out.txt" FM_SPAWN_BIN="$STUB" \
  bash bin/fm-spawn-acct.sh T-1 /proj --account claude-alt --model opus >/dev/null 2>&1
{ grep -qxF "env_name=CLAUDE_CONFIG_DIR" "$TMP/out.txt" \
  && grep -qxF "env_value=$CD" "$TMP/out.txt" \
  && grep -qxF "arg=T-1" "$TMP/out.txt" \
  && grep -qxF "arg=/proj" "$TMP/out.txt" \
  && grep -qxF "arg=--harness" "$TMP/out.txt" \
  && grep -qxF "arg=claude" "$TMP/out.txt" \
  && grep -qxF "arg=--model" "$TMP/out.txt" \
  && grep -qxF "arg=opus" "$TMP/out.txt" \
  && ! grep -q "arg=CLAUDE_CONFIG_DIR=" "$TMP/out.txt"; } \
  && ok "wrapper passes canonical harness launch to fm-spawn" || bad "wrapper canonical passthrough ($(cat "$TMP/out.txt"))"

# 8. wrapper forwards config-dir-flag isolation without splitting spaces
FM_STUB_OUT="$TMP/out-flag.txt" FM_SPAWN_BIN="$STUB" \
  bash bin/fm-spawn-acct.sh T-3 /proj --account cline-space >/dev/null 2>&1
{ grep -qxF "argv_flag=--config" "$TMP/out-flag.txt" \
  && grep -qxF "argv_value=$CD_SPACE" "$TMP/out-flag.txt" \
  && grep -qxF "arg=--harness" "$TMP/out-flag.txt" \
  && grep -qxF "arg=cline" "$TMP/out-flag.txt"; } \
  && ok "wrapper passes config-dir-flag isolation to fm-spawn" || bad "wrapper flag passthrough ($(cat "$TMP/out-flag.txt"))"

# 9. wrapper refuses api-key account (fail-closed; stub NOT invoked)
: > "$TMP/out2.txt"
FM_STUB_OUT="$TMP/out2.txt" FM_SPAWN_BIN="$STUB" \
  bash bin/fm-spawn-acct.sh T-2 /proj --account grok-x >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ ! -s "$TMP/out2.txt" ]; } && ok "wrapper fail-closed on api-key account" || bad "wrapper api-key (rc=$rc, stub-called=$( [ -s "$TMP/out2.txt" ] && echo yes || echo no ))"

# 10. apply_env exports in the CALLER's shell (regression: must NOT be a subshell)
( unset CLAUDE_CONFIG_DIR; fm_account_apply_env claude-alt && [ "$CLAUDE_CONFIG_DIR" = "$CD" ] ) \
  && ok "apply_env exports config-dir-env in caller shell" || bad "apply_env export (subshell regression)"

# 11. config-dir-flag sets FM_ACCT_ARGV_SUFFIX (not stdout)
( fm_account_apply_env cline-x && [ "$FM_ACCT_ARGV_SUFFIX" = "--config $CD" ] ) \
  && ok "apply_env sets argv suffix for flag method" || bad "apply_env suffix"

# 12. config-dir-flag direct launches keep the config dir as one argv
( fm_account_apply_env cline-space \
  && [ "${#FM_ACCT_ARGV_SUFFIX_ARGS[@]}" -eq 2 ] \
  && [ "${FM_ACCT_ARGV_SUFFIX_ARGS[0]}" = "--config" ] \
  && [ "${FM_ACCT_ARGV_SUFFIX_ARGS[1]}" = "$CD_SPACE" ] ) \
  && ok "apply_env sets argv array for config-dir-flag" || bad "apply_env argv array"

rm -rf "$TMP"
echo "-----"; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
