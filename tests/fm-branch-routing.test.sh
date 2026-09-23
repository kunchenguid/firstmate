#!/usr/bin/env bash
# Drives the supervision-branch mod's wake-routing decision
# (.claude/mods/fm-branch-mod/lib/fm-branch-routing.ts, the canonical copy
# the repo's lib/ symlinks to) on one fixture set:
#   - the lib leg: createWakeRouter through scripted deps, one fresh router
#     per scenario (the deliberate two-call sequences aside), pinning the
#     pass/grant verdict table, the passed-wake dedupe key and window, the
#     handled-row and in-flight dedupe, the classifier gate, the grant
#     publish verdicts, and the pass effects (the evidence-offset advance
#     and the covering captain row);
#   - the mod leg: the REAL hook's exported routeWake, driven through
#     bind() with a mocked host over in-memory state files, a scripted
#     clock, and mocked scripts, one fresh module instance per scenario,
#     must agree with the lib leg on every verdict and the event stream.
# The in-flight stale release needs real-time control the mod host cannot
# express (its dateNow is the real clock), so that one scenario and the
# provider-latch admission gate are lib-leg-only, like the classifier
# suite's lib-only fixtures; the mod's own engine suite pins both paths
# end to end.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-routing)

# ---------- fixture plan ------------------------------------------------------
# Per step: the wake text, the scope facts ([status, eligibleSeqs,
# wakeKey, eligibleTasks, needsDecisionTasks]), the classifier verdict,
# the grant publish rc, the delivery outcome, and the clock step between
# two-call sequences. Steps with "calls" drive a sequence over one router.
PLAN='[
 {"name":"mode-off","wake":"signal: ship-a.status","mode":false,
  "scope":["safe",["1"],"100:1",["ship-a"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"latched","wake":"signal: ship-a.status","mode":true,"latched":true,
  "scope":["safe",["1"],"100:1",["ship-a"],[]],"classifier":"routine","publish":0,"deliver":"ok","libOnly":true},
 {"name":"afk","wake":"signal: ship-a.status","mode":true,"afk":true,
  "scope":["safe",["1"],"100:1",["ship-a"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"no-reason","wake":"alarm: the watcher failed loudly","mode":true,
  "scope":["safe",["1"],"100:1",["ship-a"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"empty-signal","wake":"signal: ship-a.status","mode":true,
  "scope":["empty",[],"",[],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"empty-check","wake":"check: startup-network finished","mode":true,
  "scope":["empty",[],"",[],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"scope-unsafe","wake":"signal: ship-a.status","mode":true,
  "scope":["unsafe",[],"",[],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"classifier-captain","wake":"signal: ship-a.status","mode":true,
  "scope":["safe",["1"],"100:1",["ship-a"],[]],"classifier":"captain","publish":0,"deliver":"ok"},
 {"name":"dedupe-window","wake":"signal: ship-b.status","mode":true,"calls":2,"clockStep":1000,
  "scope":["safe",["2"],"101:2",["ship-b"],[]],"classifier":"captain","publish":0,"deliver":"ok"},
 {"name":"unacknowledged-after-window","wake":"signal: ship-c.status","mode":true,"calls":2,"clockStep":91000,
  "scope":["safe",["3"],"102:3",["ship-c"],[]],"classifier":"captain","publish":0,"deliver":"ok"},
 {"name":"routine-grant","wake":"signal: ship-d.status","mode":true,
  "scope":["safe",["4"],"103:4",["ship-d"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"deliver-fails","wake":"signal: ship-e.status","mode":true,"calls":2,
  "scope":["safe",["5"],"104:5",["ship-e"],[]],"classifier":"routine","publish":0,"deliver":"deny"},
 {"name":"publish-rc3","wake":"signal: ship-f.status","mode":true,
  "scope":["safe",["6"],"105:6",["ship-f"],[]],"classifier":"routine","publish":3,"deliver":"ok"},
 {"name":"no-lock","wake":"signal: ship-g.status","mode":true,"activate":false,
  "scope":["safe",["7"],"106:7",["ship-g"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"inflight-queues","wake":"signal: ship-h.status","mode":true,"inFlight":{"seqs":["99"],"wakeNo":1},
  "scope":["safe",["8"],"107:8",["ship-h"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"handled-dedupes","wake":"signal: ship-d.status","mode":true,"calls":2,
  "scope":["safe",["4"],"103:4",["ship-d"],[]],"classifier":"routine","publish":0,"deliver":"ok"},
 {"name":"stale-inflight","wake":"signal: ship-i.status","mode":true,"inFlight":{"seqs":["98"],"wakeNo":1,"ageMs":200000},
  "scope":["safe",["9"],"108:9",["ship-i"],[]],"classifier":"routine","publish":0,"deliver":"ok","libOnly":true}
]'

export ROUTINE='{"verdict":"routine","reason":"nothing new"}'
export CAPTAIN='{"verdict":"captain","reason":"needs the captain"}'

# ---------- lib driver --------------------------------------------------------
cat > "$TMP_ROOT/routing-run.mjs" <<'DRIVER'
// Drives createWakeRouter over the plan with scripted deps; one fresh
// router (and wake counter) per step so the numbering matches the mod
// leg's fresh module instances, and every effect captured.
import { pathToFileURL } from "node:url";
const plan = JSON.parse(process.argv[2]);
const routing = await import(pathToFileURL(process.argv[3]).href);
const text = await import(pathToFileURL(process.argv[4]).href);
const classifier = await import(pathToFileURL(process.argv[5]).href);
const out = [];
for (const step of plan) {
  const events = [];
  const outcomeArgvs = [];
  const evidence = [];
  const passedWrites = [];
  const releases = [];
  let wakeCounter = 0;
  let now = 1_000_000;
  let dateNow = 500_000_000;
  let passedSet = new Set(step.passed ?? []);
  const scopeOf = () => {
    const [status, eligibleSeqs, eligibleWakeKey, eligibleTasks, needsDecisionTasks] = step.scope;
    return { status, eligibleSeqs, eligibleWakeKey, eligibleTasks, corrupted: status === "unsafe", needsDecisionTasks };
  };
  const makeDeps = () => ({
    log: (kind, data) => events.push({ kind, data }),
    reasonLines: text.reasonLines,
    clockNow: async () => (now += step.clockStep ?? 10_000),
    dateNow: () => (dateNow += 1_000),
    modeOn: async () => step.mode ?? true,
    latched: () => step.latched ?? false,
    afkPresent: async () => step.afk ?? false,
    scopeFor: async () => scopeOf(),
    readPassedSeqs: async () => [...passedSet],
    writePassedSeqs: async (seqs) => {
      passedSet = new Set(seqs);
      passedWrites.push([...seqs]);
    },
    classify: async () => ({
      verdict: step.classifier,
      reason: step.classifier === "routine" ? "nothing new" : "needs the captain",
      ms: 12,
      promptChars: 100,
      answer: "",
      model: "haiku",
      evidence: step.classifier === "routine" ? [{ task: "x", from: 0, to: 9, text: "## task x status bytes 0-9" }] : [],
    }),
    ensureActivated: async () => step.activate ?? true,
    grantPublish: async () => step.publish ?? 0,
    grantRelease: async () => {
      releases.push(1);
    },
    advanceEvidence: (task) => evidence.push(task),
    runOutcome: async (argv) => {
      outcomeArgvs.push(argv);
      if (argv[0] === "append") return { ok: true, stdout: "42", detail: "" };
      return { ok: true, stdout: "", detail: "" };
    },
    passedToMainSummary: classifier.passedToMainSummary,
    classifierPassCoverArgv: classifier.classifierPassCoverArgv,
    claimWakeNo: async () => {
      wakeCounter += 1;
      return wakeCounter;
    },
    freshAgentNeeded: () => false,
    stateDir: () => "/fm/home/state",
    statusNote: async () => "\n\nStatus lines of note",
    resetStepCounter: () => {},
    deliver: async () => (step.deliver === "deny" ? { ok: false, via: "spawn", detail: "no agentId" } : { ok: true, via: "spawn", detail: "br-1" }),
    spawnSendCounts: () => ({ spawnCount: step.deliver === "deny" ? 0 : 1, sendCount: 0 }),
  });
  const router = routing.createWakeRouter();
  if (step.inFlight) {
    router.setInFlightForTest({
      seqs: step.inFlight.seqs,
      wakeKey: "",
      tasks: new Set(["old-task"]),
      heartbeat: false,
      wakeText: "signal: old",
      reason: "signal: old",
      reportedSeqs: [],
      startedAt: dateNow - (step.inFlight.ageMs ?? 1_000),
      granted: true,
      wakeNo: step.inFlight.wakeNo,
      via: "send",
    });
  }
  const verdicts = [];
  const calls = step.calls ?? 1;
  for (let i = 0; i < calls; i += 1) verdicts.push(await router.routeWake(makeDeps(), step.wake, "stop-hook"));
  // Let the pass effects' detached cover rows settle before reading.
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  const p = router.peekInFlight();
  out.push({
    name: step.name,
    libOnly: step.libOnly === true,
    verdicts,
    events: events.map((e) => ({ kind: e.kind, data: e.data })),
    outcomeArgvs,
    evidence,
    passedWrites,
    releases: releases.length,
    inFlight: p ? { wakeNo: p.wakeNo, seqs: p.seqs, granted: p.granted } : null,
  });
}
console.log(JSON.stringify(out));
DRIVER

# ---------- mod driver --------------------------------------------------------
cat > "$TMP_ROOT/mod-routing-one.mjs" <<'DRIVER'
// One scenario, one fresh module instance: bind() to a mocked host over
// in-memory state files shaped by the scenario's scope, a scripted clock,
// and mocked scripts, then drive the exported routeWake and report the
// verdicts, the event log, the outcome argvs, the passed-file writes, and
// the delivery prompts.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const step = JSON.parse(process.argv[2]);
const HOME = "/fm/home";
const STATE = `${HOME}/state`;
process.env.FM_HOME = HOME;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const files = new Map();
const writes = [];
const events = [];
const outcomeArgvs = [];
const grants = [];
const evidenceRuns = [];
const prompts = [];
let outcomeSeq = 40;
let clock = 1_000_000;

// The state directory the scenario's scope names: the queue rows (a torn
// epoch for the unsafe scope), the metas, and the status logs they fold.
if (step.mode !== false) files.set(`${STATE}/.branch-mod-mode`, "");
if (step.afk) files.set(`${STATE}/.afk`, "away\n");
if (step.activate !== false) files.set(`${STATE}/.lock`, "4242\n");
{
  const [status, eligibleSeqs, , eligibleTasks] = step.scope;
  if (status === "empty") {
    files.set(`${STATE}/.wake-queue`, "\n");
    files.set(`${STATE}/ship-x.meta`, "kind=ship\nproject=demo\n");
  } else {
    const seqs = eligibleSeqs.length ? eligibleSeqs : ["1"];
    const torn = status === "unsafe";
    const rows = seqs.map((s, i) => `${torn ? "torn" : `1${i}${s}`}\t${s}\tsignal\t${(eligibleTasks[i] ?? "ship-x") + ".status"}\tsignal: working`).join("\n");
    files.set(`${STATE}/.wake-queue`, `${rows}\n`);
    for (const t of eligibleTasks.length ? eligibleTasks : ["ship-x"]) {
      files.set(`${STATE}/${t}.meta`, "kind=ship\nproject=demo\n");
      files.set(`${STATE}/${t}.status`, "working: implementing the fix\n");
      files.set(`${STATE}/.${t}.branch-outcome-index`, "fm-branch-outcome-index-v1\t9\t0\tident");
    }
  }
}
const classifierAnswer = step.classifier === "captain" ? process.env.CAPTAIN : process.env.ROUTINE;
const realSpawn = async () => (step.deliver === "deny" ? { deny: "no agentId" } : { agentId: "br-1" });
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => "/work" },
  fs: {
    exists: async (path) => files.has(String(path)),
    read: async (path) => {
      const p = String(path);
      if (files.has(p)) return files.get(p);
      if (p.endsWith("classifier-system.txt")) return "CLASSIFIER SYSTEM\n";
      throw new Error("no file");
    },
    write: async (path, text) => {
      files.set(String(path), String(text));
      writes.push({ path: String(path), text: String(text) });
    },
    append: async () => {},
    mkdir: async () => {},
    rm: async () => {},
    readDir: async () => [],
    list: async (path) =>
      [...files.keys()]
        .filter((k) => k.startsWith(`${String(path)}/`))
        .map((k) => ({ name: k.slice(String(path).length + 1) }))
        .filter((e) => !e.name.includes("/")),
    stat: async (path) => {
      if (!files.has(String(path))) throw new Error("no file");
      return { isLink: false, size: (files.get(String(path)) ?? "").length, mtimeMs: 1 };
    },
  },
  ui: { log: () => {} },
  prompt: { submit: async () => {} },
  process: {
    run: async (argv, opts) => {
      const joined = argv.join(" ");
      if (argv[0] === "sh" && argv[1] === "-c") {
        events.push(JSON.parse(opts.stdin));
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      if (joined.includes("fm-wake-grant.sh")) {
        grants.push(argv[2]);
        if (argv[2] === "publish") return { exitCode: step.publish ?? 0, stdout: "", stderr: "" };
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      if (joined.includes("fm-branch-outcome.sh")) {
        outcomeArgvs.push(argv.slice(2));
        if (argv[2] === "append") {
          outcomeSeq += 1;
          return { exitCode: 0, stdout: String(outcomeSeq), stderr: "" };
        }
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      if (joined.includes("fm-wake-evidence.sh")) {
        evidenceRuns.push(argv[argv.length - 1]);
        return { exitCode: 0, stdout: `## task ${argv[argv.length - 1]} status bytes 0-9\n(working)\n`, stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  },
  tool: {
    call: async (req) => {
      if (req.tool === "SendMessage") return { result: JSON.stringify({ success: true, resumedAgentId: "br-1" }) };
      return { result: "" };
    },
  },
  agent: {
    spawn: async (opts) => {
      prompts.push(opts.prompt);
      return realSpawn();
    },
    list: async () => [],
  },
  model: {
    complete: async () => classifierAnswer,
  },
  clock: { now: async () => (clock += step.clockStep ?? 10_000) },
};
await mod.bind($, "/work");
if (step.inFlight) {
  mod.__fmSetInFlight({
    seqs: step.inFlight.seqs,
    wakeKey: "",
    tasks: new Set(["old-task"]),
    heartbeat: false,
    wakeText: "signal: old",
    reason: "signal: old",
    reportedSeqs: [],
    startedAt: Date.now() - 1_000,
    granted: true,
    wakeNo: step.inFlight.wakeNo,
    via: "send",
  });
}
const verdicts = [];
const calls = step.calls ?? 1;
const flush = () => new Promise((r) => setImmediate(r));
for (let i = 0; i < calls; i += 1) {
  verdicts.push(await mod.routeWake($, step.wake, "stop-hook"));
  await flush();
  await flush();
}
const passedWrites = writes.filter((w) => w.path === `${STATE}/.branch-mod-passed`).map((w) => JSON.parse(w.text));
console.log(JSON.stringify({
  name: step.name,
  verdicts,
  // Only the event log's records carry a kind; the classification log's
  // appends ride the same shell seam and are not events.
  events: events.filter((e) => e && e.kind !== undefined).map((e) => ({ kind: e.kind, data: e.data })),
  outcomeArgvs,
  evidence: evidenceRuns,
  passedWrites,
  prompts,
  releases: grants.filter((g) => g === "release").length,
}));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
node --experimental-strip-types "$TMP_ROOT/routing-run.mjs" "$(cat "$TMP_ROOT/plan.json")" "$ROOT/lib/fm-branch-routing.ts" "$ROOT/lib/fm-branch-text.ts" "$ROOT/lib/fm-branch-classifier.ts" > "$TMP_ROOT/lib.json"
: > "$TMP_ROOT/mod-lines.json"
total=$(jq 'length' "$TMP_ROOT/plan.json")
i=0
while [ "$i" -lt "$total" ]; do
  step=$(jq -c ".[$i]" "$TMP_ROOT/plan.json")
  name=$(printf '%s' "$step" | jq -r '.name')
  libonly=$(printf '%s' "$step" | jq -r '.libOnly // false')
  if [ "$libonly" = "true" ]; then
    printf '{"name":"%s","skipped":"lib-only"}\n' "$name" >> "$TMP_ROOT/mod-lines.json"
  else
    node --experimental-strip-types "$TMP_ROOT/mod-routing-one.mjs" "$step" >> "$TMP_ROOT/mod-lines.json"
  fi
  i=$((i + 1))
done
jq -s . "$TMP_ROOT/mod-lines.json" > "$TMP_ROOT/mod.json"
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg routing driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

step() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP_ROOT/lib.json"; }
modstep() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP_ROOT/mod.json"; }
verdict_of() { jq -r '.verdicts | join(",")'; }

check_verdict() {
  local name=$1 want=$2 what=$3
  if [ "$(step "$name" | verdict_of)" = "$want" ] && [ "$(modstep "$name" | verdict_of)" = "$want" ]; then
    pass "$what"
  else
    fail "$what (lib=$(step "$name" | verdict_of) mod=$(modstep "$name" | verdict_of))"
  fi
}
check_verdict mode-off passed "a missing mode switch passes the wake to main untouched"
check_verdict afk passed "an away flag passes the wake to main"
check_verdict no-reason passed "a wake with no actionable reason line passes to main"
check_verdict empty-signal dropped "an empty queue under a signal reason is dropped (the other continuity path routed it)"
check_verdict empty-check passed "an empty queue under a check reason still passes (main must acknowledge)"
check_verdict scope-unsafe passed "an unsafe scope passes the wake to main untouched"
check_verdict classifier-captain passed "a captain classifier verdict passes the wake to main"
check_verdict dedupe-window passed,dropped "the same passed wake inside the dedupe window is dropped"
check_verdict unacknowledged-after-window passed,passed "a passed row still queued after the window goes back to main unclassified"
check_verdict routine-grant dropped "a routine verdict grants the wake and the branch takes it"
check_verdict deliver-fails passed,dropped "a failed delivery releases the grant and passes the wake to main; the repeat is deduped"
check_verdict publish-rc3 passed "a main-owned publish verdict passes the wake to main"
check_verdict no-lock passed "a missing session lock passes the wake to main"
check_verdict inflight-queues dropped "a wake arriving while the branch is busy is queued for the settlement"
check_verdict handled-dedupes dropped,dropped "a wake already in the branch's hands is deduped"

# The lib-only scenarios: the latched admission gate and the stale
# in-flight release (the mod host cannot script its real clock or the
# provider latch from outside).
if [ "$(step latched | jq -r '.events[0].data.why')" = "latched" ]; then
  pass "a latched provider passes the wake with the latched reason"
else
  fail "the latched admission drifted"
fi
if [ "$(step stale-inflight | jq -r '.releases')" = "1" ] && [ "$(step stale-inflight | verdict_of)" = "dropped" ] && [ "$(step stale-inflight | jq -r '.inFlight.wakeNo')" = "1" ]; then
  pass "a stale in-flight record frees the grant and the fresh wake is delivered"
else
  fail "the stale in-flight release drifted: $(step stale-inflight)"
fi

# The pass effects: the captain verdict writes the covering row.
COVER_ARGV="$(step classifier-captain | jq -c '.outcomeArgvs[0]')"
if [ "$(step classifier-captain | jq -r '.outcomeArgvs[0][0]')" = "append" ] \
  && [ "$(step classifier-captain | jq -r '.outcomeArgvs[0][2]')" = "ship-a" ] \
  && [ "$(step classifier-captain | jq -r '.outcomeArgvs[0][4]')" = "captain" ] \
  && [ "$(step classifier-captain | jq -r '.outcomeArgvs[0][6]')" = "Passed to main directly (classifier captain): needs the captain" ] \
  && [ "$(step classifier-captain | jq -r '.outcomeArgvs[1][0]')" = "mark-read" ] \
  && [ "$(step classifier-captain | jq -r '.outcomeArgvs[2][0]')" = "mark-processed" ] \
  && [ "$(step classifier-captain | jq -c '.evidence')" = '["ship-a"]' ]; then
  pass "a classifier pass writes the covering captain row, advances the cursors, and gathers evidence"
else
  fail "the cover-row effects drifted: $COVER_ARGV"
fi

# The granted wake's prompt bytes through the mod binding.
PROMPT="$(modstep routine-grant | jq -r '.prompts[0] // ""')"
if [ "$(printf '%s' "$PROMPT" | head -1)" = "FIRSTMATE SUPERVISION WAKE: signal: ship-d.status" ] \
  && [ "$(printf '%s' "$PROMPT" | sed -n 3p)" = "(wake 1 of this session)" ] \
  && [ "$(printf '%s' "$PROMPT" | sed -n 4p)" = "Handle this per your operating procedure and finish with fm_branch_report." ] \
  && [ "$(printf '%s' "$PROMPT" | sed -n 6p)" = "This wake's rows resolve to task ship-d (records: /fm/home/state/ship-d.meta and /fm/home/state/ship-d.status). Report with task=ship-d, never fleet." ] \
  && [ "$(printf '%s' "$PROMPT" | sed -n 8p)" = "Status lines of ship-d appended since your last outcome (seq 9):" ]; then
  pass "the granted wake carries the supervision prompt with its task scope note"
else
  fail "the granted wake's prompt drifted: $PROMPT"
fi

# The passed-wake file: a captain verdict records the rows.
if [ "$(step classifier-captain | jq -c '.passedWrites[-1]')" = '["1"]' ]; then
  pass "a classifier pass records the passed rows durably"
else
  fail "the passed-rows write drifted: $(step classifier-captain | jq -c '.passedWrites')"
fi

# The event streams agree between the legs on every shared step: the
# verdict table above already pins the outcomes, so this comparison pins
# the router-owned events and the durable writes, with the host-seam event
# kinds (activation, delivery, counters) and the host-owned numbers (the
# outcome-store seqs, the classifier ms/answer/model, the canned scope,
# and the classifier's own evidence gathers, which the lib leg scripts
# away) normalized out.
normalize_leg() {
  jq -S -c 'map(select((.skipped // .libOnly) | not) | {
    name,
    verdicts,
    events: [.events[] | select(.kind == "wake.passed" or .kind == "wake.scope" or .kind == "wake.passed.deduped" or .kind == "wake.dropped.empty" or .kind == "wake.deduped" or .kind == "inflight.stale" or .kind == "wake.queued" or .kind == "classifier" or .kind == "grant.publish" or .kind == "wake.delivered" or .kind == "wake.dropped" or .kind == "pass.cover" or .kind == "pass.cover.error") | {kind, data: (.data | del(.ms, .promptChars, .answer, .estTokens, .model, .scope, .seq))}],
    outcomeArgvs: [(.outcomeArgvs // [])[] | map(if (tonumber? // null) != null then "N" else . end)],
    passedWrites: (.passedWrites // [])
  })' "$1"
}
if [ "$(normalize_leg "$TMP_ROOT/lib.json")" = "$(normalize_leg "$TMP_ROOT/mod.json")" ]; then
  pass "the mod hook's routeWake binding routes the shared decision identically on every shared step"
else
  fail "the mod hook's routeWake binding diverges from the shared module"
fi
