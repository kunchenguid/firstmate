#!/usr/bin/env bash
# Drives the supervision-branch mod's session and settlement rules
# (.claude/mods/fm-branch-mod/lib/fm-branch-settlement.ts, the canonical
# copy the repo's lib/ symlinks to) on one fixture set:
#   - the lib leg: the deterministic backstop through injected deps (the
#     evidence-covered runner, the main prompt submission, logging),
#     pinning its call order, its prompt bytes, and its never-throw error
#     surface; plus the transcript-persistence rule table, the counters
#     record's build/parse/apply verdicts, and the usage fold with its
#     rotation bound;
#   - the mod leg: the REAL hook's exported backstopCheck binding, driven
#     through bind() with a mocked host, must agree with the lib leg on
#     the prompts delivered and the event stream.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-settlement)

# ---------- fixture plan ------------------------------------------------------
# Each backstop step names the covered lines the evidence runner answers
# per task, whether the submission throws, and the tasks in order.
PLAN='[
 {"name":"covered-two-tasks","tasks":["ship-a","ship-b"],"wakeNo":3,
  "covered":{"ship-a":["9\tneeds-decision [key=x]: pick one\tship-a.status","10\tdone: PR https://example.com/pull/9 checks green\tship-a.status"],
             "ship-b":["11\tblocked [key=y]: upstream\tship-b.status"]}},
 {"name":"nothing-covered","tasks":["ship-a"],"wakeNo":4,"covered":{"ship-a":[]}},
 {"name":"submit-throws","tasks":["ship-a"],"wakeNo":5,"throwOn":"ship-a",
  "covered":{"ship-a":["12\tcaptain: a line\tship-a.status"]}}
]'

