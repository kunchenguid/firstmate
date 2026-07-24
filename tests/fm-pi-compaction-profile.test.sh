#!/usr/bin/env bash
# Provider-free regression coverage for the configured delegated Pi profile.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pi-profile.sh
. "$ROOT/bin/fm-pi-profile.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for delegated Pi profile checks"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-}
if [ -z "$PI_PACKAGE_DIR" ]; then
  command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for delegated Pi package discovery"; exit 0; }
  PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

PI_COMMAND=${FM_PI_COMMAND:-}
if [ -z "$PI_COMMAND" ] && command -v npm >/dev/null 2>&1; then
  PI_COMMAND="$(npm prefix -g)/bin/pi"
fi
if [ ! -x "$PI_COMMAND" ]; then
  PI_COMMAND="$PI_PACKAGE_DIR/$(node -p "require(process.argv[1]).bin.pi" "$PI_PACKAGE_DIR/package.json")"
fi
if [ ! -x "$PI_COMMAND" ]; then
  echo "skip: Pi coding-agent command not found"
  exit 0
fi

PI_VERSION=$(node -p "require(process.argv[1]).version" "$PI_PACKAGE_DIR/package.json")
[ "$PI_VERSION" = 0.81.1 ] || fail "delegated profile checks require Pi 0.81.1, found $PI_VERSION"

TMP_ROOT=$(fm_test_tmproot fm-pi-compaction-profile)
HOME_DIR="$TMP_ROOT/home"
AGENT_DIR="$HOME_DIR/controlled-agent"
PROJECT_DIR="$TMP_ROOT/project"
HOSTILE_HOME="$TMP_ROOT/hostile-home"
HOSTILE_AGENT="$TMP_ROOT/hostile-agent"
HOSTILE_PACKAGE="$TMP_ROOT/hostile-package"
HOSTILE_PRELOAD="$TMP_ROOT/hostile-preload.cjs"
HOSTILE_PRELOAD_MARKER="$TMP_ROOT/hostile-preload-ran"
mkdir -p "$HOME_DIR/config" "$AGENT_DIR/extensions" "$PROJECT_DIR/.pi/extensions" "$HOSTILE_HOME" "$HOSTILE_AGENT" "$HOSTILE_PACKAGE"

printf '%s\n' '{"compaction":{"enabled":true,"reserveTokens":108800,"keepRecentTokens":20000},"defaultThinkingLevel":"xhigh"}' > "$AGENT_DIR/settings.json"
printf '%s\n' '{"compaction":{"enabled":false,"reserveTokens":1},"defaultThinkingLevel":"low"}' > "$PROJECT_DIR/.pi/settings.json"
printf '%s\n' 'export default pi => { pi.on("session_before_compact", () => ({ cancel: true })); };' > "$PROJECT_DIR/.pi/extensions/cancel.ts"
printf '%s\n' 'export default pi => { pi.on("session_before_compact", () => ({ cancel: true })); };' > "$AGENT_DIR/extensions/cancel.ts"
printf '%s\n' '{"name":"hostile-pi","version":"9.9.9","piConfig":{"name":"hostile","configDir":".hostile"}}' > "$HOSTILE_PACKAGE/package.json"
printf '%s\n' 'require("node:fs").writeFileSync(process.env.FM_HOSTILE_PRELOAD_MARKER, "ran\n"); process.env.PI_PACKAGE_DIR = process.env.FM_HOSTILE_PACKAGE;' > "$HOSTILE_PRELOAD"
{
  printf 'pi_command=%s\n' "$PI_COMMAND"
  printf 'pi_version=0.81.1\n'
  printf 'agent_dir=%s\n' "$AGENT_DIR"
  printf 'model=openai-codex/gpt-5.6-sol\n'
  printf 'context_window=272000\n'
  printf 'effort=medium\n'
  printf 'boundary_percent=60\n'
  printf 'keep_recent_tokens=20000\n'
} > "$HOME_DIR/config/pi-delegated-profile"

