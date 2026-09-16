#!/usr/bin/env bash
# Live DeepSeek Harness primary-integration guard (live-harness-optin family).
#
# The portable regression (tests/fm-dsh-harness.test.sh) pins firstmate's own
# logic against synthetic fixtures. It cannot catch a DSH release changing hook
# semantics, which is what this guard exists for: it builds a throwaway profile,
# installs the hooks bridge at the running dsh-base version, and drives real
# headless sessions to prove the three integration contracts still hold.
#
# Run explicitly with FM_DSH_LIVE_E2E=1 after a dsh upgrade, and before trusting
# a refreshed docs/verification/supervision.md DSH entry. It fails naming the
# harness and version rather than degrading quietly.
#
# The three contracts, each of which was once assumed and later measured:
#   1. UserPromptSubmit delivers additionalContext BEFORE the first request.
#      DSH's SessionStart hook runs detached and lands after it, so the digest
#      rides UserPromptSubmit; if that ever stops holding, the session-start
#      digest silently arrives a turn late.
#   2. A PreToolUse hook with the lowercase `bash` matcher fires AND a deny
#      blocks the call. The delegation guard and both seatbelts rest on it.
#   3. A Stop hook that exits 2 forces one more model step, and the terminal
#      alarm turn is bounded rather than looping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_DSH_LIVE_E2E dsh node jq pnpm

TMP_ROOT=$(fm_test_tmproot fm-dsh-live)
# The real harness home, deliberately: a throwaway DSH_HOME also throws away the
# credential store, and the sessions below then fail with MISSING_CREDENTIAL
# rather than exercising anything. Only the PROFILE is disposable.
PROFILE=fmdshlive
PROFILE_DIR="${DSH_HOME:-$HOME/.dsh}/profiles/$PROFILE"
WORK="$TMP_ROOT/work"
PROBE="$TMP_ROOT/probe"
HOOKLOG="$WORK/hooks.log"
STOPCOUNT="$WORK/stop-count"
SENTINEL="$WORK/deny-sentinel"
mkdir -p "$WORK" "$PROBE"