# ---------- node drivers ------------------------------------------------------
cat > "$TMP_ROOT/settlement-run.mjs" <<'DRIVER'
// Drives the settlement rules over the plan with every effect captured.
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const plan = JSON.parse(process.argv[3]);
const m = await import(pathToFileURL(modulePath).href);
const out = [];
for (const step of plan) {
  const events = [];
  const prompts = [];
  const runs = [];
  const deps = {
    log: (kind, data) => events.push({ kind, data }),
    runCovered: async (task) => {
      runs.push(task);
      return { exitCode: 0, stdout: (step.covered[task] ?? []).join("\n") + ((step.covered[task] ?? []).length ? "\n" : ""), stderr: "" };
    },
    submitPrompt: async (text) => {
      if (step.throwOn === taskOf(text)) throw new Error("submit refused");
      prompts.push(text);
    },
  };
  // The throw predicate keys on the task the prompt names.
  function taskOf(text) {
    for (const t of step.tasks) if (text.includes(`task ${t} `) || text.includes(`task ${t},`) || text.includes(`task ${t}\n`) || text.includes(`task ${t} routine`)) return t;
    return "";
  }
  await m.backstopCheck(deps, step.tasks, step.wakeNo);
  out.push({ name: step.name, events, prompts, runs });
}
// The transcript-persistence rule table.
out.push({ name: "persistence", cases: [
  { label: "default", got: m.transcriptPersistenceFromEnv("", "") },
  { label: "force", got: m.transcriptPersistenceFromEnv("1", "") },
  { label: "marker", got: m.transcriptPersistenceFromEnv("", "1") },
  { label: "force-wins", got: m.transcriptPersistenceFromEnv("1", "1") },
] });
// The counters record: build byte order, parse, apply verdicts.
const text = m.buildCountersText({ lockPid: "4242", wakeCounter: 7, spawnCount: 2, sendCount: 1, generation: "cc1", branchGeneration: 3, branchRef: "a1b2", branchAgentId: "ade3", monitorTaskId: "m1", monitorArmedAt: 99 });
out.push({
  name: "counters",
  text,
  parsed: m.parseCountersRecord(text),
  garbage: m.parseCountersRecord("not json"),
  applyMatch: m.countersApplyVerdict(JSON.parse(text), "4242"),
  applyMismatch: m.countersApplyVerdict(JSON.parse(text), "9999"),
  applyAbsent: m.countersApplyVerdict({}, "4242"),
});
// The usage fold and the rotation bound.
out.push({ name: "usage", cases: [
  { label: "plain", got: m.wakeUsageFold({ input_tokens: 100, cache_read_input_tokens: 50, cache_creation_input_tokens: 50 }, 4) },
  { label: "missing-usage", got: m.wakeUsageFold(undefined, 0) },
  { label: "one-step", got: m.wakeUsageFold({ input_tokens: 60_001 }, 1) },
], rotate: [
  { label: "at-bound", got: m.rotateDue(60_000, false) },
  { label: "past-bound", got: m.rotateDue(60_001, false) },
  { label: "already-pending", got: m.rotateDue(60_001, true) },
] });
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-settlement-run.mjs" <<'DRIVER'
// Drives the REAL mod hook's backstopCheck through bind() with a mocked
// host, over the same plan.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const plan = JSON.parse(process.argv[2]);
const HOME = "/fm/home";
process.env.FM_HOME = HOME;
const out = [];
for (const step of plan) {
  const events = [];
  const prompts = [];
  const runs = [];
  let active = null;
  const $ = {
    plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
    env: { get: async (name) => process.env[name] ?? "" },
    session: { cwd: async () => "/work" },
    fs: {
      exists: async () => false,
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
    prompt: {
      submit: async (req) => {
        if (step.throwOn !== undefined && req.text.includes(`task ${step.throwOn} routine`)) throw new Error("submit refused");
        prompts.push(req.text);
      },
    },
    process: {
      run: async (argv) => {
        const joined = argv.join(" ");
        if (joined.includes("fm-wake-evidence.sh") && joined.includes("--routine-covered")) {
          const task = argv[argv.length - 1];
          runs.push(task);
          return { exitCode: 0, stdout: (step.covered[task] ?? []).join("\n") + ((step.covered[task] ?? []).length ? "\n" : ""), stderr: "" };
        }
        if (argv[0] === "sh" && argv[1] === "-c") {
          events.push(JSON.parse(arguments[2] ?? "{}"));
          return { exitCode: 0, stdout: "", stderr: "" };
        }
        return { exitCode: 0, stdout: "", stderr: "" };
      },
    },
    model: { complete: async () => "" },
    clock: { now: async () => 0 },
  };
  void active;
  // The event log's append shell is captured through a wrapper because the
  // process.run signature carries stdin on opts, not argv.
  const plainRun = $.process.run;
  $.process.run = async (argv, opts) => {
    if (argv[0] === "sh" && argv[1] === "-c") {
      events.push(JSON.parse(opts.stdin));
      return { exitCode: 0, stdout: "", stderr: "" };
    }
    return plainRun(argv, opts);
  };
  await mod.bind($, "/work");
  await mod.backstopCheck($, new Set(step.tasks), step.wakeNo);
  out.push({ name: step.name, events: events.map((e) => ({ kind: e.kind, data: e.data })), prompts, runs });
}
console.log(JSON.stringify(out));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
PLAN_ARG="$(cat "$TMP_ROOT/plan.json")"
node --experimental-strip-types "$TMP_ROOT/settlement-run.mjs" "$ROOT/lib/fm-branch-settlement.ts" "$PLAN_ARG" > "$TMP_ROOT/lib.json"
node --experimental-strip-types "$TMP_ROOT/mod-settlement-run.mjs" "$PLAN_ARG" > "$TMP_ROOT/mod.json"
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg settlement driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

step() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP_ROOT/lib.json"; }

# The mod's backstop binding agrees with the module on the event stream,
# the prompts, and the runner order.
if [ "$(jq -S -c 'map(select(.prompts))' "$TMP_ROOT/lib.json")" = "$(jq -S -c 'map(select(.prompts))' "$TMP_ROOT/mod.json")" ]; then
  pass "the mod hook's backstop binding routes the shared rule identically"
else
  fail "the mod hook's backstop binding diverges from the shared module"
fi

# The covered run order follows the task order.
if [ "$(step covered-two-tasks | jq -c '.runs')" = '["ship-a","ship-b"]' ] && [ "$(step covered-two-tasks | jq -r '.events[0].kind')" = "backstop.check" ] && [ "$(step covered-two-tasks | jq -r '.events[0].data.rc')" = "0" ]; then
  pass "the backstop runs the covered check per task in order and logs its result first"
else
  fail "the covered-run order drifted: $(step covered-two-tasks)"
fi

# The prompt bytes, pinned on the first task of the covered step.
EXPECTED_PROMPT='Supervision backstop (deterministic, delivered automatically by fm-branch-mod, not typed by the captain): the supervision branch marked a wake of task ship-a routine, but the status log carries 2 captain-facing line(s) it covered:
  needs-decision [key=x]: pick one	ship-a.status
  done: PR https://example.com/pull/9 checks green	ship-a.status

Run bin/fm-wake-drain.sh (its STATUS OUTCOME BACKSTOP section names the same line), tell the captain the outcome in one sentence, then run the exact --ack-through command it printed.'
if [ "$(step covered-two-tasks | jq -r '.prompts[0]')" = "$EXPECTED_PROMPT" ] && [ "$(step covered-two-tasks | jq -c '.prompts | length')" = "2" ]; then
  pass "each covered task delivers its deterministic prompt with the tab-stripped lines"
else
  fail "the backstop prompt bytes drifted"
fi

# Nothing covered: no prompt, one check event.
if [ "$(step nothing-covered | jq -c '.prompts | length')" = "0" ] && [ "$(step nothing-covered | jq -c '.events | length')" = "1" ]; then
  pass "a task with nothing covered delivers no prompt"
else
  fail "the nothing-covered step drifted"
fi

# A failed submission logs the error and never throws.
if [ "$(step submit-throws | jq -r '.events[1].kind')" = "backstop.error" ] && [ "$(step submit-throws | jq -r '.events[1].data.error')" = "Error: submit refused" ]; then
  pass "a failed backstop submission is logged as backstop.error, never thrown"
else
  fail "the error surface drifted: $(step submit-throws)"
fi

# The transcript-persistence rule table.
persistence_case() {
  local label=$1 want=$2 what=$3
  if [ "$(jq -c --arg l "$label" '.[] | select(.name == "persistence") | .cases[] | select(.label == $l) | .got' "$TMP_ROOT/lib.json")" = "$want" ]; then
    pass "$what"
  else
    fail "$what"
  fi
}
persistence_case default '{"on":true,"cause":"default"}' "unset environment reads persistence on by default"
persistence_case force '{"on":true,"cause":"CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"}' "the force variable restores persistence"
persistence_case marker '{"on":false,"cause":"inherited CLAUDE_CODE_CHILD_SESSION marker"}' "the inherited child-session marker disables persistence"
persistence_case force-wins '{"on":true,"cause":"CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"}' "the force variable wins over the marker"

# The counters record.
if [ "$(jq -r '.[] | select(.name == "counters") | .text' "$TMP_ROOT/lib.json")" = '{"lockPid":"4242","wakeCounter":7,"spawnCount":2,"sendCount":1,"generation":"cc1","branchGeneration":3,"branchRef":"a1b2","branchAgentId":"ade3","monitorTaskId":"m1","monitorArmedAt":99}' ]; then
  pass "the counters record keeps its pinned field order"
else
  fail "the counters record bytes drifted"
fi
if [ "$(jq -r '.[] | select(.name == "counters") | .applyMatch' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[] | select(.name == "counters") | .applyMismatch' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[] | select(.name == "counters") | .applyAbsent' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[] | select(.name == "counters") | .garbage' "$TMP_ROOT/lib.json")" = "null" ]; then
  pass "the counters record parses or refuses, and applies only on the same lock pid"
else
  fail "the counters parse and apply verdicts drifted"
fi

# The usage fold and the rotation bound.
if [ "$(jq -c '.[] | select(.name == "usage") | .cases[0].got' "$TMP_ROOT/lib.json")" = '{"wakeTokens":200,"stepContext":50}' ] \
  && [ "$(jq -c '.[] | select(.name == "usage") | .cases[1].got' "$TMP_ROOT/lib.json")" = '{"wakeTokens":0,"stepContext":0}' ] \
  && [ "$(jq -c '.[] | select(.name == "usage") | .cases[2].got' "$TMP_ROOT/lib.json")" = '{"wakeTokens":60001,"stepContext":60001}' ]; then
  pass "the usage fold sums the request tokens and divides by the step count"
else
  fail "the usage fold drifted"
fi
if [ "$(jq -r '.[] | select(.name == "usage") | .rotate[0].got' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[] | select(.name == "usage") | .rotate[1].got' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[] | select(.name == "usage") | .rotate[2].got' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "the rotation bound fires past 60000 per-step tokens, once per crossing"
else
  fail "the rotation bound drifted"
fi
