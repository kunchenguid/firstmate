#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (/^fm_watch_arm_(pi|omp)$/.test(candidate.name)) tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

test_adapter_waits_for_slow_supervision_scan() (
  local mode=$1 dir repo home fakebin plugin delay=20
  dir=$(make_case "slow-adapter-$mode")
  repo="$dir/repo"
  home="$dir/home"
  fakebin="$dir/fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_test_track_watcher_state "$home/state"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  install_pi_watch_extension_fixture "$repo"
  cp -R "$ROOT/bin/." "$repo/bin/"
  if [ "$mode" = pi ]; then
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  elif [[ "$mode" = omp* ]]; then
    mkdir -p "$repo/.omp/extensions"
    cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
    plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  else
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  fi
  if [[ "$mode" = *-host ]]; then
    delay=35
    : > "$home/config/supervision-host"
  else
    : > "$home/config/supervision-host-off"
  fi
  export FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state"
  export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_TIMEOUT=45 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999
  unset FM_OMP_ARM_READY_TIMEOUT_MS FM_PI_ARM_READY_TIMEOUT_MS FM_OPENCODE_ARM_READY_TIMEOUT_MS FM_ARM_CONFIRM_TIMEOUT FM_SUPERVISION_HOST_READY_TIMEOUT
  {
    printf '#!/usr/bin/env bash\nsleep %s\n' "$delay"
    cat <<'SH'
touch "$FM_HOME/scanned"
SH
  } > "$home/state/slow.check.sh"
  chmod 0700 "$home/state/slow.check.sh"
  "$ROOT/bin/fm-check-register.sh" slow >/dev/null || fail "register slow adapter check"
  printf 'pending:downtime:adapter.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: adapter recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  PLUGIN="$plugin" MODE="$mode" PATH="$fakebin:$PATH" bash -c 'case "$1" in omp*) name=omp ;; opencode*) name=opencode ;; *) name=$1 ;; esac; exec -a "$name" node --input-type=module' _ "$mode" <<'JS' || fail "$mode aborted a legitimate slow supervision scan"
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const prompts = [];
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
if (process.env.MODE === "pi" || process.env.MODE.startsWith("omp")) {
  let tool;
  mod.default({
    on() {}, registerCommand() {},
    registerTool(candidate) { if (/^fm_watch_arm_(pi|omp)$/.test(candidate.name)) tool = candidate; },
    sendUserMessage: async (message) => { prompts.push(String(message)); },
  });
  await tool.execute("slow-scan", {}, undefined, undefined, {});
} else {
  const client = { session: { promptAsync: async (request) => { prompts.push(JSON.stringify(request)); } } };
  await mod.FmPrimaryWatchArm({ client, directory: process.env.FM_ROOT_OVERRIDE, worktree: process.env.FM_ROOT_OVERRIDE });
  await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("slow-scan", client);
}
for (let i = 0; i < 1200 && !prompts.length; i++) await new Promise((resolve) => setTimeout(resolve, 100));
if (prompts.length !== 1) throw new Error(`expected one recovery delivery, got ${prompts.length}`);
if (/watcher: FAILED|could not restore|could not verify/.test(prompts[0])) throw new Error(prompts[0]);
if (!existsSync(`${home}/scanned`)) throw new Error("recovery delivered before the slow check completed");
if (!existsSync(`${home}/state/.last-watcher-beat`)) throw new Error("recovery lacks a completed-scan heartbeat");
const pid = Number(readFileSync(`${home}/state/.watch.lock/pid`, "utf8").trim());
process.kill(pid, 0);
process.exit(0);
JS
  pass "$mode waits for a slow real supervision scan before recovery delivery"
)

test_adapter_waits_for_slow_supervision_scan pi || exit 1
test_adapter_waits_for_slow_supervision_scan opencode || exit 1
test_adapter_waits_for_slow_supervision_scan opencode-host || exit 1
test_adapter_waits_for_slow_supervision_scan omp || exit 1
test_adapter_waits_for_slow_supervision_scan omp-host || exit 1

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
