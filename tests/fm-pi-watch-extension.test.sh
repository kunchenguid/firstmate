#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$repo/bin/fm-pi-arm-tree-retire.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$repo/bin/fm-wake-lib.sh"
  chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-pi-arm-tree-retire.sh" "$repo/bin/fm-wake-lib.sh"
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

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}

const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_afk_handoff_yields_and_resumes_exact_cycle() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-afk-handoff-root"
  home="$TMP_ROOT/pi-afk-handoff-home"
  log="$TMP_ROOT/pi-afk-handoff.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
trap 'printf "term=%s\n" "$$" >> "$FM_ARM_LOG"; exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_AFK_HANDOFF_POLL_MS=5 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
  events: { on() {} },
};
const state = `${process.env.FM_HOME}/state`;
const afk = `${state}/.afk`;
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split(/\n/).filter(Boolean)
  : [];
const starts = () => rows().filter((line) => line.startsWith("start="));
const terms = () => rows().filter((line) => line.startsWith("term="));
async function waitFor(predicate, label) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}: ${rows().join(" | ")}`);
}

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
writeFileSync(afk, "away\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
const stoodDown = await tool.execute("startup-away", {}, undefined, undefined, {});
if (!stoodDown.details?.ok || !stoodDown.content[0]?.text.includes("away mode owns supervision")) {
  throw new Error(`startup-away did not stand down: ${JSON.stringify(stoodDown.details)}`);
}
await new Promise((resolve) => setTimeout(resolve, 80));
if (starts().length !== 0) throw new Error(`startup-away armed ${starts().length} children`);

rmSync(afk);
await waitFor(() => starts().length === 1, "automatic first post-away arm");
const firstPid = starts()[0].match(/start=(\d+)/)?.[1];
if (!firstPid) throw new Error(`missing first child identity: ${starts()[0]}`);

writeFileSync(afk, "away-again\n");
await waitFor(() => terms().length === 1, "exact first arm retirement");
if (terms()[0] !== `term=${firstPid}`) {
  throw new Error(`handoff retired the wrong child: start=${firstPid} term=${terms()[0]}`);
}
await new Promise((resolve) => setTimeout(resolve, 60));
if (starts().length !== 1) throw new Error(`extension re-armed while away: ${rows().join(" | ")}`);
if (prompts.length !== 0) throw new Error(`exact-child yield injected ${prompts.length} Pi prompts`);

const input = handlers.get("input");
if (!input) throw new Error("Pi input handoff boundary was not registered");
const watcher = input({
  type: "input",
  source: "extension",
  text: "\u2063FIRSTMATE_OP: v1 watcher: routine heartbeat",
});
if (watcher?.action !== "handled") throw new Error(`away watcher input was not absorbed: ${JSON.stringify(watcher)}`);
const actionable = input({
  type: "input",
  source: "extension",
  text: "\u2063FIRSTMATE_OP: v1 away-supervisor: actionable blocker",
});
if (actionable?.action !== "continue") throw new Error(`away-supervisor input was suppressed: ${JSON.stringify(actionable)}`);

rmSync(afk);
await waitFor(() => starts().length === 2, "automatic first return arm");
writeFileSync(afk, "away-third\n");
await waitFor(() => terms().length === 2, "second exact arm retirement");
rmSync(afk);
await waitFor(() => starts().length === 3, "automatic repeated return arm");
await new Promise((resolve) => setTimeout(resolve, 80));
if (starts().length !== 3) throw new Error(`repeated convergence duplicated cycles: ${rows().join(" | ")}`);
if (prompts.length !== 0) throw new Error(`repeated AFK lifecycle injected ${prompts.length} Pi prompts`);
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => terms().length === 3, "shutdown retirement");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi AFK lifecycle must stand down, yield its exact child, absorb watcher input, and resume once"
  [ -z "$out" ] || fail "Pi AFK handoff test printed output: $out"
  pass "Pi AFK handoff yields the exact arm and resumes one cycle across repeated entry and return"
}

test_pi_afk_windows_handoff_retires_exact_tree() {
  local repo home plugin fakebin proc_root log watcher_file taskkill_log out status
  repo="$TMP_ROOT/pi-afk-windows-tree-root"
  home="$TMP_ROOT/pi-afk-windows-tree-home"
  fakebin="$TMP_ROOT/pi-afk-windows-tree-bin"
  proc_root="$TMP_ROOT/pi-afk-windows-tree-proc"
  log="$TMP_ROOT/pi-afk-windows-tree.log"
  watcher_file="$TMP_ROOT/pi-afk-windows-tree-watcher"
  taskkill_log="$TMP_ROOT/pi-afk-windows-taskkill.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin" "$proc_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/fm-wake-lib.sh"
mkdir -p "$FM_PROC_ROOT_OVERRIDE/$FM_FAKE_MSYS_PID"
printf '%s\n' "$FM_FAKE_MSYS_PID" > "$FM_PI_ARM_WRAPPER_PID_FILE"
printf '%s\n' "$$" > "$FM_PROC_ROOT_OVERRIDE/$FM_FAKE_MSYS_PID/winpid"
printf 'FM_PI_ARM_TREE_TOKEN=%s\000' "$FM_PI_ARM_TREE_TOKEN" > "$FM_PROC_ROOT_OVERRIDE/$FM_FAKE_MSYS_PID/environ"
sleep 300 &
watcher=$!
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$watcher" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$(dirname "$0")/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$watcher" > "$STATE/.watch.lock/pid-identity"
printf '%s\n' "$watcher" > "${FM_FAKE_WATCHER_FILE:?}"
printf 'start=%s watcher=%s\n' "$$" "$watcher" >> "${FM_ARM_LOG:?}"
trap 'kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; exit 0' TERM INT
wait "$watcher"
SH
  cat > "$fakebin/taskkill.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TASKKILL_LOG:?}"
pid=
while [ "$#" -gt 0 ]; do
  if [ "$1" = /PID ] && [ "$#" -ge 2 ]; then pid=$2; shift 2; continue; fi
  shift
done
case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
watcher=$(cat "${FM_FAKE_WATCHER_FILE:?}")
kill -TERM "$watcher" 2>/dev/null || true
kill -TERM "$pid" 2>/dev/null || true
msys_pid=$(cat "${FM_PI_ARM_WRAPPER_PID_FILE:?}" 2>/dev/null || true)
rm -f "${FM_PROC_ROOT_OVERRIDE:?}/$msys_pid/winpid" "${FM_PROC_ROOT_OVERRIDE:?}/$msys_pid/environ"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$fakebin/taskkill.exe"
  out=$(PATH="$fakebin:$PATH" PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
    FM_FAKE_WATCHER_FILE="$watcher_file" FM_FAKE_TASKKILL_LOG="$taskkill_log" FM_FAKE_MSYS_PID=424242 \
    FM_PROC_ROOT_OVERRIDE="$proc_root" FM_PI_AFK_HANDOFF_POLL_MS=5 \
    node --input-type=module 2>&1 <<'EOF'
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

Object.defineProperty(process, "platform", { value: "win32" });
const handlers = new Map();
let tool = null;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async () => { throw new Error("Windows AFK handoff injected a Pi prompt"); },
  events: { on() {} },
};
const state = `${process.env.FM_HOME}/state`;
const identity = (pid) => spawnSync("ps", ["-p", String(pid), "-o", "ppid=,lstart=,args="], { encoding: "utf8" }).stdout.trim();
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
};

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await tool.execute("arm", {}, undefined, undefined, {});
await waitFor(() => existsSync(process.env.FM_ARM_LOG) && existsSync(process.env.FM_FAKE_WATCHER_FILE), "arm tree");
const row = readFileSync(process.env.FM_ARM_LOG, "utf8").trim();
const match = row.match(/^start=(\d+) watcher=(\d+)$/);
if (!match) throw new Error(`invalid arm identities: ${row}`);
const wrapperPid = Number(match[1]);
const watcherPid = Number(match[2]);
const wrapperIdentity = identity(wrapperPid);
const watcherIdentity = identity(watcherPid);
if (!wrapperIdentity || !watcherIdentity) throw new Error("arm tree identities were not live before handoff");
const wrapperPidFiles = readdirSync(state).filter((name) => /^\.pi-arm-wrapper-[0-9a-f]+\.pid$/.test(name));
if (wrapperPidFiles.length !== 1) throw new Error(`ambiguous wrapper PID publication: ${wrapperPidFiles.join(" | ")}`);
const wrapperPidFile = `${state}/${wrapperPidFiles[0]}`;
const msysPid = Number(readFileSync(wrapperPidFile, "utf8").trim());
if (msysPid !== Number(process.env.FM_FAKE_MSYS_PID) || msysPid === wrapperPid) {
  throw new Error(`wrapper did not publish its distinct MSYS PID: native=${wrapperPid} msys=${msysPid}`);
}
const sibling = spawn("sleep", ["300"], { stdio: "ignore" });
let siblingIdentity = "";
await waitFor(() => {
  siblingIdentity = identity(sibling.pid);
  return Boolean(siblingIdentity);
}, "unrelated sibling identity");
try {
  writeFileSync(`${state}/.afk`, "away\n");
  await waitFor(() => existsSync(process.env.FM_FAKE_TASKKILL_LOG), "Windows tree retirement");
  await waitFor(() => identity(wrapperPid) !== wrapperIdentity && identity(watcherPid) !== watcherIdentity, "retired wrapper and watcher identities");
  await waitFor(() => !existsSync(wrapperPidFile), "wrapper PID publication cleanup");
  const taskkill = readFileSync(process.env.FM_FAKE_TASKKILL_LOG, "utf8").trim();
  if (taskkill !== `/PID ${wrapperPid} /T /F`) throw new Error(`wrong rooted taskkill: ${taskkill}`);
  if (identity(sibling.pid) !== siblingIdentity) throw new Error("Windows tree retirement changed an unrelated sibling identity");
} finally {
  sibling.kill("SIGTERM");
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi Windows AFK handoff must retire the exact wrapper and watcher identities"
  [ -z "$out" ] || fail "Pi Windows AFK tree-retirement test printed output: $out"
  pass "Pi Windows AFK handoff retires one identity-bounded arm tree"
}

test_pi_afk_windows_namespace_identity_refusals() {
  local dir home state fakebin proc_root ready taskkill_log token watch_path wrapper watcher wrapper_expected watcher_expected
  local msys_pid wrapper_pid_file out status wrapper_current watcher_current
  dir="$TMP_ROOT/pi-afk-windows-namespace-refusals"
  home="$dir/home"
  state="$home/state"
  fakebin="$dir/bin"
  proc_root="$dir/proc"
  ready="$dir/ready"
  taskkill_log="$dir/taskkill.log"
  token=0123456789abcdef0123456789abcdef
  watch_path="$dir/fm-watch.sh"
  msys_pid=434343
  wrapper_pid_file="$state/.pi-arm-wrapper-$token.pid"
  mkdir -p "$state" "$fakebin" "$proc_root/$msys_pid"
  cat > "$fakebin/taskkill.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TASKKILL_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/taskkill.exe"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_PI_ARM_TREE_TOKEN="$token" \
    FM_READY_FILE="$ready" FM_WATCH_PATH="$watch_path" bash -c '
      . "$1"
      sleep 300 &
      watcher=$!
      mkdir -p "$STATE/.watch.lock"
      printf "%s\n" "$watcher" > "$STATE/.watch.lock/pid"
      printf "%s\n" "$FM_HOME" > "$STATE/.watch.lock/fm-home"
      printf "%s\n" "$FM_WATCH_PATH" > "$STATE/.watch.lock/watcher-path"
      fm_pid_identity "$watcher" > "$STATE/.watch.lock/pid-identity"
      printf "%s\n" "$watcher" > "$FM_READY_FILE"
      wait "$watcher"
    ' _ "$ROOT/bin/fm-wake-lib.sh" &
  wrapper=$!
  for _ in $(seq 1 300); do [ -s "$ready" ] && break; sleep 0.01; done
  [ -s "$ready" ] || fail "Windows namespace refusal fixture did not publish its watcher"
  watcher=$(cat "$ready")
  wrapper_expected=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$wrapper") \
    || fail "Windows namespace refusal fixture did not capture the wrapper identity"
  watcher_expected=$(cat "$state/.watch.lock/pid-identity")

  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_TASKKILL_LOG="$taskkill_log" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Windows retirement accepted an absent wrapper PID publication"

  printf '%s\n%s\n' "$msys_pid" "$((msys_pid + 1))" > "$wrapper_pid_file"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_TASKKILL_LOG="$taskkill_log" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Windows retirement accepted an ambiguous wrapper PID publication"

  printf '%s\n' "$msys_pid" > "$wrapper_pid_file"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_TASKKILL_LOG="$taskkill_log" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Windows retirement accepted an absent MSYS-to-native PID mapping"

  printf '%s\n' "$((wrapper + 1))" > "$proc_root/$msys_pid/winpid"
  printf 'FM_PI_ARM_TREE_TOKEN=%s\000' "$token" > "$proc_root/$msys_pid/environ"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_TASKKILL_LOG="$taskkill_log" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Windows retirement accepted a mismatched native PID namespace mapping"

  printf '%s\n' "$wrapper" > "$proc_root/$msys_pid/winpid"
  printf 'FM_PI_ARM_TREE_TOKEN=reused\000' > "$proc_root/$msys_pid/environ"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_TASKKILL_LOG="$taskkill_log" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Windows retirement accepted a reused MSYS wrapper identity"
  [ ! -e "$taskkill_log" ] || fail "Windows namespace refusal reached taskkill: $(cat "$taskkill_log")"
  [ -z "$out" ] || fail "Windows namespace refusal printed output: $out"
  wrapper_current=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$wrapper" 2>/dev/null || true)
  watcher_current=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" 2>/dev/null || true)
  [ "$wrapper_current" = "$wrapper_expected" ] || fail "Windows namespace refusal changed the wrapper identity"
  [ "$watcher_current" = "$watcher_expected" ] || fail "Windows namespace refusal changed the watcher identity"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  pass "Pi Windows retirement refuses absent, ambiguous, mismatched, and reused PID identities"
}

test_pi_afk_windows_partial_tree_retirement_fails_closed() {
  local dir home state fakebin proc_root ready token watch_path msys_pid wrapper_pid_file wrapper watcher expected current out status
  dir="$TMP_ROOT/pi-afk-windows-partial-tree"
  home="$dir/home"
  state="$home/state"
  fakebin="$dir/bin"
  proc_root="$dir/proc"
  ready="$dir/ready"
  token=0123456789abcdef0123456789abcdef
  watch_path="$dir/fm-watch.sh"
  msys_pid=444444
  wrapper_pid_file="$state/.pi-arm-wrapper-$token.pid"
  mkdir -p "$state" "$fakebin" "$proc_root/$msys_pid"
  cat > "$fakebin/taskkill.exe" <<'SH'
#!/usr/bin/env bash
pid=
while [ "$#" -gt 0 ]; do
  if [ "$1" = /PID ] && [ "$#" -ge 2 ]; then pid=$2; shift 2; continue; fi
  shift
done
case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
kill -KILL "$pid" 2>/dev/null || true
msys_pid=$(cat "${FM_PI_ARM_WRAPPER_PID_FILE:?}" 2>/dev/null || true)
rm -f "${FM_PROC_ROOT_OVERRIDE:?}/$msys_pid/winpid" "${FM_PROC_ROOT_OVERRIDE:?}/$msys_pid/environ"
exit 0
SH
  chmod +x "$fakebin/taskkill.exe"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_PI_ARM_TREE_TOKEN="$token" \
    FM_READY_FILE="$ready" FM_WATCH_PATH="$watch_path" \
    bash -c '
      . "$1"
      sleep 300 &
      watcher=$!
      mkdir -p "$STATE/.watch.lock"
      printf "%s\n" "$watcher" > "$STATE/.watch.lock/pid"
      printf "%s\n" "$FM_HOME" > "$STATE/.watch.lock/fm-home"
      printf "%s\n" "$FM_WATCH_PATH" > "$STATE/.watch.lock/watcher-path"
      fm_pid_identity "$watcher" > "$STATE/.watch.lock/pid-identity"
      {
        printf "%s\n" "$watcher"
        cat "$STATE/.watch.lock/pid-identity"
      } > "$FM_READY_FILE"
      wait "$watcher"
    ' _ "$ROOT/bin/fm-wake-lib.sh" &
  wrapper=$!
  for _ in $(seq 1 300); do [ -s "$ready" ] && break; sleep 0.01; done
  [ -s "$ready" ] || fail "partial Windows retirement fixture did not publish watcher identity"
  watcher=$(head -1 "$ready")
  expected=$(tail -n +2 "$ready")
  printf '%s\n' "$msys_pid" > "$wrapper_pid_file"
  printf '%s\n' "$wrapper" > "$proc_root/$msys_pid/winpid"
  printf 'FM_PI_ARM_TREE_TOKEN=%s\000' "$token" > "$proc_root/$msys_pid/environ"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$proc_root" FM_PI_ARM_WRAPPER_PID_FILE="$wrapper_pid_file" \
    "$ROOT/bin/fm-pi-arm-tree-retire.sh" "$wrapper" "$token" "$state" "$watch_path" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "partial Windows tree kill was accepted despite a surviving watcher identity"
  current=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" 2>/dev/null || true)
  [ "$current" = "$expected" ] || fail "partial Windows fixture did not retain the recorded watcher identity"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  [ -z "$out" ] || fail "partial Windows tree retirement printed output: $out"
  pass "Pi Windows AFK retirement rejects a surviving recorded watcher"
}

test_pi_afk_handoff_is_home_scoped() {
  local repo runner home_a home_b log_a log_b ready_a ready_b stop_a stop_b pid_a pid_b out status
  repo="$TMP_ROOT/pi-afk-isolation-root"
  runner="$repo/runner.mjs"
  home_a="$TMP_ROOT/pi-afk-isolation-home-a"
  home_b="$TMP_ROOT/pi-afk-isolation-home-b"
  log_a="$TMP_ROOT/pi-afk-isolation-a.log"
  log_b="$TMP_ROOT/pi-afk-isolation-b.log"
  ready_a="$TMP_ROOT/pi-afk-isolation-a.ready"
  ready_b="$TMP_ROOT/pi-afk-isolation-b.ready"
  stop_a="$TMP_ROOT/pi-afk-isolation-a.stop"
  stop_b="$TMP_ROOT/pi-afk-isolation-b.stop"
  mkdir -p "$repo/bin" "$home_a/state" "$home_a/config" "$home_b/state" "$home_b/config"
  install_pi_watch_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start=%s\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'printf "term=%s\n" "$$" >> "$FM_ARM_LOG"; exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cat > "$runner" <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
let tool = null;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async () => { throw new Error("isolated AFK handoff injected a Pi prompt"); },
  events: { on() {} },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await tool.execute("arm", {}, undefined, undefined, {});
writeFileSync(process.env.FM_READY, "ready\n");
while (!existsSync(process.env.FM_STOP)) await new Promise((resolve) => setTimeout(resolve, 10));
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await new Promise((resolve) => setTimeout(resolve, 80));
JS
  PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home_a" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log_a" FM_READY="$ready_a" FM_STOP="$stop_a" FM_PI_AFK_HANDOFF_POLL_MS=5 node "$runner" >"$TMP_ROOT/isolation-a.out" 2>&1 &
  pid_a=$!
  PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home_b" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log_b" FM_READY="$ready_b" FM_STOP="$stop_b" FM_PI_AFK_HANDOFF_POLL_MS=5 node "$runner" >"$TMP_ROOT/isolation-b.out" 2>&1 &
  pid_b=$!
  status=0
  for _ in $(seq 1 300); do
    [ -s "$ready_a" ] && [ -s "$ready_b" ] && [ -s "$log_a" ] && [ -s "$log_b" ] && break
    sleep 0.01
  done
  if [ ! -s "$ready_a" ] || [ ! -s "$ready_b" ] || [ ! -s "$log_a" ] || [ ! -s "$log_b" ]; then
    status=1
  else
    : > "$home_a/state/.afk"
    for _ in $(seq 1 300); do grep -q '^term=' "$log_a" 2>/dev/null && break; sleep 0.01; done
    grep -q '^term=' "$log_a" 2>/dev/null || status=1
    grep -q '^term=' "$log_b" 2>/dev/null && status=1
    kill -0 "$pid_b" 2>/dev/null || status=1
  fi
  : > "$stop_a"
  : > "$stop_b"
  wait "$pid_a" || status=1
  wait "$pid_b" || status=1
  out=$(cat "$TMP_ROOT/isolation-a.out" "$TMP_ROOT/isolation-b.out")
  expect_code 0 "$status" "Pi AFK handoff must retire only the exact home-scoped extension child"
  [ -z "$out" ] || fail "Pi sibling-home isolation test printed output: $out"
  pass "Pi AFK handoff leaves a sibling home's live cycle untouched"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance"
  [ -z "$out" ] || fail "Pi redundant-call test printed output: $out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-first", {}, undefined, undefined, {});
let redundant = null;
for (let i = 0; i < 100; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
  redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
  if (redundant.content[0]?.text.includes("scheduled continuity retry")) break;
}
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`scheduled retry call spawned ${rows.length} arm children`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry"
  [ -z "$out" ] || fail "Pi scheduled-retry test printed output: $out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
}

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releaseDelivery();
for (let i = 0; i < 100; i += 1) {
  if (readFileSync(process.env.FM_ARM_LOG, "utf8").includes("confirmed generation=fixture-generation")) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "Pi hung-successor test printed output: $out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  release="$TMP_ROOT/pi-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "Pi unretired-successor test printed output: $out"
  pass "Pi unretired successor falls back without an overlapping retry"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log ready retired release stop out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    retired="$TMP_ROOT/pi-late-$kind.retired"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
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
    prompts.push(message);
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "Pi late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "Pi late-$kind test printed output: $out"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "Pi empty-close retry test printed output: $out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "Pi established-empty-close retry test printed output: $out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "Pi close lock test printed output: $out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
const assertMissingLock = (result, label) => {
  if (result.details?.ok !== false) throw new Error(`${label} unexpectedly armed: ${JSON.stringify(result.details)}`);
  if (!result.details.message.includes("no live session holds the lock")) {
    throw new Error(`${label} missing no-live-session guidance: ${result.details.message}`);
  }
  if (!result.details.message.includes("bin/fm-session-start.sh") || !result.details.message.includes("re-arm")) {
    throw new Error(`${label} missing reclaim and re-arm guidance: ${result.details.message}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
