#!/usr/bin/env bash
# Drives the supervision-branch mod's monitor guard
# (.claude/mods/fm-branch-mod/lib/fm-branch-monitor.ts, the canonical copy
# the repo's lib/ symlinks to) on one fixture set:
#   - the lib leg: createMonitorGuard through injected deps (a scripted
#     clock, the mode switch, a capturing Monitor start with scripted
#     answers or denials or throws, and the counters persistence), pinning
#     the claim/stale machine, the double-arm guard, the expiry re-arm
#     verdicts, the counters snapshot/restore, and the loop command bytes;
#   - the mod leg: the REAL hook's exported armMonitor binding, driven
#     through bind() with a mocked host, must agree with the lib leg on
#     the armed event stream and the command bytes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-monitor)

# ---------- shared fixtures ---------------------------------------------------
# One monitor lifecycle script, driven through every leg: arm, second arm
# inside the stale window (no-op), arm past the stale window (re-arm), a
# denied arm (claim lost), and the recovery arm.
PLAN='[
 {"name":"arm","why":"session start","clock":1000,"mode":true,"answer":{"text":"Monitor started (task m1)"}},
 {"name":"arm-again-inside-window","why":"first prompt","clock":2000,"mode":true,"answer":{"text":"Monitor started (task m2)"},"expectNoStart":true},
 {"name":"arm-past-stale-window","why":"stop-hook wake without monitor","clock":2101000,"mode":true,"answer":{"text":"Monitor started (task m3)"}},
 {"name":"arm-while-mode-off","why":"session start","clock":1000,"mode":false,"answer":{"text":"Monitor started (task m4)"},"expectNoStart":true},
 {"name":"arm-denied","why":"session start","clock":2101000,"mode":true,"answer":{"deny":"Monitor tool unavailable"}},
 {"name":"arm-throws","why":"session start","clock":1000,"mode":true,"answer":{"throw":"boom"}},
 {"name":"arm-after-deny-recovers","why":"first prompt","clock":2000,"mode":true,"answer":{"text":"Monitor started (task m5)"}}
]'

