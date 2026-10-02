#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

test_opencode_consecutive_wakes_keep_successor() {
  local repo out status
  repo="$TMP_ROOT/opencode-consecutive"
  mkdir -p "$repo/bin" "$repo/state" "$repo/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$repo/state/crew.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_HOME/state/arm-count" ] || read -r count < "$FM_HOME/state/arm-count"
count=$((count + 1))
printf '%s\n' "$count" > "$FM_HOME/state/arm-count"
printf 'watcher: started pid=%s\n' "$$"
if [ "$count" -le 2 ]; then
  sleep 0.1
  printf 'check: consecutive-%s\n' "$count"
else
  printf '%s\n' "$$" > "$FM_HOME/state/successor-pid"
  exec sleep 60
fi
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$repo/state" \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const prompts = [];
const client = { session: { promptAsync: async ({ body }) => {
  // Hold predecessor delivery open while the successor fires independently.
  await new Promise(resolve => setTimeout(resolve, 400));
  prompts.push(body.parts[0].text);
} } };
const mod = await import(pathToFileURL(process.env.PLUGIN));
const hooks = await mod.FmPrimaryWatchArm({ client, directory: home, worktree: home });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "fixture" } } });
const deadline = Date.now() + 10000;
while (Date.now() < deadline && prompts.length < 2) {
  await new Promise(resolve => setTimeout(resolve, 50));
}
let pid;
try {
  if (existsSync(`${home}/state/successor-pid`)) {
    pid = Number(readFileSync(`${home}/state/successor-pid`, "utf8"));
    process.kill(pid, 0);
  }
  if (!pid) throw new Error("no live third arm after consecutive wakes");
  if (prompts.length !== 2 || !prompts[0].includes("consecutive-1") || !prompts[1].includes("consecutive-2")) {
    throw new Error(`wakes lost or reordered: ${JSON.stringify(prompts)}`);
  }
  if (Number(readFileSync(`${home}/state/arm-count`, "utf8")) !== 3) {
    throw new Error("unexpected extra successor");
  }
  console.log("two overlapping wakes delivered in order; third arm alive");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  if (pid) process.kill(pid, "SIGTERM");
  process.exit(process.exitCode ?? 0);
}
JS
  )
  status=$?
  expect_code 0 "$status" "OpenCode must retain overlapping actionable closes: $out"
  pass "OpenCode delivers consecutive wakes and keeps one live successor"
}

test_opencode_failed_successor_during_delivery_rearms() {
  local repo out status
  repo="$TMP_ROOT/opencode-failed-successor"
  mkdir -p "$repo/bin" "$repo/state" "$repo/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$repo/state/crew.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_HOME/state/arm-count" ] || read -r count < "$FM_HOME/state/arm-count"
count=$((count + 1))
printf '%s\n' "$count" > "$FM_HOME/state/arm-count"
printf 'watcher: started pid=%s\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'check: delivery-blocked\n'
else
  printf '%s\n' "$$" > "$FM_HOME/state/successor-pid"
  exec sleep 60
fi
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$repo/state" \
    FM_WATCH_REARM_RETRY_BASE_MS=10 node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
let releaseDelivery;
const deliveryBlocked = new Promise(resolve => { releaseDelivery = resolve; });
let deliveryStarted = false;
const prompts = [];
const client = { session: { promptAsync: async ({ body }) => {
  deliveryStarted = true;
  await deliveryBlocked;
  prompts.push(body.parts[0].text);
} } };
const mod = await import(pathToFileURL(process.env.PLUGIN));
const hooks = await mod.FmPrimaryWatchArm({ client, directory: home, worktree: home });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "fixture" } } });
const blockedDeadline = Date.now() + 5000;
while (Date.now() < blockedDeadline && (!deliveryStarted || !existsSync(`${home}/state/successor-pid`))) {
  await new Promise(resolve => setTimeout(resolve, 20));
}
let pid;
try {
  if (!deliveryStarted) throw new Error("wake delivery did not block");
  pid = Number(readFileSync(`${home}/state/successor-pid`, "utf8"));
  const failedPid = pid;
  process.kill(failedPid, "SIGHUP");
  const retryDeadline = Date.now() + 5000;
  while (Date.now() < retryDeadline) {
    pid = Number(readFileSync(`${home}/state/successor-pid`, "utf8"));
    if (pid !== failedPid) break;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  if (pid === failedPid) throw new Error("failed successor was not replaced during blocked delivery");
  process.kill(pid, 0);
  if (Number(readFileSync(`${home}/state/arm-count`, "utf8")) !== 3 || prompts.length !== 0) {
    throw new Error("failure retry waited for delivery or duplicated successor launches");
  }
  releaseDelivery();
  const deliveryDeadline = Date.now() + 5000;
  while (Date.now() < deliveryDeadline && prompts.length === 0) {
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  if (prompts.length !== 1) {
    throw new Error("wake delivery did not complete after release");
  }
  console.log("failed successor rearmed while delivery remained blocked");
} catch (error) {
  releaseDelivery();
  console.error(error);
  process.exitCode = 1;
} finally {
  if (pid) {
    try { process.kill(pid, "SIGTERM"); } catch {}
  }
  process.exit(process.exitCode ?? 0);
}
JS
  )
  status=$?
  expect_code 0 "$status" "OpenCode must rearm a failed successor during blocked wake delivery: $out"
  pass "OpenCode rearms a failed successor during blocked wake delivery"
}