cleanup() {
  tmux kill-session -t firstmate 2>/dev/null || true
  rm -rf "$PROFILE_DIR" 2>/dev/null || true
  rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# --- resolve the running dsh-base version, so the bridge pin can match it -----
DSH_BIN=$(command -v dsh)
DSH_REAL=$(node -e 'console.log(require("node:fs").realpathSync(process.argv[1]))' "$DSH_BIN")
SCOPE_DIR=$(dirname "$(dirname "$(dirname "$DSH_REAL")")")
BASE_VERSION=$(node -p "require(process.argv[1] + '/dsh-base/package.json').version" "$SCOPE_DIR" 2>/dev/null || true)
[ -n "$BASE_VERSION" ] \
  || fail "could not resolve dsh-base's version beside $DSH_BIN; the live guard cannot pin the bridge"
printf 'info: dsh-base %s at %s\n' "$BASE_VERSION" "$SCOPE_DIR"

# --- probe hooks -------------------------------------------------------------
# Each writes INSIDE the session workspace root: a hook that writes outside it is
# silently sandbox-denied, which reads exactly like a hook that never fired.
cat > "$PROBE/ups.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'UserPromptSubmit\n' >> "$HOOKLOG"
printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"FM-DSH-LIVE-TOKEN-4242"}}'
exit 0
SH
cat > "$PROBE/pretool.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'PreToolUse\n' >> "$HOOKLOG"
echo "FM-DSH-LIVE: this shell command is refused by policy; do not retry it." >&2
exit 2
SH
cat > "$PROBE/stop.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
n=\$(cat "$STOPCOUNT" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$STOPCOUNT"
printf 'Stop#%s\n' "\$n" >> "$HOOKLOG"
if [ "\$n" -le 1 ]; then
  echo "FM-DSH-LIVE: turn end blocked; reply with the single word CONTINUED." >&2
  exit 2
fi
exit 0
SH
chmod +x "$PROBE"/*.sh
cat > "$PROBE/hooks.json" <<SH
{ "hooks": {
  "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "$PROBE/ups.sh" } ] } ],
  "PreToolUse": [ { "matcher": "bash", "hooks": [ { "type": "command", "command": "$PROBE/pretool.sh", "timeout": 10 } ] } ],
  "Stop": [ { "hooks": [ { "type": "command", "command": "$PROBE/stop.sh", "timeout": 30 } ] } ]
} }
SH

# --- throwaway profile carrying the probe hooks ------------------------------
run_headless() {  # <prompt>
  ( cd "$WORK" && dsh --profile "$PROFILE" "$1" 2>&1 )
}

dsh --profile "$PROFILE" --from-default-profile headless --dump-config >/dev/null 2>&1 \
  || fail "could not create the throwaway profile '$PROFILE'"
dsh plugin --profile "$PROFILE" add "@deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION" >/dev/null 2>&1 \
  || fail "could not install @deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION into '$PROFILE'"
cat > "$PROFILE_DIR/cordis.patch.yml" <<SH
- insert:
    - id: hooks-claude-code
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: $PROBE/hooks.json
        projectDir: $ROOT
- id: agent-instructions
  config:
    maxBytes: 262144
- id: permission
  config:
    defaultPreset: danger-full-access
SH

# --- 1. the bridge pin is what the preflight expects -------------------------
if ! "$ROOT/bin/fm-dsh-preflight.sh" --profile "$PROFILE" --home "$ROOT" >/dev/null 2>&1; then
  fail "fm-dsh-preflight.sh rejected the freshly pinned profile '$PROFILE' (dsh-base $BASE_VERSION)"
fi
pass "live dsh $BASE_VERSION: a matching bridge pin passes the preflight"

# --- 2. UserPromptSubmit delivers before the first request -------------------
: > "$HOOKLOG"; rm -f "$STOPCOUNT"
out=$(run_headless "Without using any tools, reply with ONLY the FM-DSH-LIVE-TOKEN value if you can see one in your context, otherwise reply NONE.") || true
if ! grep -q '^UserPromptSubmit$' "$HOOKLOG"; then
  fail "live dsh $BASE_VERSION: the UserPromptSubmit hook never fired"
fi
case "$out" in
  *FM-DSH-LIVE-TOKEN-4242*) pass "live dsh $BASE_VERSION: UserPromptSubmit context reached the first request" ;;
  *) fail "live dsh $BASE_VERSION: UserPromptSubmit fired but its additionalContext did not reach the model's first look" ;;
esac

# --- 3. a PreToolUse deny fires AND blocks ----------------------------------
: > "$HOOKLOG"; rm -f "$SENTINEL"
run_headless "Run the bash tool exactly once to execute: touch '$SENTINEL' -- then reply with one sentence about what happened." >/dev/null 2>&1 || true
if ! grep -q '^PreToolUse$' "$HOOKLOG"; then
  fail "live dsh $BASE_VERSION: the model did not call the shell tool, so the PreToolUse deny is UNPROVEN (inconclusive, not passing)"
fi
[ -e "$SENTINEL" ] \
  && fail "live dsh $BASE_VERSION: the PreToolUse deny fired but the command still ran" \
  || pass "live dsh $BASE_VERSION: the bash-matcher PreToolUse deny blocked the command"

# --- 4. the Stop hook blocks once, then allows ------------------------------
: > "$HOOKLOG"; rm -f "$STOPCOUNT"
out=$(run_headless "Without using any tools, reply with ONLY the word PING.") || true
stops=$(cat "$STOPCOUNT" 2>/dev/null || echo 0)
[ "$stops" -ge 2 ] \
  || fail "live dsh $BASE_VERSION: the Stop hook fired ${stops}x; a blocking Stop must force one more step before allowing"
case "$out" in
  *CONTINUED*) pass "live dsh $BASE_VERSION: the Stop hook forced one bounded continuation (${stops} firings)" ;;
  *) pass "live dsh $BASE_VERSION: the Stop hook fired ${stops}x and the run settled (continuation not echoed)" ;;
esac