# ---------- node drivers ------------------------------------------------------
cat > "$TMP_ROOT/monitor-run.mjs" <<'DRIVER'
// Drives the monitor guard through the fixture script with every effect
// captured: the armed event log, the started commands, the expiry
// verdicts, and the counters saves.
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const plan = JSON.parse(process.argv[3]);
const m = await import(pathToFileURL(modulePath).href);
const out = [];
const events = [];
const commands = [];
const saves = [];
const PATHS = { cwd: "/work", home: "/fm/home", state: "/fm/home/state", config: "/fm/home/config", bin: "/fm/code/bin" };
let clock = 0;
const guard = m.createMonitorGuard();
const deps = (step) => ({
  log: (kind, data) => events.push({ kind, data }),
  clockNow: async () => (clock += step.clock),
  modeOn: async () => step.mode,
  startMonitor: async (command) => {
    commands.push(command);
    if (step.answer.throw !== undefined) throw new Error(step.answer.throw);
    return { text: step.answer.text ?? "", deny: step.answer.deny };
  },
  saveCounters: async () => {
    saves.push(guard.snapshot());
  },
  paths: () => PATHS,
});
for (const step of plan) {
  events.length = 0;
  commands.length = 0;
  const startsBefore = commands.length;
  await guard.armMonitor(deps(step), step.why);
  out.push({
    name: step.name,
    events: [...events],
    started: commands.length - startsBefore,
    armed: guard.isArmed(),
    command: commands[0] ?? null,
  });
}
// The expiry verdicts: a live monitor's own notice re-arms; a foreign
// notice from an older monitor does not.
out.push({ name: "expiry", cases: [
  { label: "live-own", got: guard.noteExpiry("m5") },
  { label: "foreign", got: guard.noteExpiry("m-old") },
] });
// The counters round-trip: restore honours a recorded arm time and falls
// back to the given now when the record carries none.
const fresh = m.createMonitorGuard();
fresh.restoreFromCounters("m9", 4242, 7777);
const legacy = m.createMonitorGuard();
legacy.restoreFromCounters("m-old", undefined, 8888);
out.push({
  name: "counters",
  restored: fresh.snapshot(),
  legacy: legacy.snapshot(),
  restoredArmed: fresh.isArmed(),
});
out.push({ name: "saves", count: saves.length });
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-monitor-run.mjs" <<'DRIVER'
// Drives the REAL mod hook's armMonitor through bind() with a mocked
// host, over the same script. The clock advances by each step's delta on
// every $.clock.now read.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const plan = JSON.parse(process.argv[2]);
const HOME = "/fm/home";
process.env.FM_HOME = HOME;
const out = [];
const events = [];
const commands = [];
let clock = 0;
let active = null;
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => "/work" },
  fs: {
    exists: async (path) => String(path) === `${HOME}/state/.branch-mod-mode` && active.mode,
    read: async () => {
      throw new Error("no file");
    },
    write: async () => {},
    append: async () => {},
    mkdir: async () => {},
    rm: async () => {},
    readDir: async () => [],
    list: async () => [],
    stat: async () => ({ isLink: false }),
  },
  ui: { log: () => {} },
  prompt: { submit: async () => {} },
  process: {
    run: async (argv, opts) => {
      // The event log's append shell: capture the line, answer success.
      if (argv[0] === "sh" && argv[1] === "-c") {
        events.push(JSON.parse(opts.stdin));
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  },
  tool: {
    call: async (req) => {
      if (req.tool !== "Monitor") return { result: "" };
      commands.push(req.command);
      if (active.answer.throw !== undefined) throw new Error(active.answer.throw);
      if (active.answer.deny !== undefined) return { deny: active.answer.deny };
      return { result: active.answer.text ?? "" };
    },
  },
  model: { complete: async () => "" },
  clock: { now: async () => (clock += active.clock) },
};
await mod.bind($, "/work");
for (const step of plan) {
  events.length = 0;
  commands.length = 0;
  active = step;
  const startsBefore = commands.length;
  await mod.armMonitor($, step.why);
  out.push({
    name: step.name,
    events: events.map((e) => ({ kind: e.kind, data: e.data })),
    started: commands.length - startsBefore,
    command: commands[0] ?? null,
  });
}
console.log(JSON.stringify(out));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
PLAN_ARG="$(cat "$TMP_ROOT/plan.json")"
node --experimental-strip-types "$TMP_ROOT/monitor-run.mjs" "$ROOT/lib/fm-branch-monitor.ts" "$PLAN_ARG" > "$TMP_ROOT/lib.json"
node --experimental-strip-types "$TMP_ROOT/mod-monitor-run.mjs" "$PLAN_ARG" > "$TMP_ROOT/mod.json"
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg monitor driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

# The mod's armMonitor binding agrees with the module on the armed event
# stream and the command bytes for every step of the script. The mod's
# command names the real code root's bin (bind derives it from the plugin
# path) and the armed-state flag is guard-internal, so the comparison
# projects both legs to the shared bytes: events, start counts, and the
# command with the bin path normalized away.
normalize_leg() {
  jq -S -c --arg root "$FM_RS_ROOT" 'map(select(.events) | {name, events, started, command: (.command | if . then gsub($root; "/fm/code") else . end)})' "$1"
}
if [ "$(normalize_leg "$TMP_ROOT/lib.json")" = "$(normalize_leg "$TMP_ROOT/mod.json")" ]; then
  pass "the mod hook's armMonitor binding routes the shared guard identically"
else
  fail "the mod hook's armMonitor binding diverges from the shared module"
fi

step() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP_ROOT/lib.json"; }
if [ "$(step arm | jq -r '.started')" = "1" ] && [ "$(step arm | jq -r '.events[0].kind')" = "monitor.armed" ] && [ "$(step arm | jq -r '.events[0].data.taskId')" = "m1" ] && [ "$(step arm | jq -r '.armed')" = "true" ]; then
  pass "a cold arm starts one Monitor task and records its task id"
else
  fail "the cold arm drifted: $(step arm)"
fi
if [ "$(step arm-again-inside-window | jq -r '.started')" = "0" ] && [ "$(step arm-again-inside-window | jq -r '.events | length')" = "0" ]; then
  pass "a second arm inside the stale window is a no-op"
else
  fail "the in-window double-arm guard drifted"
fi
if [ "$(step arm-past-stale-window | jq -r '.started')" = "1" ] && [ "$(step arm-past-stale-window | jq -r '.events[0].kind')" = "monitor.stale.claim" ] && [ "$(step arm-past-stale-window | jq -r '.events[1].data.taskId')" = "m3" ]; then
  pass "an armed claim older than the stale bound expires and the next arm site arms"
else
  fail "the stale-claim expiry drifted: $(step arm-past-stale-window)"
fi
if [ "$(step arm-while-mode-off | jq -r '.started')" = "0" ] && [ "$(step arm-while-mode-off | jq -r '.events | length')" = "0" ]; then
  pass "a mode-off arm never starts a Monitor (the standing claim is untouched)"
else
  fail "the mode-off arm drifted"
fi
if [ "$(step arm-denied | jq -r '.events[1].data.deny')" = "Monitor tool unavailable" ] && [ "$(step arm-denied | jq -r '.armed')" = "false" ]; then
  pass "a denied Monitor start loses the claim"
else
  fail "the denied arm drifted: $(step arm-denied)"
fi
if [ "$(step arm-throws | jq -r '.events[0].kind')" = "monitor.error" ] && [ "$(step arm-throws | jq -r '.armed')" = "false" ]; then
  pass "a throwing Monitor start records the error and loses the claim"
else
  fail "the throwing arm drifted: $(step arm-throws)"
fi
if [ "$(step arm-after-deny-recovers | jq -r '.started')" = "1" ] && [ "$(step arm-after-deny-recovers | jq -r '.armed')" = "true" ]; then
  pass "the next arm after a lost claim recovers"
else
  fail "the recovery arm drifted"
fi

# The loop command bytes, pinned: the rotate deadline is one monitor
# timeout minus three minutes (1620s) and every path is JSON-quoted.
# shellcheck disable=SC2016 # the loop command bytes are literal; $(...) belongs to the generated shell
EXPECTED_COMMAND_PREFIX='cd "/work" && export FM_HOME="/fm/home" FM_STATE_OVERRIDE="/fm/home/state" FM_CONFIG_OVERRIDE="/fm/home/config"; A="/fm/code/bin/fm-watch-arm.sh"; Q="/fm/home/state/.wake-queue"; D="/fm/home/state/.watcher-down"; T0=$(date +%s); while :; do out=$("$A" 2>&1); '
CMD="$(step arm | jq -r '.command')"
# shellcheck disable=SC2016 # the loop command bytes are literal; $(...) belongs to the generated shell
if case "$CMD" in "$EXPECTED_COMMAND_PREFIX"*) true;; *) false;; esac && [ "$(printf '%s' "$CMD" | grep -c '\[ $(( $(date +%s) - T0 )) -lt 1620 \] || { printf '"'"'rotate: loop exiting ahead of the monitor timeout')" = "1" ] && [ "$(printf '%s' "$CMD" | grep -c 'forced-rearm: queue or recovery marker still pending after %ss')" = "1" ]; then
  pass "the loop command keeps its exact prefix, rotate deadline, and re-arm gates"
else
  fail "the loop command drifted"
fi

# The expiry verdicts.
if [ "$(jq -c '.[] | select(.name == "expiry") | .cases[0].got' "$TMP_ROOT/lib.json")" = '{"rearm":true}' ] && [ "$(jq -c '.[] | select(.name == "expiry") | .cases[1].got' "$TMP_ROOT/lib.json")" = '{"rearm":false,"live":"m5"}' ]; then
  pass "only the live monitor's own expiry re-arms; a foreign notice is ignored with the live id"
else
  fail "the expiry verdicts drifted"
fi

# The counters round-trip.
if [ "$(jq -c '.[] | select(.name == "counters") | .restored' "$TMP_ROOT/lib.json")" = '{"monitorTaskId":"m9","monitorArmedAt":4242}' ] \
  && [ "$(jq -c '.[] | select(.name == "counters") | .legacy' "$TMP_ROOT/lib.json")" = '{"monitorTaskId":"m-old","monitorArmedAt":8888}' ] \
  && [ "$(jq -r '.[] | select(.name == "counters") | .restoredArmed' "$TMP_ROOT/lib.json")" = "true" ]; then
  pass "a restored claim honours its arm time and falls back to the given now"
else
  fail "the counters round-trip drifted"
fi