test_opencode_stale_recovery_does_not_retire_replacement() {
  local repo out status
  repo="$TMP_ROOT/opencode-stale-recovery"
  mkdir -p "$repo/bin" "$repo/state" "$repo/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$repo/state/crew.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  kill -0 "$4" 2>/dev/null
  exit $?
fi
count=0
[ ! -f "$FM_HOME/state/arm-count" ] || read -r count < "$FM_HOME/state/arm-count"
count=$((count + 1))
printf '%s\n' "$count" > "$FM_HOME/state/arm-count"
printf '%s\n' "$$" > "$FM_HOME/state/arm-pid-$count"
if [ "$count" -eq 4 ]; then
  while [ ! -f "$FM_HOME/state/release-fourth-arm" ]; do sleep 0.02; done
fi
printf 'watcher: started pid=%s recovery-generation=generation-%s\n' "$$" "$count"
case "$count" in
  1) printf 'check: first-wake\n' ;;
  2) sleep 0.3; printf 'check: queued-wake\n' ;;
  *) exec sleep 60 ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$repo/state" \
    FM_WATCH_REARM_RETRY_BASE_MS=10 node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
let releaseFirst;
const firstBlocked = new Promise(resolve => { releaseFirst = resolve; });
const prompts = [];
const client = { session: { promptAsync: async ({ body }) => {
  prompts.push(body.parts[0].text);
  if (prompts.length === 1) await firstBlocked;
} } };
const readPid = number => Number(readFileSync(`${home}/state/arm-pid-${number}`, "utf8"));
const waitForFile = async (path, timeout = 5000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline && !existsSync(path)) {
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  if (!existsSync(path)) throw new Error(`timed out waiting for ${path}`);
};
const mod = await import(pathToFileURL(process.env.PLUGIN));
const hooks = await mod.FmPrimaryWatchArm({ client, directory: home, worktree: home });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "fixture" } } });
let replacementPid;
try {
  await waitForFile(`${home}/state/arm-pid-3`);
  const stalePid = readPid(3);
  process.kill(stalePid, "SIGHUP");
  await waitForFile(`${home}/state/arm-pid-4`);
  replacementPid = readPid(4);
  process.kill(replacementPid, 0);
  if (prompts.length !== 1) throw new Error("first wake delivery was not blocked");
  releaseFirst();
  const queuedDeadline = Date.now() + 5000;
  while (Date.now() < queuedDeadline && prompts.length < 2) {
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  if (prompts.length !== 2 || !prompts[1].includes("queued-wake")) {
    throw new Error(`queued wake was not delivered in order: ${JSON.stringify(prompts)}`);
  }
  process.kill(replacementPid, 0);
  if (Number(readFileSync(`${home}/state/arm-count`, "utf8")) !== 4) {
    throw new Error("stale recovery retired the replacement arm");
  }
  writeFileSync(`${home}/state/release-fourth-arm`, "ready\n");
  await new Promise(resolve => setTimeout(resolve, 100));
  process.kill(replacementPid, 0);
  console.log("stale recovery left the exact replacement arm alive");
} catch (error) {
  releaseFirst();
  console.error(error);
  process.exitCode = 1;
} finally {
  if (replacementPid) {
    try { process.kill(replacementPid, "SIGTERM"); } catch {}
  }
  process.exit(process.exitCode ?? 0);
}
JS
  )
  status=$?
  expect_code 0 "$status" "OpenCode must not retire a replacement for a stale recovery generation: $out"
  pass "OpenCode binds recovery retirement to its exact arm"
}

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
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
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

test_handling_successor_does_not_go_blind
test_opencode_consecutive_wakes_keep_successor
test_opencode_failed_successor_during_delivery_rearms
test_opencode_stale_recovery_does_not_retire_replacement
test_unacknowledged_recovery_is_announced_once_per_generation
