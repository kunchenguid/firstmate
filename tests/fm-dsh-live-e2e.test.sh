#!/usr/bin/env bash
# Live DeepSeek Harness primary-integration guard (live-harness-optin family).
#
# The portable regression (tests/fm-dsh-harness.test.sh) pins firstmate's own
# logic against synthetic fixtures. It cannot catch a DSH release changing hook
# semantics, which is what this guard exists for: it builds a throwaway profile,
# installs the hooks bridge at the running dsh-base version, and drives real
# headless sessions to prove the integration contracts below still hold.
#
# Run explicitly with FM_DSH_LIVE_E2E=1 after a dsh upgrade, and before trusting
# a refreshed docs/verification/supervision.md DSH entry. It fails naming the
# harness and version rather than degrading quietly.
#
# The contracts, each of which was once assumed and later measured:
#   1. UserPromptSubmit delivers additionalContext BEFORE the first request.
#      DSH's SessionStart hook runs detached and lands after it, so the digest
#      rides UserPromptSubmit; if that ever stops holding, the session-start
#      digest silently arrives a turn late.
#   2. A PreToolUse hook with the lowercase `bash` matcher fires AND a deny
#      blocks the call. The delegation guard and both seatbelts rest on it.
#   3. A Stop hook that exits 2 forces one more model step, and the terminal
#      alarm turn is bounded rather than looping.
#   4. A hook subprocess inherits the host's environment, which is the premise
#      bin/fm-dsh-launch.sh's exported marker depends on.
#   5. The documented `web` launch renders AGENTS.md whole. dsh-web-app disables
#      the host agent-instructions row and composes each session from its
#      default agent preset, so the budget that matters is the tracked firstmate
#      preset's. The headless sessions above cannot see this: their host row is
#      live, which is how a disabled web row once passed unnoticed.
#   6. bin/fm-dsh-launch.sh's own exec loads the web plugin tree with the
#      tracked patch applied once. DSH refuses a parent --patch before `web`, and
#      a doubled bridge insert throws "duplicate loader entry id" only when the
#      tree loads, so a config dump through the preflight passed both unnoticed.
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
HOOKENV="$WORK/hook-env"
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
printf '%s\n' "\${FM_DSH_HARNESS:-unset}" >> "$HOOKENV"
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
# Invoked with the tracked patch, because that is what the launcher passes: the
# patch is the install step for the bridge mount, the instruction budget and the
# hook sandbox mode, none of which the throwaway profile carries on its own.
if ! "$ROOT/bin/fm-dsh-preflight.sh" --profile "$PROFILE" --home "$ROOT" \
    --patch "$ROOT/.dsh/profile.patch.yml" >/dev/null 2>&1; then
  fail "fm-dsh-preflight.sh rejected the freshly pinned profile '$PROFILE' with the tracked patch (dsh-base $BASE_VERSION)"
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
if [ -e "$SENTINEL" ]; then
  fail "live dsh $BASE_VERSION: the PreToolUse deny fired but the command still ran"
fi
pass "live dsh $BASE_VERSION: the bash-matcher PreToolUse deny blocked the command"

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

# --- 5. a hook subprocess inherits the host environment ---------------------
# bin/fm-dsh-launch.sh is the launch boundary precisely because DSH exposes no
# identity of its own: it exports FM_DSH_HARNESS=dsh and clears foreign markers
# at process start, on the premise that hook and tool subprocesses then inherit
# it. Nothing verified that premise, and if it were false the marker would reach
# no guard - detection would fall back to ancestry alone, which under DSH is only
# args strength. Export it here rather than through the launcher so the assertion
# is about inheritance and not about the launcher's own correctness.
: > "$HOOKENV"
export FM_DSH_HARNESS=dsh
run_headless "Without using any tools, reply with ONLY the word PING." >/dev/null 2>&1 || true
unset FM_DSH_HARNESS
hookenv=$(cat "$HOOKENV" 2>/dev/null || true)
case "$hookenv" in
  dsh) pass "live dsh $BASE_VERSION: a hook subprocess inherits the host's harness marker" ;;
  "") fail "live dsh $BASE_VERSION: the UserPromptSubmit probe wrote no marker, so hook inheritance is UNPROVEN (inconclusive, not passing)" ;;
  *) fail "live dsh $BASE_VERSION: a hook subprocess saw FM_DSH_HARNESS='$hookenv', not the host's value; the launch boundary cannot reach the guards" ;;
esac