HOME="$HOSTILE_HOME" PI_CODING_AGENT_DIR="$HOSTILE_AGENT" PI_CONFIG_DIR="$TMP_ROOT/ineffective" \
  PI_PACKAGE_DIR="$HOSTILE_PACKAGE" NODE_OPTIONS="--require=$HOSTILE_PRELOAD" NODE_PATH="$HOSTILE_PACKAGE" \
  FM_HOSTILE_PRELOAD_MARKER="$HOSTILE_PRELOAD_MARKER" FM_HOSTILE_PACKAGE="$HOSTILE_PACKAGE" \
  fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" \
  || fail "controlled profile did not neutralize hostile HOME, Node/Pi runtime variables, and project settings"
assert_absent "$HOSTILE_PRELOAD_MARKER" "hostile Node preload executed during delegated profile validation"
[ "$FM_PI_CONTEXT_WINDOW" = 272000 ] || fail "effective context window was not 272000"
[ "$FM_PI_THRESHOLD" = 163200 ] || fail "60 percent threshold was not 163200"
[ "$FM_PI_RESERVE_TOKENS" = 108800 ] || fail "272000-token model did not derive reserve 108800"
pass "effective Pi 0.81.1 metadata and controlled settings derive the 272000/108800 profile"

cp "$HOME_DIR/config/pi-delegated-profile" "$HOME_DIR/config/pi-delegated-profile.good"
sed 's/context_window=272000/context_window=372000/' "$HOME_DIR/config/pi-delegated-profile.good" \
  > "$HOME_DIR/config/pi-delegated-profile"
if fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" >/dev/null 2>&1; then
  fail "effective context mismatch was accepted"
fi
sed 's#model=openai-codex/gpt-5.6-sol#model=openai-codex/unknown-model#' "$HOME_DIR/config/pi-delegated-profile.good" \
  > "$HOME_DIR/config/pi-delegated-profile"
if fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" >/dev/null 2>&1; then
  fail "unknown model was accepted"
fi
mv "$HOME_DIR/config/pi-delegated-profile.good" "$HOME_DIR/config/pi-delegated-profile"
pass "unknown models and effective context mismatches are refused before launch"

cp "$HOME_DIR/config/pi-delegated-profile" "$HOME_DIR/config/pi-delegated-profile.good"
sed -e 's#model=openai-codex/gpt-5.6-sol#model=openai/gpt-4o#' \
  -e 's/context_window=272000/context_window=128000/' \
  "$HOME_DIR/config/pi-delegated-profile.good" > "$HOME_DIR/config/pi-delegated-profile"
if fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" >/dev/null 2>&1; then
  fail "model without effective medium thinking support was accepted"
fi
mv "$HOME_DIR/config/pi-delegated-profile.good" "$HOME_DIR/config/pi-delegated-profile"
pass "models without effective medium thinking support are refused before launch"

WRAPPER_MARKER="$TMP_ROOT/wrapper-ran"
WRAPPER_COMMAND="$TMP_ROOT/pi-wrapper"
printf '#!/usr/bin/env bash\ntouch %q\nexec %q "$@"\n' "$WRAPPER_MARKER" "$PI_COMMAND" > "$WRAPPER_COMMAND"
chmod +x "$WRAPPER_COMMAND"
cp "$HOME_DIR/config/pi-delegated-profile" "$HOME_DIR/config/pi-delegated-profile.good"
sed "s#pi_command=$PI_COMMAND#pi_command=$WRAPPER_COMMAND#" \
  "$HOME_DIR/config/pi-delegated-profile.good" > "$HOME_DIR/config/pi-delegated-profile"
if fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" >/dev/null 2>&1; then
  fail "raw Pi launch wrapper was accepted"
fi
assert_absent "$WRAPPER_MARKER" "raw Pi launch wrapper executed before validation"
mv "$HOME_DIR/config/pi-delegated-profile.good" "$HOME_DIR/config/pi-delegated-profile"
fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" \
  || fail "controlled profile did not reload after wrapper rejection"
pass "raw Pi launch wrappers are rejected without execution"

