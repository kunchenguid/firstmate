#!/usr/bin/env bash
# Exercise the OpenCode coordinator's readiness deadlines through its public API.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-host-startup)
trap fm_test_cleanup EXIT
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

test_readiness_window() {  # <host-ready|host-expiry|host-explicit|arm>
  local kind=$1 repo home out status
  repo="$TMP_ROOT/$kind/root"
  home="$TMP_ROOT/$kind/home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  [ "$kind" = arm ] || : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/child-pid"
trap 'exit 0' TERM INT
while [ ! -e "$FM_HOME/ready" ] && [ ! -e "$FM_HOME/stop" ] && [ -e "$0" ]; do sleep 0.02; done
[ ! -e "$FM_HOME/stop" ] || exit 0
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -e "$FM_HOME/stop" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  cp "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" WORKTREE="$repo" PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000 FM_SUPERVISION_HOST_READY_TIMEOUT="$([ "$kind" != host-explicit ] || printf 120)" \
    NODE_NO_WARNINGS=1 TEST_KIND="$kind" node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const sleep = (ms) => new Promise((resolve) => nativeTimeout(resolve, ms));
const nativeTimeout = globalThis.setTimeout;
const nativeClear = globalThis.clearTimeout;
const timers = new Set();
let now = 0;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay < 1000) return nativeTimeout(callback, delay, ...args);
  const timer = { at: now + delay, callback: () => callback(...args), unref() { return this; } };
  timers.add(timer);
  return timer;
};
globalThis.clearTimeout = (timer) => { if (!timers.delete(timer)) nativeClear(timer); };
const advance = async (time) => {
  now = time;
  for (const timer of [...timers]) if (timer.at <= now) { timers.delete(timer); timer.callback(); }
  await new Promise(setImmediate);
};
const home = process.env.FM_HOME;
try {
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  const client = { session: { promptAsync: async () => {} } };
  await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
  writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
  let status;
  const ready = globalThis.__firstmateOpenCodeWatchArm.ensureArmed("startup-test", client).then((value) => { status = value; });
  for (let i = 0; i < 500 && (!timers.size || !existsSync(`${home}/child-pid`)); i += 1) await sleep(10);
  if (!timers.size || !existsSync(`${home}/child-pid`)) throw new Error("coordinator did not start its readiness wait");
  const deadline = [...timers][0].at;
  if (process.env.TEST_KIND === "arm") {
    await advance(12000);
    await ready;
    if (status !== "timeout") throw new Error(`plain arm lost its configured 12 s bound: ${status}`);
  } else {
    const total = process.env.TEST_KIND === "host-explicit" ? 120000 : 100000;
    await advance(35000);
    if (status !== undefined) throw new Error(`host expired during progressing startup at 35 s: ${status}`);
    await advance(total);
    if (status !== undefined) throw new Error(`host was retired before its ${total} ms total window: ${status}`);
    if (deadline <= total || deadline > total + 10000) throw new Error(`host margin is outside (0, 10 s]: ${deadline - total}`);
    if (process.env.TEST_KIND === "host-expiry") {
      await advance(deadline);
      await ready;
      if (status !== "timeout") throw new Error(`unready host did not expire at its enclosing bound: ${status}`);
    } else {
      writeFileSync(`${home}/ready`, "ready\n");
      for (let i = 0; i < 300 && status === undefined; i += 1) await sleep(10);
      if (status !== "armed") throw new Error(`host did not deliver genuine readiness: ${status}`);
      await ready;
    }
  }
} finally {
  writeFileSync(`${home}/stop`, "stop\n");
  for (let i = 0; i < 200 && existsSync(`${home}/child-pid`); i += 1) {
    try { process.kill(Number(readFileSync(`${home}/child-pid`, "utf8").trim()), 0); } catch { break; }
    await sleep(10);
  }
}
JS
  )
  status=$?
  expect_code 0 "$status" "OpenCode $kind readiness contract: $out"
  pass "OpenCode $kind preserves the enclosing startup bound"
}

for kind in host-ready host-expiry host-explicit arm; do test_readiness_window "$kind"; done