# --- 6. the documented web launch renders AGENTS.md whole --------------------
# Composed in a disposable DSH_HOME: a config dump needs no credentials, and a
# web profile initializes there from DSH's own template. The preflight must pass
# on the firstmate preset with the tracked patch and fail on DSH's standard
# preset without it, which proves it reads the composition sessions render with
# rather than the disabled host row. DSH's own preset discovery must then find
# the tracked preset healthy, and DSH's own renderer at the budget the preflight
# reported must omit nothing.
WEBHOME="$TMP_ROOT/web-dsh-home"
mkdir -p "$WEBHOME"
# Only the budget verdict: the disposable home has no hooks bridge, so the
# preflight's bridge check fails there by construction and says nothing here.
web_budget() {  # [preflight args...]
  ( cd "$ROOT" && DSH_HOME="$WEBHOME" "$ROOT/bin/fm-dsh-preflight.sh" --profile web --home "$ROOT" "$@" 2>&1 ) \
    | grep -A1 -e 'instruction budget' -e 'agent preset' -e 'agent-instructions' || true
}
out=$(web_budget --patch "$ROOT/.dsh/profile.patch.yml")
budget=$(printf '%s\n' "$out" | sed -n 's/^ok    instruction budget \([0-9][0-9]*\) fits .* in the firstmate agent preset$/\1/p')
[ -n "$budget" ] \
  || fail "live dsh $BASE_VERSION: the documented web launch did not pass the budget check on the firstmate preset: $out"
out=$(web_budget)
case "$out" in
  *"sessions compose from agent preset 'standard'"*) : ;;
  *) fail "live dsh $BASE_VERSION: without the tracked patch the web budget check did not fail on DSH's standard preset: $out" ;;
esac
verdict=$(cd "$ROOT" && node --input-type=module -e '
const [scope, root, dshHome, budget] = process.argv.slice(1);
const { pathToFileURL } = await import("node:url");
const { discoverPresets } = await import(pathToFileURL(scope + "/dsh-agent-presets/lib/index.js").href);
const { loadBaselineInstructions } = await import(pathToFileURL(scope + "/dsh-agent-instructions/lib/index.js").href);
const presets = await discoverPresets([{ path: root + "/.dsh/agent-presets", trust: "system" }], pathToFileURL(scope + "/dsh/lib/bin.js").href);
const preset = presets.find((candidate) => candidate.id === "firstmate");
if (preset === undefined) { console.log("DSH did not discover the firstmate preset"); process.exit(0); }
if (preset.broken !== undefined) { console.log("DSH reports the firstmate preset broken: " + preset.broken); process.exit(0); }
const rendered = await loadBaselineInstructions({ cwd: root, dshHome, maxBytes: Number(budget) });
if (rendered === undefined || rendered.omitted.length > 0 || rendered.truncated.length > 0) {
  console.log("DSH rendered the chain at " + budget + " with omitted " + JSON.stringify(rendered?.omitted?.map((file) => file.displayPath)) + " and truncated " + JSON.stringify(rendered?.truncated));
  process.exit(0);
}
console.log("ok");
' "$SCOPE_DIR" "$ROOT" "$WEBHOME" "$budget" 2>&1) || true
[ "$verdict" = ok ] \
  || fail "live dsh $BASE_VERSION: the firstmate preset does not deliver AGENTS.md whole under web: $verdict"
pass "live dsh $BASE_VERSION: the documented web launch renders AGENTS.md whole through the firstmate preset (budget $budget)"

# --- 7. the launcher's own exec boots the web tree with the tracked patch -----
# Contract 6 composes through the preflight, which never used the launcher's
# exec argv. `web --help` loads the plugin tree, where a misplaced or doubled
# --patch fails, and prints the web app's help without serving. The preflight is
# skipped because this disposable home has no hooks bridge.
launch_web() {  # [arguments after web...]
  ( cd "$TMP_ROOT" && DSH_HOME="$WEBHOME" FM_DSH_SKIP_PREFLIGHT=1 "$ROOT/bin/fm-dsh-launch.sh" web "$@" 2>&1 )
}
out=$(launch_web --dump-config) \
  || fail "live dsh $BASE_VERSION: the launcher's web argv did not compose: $(printf '%s\n' "$out" | tail -3)"
printf '%s\n' "$out" | grep -qx '    default: firstmate' \
  || fail "live dsh $BASE_VERSION: the launcher's web exec did not apply the tracked patch (no firstmate preset default)"
out=$(launch_web --help) \
  || fail "live dsh $BASE_VERSION: the documented web launch did not load its plugin tree: $(printf '%s\n' "$out" | tail -3)"
out=$(launch_web --patch "$ROOT/.dsh/profile.patch.yml" --help) \
  || fail "live dsh $BASE_VERSION: a web launch naming the tracked patch did not load its plugin tree: $(printf '%s\n' "$out" | tail -3)"
pass "live dsh $BASE_VERSION: the launcher's web exec loads the plugin tree with the tracked patch applied once"
