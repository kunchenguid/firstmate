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
#   1. A hooks bridge pinned at the running dsh-base passes the preflight with
#      the tracked patch, whose literal pin is the only hook sandbox mode the
#      preflight accepts.
#   2. UserPromptSubmit delivers additionalContext BEFORE the first request.
#      DSH's SessionStart hook runs detached and lands after it, so the digest
#      rides UserPromptSubmit; if that ever stops holding, the session-start
#      digest silently arrives a turn late.
#   3. A PreToolUse hook with the lowercase `bash` matcher fires AND a deny
#      blocks the call. The delegation guard and both seatbelts rest on it.
#   4. A Stop hook that exits 2 forces one more model step, and the terminal
#      alarm turn is bounded rather than looping.
#   5. A hook subprocess inherits the host's environment, which is the premise
#      bin/fm-dsh-launch.sh's exported marker depends on.
#   6. The documented `web` launch renders AGENTS.md whole. dsh-web-app disables
#      the host agent-instructions row and composes each session from its
#      default agent preset, so the budget that matters is the tracked firstmate
#      preset's. The headless sessions above cannot see this: their host row is
#      live, which is how a disabled web row once passed unnoticed.
#   7. bin/fm-dsh-launch.sh's own exec loads the web plugin tree with the
#      tracked patch applied once. DSH refuses a parent --patch before `web`, and
#      a doubled bridge insert throws "duplicate loader entry id" only when the
#      tree loads, so a config dump through the preflight passed both unnoticed.
#   8. The tracked patch keeps every permission preset dsh-base offers. A patch
#      replaces a row's whole config, so a permission row carrying only its
#      default silently drops the read-only preset from every picker.
#   9. A session takes a free fleet lock as its own, and a session finding the
#      lock held refuses into read-only. DSH gives hooks no session identity, so
#      a session finds itself and a live peer only by the launcher shape in argv;
#      if that stops matching, every session is read-only or two captains share
#      one home, and the refusal alone cannot tell which.
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
  [ -n "${LOCK_PROFILE_DIR:-}" ] && rm -rf "$LOCK_PROFILE_DIR" 2>/dev/null
  [ -n "${LOCK_HOLDER_PID:-}" ] && kill "$LOCK_HOLDER_PID" 2>/dev/null
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
# Invoked with the tracked patch, because that is what the launcher passes. The
# throwaway profile already mounts the bridge, raises the budget and sets the
# default permission preset; the hook sandbox mode comes only from the tracked
# patch's literal pin, because the preflight refuses dsh-base's expression.
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

# --- 8. the tracked patch keeps dsh-base's permission presets ----------------
# Composed with DSH's own layer composer and resolved through the permission
# plugin's own config schema, over the disposable web profile, once as the
# profile boots bare and once with the tracked patch applied last.
presets=$(cd "$ROOT" && FM_ROOT="$ROOT" node --input-type=module -e '
const [scope, root, dshHome] = process.argv.slice(1);
const { pathToFileURL } = await import("node:url");
const boot = await import(pathToFileURL(scope + "/dsh-app-boot/lib/index.js").href);
const { PermissionPresetService } = await import(pathToFileURL(scope + "/dsh-permission-presets/lib/index.js").href);
const profile = boot.loadProfile("dsh", "web", scope + "/dsh/package.json", dshHome);
const find = (rows) => {
  for (const row of rows) {
    if (row.id === "permission") return row;
    const nested = Array.isArray(row.config) ? find(row.config) : undefined;
    if (nested !== undefined) return nested;
  }
};
const resolve = (layers) => PermissionPresetService.Config(find(boot.composeEntries(layers))?.config ?? {});
const bare = resolve([profile.layers.flatMap((layer) => layer.patches), profile.patches]);
const patched = resolve([profile.layers.flatMap((layer) => layer.patches), profile.patches, boot.loadOverlayPatches("dsh", root + "/.dsh/profile.patch.yml")]);
if (JSON.stringify(patched.presets) !== JSON.stringify(bare.presets)) {
  console.log("the tracked patch offers " + JSON.stringify(patched.presets) + " where dsh-base offers " + JSON.stringify(bare.presets));
} else if (patched.defaultPreset !== "danger-full-access") {
  console.log("the tracked patch defaults new sessions to " + patched.defaultPreset);
} else {
  console.log("ok " + Object.keys(patched.presets).join(" "));
}
' "$SCOPE_DIR" "$ROOT" "$WEBHOME" 2>&1) || true
case "$presets" in
  "ok "*) pass "live dsh $BASE_VERSION: the tracked patch keeps dsh-base's permission presets (${presets#ok })" ;;
  *) fail "live dsh $BASE_VERSION: $presets" ;;