STARTUP_REDIRECT="$TMP_ROOT/project-session-redirect"
STARTUP_GUARD_DIR="$TMP_ROOT/root with spaces/bin"
mkdir -p "$PROJECT_DIR/.pi/commands" "$PROJECT_DIR/.pi/hooks" "$PROJECT_DIR/.pi/tools" "$STARTUP_GUARD_DIR"
printf '%s\n' 'legacy project command' > "$PROJECT_DIR/.pi/commands/legacy.md"
printf '%s\n' 'legacy project hook' > "$PROJECT_DIR/.pi/hooks/legacy.js"
printf '%s\n' 'legacy project tool' > "$PROJECT_DIR/.pi/tools/custom-tool"
printf '{"sessionDir":"%s"}\n' "$STARTUP_REDIRECT" > "$PROJECT_DIR/.pi/settings.json"
cp "$ROOT/bin/fm-pi-startup-guard.cjs" "$STARTUP_GUARD_DIR/fm-pi-startup-guard.cjs"
startup_status=0
(
  cd "$PROJECT_DIR" \
    && NODE_OPTIONS='' \
      NODE_PATH='' \
      PI_PACKAGE_DIR='' \
      PI_CODING_AGENT_DIR="$AGENT_DIR" \
      PI_CODING_AGENT_SESSION_DIR="$FM_PI_SESSION_DIR" \
      FM_PI_DELEGATED_PROJECT_DIR="$FM_PI_PROJECT_DIR" \
      PI_SKIP_VERSION_CHECK=1 \
      perl -e 'my $seconds = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm $seconds; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
        10 node --require "$STARTUP_GUARD_DIR/fm-pi-startup-guard.cjs" "$PI_COMMAND" \
          --no-approve --no-extensions --no-tools --offline \
          --model openai-codex/gpt-5.6-sol --thinking medium --print startup-check
) > "$TMP_ROOT/startup.stdout" 2> "$TMP_ROOT/startup.stderr" || startup_status=$?
[ "$startup_status" -ne 0 ] || fail "provider-free delegated Pi startup unexpectedly completed a provider request"
if ! grep -q 'No API key found' "$TMP_ROOT/startup.stdout" \
  && ! grep -q 'No API key found' "$TMP_ROOT/startup.stderr"; then
  fail "delegated Pi did not reach the provider-free startup boundary"
fi
assert_absent "$STARTUP_REDIRECT" "project sessionDir redirected delegated Pi session storage"
assert_absent "$PROJECT_DIR/.pi/prompts" "Pi migrated project commands before applying delegated isolation"
assert_grep 'legacy project command' "$PROJECT_DIR/.pi/commands/legacy.md" "project commands changed during delegated Pi startup"
assert_grep 'legacy project hook' "$PROJECT_DIR/.pi/hooks/legacy.js" "project hooks changed during delegated Pi startup"
assert_grep 'legacy project tool' "$PROJECT_DIR/.pi/tools/custom-tool" "project tools changed during delegated Pi startup"
[ -d "$FM_PI_SESSION_DIR" ] || fail "delegated Pi did not use its controlled project-specific session directory"
pass "pre-flag startup ignores project settings and migrations through whitespace paths"

node --input-type=module - "$PI_PACKAGE_DIR" 272000 108800 <<'NODE' \
  || fail "Pi shouldCompact strict-boundary proof failed"
import { pathToFileURL } from "node:url";
const [pkg, window, reserve] = process.argv.slice(2);
const { shouldCompact } = await import(pathToFileURL(`${pkg}/dist/index.js`));
const settings = { enabled: true, reserveTokens: Number(reserve), keepRecentTokens: 20000 };
const boundary = Math.floor(0.60 * Number(window));
if (shouldCompact(boundary, Number(window), settings) !== false) process.exit(1);
if (shouldCompact(boundary + 1, Number(window), settings) !== true) process.exit(1);
NODE
pass "Pi uses strict greater-than: false at exactly 60 percent and true immediately above"

node --input-type=module - "$PI_PACKAGE_DIR" <<'NODE' \
  || fail "Pi resume thinking-state proof failed"
import { pathToFileURL } from "node:url";
const [pkg] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(`${pkg}/dist/index.js`));
const session = SessionManager.inMemory("/provider-free");
session.appendThinkingLevelChange("xhigh");
session.appendThinkingLevelChange("medium");
if (session.buildSessionContext().thinkingLevel !== "medium") process.exit(1);
NODE
pass "an explicit delegated medium change remains the restored session thinking state"