test_rejected_host_readiness() (
  kind=$1
  close=${2:-failure}
  home="$TMP_ROOT/rejected-$kind-$close"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  fm_test_track_watcher_state "$home/state"
  ln -s /bin/bash "$home/fakebin/claude"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  printf 'project=demo\nwindow=fm-task\nharness=claude\n' > "$home/state/task.meta"
  : > "$home/config/supervision-host"
  begin=$(date +%s)
  printf '%s\n' "$begin" > "$home/startup-clock"
  export FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TEST_STARTUP_CLOCK="$home/startup-clock"
  export FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_READY_TIMEOUT=100
  export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
  export PATH="$home/fakebin:$PATH"
  host_pid='' owner_pid='' existing_arm=''
  trap '
    [ -z "$host_pid" ] || kill -CONT "$host_pid" 2>/dev/null || true
    [ -z "$host_pid" ] || kill -TERM "$host_pid" 2>/dev/null || true
    bash "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
    [ -z "$existing_arm" ] || kill -TERM "$existing_arm" 2>/dev/null || true
    [ -z "$owner_pid" ] || wait "$owner_pid" 2>/dev/null || true
    [ -z "$existing_arm" ] || wait "$existing_arm" 2>/dev/null || true
  ' EXIT
  if [ "$kind" = attached ]; then
    bash "$ROOT/bin/fm-watch-arm.sh" > "$home/existing.out" 2>&1 &
    existing_arm=$!
    i=0
    while ! grep -q '^watcher: started pid=' "$home/existing.out" && [ "$i" -lt 300 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    assert_grep 'watcher: started pid=' "$home/existing.out" "existing watcher did not start"
  fi
  cat > "$home/config/watch.env" <<'SH'
case "$0" in */fm-watch-arm.sh)
  if [ -e "$FM_HOME/pause-host" ]; then
    rm -f "$FM_HOME/pause-host"
    printf '%s\n' "$PPID" > "$FM_HOME/host-pid"
    kill -STOP "$PPID"
    : > "$FM_HOME/host-paused"
  fi
  ;;
esac
SH
  : > "$home/pause-host"
  # Expand FM_HOME, status, and positional parameters in the child shell.
  # shellcheck disable=SC2016
  "$home/fakebin/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    bash "$1/bin/fm-supervision-host.sh" park > "$FM_HOME/host.out" 2>&1
    printf "%s\n" "$?" > "$FM_HOME/host.rc"
  ' _ "$ROOT" &
  owner_pid=$!
  i=0
  while [ ! -e "$home/host-paused" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/host-paused" ] || fail "host did not reach its startup barrier"
  IFS= read -r host_pid < "$home/host-pid"
  i=0
  while ! grep -q "^watcher: $kind pid=" "$home/state"/.supervision-host-arm.* && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -h "^watcher: $kind pid=" "$home/state"/.supervision-host-arm.* \
    || fail "arm did not publish genuine $kind readiness while the host was paused"
  if [ "$close" = wake ]; then
    printf 'done [at=%s]: ready for captain\n' "$(date +%s)" >> "$home/state/task.status"
    i=0
    while ! grep -q '^signal:' "$home/state"/.supervision-host-arm.* && [ "$i" -lt 300 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    grep -q '^signal:' "$home/state"/.supervision-host-arm.* || fail "watcher did not deliver its actionable close"
  fi
  printf '%s\n' "$((begin + 100))" > "$home/startup-clock"
  kill -CONT "$host_pid"
  i=0
  while [ ! -s "$home/host.rc" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/host.rc" ] || fail "rejected startup did not return to main"
  cat "$home/host.out"
  if [ "$close" = wake ]; then
    assert_grep "signal: $home/state/task.status" "$home/host.out" "rejected startup lost its actionable wake"
  else
    assert_grep 'watcher: FAILED - no live watcher with a fresh beacon' "$home/host.out" "rejected startup lost its failure detail"
  fi
  if grep -Eq '^watcher: (started|attached)( |$)' "$home/host.out"; then
    fail "rejected $kind readiness reached the host output"
  fi
  pass "host suppresses rejected $kind readiness and preserves its $close close"
)

rejected_status=0
for kind in started attached; do
  for close in failure wake; do test_rejected_host_readiness "$kind" "$close" || rejected_status=1; done
done
expect_code 0 "$rejected_status" 'rejected host readiness must never reach OpenCode'