esac

# --- 9. a second concurrent session is refused into read-only ----------------
# The fleet lock matches its holder by launcher path in argv, and DSH gives hook
# and tool subprocesses no session identity of their own, so the question is
# whether a live DSH session is recognizable as the lock owner at all. Both
# halves run in one lock home. bin/fm-lock.sh exits before touching the lock
# when a session cannot resolve its own harness ancestry, so the refusal half
# alone would pass for a session that cannot identify itself; the control first
# requires a session to take a free lock as its own pid. The holder is a live
# node whose argv carries a dsh launcher shape, which is what
# bin/fm-session-lock-lib.sh's fm_harness_pid_alive demands of a lock holder, so
# it stands in for another live session without needing two real ones.
LOCK_HOME="$TMP_ROOT/lock-home"
LOCK_WORK="$TMP_ROOT/lock-work"
LOCK_PROFILE="${PROFILE}lock"
LOCK_PROFILE_DIR="${DSH_HOME:-$HOME/.dsh}/profiles/$LOCK_PROFILE"
mkdir -p "$LOCK_HOME/state" "$LOCK_WORK/holder/node_modules/.bin"

# A dsh-shaped process that outlives the sessions below. comm is node and argv
# carries `/.bin/dsh`, the shape fm_dsh_args_evidence accepts.
cat > "$LOCK_WORK/holder/node_modules/.bin/dsh" <<'SH'
#!/usr/bin/env node
setTimeout(function () {}, 600000)
SH
chmod +x "$LOCK_WORK/holder/node_modules/.bin/dsh"
node "$LOCK_WORK/holder/node_modules/.bin/dsh" >/dev/null 2>&1 &
LOCK_HOLDER_PID=$!
sleep 2

# A profile that mounts the TRACKED hooks, because the refusal happens inside the
# real session-start digest: the probe hooks above never run it. The tracked
# patch supplies the bridge mount, so this profile's own patch stays empty.
dsh --profile "$LOCK_PROFILE" --from-default-profile headless --dump-config >/dev/null 2>&1 \
  || fail "could not create the throwaway profile '$LOCK_PROFILE'"
dsh plugin --profile "$LOCK_PROFILE" add "@deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION" >/dev/null 2>&1 \
  || fail "could not install @deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION into '$LOCK_PROFILE'"
printf -- '- id: permission\n  config:\n    defaultPreset: danger-full-access\n' > "$LOCK_PROFILE_DIR/cordis.patch.yml"

lock_session() {
  ( cd "$LOCK_WORK" && FM_DSH_HARNESS=dsh FM_ROOT="$ROOT" FM_HOME="$LOCK_HOME" \
      FM_STATE_OVERRIDE="$LOCK_HOME/state" \
      dsh --profile "$LOCK_PROFILE" --patch "$ROOT/.dsh/profile.patch.yml" \
      "Without using any tools, reply with ONLY the word PING." >"$LOCK_WORK/out" 2>&1 ) || true
}

# Control: with the lock free, the session must write its own harness pid.
rm -f "$LOCK_HOME/state/.lock"
lock_session
held=$(cat "$LOCK_HOME/state/.lock" 2>/dev/null || true)
case "$held" in
  '' | *[!0-9]*) fail "live dsh $BASE_VERSION: a session left a free lock as '${held:-<no lock>}' rather than its own harness pid, so it cannot resolve its own ancestry and the refusal below would prove nothing" ;;
esac
[ "$held" != "$LOCK_HOLDER_PID" ] \
  || fail "live dsh $BASE_VERSION: a session took a free lock as the holder's pid $LOCK_HOLDER_PID, not its own"

# The lock the next session must find and refuse. Only a session's acquisition
# writes it, so an unchanged value after the run is proof the session did not
# take it. The marker is cleared so the digest check below is this run's own.
rm -f "$LOCK_HOME/state/.dsh-sessionstart-delivered"
printf '%s\n' "$LOCK_HOLDER_PID" > "$LOCK_HOME/state/.lock"
lock_session

held=$(cat "$LOCK_HOME/state/.lock" 2>/dev/null || true)
[ "$held" = "$LOCK_HOLDER_PID" ] \
  || fail "live dsh $BASE_VERSION: a session took a lock already held by a live dsh (pid $LOCK_HOLDER_PID -> ${held:-<empty>}); the refusal the fleet lock depends on did not happen"
[ -f "$LOCK_HOME/state/.dsh-sessionstart-delivered" ] \
  || fail "live dsh $BASE_VERSION: the second session left the lock alone but delivered no digest at all, so the read-only path was never exercised"
pass "live dsh $BASE_VERSION: a session takes a free fleet lock as its own and refuses a held one into read-only"