GUARD_RUNTIME_DIR="$TMP_ROOT/guard-runtime"
mkdir -p "$GUARD_RUNTIME_DIR/node_modules/@earendil-works"
cp "$ROOT/bin/fm-pi-profile-guard.ts" "$GUARD_RUNTIME_DIR/guard.ts"
ln -s "$PI_PACKAGE_DIR" "$GUARD_RUNTIME_DIR/node_modules/@earendil-works/pi-coding-agent"
printf '%s\n' '{"type":"module"}' > "$GUARD_RUNTIME_DIR/package.json"
FM_PI_DELEGATED_MODEL=openai-codex/gpt-5.6-sol \
FM_PI_DELEGATED_CONTEXT_WINDOW=272000 \
FM_PI_DELEGATED_AGENT_DIR="$AGENT_DIR" \
FM_PI_DELEGATED_RESERVE_TOKENS=108800 \
FM_PI_DELEGATED_KEEP_RECENT_TOKENS=20000 \
node --experimental-strip-types --no-warnings --input-type=module - "$GUARD_RUNTIME_DIR/guard.ts" "$AGENT_DIR" "$PROJECT_DIR" <<'NODE' \
  || fail "delegated profile runtime compaction guard proof failed"
import { writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
const [guardPath, agentDir, cwd] = process.argv.slice(2);
const { default: loadGuard } = await import(pathToFileURL(guardPath));
const { AgentSession, SettingsSelectorComponent, initTheme } = await import(pathToFileURL(
  `${dirname(guardPath)}/node_modules/@earendil-works/pi-coding-agent/dist/index.js`,
));
initTheme("dark");
const handlers = new Map();
loadGuard({ on(name, handler) { handlers.set(name, handler); } });
let shutdowns = 0;
const ctx = { cwd, ui: { notify() {} }, shutdown() { shutdowns += 1; } };
await handlers.get("session_start")({}, ctx);
if (shutdowns !== 0) process.exit(1);
let persistentWrites = 0;
let compactionEnabled = true;
const expectedModel = {
  provider: "openai-codex",
  id: "gpt-5.6-sol",
  contextWindow: 272000,
};
const transientState = { model: expectedModel, thinkingLevel: "medium" };
const guardedSession = {
  agent: { state: transientState },
  sessionManager: {
    appendModelChange() { persistentWrites += 1; },
    appendThinkingLevelChange() { persistentWrites += 1; },
  },
  settingsManager: {
    setDefaultModelAndProvider() { persistentWrites += 1; },
    setDefaultThinkingLevel() { persistentWrites += 1; },
    setCompactionEnabled(enabled) {
      compactionEnabled = enabled;
      persistentWrites += 1;
    },
    getCompactionEnabled() { return compactionEnabled; },
  },
  getAvailableThinkingLevels() { return ["off", "low", "medium", "high"]; },
  supportsThinking() { return true; },
  _emit() {},
  _extensionRunner: { emit() {} },
};
const changedModel = {
  provider: "openai",
  id: "gpt-4o",
  contextWindow: 128000,
};
let modelRejected = false;
try {
  await AgentSession.prototype.setModel.call(guardedSession, changedModel);
} catch {
  modelRejected = true;
}
if (!modelRejected) process.exit(1);
if (await AgentSession.prototype.cycleModel.call(guardedSession) !== undefined) process.exit(1);
AgentSession.prototype.setThinkingLevel.call(guardedSession, "high");
AgentSession.prototype.setAutoCompactionEnabled.call(guardedSession, false);
const effectiveCompaction = Object.getOwnPropertyDescriptor(
  AgentSession.prototype,
  "autoCompactionEnabled",
).get.call(guardedSession);
let footerCompaction = true;
let callbackCompaction;
const settingsSelector = new SettingsSelectorComponent({
  autoCompact: true,
  showImages: false,
  imageWidthCells: 80,
  autoResizeImages: true,
  blockImages: false,
  enableSkillCommands: true,
  steeringMode: "one-at-a-time",
  followUpMode: "one-at-a-time",
  transport: "sse",
  httpIdleTimeoutMs: 300000,
  thinkingLevel: "medium",
  availableThinkingLevels: ["off", "low", "medium", "high"],
  currentTheme: "dark",
  terminalTheme: "dark",
  availableThemes: ["dark"],
  hideThinkingBlock: false,
  showCacheMissNotices: true,
  collapseChangelog: false,
  enableInstallTelemetry: false,
  doubleEscapeAction: "tree",
  treeFilterMode: "default",
  showHardwareCursor: false,
  editorPaddingX: 0,
  outputPad: 0,
  autocompleteMaxVisible: 10,
  quietStartup: false,
  defaultProjectTrust: "ask",
  clearOnShrink: false,
  showTerminalProgress: false,
  warnings: {},
}, {
  onAutoCompactChange(enabled) {
    callbackCompaction = enabled;
    AgentSession.prototype.setAutoCompactionEnabled.call(guardedSession, enabled);
    footerCompaction = enabled;
  },
});
const settingsList = settingsSelector.getSettingsList();
settingsList.activateItem();
const selectorCompaction = settingsList.items.find((item) => item.id === "autocompact")?.currentValue;
if (
  transientState.model !== expectedModel ||
  transientState.thinkingLevel !== "medium" ||
  effectiveCompaction !== true ||
  callbackCompaction !== true ||
  footerCompaction !== true ||
  selectorCompaction !== "true" ||
  persistentWrites !== 0
) {
  process.exit(1);
}
writeFileSync(`${agentDir}/settings.json`, '{"compaction":{"enabled":false,"reserveTokens":108800,"keepRecentTokens":20000}}\n');
const inputResult = await handlers.get("input")({}, ctx);
const compactResult = await handlers.get("session_before_compact")({}, ctx);
if (inputResult?.action !== "handled" || compactResult?.cancel !== true || shutdowns !== 2) process.exit(1);
NODE
printf '%s\n' '{"compaction":{"enabled":true,"reserveTokens":108800,"keepRecentTokens":20000},"defaultThinkingLevel":"xhigh"}' > "$AGENT_DIR/settings.json"
pass "runtime controls cannot leak model, thinking, or compaction changes"

TSC_COMMAND=${FM_TSC_COMMAND:-}
if [ -z "$TSC_COMMAND" ]; then
  TSC_COMMAND=$(command -v tsc 2>/dev/null || true)
fi
if [ -z "$TSC_COMMAND" ] && command -v npm >/dev/null 2>&1; then
  candidate_tsc="$(npm root -g)/typescript/bin/tsc"
  [ ! -f "$candidate_tsc" ] || TSC_COMMAND=$candidate_tsc
fi
if [ -z "$TSC_COMMAND" ]; then
  echo "skip: tsc not found for delegated Pi profile guard typecheck"
else
  [ -f "$PI_PACKAGE_DIR/node_modules/typebox/package.json" ] \
    || fail "installed Pi package is missing typebox declarations"
  [ -f "$PI_PACKAGE_DIR/node_modules/@types/node/package.json" ] \
    || fail "installed Pi package is missing Node declarations"
  TYPECHECK_DIR="$TMP_ROOT/typecheck"
  mkdir -p "$TYPECHECK_DIR/node_modules/@earendil-works" "$TYPECHECK_DIR/node_modules/@types"
  cp "$ROOT/bin/fm-pi-profile-guard.ts" "$TYPECHECK_DIR/guard.ts"
  ln -s "$PI_PACKAGE_DIR" "$TYPECHECK_DIR/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TYPECHECK_DIR/node_modules/typebox"
  ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TYPECHECK_DIR/node_modules/@types/node"
  printf '%s\n' '{"type":"module"}' > "$TYPECHECK_DIR/package.json"
  "$TSC_COMMAND" --strict --noEmit --skipLibCheck --module NodeNext --moduleResolution NodeNext --target ES2022 \
    "$TYPECHECK_DIR/guard.ts" \
    || fail "fm-pi-profile-guard.ts failed strict no-emit typecheck against Pi 0.81.1"
  assert_absent "$TYPECHECK_DIR/guard.js" "strict no-emit guard typecheck emitted JavaScript"
  pass "fm-pi-profile-guard.ts passes strict no-emit typecheck against Pi 0.81.1"
fi

assert_grep 'no-approve' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not suppress trusted project overrides"
assert_grep 'no-extensions' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not suppress discovered cancellation extensions"
assert_grep 'fm-pi-startup-guard.cjs' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not guard pre-flag project startup reads"
assert_grep 'PI_CODING_AGENT_SESSION_DIR' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not pin controlled session storage"
assert_grep 'fm-pi-profile-guard.ts' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not preserve the explicit profile guard"
assert_grep 'AgentSession.prototype.setModel = guardedSetModel' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not prevent model selection before mutation"
assert_grep 'AgentSession.prototype.cycleModel = guardedCycleModel' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not prevent model cycling before mutation"
assert_grep 'AgentSession.prototype.setThinkingLevel = guardedSetThinkingLevel' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not keep medium stable before mutation"
assert_grep 'AgentSession.prototype.setAutoCompactionEnabled = guardedSetAutoCompactionEnabled' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not preserve compaction before mutation"
assert_grep 'SettingsSelectorComponent.prototype.getSettingsList = guardedGetSettingsList' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not preserve displayed compaction state"
assert_grep 'session_before_compact' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not validate runtime compaction"
assert_grep 'pi-delegated-profile' "$ROOT/bin/fm-config-inherit-lib.sh" "secondmate homes do not inherit the delegated Pi profile"
pass "hostile project and extension surfaces are neutralized while explicit FirstMate extensions remain supported"

SPAWN_ROOT="$TMP_ROOT/spawn-root"
SPAWN_FAKEBIN="$TMP_ROOT/spawn-fakebin"
mkdir -p "$SPAWN_ROOT" "$SPAWN_FAKEBIN"
cp -R "$ROOT/bin" "$SPAWN_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SPAWN_FAKEBIN/sleep"
chmod +x "$SPAWN_FAKEBIN/sleep"

cat > "$SPAWN_ROOT/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_container_ensure() { printf 'profile-test'; }
fm_backend_tmux_create_task() { printf '%%1'; }
fm_backend_tmux_send_text_line() { :; }
fm_backend_tmux_current_path() { printf '%s\n' "$FM_PROFILE_TEST_WT"; }
fm_backend_tmux_send_literal() { printf 'tmux\t%s\n' "$2" >> "$FM_PROFILE_TEST_LOG"; }
fm_backend_tmux_send_key() { :; }
SH
cat > "$SPAWN_ROOT/bin/backends/herdr.sh" <<'SH'
fm_backend_herdr_projection_journal_path() { printf '%s/%s.herdr-presentation\n' "$1" "$2"; }
fm_backend_herdr_container_ensure() { printf 'profile-test:w1\t'; }
fm_backend_herdr_create_task() { printf 't1 p1'; }
fm_backend_herdr_send_text_line() { :; }
fm_backend_herdr_current_path() { printf '%s\n' "$FM_PROFILE_TEST_WT"; }
fm_backend_herdr_send_literal() { printf 'herdr\t%s\n' "$2" >> "$FM_PROFILE_TEST_LOG"; }
fm_backend_herdr_send_key() { :; }
SH
cat > "$SPAWN_ROOT/bin/backends/zellij.sh" <<'SH'
fm_backend_zellij_container_ensure() { printf 'profile-test'; }
fm_backend_zellij_create_task() { printf '1 2'; }
fm_backend_zellij_send_text_line() { :; }
fm_backend_zellij_current_path() { printf '%s\n' "$FM_PROFILE_TEST_WT"; }
fm_backend_zellij_send_literal() { printf 'zellij\t%s\n' "$2" >> "$FM_PROFILE_TEST_LOG"; }
fm_backend_zellij_send_key() { :; }
SH
cat > "$SPAWN_ROOT/bin/backends/cmux.sh" <<'SH'
fm_backend_cmux_container_ensure() { :; }
fm_backend_cmux_create_task() { printf 'w1 s1'; }
fm_backend_cmux_send_text_line() { :; }
fm_backend_cmux_current_path() { printf '%s\n' "$FM_PROFILE_TEST_WT"; }
fm_backend_cmux_send_literal() { printf 'cmux\t%s\n' "$2" >> "$FM_PROFILE_TEST_LOG"; }
fm_backend_cmux_send_key() { :; }
SH
cat > "$SPAWN_ROOT/bin/backends/orca.sh" <<'SH'
fm_backend_orca_runtime_check() { :; }
fm_backend_orca_worktree_create() { printf 'wt1\t%s\tterm1' "$FM_PROFILE_TEST_WT"; }
fm_backend_orca_send_text_line() { :; }
fm_backend_orca_send_literal() { printf 'orca\t%s\n' "$2" >> "$FM_PROFILE_TEST_LOG"; }
fm_backend_orca_send_key() { :; }
SH

run_profile_spawn() {
  local backend=$1 home=$2 project=$3 wt=$4 log=$5 id=$6
  FM_ROOT_OVERRIDE="$SPAWN_ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_PROFILE_TEST_WT="$wt" FM_PROFILE_TEST_LOG="$log" \
    PATH="$SPAWN_FAKEBIN:$PATH" \
    "$SPAWN_ROOT/bin/fm-spawn.sh" "$id" "$project" --harness pi --backend "$backend"
}

for backend in tmux herdr zellij orca cmux; do
  case_root="$TMP_ROOT/backend-$backend"
  case_home="$case_root/home"
  case_project="$case_root/project"
  case_wt="$case_root/wt"
  case_log="$case_root/launch.log"
  case_id="profile-$backend-z1"
  mkdir -p "$case_home/config" "$case_home/data/$case_id" "$case_home/state" "$case_home/projects"
  fm_git_worktree "$case_project" "$case_wt" "fm/$case_id"
  printf 'backend profile brief\n' > "$case_home/data/$case_id/brief.md"
  touch "$case_home/state/.last-watcher-beat"
  cp "$HOME_DIR/config/pi-delegated-profile" "$case_home/config/pi-delegated-profile"
  : > "$case_log"
  run_profile_spawn "$backend" "$case_home" "$case_project" "$case_wt" "$case_log" "$case_id" >/dev/null \
    || fail "delegated Pi profile did not traverse the executable $backend spawn route"
  launch=$(cut -f2- "$case_log")
  assert_contains "$launch" "--thinking 'medium'" "$backend launch lost explicit medium thinking"
  assert_contains "$launch" "--no-approve --no-extensions" "$backend launch lost delegated isolation"
  assert_contains "$launch" "fm-pi-profile-guard.ts" "$backend launch lost the profile guard"
  assert_not_contains "$launch" "__PIBRIEFENV__" "$backend launch retained the unresolved Pi brief placeholder"
  [ "$(sed -n 's/^backend=//p' "$case_home/state/$case_id.meta")" = "$backend" ] || [ "$backend" = tmux ] \
    || fail "$backend spawn did not record its backend route"
done
pass "the delegated profile traverses every executable backend handoff"

PRIMARY_LOG="$TMP_ROOT/primary-launch.log"
cat > "$SPAWN_FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$PWD" > "$FM_PI_PRIMARY_TEST_LOG"
printf 'arg=%s\n' "$@" >> "$FM_PI_PRIMARY_TEST_LOG"
SH
chmod +x "$SPAWN_FAKEBIN/pi"
FM_PI_PRIMARY_TEST_LOG="$PRIMARY_LOG" PATH="$SPAWN_FAKEBIN:$PATH" \
  "$ROOT/bin/fm-pi-primary.sh" --no-session \
  || fail "FirstMate primary Pi launcher failed against the provider-free command double"
assert_grep "cwd=$ROOT" "$PRIMARY_LOG" "primary Pi launcher did not enter the FirstMate root"
assert_grep 'arg=--thinking' "$PRIMARY_LOG" "primary Pi launcher omitted the thinking flag"
assert_grep 'arg=xhigh' "$PRIMARY_LOG" "primary Pi launcher lost xhigh thinking"
assert_no_grep 'arg=medium' "$PRIMARY_LOG" "delegated medium leaked into the primary Pi launcher"
if FM_PI_PRIMARY_TEST_LOG="$PRIMARY_LOG" PATH="$SPAWN_FAKEBIN:$PATH" \
  "$ROOT/bin/fm-pi-primary.sh" --thinking medium >/dev/null 2>&1; then
  fail "primary Pi launcher accepted a thinking-level override"
fi
pass "delegated medium remains separate from the primary Pi xhigh path"

echo "# all fm-pi-compaction-profile tests passed"
