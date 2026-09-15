#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
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

# T2: a handling successor must enter its poll loop immediately and surface a
# real crew event instead of sitting in a pre-loop wait that refreshes the
# liveness beacon and then exits with a synthetic rearm-resurface.
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
  while [ "$now" -lt 5 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within a poll interval or two (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
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

# T3: handling can finish between successor readiness and the delivery RPC.
# Keep the real arm, watcher, queue and acknowledgement owner; the wrapper only
# schedules that race deterministically, before forwarding the real RPC.
test_pi_acknowledged_wake_is_not_delivered_again() {
  local scenario repo home fakebin out status
  for scenario in acked early-acked pending empty-pending newer malformed missing; do
    repo="$TMP_ROOT/t3-$scenario-root"
    home="$TMP_ROOT/t3-$scenario-home"
    fakebin="$TMP_ROOT/t3-$scenario-fakebin"
    mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
    install_pi_watch_extension_fixture "$repo"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
    chmod +x "$fakebin/tmux"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
export FM_ROOT_OVERRIDE="$FM_REAL_ROOT"
export PATH="$FM_FIXTURE_BIN:$PATH"
if [ "$FM_RACE" = early-acked ] && [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] && [ ! -e "$FM_HOME/raced" ]; then
  "$FM_REAL_ROOT/bin/fm-wake-drain.sh" --ack-through 1 --recovery-generation seed.1.aaa > "$FM_HOME/ack.out" 2>&1 || exit 99
  touch "$FM_HOME/raced"
fi
if [ "${1:-}" = --handling-delivered ]; then
  if [ ! -e "$FM_HOME/raced" ]; then
    touch "$FM_HOME/raced"
    case "$FM_RACE" in
      acked|newer)
        "$FM_REAL_ROOT/bin/fm-wake-drain.sh" --ack-through 1 --recovery-generation "$2" > "$FM_HOME/ack.out" 2>&1 || exit 99
        if [ "$FM_RACE" = newer ]; then
          bash -c '. "$FM_REAL_ROOT/bin/fm-wake-lib.sh"; fm_wake_append check newer "check: newer work"' || exit 99
        fi
        ;;
      empty-pending) : > "$FM_HOME/state/.wake-queue" ;;
      malformed) printf 'invalid\n' > "$FM_HOME/state/.watcher-down" ;;
      missing) rm "$FM_HOME/state/.watcher-down" ;;
    esac
  fi
  "$FM_REAL_ROOT/bin/fm-watch-arm.sh" "$@"
  rc=$?
  printf '%s\n' "$rc" >> "$FM_HOME/confirm.log"
  exit "$rc"
fi
exec "$FM_REAL_ROOT/bin/fm-watch-arm.sh" "$@"
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    : > "$home/state/seed.meta"
    printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_REAL_ROOT="$ROOT" \
      bash -c '. "$FM_REAL_ROOT/bin/fm-wake-lib.sh"; fm_wake_append check unfinished-execution "check: unfinished-execution"' \
      || fail "could not seed real wake queue"
    out=$(
      PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" \
        FM_ROOT_OVERRIDE="$repo" FM_REAL_ROOT="$ROOT" FM_FIXTURE_BIN="$fakebin" FM_RACE="$scenario" \
        FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
        FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_HOME;
const prompts = [];
const handlers = new Map();
let tool;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { tool = candidate; },
  sendUserMessage: async (message) => { prompts.push(message); },
};
const pause = () => new Promise(resolve => setTimeout(resolve, 50));
async function waitFor(predicate, label) {
  for (let i = 0; i < 300; i++) {
    if (predicate()) return;
    await pause();
  }
  throw new Error(`timeout: ${label}`);
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tool.execute();
  await waitFor(() => existsSync(`${home}/confirm.log`), "real handshake");
  // Allow both rejected-confirmation retries and prompt dispatch to settle.
  for (let i = 0; i < 10; i++) await pause();
  const results = readFileSync(`${home}/confirm.log`, "utf8").trim().split("\n");
  if (["acked", "early-acked"].includes(process.env.FM_RACE)) {
    assert.equal(readFileSync(`${home}/state/.wake-queue`, "utf8"), "");
    assert.match(readFileSync(`${home}/state/.watcher-down`, "utf8"), /^acked:/);
    assert.equal(prompts.length, 0, `handled wake was re-delivered (RPC ${results}): ${prompts.join(" | ")}`);
    assert.deepEqual(results, ["4"], "already handled is terminal, not retried");
    const watcherPid = readFileSync(`${home}/state/.watch.lock/pid`, "utf8").trim();
    const confirm = (generation, pid) => spawnSync("bash", [
      `${process.env.FM_REAL_ROOT}/bin/fm-watch-arm.sh`, "--handling-delivered", generation, "--watcher-pid", pid,
    ], { env: process.env, encoding: "utf8" }).status;
    assert.equal(confirm("wrong-generation", watcherPid), 3, "retirement requires exact generation");
    assert.equal(confirm("seed.1.aaa", String(process.pid)), 1, "retirement requires the actual successor");
    for (let i = 0; i < 3; i++) {
      assert.equal(confirm("seed.1.aaa", watcherPid), 4, "repeated stale confirmations stay terminal");
    }
    // The live successor must still deliver newly arriving work after skipping.
    writeFileSync(`${home}/state/seed.status`, "done: fresh work after acknowledgement\n");
    await waitFor(() => prompts.length > 0, "fresh actionable wake after retired delivery");
    assert.match(prompts[0], /signal:.*seed.status/);
    assert.match(readFileSync(`${home}/state/.wake-queue`, "utf8"), /\tsignal\tseed.status\t/);
  } else {
    assert.equal(prompts.length, 1, `outstanding or uncertain work was silenced: ${results}`);
    assert.match(prompts[0], /Run bin\/fm-wake-drain.sh first/);
    if (["newer", "malformed", "missing"].includes(process.env.FM_RACE)) {
      assert.match(prompts[0], /handling delivery confirmation was rejected/);
    }
    if (process.env.FM_RACE === "newer") {
      assert.match(readFileSync(`${home}/state/.wake-queue`, "utf8"), /check: newer work/);
    }
  }
  const pid = readFileSync(`${home}/state/.watch.lock/pid`, "utf8").trim();
  process.kill(Number(pid), 0);
} finally {
  await handlers.get("session_shutdown")?.();
}
EOF
    )
    status=$?
    expect_code 0 "$status" "Pi real acknowledgement race ($scenario): $out"
    [ -z "$out" ] || fail "Pi acknowledgement race printed output: $out"
  done
  pass "Pi skips an acknowledged wake but preserves pending, uncertain and newly arriving work"
}

test_pi_acknowledged_wake_is_not_delivered_again
test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
