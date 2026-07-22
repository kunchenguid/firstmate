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
mkdir -p "$HOME_DIR/config" "$AGENT_DIR/extensions" "$PROJECT_DIR/.pi/extensions" "$HOSTILE_HOME" "$HOSTILE_AGENT" "$HOSTILE_PACKAGE"

printf '%s\n' '{"compaction":{"enabled":true,"reserveTokens":108800,"keepRecentTokens":20000},"defaultThinkingLevel":"xhigh"}' > "$AGENT_DIR/settings.json"
printf '%s\n' '{"compaction":{"enabled":false,"reserveTokens":1},"defaultThinkingLevel":"low"}' > "$PROJECT_DIR/.pi/settings.json"
printf '%s\n' 'export default pi => { pi.on("session_before_compact", () => ({ cancel: true })); };' > "$PROJECT_DIR/.pi/extensions/cancel.ts"
printf '%s\n' 'export default pi => { pi.on("session_before_compact", () => ({ cancel: true })); };' > "$AGENT_DIR/extensions/cancel.ts"
printf '%s\n' '{"name":"hostile-pi","version":"9.9.9","piConfig":{"name":"hostile","configDir":".hostile"}}' > "$HOSTILE_PACKAGE/package.json"
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
  PI_PACKAGE_DIR="$HOSTILE_PACKAGE" \
  fm_pi_profile_load "$HOME_DIR/config" "$PROJECT_DIR" \
  || fail "controlled profile did not neutralize hostile HOME, Pi package/config variables, and project settings"
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
pass "raw Pi launch wrappers are rejected without execution"

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
import { pathToFileURL } from "node:url";
const [guardPath, agentDir, cwd] = process.argv.slice(2);
const { default: loadGuard } = await import(pathToFileURL(guardPath));
const handlers = new Map();
loadGuard({ on(name, handler) { handlers.set(name, handler); } });
let shutdowns = 0;
const ctx = { cwd, ui: { notify() {} }, shutdown() { shutdowns += 1; } };
await handlers.get("session_start")({}, ctx);
if (shutdowns !== 0) process.exit(1);
writeFileSync(`${agentDir}/settings.json`, '{"compaction":{"enabled":false,"reserveTokens":108800,"keepRecentTokens":20000}}\n');
const inputResult = await handlers.get("input")({}, ctx);
const compactResult = await handlers.get("session_before_compact")({}, ctx);
if (inputResult?.action !== "handled" || compactResult?.cancel !== true || shutdowns !== 2) process.exit(1);
NODE
printf '%s\n' '{"compaction":{"enabled":true,"reserveTokens":108800,"keepRecentTokens":20000},"defaultThinkingLevel":"xhigh"}' > "$AGENT_DIR/settings.json"
pass "runtime compaction changes block turns and compaction"

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
assert_grep 'fm-pi-profile-guard.ts' "$ROOT/bin/fm-spawn.sh" "delegated Pi command does not preserve the explicit profile guard"
assert_grep 'event.level !== "medium"' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not keep medium stable on resume"
assert_grep 'selected !== expectedModel' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not refuse model cycling"
assert_grep 'session_before_compact' "$ROOT/bin/fm-pi-profile-guard.ts" "profile guard does not validate runtime compaction"
assert_grep 'pi-delegated-profile' "$ROOT/bin/fm-config-inherit-lib.sh" "secondmate homes do not inherit the delegated Pi profile"
pass "hostile project and extension surfaces are neutralized while explicit FirstMate extensions remain supported"

for backend in tmux herdr zellij orca cmux; do
  assert_grep "  $backend)" "$ROOT/bin/fm-spawn.sh" "spawn lost the $backend route"
done
assert_grep 'MODELFLAG=$(model_flag_for_harness' "$ROOT/bin/fm-spawn.sh" "backend routes no longer converge on one rendered profile"
assert_grep 'spawn_send_literal "$T" "$LAUNCH"' "$ROOT/bin/fm-spawn.sh" "rendered profile is not submitted through the common backend handoff"
assert_grep 'backend=orca does not support --secondmate' "$ROOT/bin/fm-spawn.sh" "Orca secondmate safe refusal changed"
assert_grep 'backend=cmux does not support --secondmate' "$ROOT/bin/fm-spawn.sh" "cmux secondmate safe refusal changed"
pass "ships, scouts, batches, recovery, and supported secondmates share one profile across all backends"

assert_grep 'FM_PI_EFFORT" = medium' "$ROOT/bin/fm-pi-profile.sh" "delegated Pi profile does not require medium"
PRIMARY_PI_LAUNCHER=${FM_PI_PRIMARY_LAUNCHER:-}
if [ -n "$PRIMARY_PI_LAUNCHER" ]; then
  [ -f "$PRIMARY_PI_LAUNCHER" ] || fail "configured primary Pi launcher is absent: $PRIMARY_PI_LAUNCHER"
  assert_grep 'thinking xhigh' "$PRIMARY_PI_LAUNCHER" "primary Pi xhigh path changed"
  pass "delegated Pi remains medium while the configured primary Pi path remains xhigh"
else
  echo "skip: FM_PI_PRIMARY_LAUNCHER not set for optional primary Pi xhigh check"
  pass "delegated Pi profile requires medium"
fi

echo "# all fm-pi-compaction-profile tests passed"
