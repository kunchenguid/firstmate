#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-consumers)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
mkdir -p \
  "$repo/.pi/extensions/lib" "$repo/bin" "$home/state" "$home/config" \
  "$repo/node_modules/@earendil-works/pi-coding-agent" \
  "$repo/node_modules/@earendil-works/pi-tui" \
  "$repo/node_modules/typebox"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
printf '%s\n' 'export function getMarkdownTheme() { return {}; } export class UserMessageComponent {}' \
  > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-tui/package.json"
printf '%s\n' 'export class Box {} export class Container {} export class Text {}' \
  > "$repo/node_modules/@earendil-works/pi-tui/index.js"
printf '%s\n' '{"name":"typebox","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/typebox/package.json"
printf '%s\n' 'export const Type = { Object(properties) { return { properties }; } };' \
  > "$repo/node_modules/typebox/index.js"
printf 'root\n' > "$repo/AGENTS.md"
git init -q "$repo"

cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
case "${FM_SCENARIO:?}" in
  benign)
    printf 'FM_WATCH_ARM_STATE=busy-holder-waiting\n'
    printf 'FM_WATCH_ARM_RESULT=busy-holder\n'
    ;;
  restoration)
    if [ "$count" -eq 1 ]; then
      printf 'signal: restoration fixture\n'
      exit 0
    fi
    printf 'FM_WATCH_ARM_STATE=busy-holder-waiting\n'
    trap 'printf killed > "$FM_KILLED"; exit 143' TERM INT
    while [ ! -e "$FM_RELEASE" ]; do sleep 0.02; done
    printf 'FM_WATCH_ARM_RESULT=busy-holder\n'
    ;;
esac
SH
chmod +x "$repo/bin/fm-watch-arm.sh"

cat > "$TMP_ROOT/pi-runner.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async (message) => { prompts.push(message); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const plugin = await import(pathToFileURL(process.env.FM_PI_PLUGIN).href);
plugin.default(pi);
await tool.execute("arm-consumer", {}, undefined, undefined, {});
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
if (process.env.FM_SCENARIO === "restoration") {
  for (let i = 0; i < 100 && (!existsSync(process.env.FM_ARM_LOG) || readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length < 2); i += 1) await sleep(20);
  await sleep(1200);
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 2) throw new Error(`Pi replaced a typed busy wait: ${rows.join(",")}`);
  if (existsSync(process.env.FM_KILLED)) throw new Error("Pi retired the typed busy-wait arm");
  if (JSON.stringify(prompts).includes("watcher: FAILED")) throw new Error("Pi emitted a restoration alarm during a typed busy wait");
  writeFileSync(process.env.FM_RELEASE, "release\n");
  await sleep(100);
} else {
  await sleep(500);
  if (prompts.length !== 0) throw new Error("Pi alarmed on a benign busy-holder close");
}
JS

cat > "$TMP_ROOT/opencode-runner.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request); } } };
const plugin = await import(pathToFileURL(process.env.FM_OPENCODE_PLUGIN).href);
const hooks = await plugin.FmPrimaryWatchArm({ client, directory: process.env.FM_REPO, worktree: process.env.FM_REPO });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "arm-consumer" } } });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
if (process.env.FM_SCENARIO === "restoration") {
  for (let i = 0; i < 100 && (!existsSync(process.env.FM_ARM_LOG) || readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length < 2); i += 1) await sleep(20);
  await sleep(1200);
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 2) throw new Error(`OpenCode replaced a typed busy wait: ${rows.join(",")}`);
  if (existsSync(process.env.FM_KILLED)) throw new Error("OpenCode retired the typed busy-wait arm");
  if (JSON.stringify(prompts).includes("watcher: FAILED")) throw new Error("OpenCode emitted a restoration alarm during a typed busy wait");
  writeFileSync(process.env.FM_RELEASE, "release\n");
  await sleep(100);
} else {
  await sleep(500);
  if (prompts.length !== 0) throw new Error("OpenCode alarmed on a benign busy-holder close");
}
JS

run_scenario() {
  local consumer=$1 scenario=$2 runner plugin scenario_home log release killed
  scenario_home="$home/$consumer-$scenario"
  log="$TMP_ROOT/$consumer-$scenario.log"
  release="$TMP_ROOT/$consumer-$scenario.release"
  killed="$TMP_ROOT/$consumer-$scenario.killed"
  mkdir -p "$scenario_home/state" "$scenario_home/config"
  : > "$scenario_home/state/task.meta"
  case "$consumer" in
    pi)
      runner="$TMP_ROOT/pi-runner.mjs"
      FM_PI_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts"
      export FM_PI_PLUGIN
      ;;
    opencode)
      runner="$TMP_ROOT/opencode-runner.mjs"
      FM_OPENCODE_PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
      export FM_OPENCODE_PLUGIN
      ;;
  esac
  FM_REPO="$repo" FM_HOME="$scenario_home" FM_ROOT_OVERRIDE="$repo" \
    FM_ARM_LOG="$log" FM_RELEASE="$release" FM_KILLED="$killed" FM_SCENARIO="$scenario" \
    FM_PI_ARM_READY_TIMEOUT_MS=1000 FM_OPENCODE_ARM_READY_TIMEOUT_MS=1000 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=1 \
    NODE_NO_WARNINGS=1 node "$runner"
}

for consumer in pi opencode; do
  run_scenario "$consumer" benign || fail "$consumer alarmed on a typed benign arm close"
  run_scenario "$consumer" restoration || fail "$consumer mishandled a typed busy-holder restoration wait"
done

pass "Pi and OpenCode preserve typed busy-holder waits"