assertMissingLock(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
assertMissingLock(await callArm(), "dead lock holder");

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - session lock is held by another firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watcher arm ran without lock ownership");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true || !owned.details.message.includes("started Pi extension arm child")) {
  throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
}
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("owned lock did not run the watcher arm");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm must distinguish owned, live-other, and missing or dead session locks"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm distinguishes all session lock ownership states"
}

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file arm_log out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf 'arm pid=%s\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_ARM_LOG="$arm_log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async () => {},
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(pred, label, attempts = 250) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+)/.exec(line);
      return match ? match[1] : "";
    })
    .filter(Boolean)
    .filter(pidAlive);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
const first = await startup.getTool().execute("startup", {}, undefined, undefined, {});
if (!first.details?.ok || !String(first.details.message).includes("started Pi extension arm child")) {
  throw new Error(`startup arm failed: ${JSON.stringify(first.details)}`);
}
await waitFor(() => existsSync(process.env.FM_CHILD_PID_FILE), "startup child");
const startupChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousChild = existsSync(process.env.FM_CHILD_PID_FILE)
    ? readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim()
    : "";
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (previousChild) {
    await waitFor(() => !pidAlive(previousChild), `${reason} previous child exit`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  const armed = await next.getTool().execute(`arm-${reason}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) {
    throw new Error(`${reason} replacement arm failed: ${JSON.stringify(armed.details)}`);
  }
  if (String(armed.details.message).includes("shutting down")) {
    throw new Error(`${reason} replacement still refused with shutting-down latch`);
  }
  await waitFor(() => {
    if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
    const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
    return child && child !== previousChild && pidAlive(child);
  }, `${reason} replacement child`);
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
const sameInstanceArm = await current.getTool().execute("same-instance", {}, undefined, undefined, {});
if (!sameInstanceArm.details?.ok || String(sameInstanceArm.details.message).includes("shutting down")) {
  throw new Error(`same-instance replacement arm failed: ${JSON.stringify(sameInstanceArm.details)}`);
}
await waitFor(() => {
  if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
  const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  return child !== sameInstanceChild && pidAlive(child);
}, "same-instance replacement child");
await waitFor(() => !pidAlive(sameInstanceChild), "same-instance previous child exit");
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (pidAlive(startupChild)) throw new Error("startup generation child was resurrected");
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => !pidAlive(finalChild), "terminal shutdown child exit");
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session transitions must rearm through an explicit generation owner"
  [ -z "$out" ] || fail "Pi session-transition generation owner test printed output: $out"
  pass "Pi session transitions use a generation owner across /new /resume /fork, stale callbacks, and quit"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must remain singular across session replacement"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
const firstChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const currentChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  if (currentChild !== firstChild) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim() === firstChild) {
  throw new Error("replacement arm child did not start");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 250 ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must import beneath an explicit ESM package boundary"
  [ -z "$out" ] || fail "OpenCode ESM boundary import printed output: $out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await hooks.event(event);
await new Promise((resolve) => setTimeout(resolve, 120));
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let rowsAtPrompt = 0;
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const client = {
  session: {
    promptAsync: async () => {
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      prompts += 1;
      await promptBlocked;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts >= 1) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releasePrompt();
for (let i = 0; i < 100; i += 1) {
  if (readFileSync(process.env.FM_ARM_LOG, "utf8").includes("confirmed generation=fixture-generation")) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must start one successor before wake prompt delivery settles: $out"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts.some((message) => message.includes("original wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`pre-ready successor was replaced before its close: ${rows.join(" | ")}`);
if (!prompts.some((message) => message.includes("original wake"))) throw new Error(`original actionable wake was not delivered: ${prompts.join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, 150));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  const successorRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (successorRows.length >= 3 && prompts.some((message) => message.includes("pre-ready successor wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 3) throw new Error(`pre-ready close did not create exactly one successor: ${stableRows.join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retire the pre-ready arm, not its actionable successor"
  [ -z "$out" ] || fail "OpenCode pre-ready actionable test printed output: $out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "OpenCode hung-successor test printed output: $out"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "OpenCode unretired-successor test printed output: $out"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log ready retired release stop out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    retired="$TMP_ROOT/opencode-late-$kind.retired"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "OpenCode late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "OpenCode late-$kind test printed output: $out"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OpenCode empty-close retry test printed output: $out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "OpenCode established-empty-close retry test printed output: $out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode close handler must verify session-lock ownership before successor launch"
  [ -z "$out" ] || fail "OpenCode close lock test printed output: $out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

test_pi_extension_reports_external_healthy_watcher
test_pi_afk_handoff_yields_and_resumes_exact_cycle
test_pi_afk_windows_handoff_retires_exact_tree
test_pi_afk_windows_namespace_identity_refusals
test_pi_afk_windows_partial_tree_retirement_fails_closed
test_pi_afk_handoff_is_home_scoped
test_pi_tool_returns_agent_tool_result
test_pi_redundant_tool_call_is_owned_noop
test_pi_scheduled_retry_call_is_owned_noop
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_session_transition_generation_owner
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_opencode_plugin_package_boundary_is_explicit_esm
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_pre_ready_actionable_close_preserves_its_successor
test_opencode_hung_successor_falls_back_to_typed_wake
test_opencode_unretired_successor_falls_back_without_retry
test_opencode_late_unretired_close_resumes_supervision
test_opencode_empty_close_retries_instead_of_disappearing
test_opencode_established_empty_close_honors_retry_limit
test_opencode_actionable_close_rechecks_session_lock
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
