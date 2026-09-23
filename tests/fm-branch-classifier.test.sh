#!/usr/bin/env bash
# Drives the shared pre-branch classifier core
# (.claude/mods/fm-branch-mod/lib/fm-branch-classifier.ts, the canonical copy
# the repo's lib/ symlinks to) from the two hosts that consume it, on one
# fixture set (A5 of the supervision-branch hexagon refactor):
#   - the lib leg: the module the Pi extension imports through the repo's
#     symlink, through its declared seams (script runner, system-prompt and
#     model-config reads, the model call, an injected clock);
#   - the mod leg: the REAL Claude Code supervision-branch hook
#     (.claude/mods/fm-branch-mod/hooks/branch.ts classify), bound through the
#     exported bind() with a capturing process runner - its clock is host
#     code, so record t/ms are normalized to the injected clock's values
#     before the legs are compared.
# Pinned byte-for-byte: the evidence gatherer argv and timeout, the evidence
# byte-range parse and the failed-gatherer text, the prompt construction, the
# answer interpretation rule (whitelisted verdicts, unparsed and failed-call
# fallbacks, the answer cap), the durable record shape and field order, the
# system-prompt memo (one read per module lifetime, cleared only by the
# module's test reset), and the classifier-pass covering summary and argv.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-classifier)

# ---------- fixture plan (one set, driven through every leg) -----------------
# Per step: the evidence gatherer's scripted result per task (in task order),
# the model answer (or a complete failure), and the configured model value.
PLAN='[
 {"name":"captain-clean","tasks":["ship-a"],"seqs":["1","2"],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 100-240\n## status lines appended since last outcome\n  done: compiled the fleet chart\n","stderr":""}],
  "answer":"{\"verdict\":\"captain\",\"reason\":\"needs human\"}","config":"haiku"},
 {"name":"routine-two-tasks-second-gather-fails","tasks":["ship-a","ship-b"],"seqs":["3"],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 0-9\n## status lines appended since last outcome\n  (none)\n","stderr":""},
              {"exitCode":1,"stdout":"","stderr":"spawn exploded"}],
  "answer":"{\"verdict\":\"routine\",\"reason\":\"nothing new\"}","config":"gpt-5-nano"},
 {"name":"prose-wrapped-json","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "answer":"Sure! {\"verdict\":\"uncertain\",\"reason\":\"unclear\"} hope that helps","config":"haiku"},
 {"name":"malformed-answer","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "answer":"not json at all","config":"haiku"},
 {"name":"non-whitelisted-verdict","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "answer":"{\"verdict\":\"ship\",\"reason\":\"go\"}","config":"haiku"},
 {"name":"complete-throws","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "completeError":"no quota left","config":"haiku"},
 {"name":"empty-reason","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "answer":"{\"verdict\":\"routine\"}","config":"haiku"},
 {"name":"no-range-exit-0","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a\nno range named here\n","stderr":""}],
  "answer":"{\"verdict\":\"routine\",\"reason\":\"ok\"}","config":"haiku"},
 {"name":"answer-cap-400","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "answer":"{\"verdict\":\"routine\",\"reason\":\"aaaa\",\"pad\":\"012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\"}","config":"haiku"},
 {"name":"three-tasks-order","tasks":["c-task","a-task","b-task"],"seqs":["9"],
  "evidence":[{"exitCode":0,"stdout":"## task c-task status bytes 30-40\n","stderr":""},
              {"exitCode":0,"stdout":"## task a-task status bytes 1-2\n","stderr":""},
              {"exitCode":0,"stdout":"## task b-task status bytes 20-25\n","stderr":""}],
  "answer":"{\"verdict\":\"captain\",\"reason\":\"multi\"}","config":"haiku"},
 {"name":"fallback-on-not-found","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "completeError":"fm-branch-mod: $.model.complete: the request to opus-x failed (HTTP 404)","config":"opus-x",
  "defaultModel":"haiku","fallbackAnswer":"{\"verdict\":\"routine\",\"reason\":\"on the host default\"}"},
 {"name":"fallback-unavailable","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "completeError":"classifier model not found: zai/glm-flash","config":"zai/glm-flash"},
 {"name":"quota-failure-never-falls-back","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "completeError":"no quota left","config":"haiku","defaultModel":"anthropic/main-model"},
 {"name":"fallback-same-name-no-retry","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "completeError":"classifier model not found: haiku","defaultModel":"haiku"},
 {"name":"default-when-unconfigured","tasks":["ship-a"],"seqs":[],
  "evidence":[{"exitCode":0,"stdout":"## task ship-a status bytes 5-6\n","stderr":""}],
  "defaultModel":"haiku",
  "answer":"{\"verdict\":\"routine\",\"reason\":\"on the host default\"}"}
]'

# ---------- node drivers -----------------------------------------------------
cat > "$TMP_ROOT/classifier-run.mjs" <<'DRIVER'
// Drives one classifier module (lib or mod leg) through the fixture plan
// with every seam captured: script spawns (argv + opts), the complete()
// request, and the returned result plus the exact record line. The clock is
// injected (iso -> "T", now -> fixed) so record bytes are leg-comparable.
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const plan = JSON.parse(process.argv[3]);
const m = await import(pathToFileURL(modulePath).href);
const SYSTEM = "CLASSIFIER SYSTEM PROMPT v1\n";
const out = [];
let nowTick = 0;
const clock = { now: () => 1000 + nowTick++, iso: () => "T" };
let systemReads = 0;
for (const step of plan) {
  const spawns = [];
  const completeReqs = [];
  const deps = {
    paths: { bin: "/fake/bin" },
    runScript: async (argv, opts) => {
      spawns.push({ argv, opts });
      const r = step.evidence[spawns.length - 1] ?? { exitCode: 0, stdout: "", stderr: "" };
      return r;
    },
    readSystemPrompt: async () => {
      systemReads++;
      return SYSTEM;
    },
    readConfiguredModel: async () => step.config ?? null,
    readDefaultModel: async () => step.defaultModel ?? null,
    complete: async (req) => {
      completeReqs.push(req);
      // A retry on the host fallback (any name but the one resolved first)
      // is scripted by fallbackAnswer; every other call answers or fails as
      // the step names.
      if (req.model !== (step.config ?? step.defaultModel) && step.fallbackAnswer !== undefined) return step.fallbackAnswer;
      if (step.completeError !== undefined) throw new Error(step.completeError);
      return step.answer;
    },
    clock,
  };
  const o = await m.classifyWake(deps, { wake: `heartbeat: ${step.name}`, tasks: step.tasks, seqs: step.seqs });
  out.push({
    name: step.name,
    result: o.result,
    recordLine: o.recordLine,
    completeReqs,
    spawns,
  });
}
// The memo seam: the whole plan above shares one module lifetime, so exactly
// one system-prompt read must have happened; the reset clears it.
out.push({ name: "system-reads-after-plan", count: systemReads });
m.__resetClassifierSystemPrompt();
const deps = {
  paths: { bin: "/fake/bin" },
  runScript: async () => ({ exitCode: 0, stdout: "## task t status bytes 0-1\n", stderr: "" }),
  readSystemPrompt: async () => {
    systemReads++;
    return SYSTEM;
  },
  readConfiguredModel: async () => null,
  readDefaultModel: async () => "haiku",
  complete: async () => '{"verdict":"routine","reason":"ok"}',
  clock,
};
await m.classifyWake(deps, { wake: "heartbeat: reset", tasks: ["t"], seqs: [] });
out.push({ name: "system-reads-after-reset", count: systemReads });
// The classifier-pass covering rule, byte-pinned.
out.push({
  name: "pass-cover",
  summary: m.passedToMainSummary("classifier", "needs human"),
  argv: m.classifierPassCoverArgv("ship-a", m.passedToMainSummary("classifier", "needs human"), "9:12"),
});
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-classifier-run.mjs" <<'DRIVER'
// Drives the REAL mod hook classify() through the same plan. The mod's clock
// is host code, so record t/ms are normalized to the injected legs' values
// ("T" / 0) before comparison. Evidence spawns, the sh -c classification-log
// append, and the complete() request are all captured.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const plan = JSON.parse(process.argv[2]);
const SYSTEM = "CLASSIFIER SYSTEM PROMPT v1\n";
const evidenceSpawns = [];
const appends = [];
const completions = [];
let systemReads = 0;
let evidenceQueue = [];
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => process.cwd() },
  fs: {
    exists: async () => false,
    read: async (path) => {
      if (String(path).endsWith("classifier-system.txt")) {
        systemReads++;
        return SYSTEM;
      }
      if (String(path).endsWith("classifier-model")) return evidenceQueue.config ?? "";
      throw new Error("no file");
    },
    write: async () => {},
    append: async () => {},
    mkdir: async () => {},
    rm: async () => {},
    readDir: async () => [],
    stat: async () => ({ isLink: false }),
  },
  ui: { log: () => {} },
  prompt: { submit: async () => {} },
  process: {
    run: async (argv, opts) => {
      if (argv[0] === "bash" && String(argv[1] ?? "").endsWith("fm-wake-evidence.sh")) {
        evidenceSpawns.push({ argv, opts });
        // The step's evidence array is per task, in tasks order; repeats of
        // the same task consume the following entries.
        const same = evidenceSpawns.filter((s) => s.argv[2] === argv[2]);
        const idx = evidenceQueue.tasks.indexOf(argv[2]) + same.length - 1;
        return evidenceQueue.evidence?.[idx] ?? { exitCode: 0, stdout: "", stderr: "" };
      }
      if (argv[0] === "sh" && argv[1] === "-c") {
        appends.push(opts.stdin);
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  },
  model: {
    complete: async (req) => {
      completions.push(req);
      // Mirrors the lib driver: a retry on the fallback name is scripted by
      // fallbackAnswer; every other call answers or fails as the step names.
      if (req.model !== (evidenceQueue.config ?? evidenceQueue.defaultModel) && evidenceQueue.fallbackAnswer !== undefined) return evidenceQueue.fallbackAnswer;
      if (evidenceQueue.completeError !== undefined) throw new Error(evidenceQueue.completeError);
      return evidenceQueue.answer;
    },
  },
};
await mod.bind($, process.cwd());
const out = [];
for (const step of plan) {
  // Fresh capture arrays per step (a shared array would alias across steps),
  // and spawns normalized to the module-owned bytes: the task argv and the
  // timeout. The host's cwd/env binding is a seam, not a module byte.
  const stepSpawns = [];
  evidenceSpawns.length = 0;
  appends.length = 0;
  completions.length = 0;
  evidenceQueue = step;
  const r = await mod.classify($, `heartbeat: ${step.name}`, step.tasks, step.seqs);
  for (const s of evidenceSpawns) stepSpawns.push({ argv: s.argv, opts: { timeoutMs: s.opts.timeoutMs } });
  out.push({
    name: step.name,
    result: r,
    recordLine: appends[0] ?? null,
    completeReqs: completions.slice(),
    spawns: stepSpawns,
  });
}
out.push({ name: "system-reads-after-plan", count: systemReads });
console.log(JSON.stringify(out));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
PLAN_ARG="$(cat "$TMP_ROOT/plan.json")"
node --experimental-strip-types "$TMP_ROOT/classifier-run.mjs" "$ROOT/lib/fm-branch-classifier.ts" "$PLAN_ARG" > "$TMP_ROOT/lib.json"
node --experimental-strip-types "$TMP_ROOT/mod-classifier-run.mjs" "$PLAN_ARG" > "$TMP_ROOT/mod.json"
# A crashed driver writes an empty or partial file whose legs would then
# compare vacuously; require parseable non-empty output before comparing.
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg classifier driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

# The mod leg must agree with the lib leg on every module-owned byte: result,
# complete request, the appended record line with the host clock normalized
# away, and the spawns projected to the task and timeout (the script's bind
# path is a host seam, so full-argv equality is only pinned on the lib leg).
# The memo-reset and pass-cover records are lib-driver-only sections with
# their own assertions below; classify() itself does not produce them.
# The mod host cannot express an absent default name (its default is always
# haiku), so the no-default not-found fixture is lib-only,
# like the lib-driver-only sections below.
normalize_leg() {
  jq -S 'map(select(.name != "system-reads-after-reset" and .name != "pass-cover" and .name != "fallback-unavailable"))
    | map(.recordLine = (if .recordLine then ((.recordLine | fromjson) | .t = "T" | .ms = 0 | tostring) else .recordLine end)
    | .result = (if .result then (.result | .ms = 0) else .result end)
    | .spawns = ((.spawns // []) | map({task: (.argv[2] // null), timeoutMs: .opts.timeoutMs})))' "$1"
}
normalize_leg "$TMP_ROOT/mod.json" > "$TMP_ROOT/mod-norm.json"
normalize_leg "$TMP_ROOT/lib.json" > "$TMP_ROOT/lib-norm.json"
if cmp -s "$TMP_ROOT/lib-norm.json" "$TMP_ROOT/mod-norm.json"; then
  pass "the mod hook routes the classifier core byte-identically to the shared module"
else
  fail "the mod hook's classifier output diverges from the shared module"
fi

# Evidence gatherer argv and timeout, on the first fixture.
if [ "$(jq -c '.[0].spawns[0].argv' "$TMP_ROOT/lib.json")" = '["bash","/fake/bin/fm-wake-evidence.sh","ship-a"]' ] \
  && [ "$(jq -r '.[0].spawns[0].opts.timeoutMs' "$TMP_ROOT/lib.json")" = "25000" ]; then
  pass "the evidence gatherer spawns bin/fm-wake-evidence.sh per task with its 25s timeout"
else
  fail "the evidence gatherer spawn contract drifted"
fi

# Verdict interpretation table.
check_verdict() {
  local idx=$1 verdict=$2 reason=$3 label=$4
  if [ "$(jq -r ".[$idx].result.verdict" "$TMP_ROOT/lib.json")" = "$verdict" ] \
    && [ "$(jq -r ".[$idx].result.reason" "$TMP_ROOT/lib.json")" = "$reason" ]; then
    pass "$label"
  else
    fail "$label (got $(jq -r ".[$idx].result.verdict + \" / \" + .[$idx].result.reason" "$TMP_ROOT/lib.json"))"
  fi
}
check_verdict 0 captain "needs human" "a whitelisted verdict is trusted with its reason"
check_verdict 1 routine "nothing new" "a failed gatherer is judgeable evidence, not a routing failure"
check_verdict 2 uncertain "unclear" "prose around the one JSON line still parses"
check_verdict 3 uncertain "unparsed" "an answer without JSON is unparsed"
check_verdict 4 uncertain "go" "a verdict outside the whitelist falls back to uncertain, keeping the reason"
check_verdict 5 uncertain "model.complete failed: Error: no quota left" "a failed model call routes uncertain with the failure text"
check_verdict 6 routine "" "a missing reason stays an empty string"
check_verdict 7 routine "ok" "an evidence bundle without a byte range records -1 spans"

# The failed gatherer's text is part of the prompt, byte-pinned.
if [ "$(jq -r '.[1].completeReqs[0].prompt' "$TMP_ROOT/lib.json" | grep -cFx '(evidence gatherer failed: spawn exploded)')" = "1" ] \
  && [ "$(jq -r '.[1].result.evidence[1].from' "$TMP_ROOT/lib.json")" = "-1" ] \
  && [ "$(jq -r '.[1].result.evidence[1].to' "$TMP_ROOT/lib.json")" = "-1" ]; then
  pass "a failed gatherer contributes its 300-capped failure text with -1 spans"
else
  fail "the failed-gatherer evidence text drifted"
fi

# Prompt construction, byte-pinned on the first fixture. The system prompt
# ends with a newline that command substitution would strip, so it is
# compared through files.
EXPECTED_PROMPT='WAKE:
heartbeat: captain-clean

EVIDENCE (bash-gathered, read-only):

## task ship-a status bytes 100-240
## status lines appended since last outcome
  done: compiled the fleet chart


Answer with the one JSON line.'
jq -j '.[0].completeReqs[0].system' "$TMP_ROOT/lib.json" > "$TMP_ROOT/system.txt"
printf 'CLASSIFIER SYSTEM PROMPT v1\n' > "$TMP_ROOT/system-expected.txt"
if [ "$(jq -r '.[0].completeReqs[0].prompt' "$TMP_ROOT/lib.json")" = "$EXPECTED_PROMPT" ] \
  && cmp -s "$TMP_ROOT/system.txt" "$TMP_ROOT/system-expected.txt" \
  && [ "$(jq -r '.[0].completeReqs[0].maxTokens' "$TMP_ROOT/lib.json")" = "200" ] \
  && [ "$(jq -r '.[0].completeReqs[0].model' "$TMP_ROOT/lib.json")" = "haiku" ]; then
  pass "the classifier prompt, system, model, and 200-token cap are byte-stable"
else
  fail "the classifier prompt construction drifted"
fi

# Record shape: field order pinned (the scorers parse this log).
EXPECTED_RECORD='{"t":"T","wake":"heartbeat: captain-clean","tasks":["ship-a"],"seqs":["1","2"],"evidence":[{"task":"ship-a","from":100,"to":240}],"verdict":"captain","reason":"needs human","model":"haiku","ms":0,"answer":"{\"verdict\":\"captain\",\"reason\":\"needs human\"}"}'
if [ "$(jq -r '.[0].recordLine | fromjson | keys_unsorted | join(",")' "$TMP_ROOT/lib.json")" = "t,wake,tasks,seqs,evidence,verdict,reason,model,ms,answer" ] \
  && [ "$(jq -r '.[0].recordLine' "$TMP_ROOT/lib-norm.json")" = "$EXPECTED_RECORD" ]; then
  pass "the classification record keeps its pinned field order and byte shape"
else
  fail "the classification record shape drifted"
fi

# The answer cap.
if [ "$(jq -r '.[8].result.answer | length' "$TMP_ROOT/lib.json")" = "400" ]; then
  pass "the durable answer keeps at most 400 characters"
else
  fail "the 400-character answer cap drifted"
fi

# Evidence order follows the task order given, not alphabetical.
if [ "$(jq -c '.[9].result.evidence | map(.task)' "$TMP_ROOT/lib.json")" = '["c-task","a-task","b-task"]' ] \
  && [ "$(jq -r '.[9].result.evidence[1].from' "$TMP_ROOT/lib.json")" = "1" ]; then
  pass "evidence bundles follow the wake's task order"
else
  fail "evidence bundle ordering drifted"
fi

# The per-host resolution rule and the one-shot model-not-found fallback
# (steps 10-14): the explicit configured name wins, the host's default fills
# the gap before any completion call, and only a not-found failure (here in
# Claude Code's HTTP 404 phrasing) retries once on the default name.
if [ "$(jq -c '.[10].completeReqs | map(.model)' "$TMP_ROOT/lib.json")" = '["opus-x","haiku"]' ] \
  && [ "$(jq -r '.[10].completeReqs[0].prompt' "$TMP_ROOT/lib.json")" = "$(jq -r '.[10].completeReqs[1].prompt' "$TMP_ROOT/lib.json")" ] \
  && [ "$(jq -r '.[10].completeReqs[0].system' "$TMP_ROOT/lib.json")" = "$(jq -r '.[10].completeReqs[1].system' "$TMP_ROOT/lib.json")" ] \
  && [ "$(jq -r '.[10].completeReqs[1].maxTokens' "$TMP_ROOT/lib.json")" = "200" ] \
  && [ "$(jq -r '.[10].result.verdict' "$TMP_ROOT/lib.json")" = "routine" ] \
  && [ "$(jq -r '.[10].result.model' "$TMP_ROOT/lib.json")" = "haiku" ] \
  && [ "$(jq -r '.[10].recordLine | fromjson | .model' "$TMP_ROOT/lib.json")" = "haiku" ]; then
  pass "a not-found model retries the same request once on the default and the record names the model used"
else
  fail "the model-not-found fallback drifted (reqs=$(jq -c '.[10].completeReqs | map(.model)' "$TMP_ROOT/lib.json") result=$(jq -c '.[10].result | {model, verdict}' "$TMP_ROOT/lib.json")"
fi

if [ "$(jq -c '.[11].completeReqs | map(.model)' "$TMP_ROOT/lib.json")" = '["zai/glm-flash"]' ] \
  && [ "$(jq -r '.[11].result.verdict' "$TMP_ROOT/lib.json")" = "uncertain" ] \
  && [ "$(jq -r '.[11].result.reason' "$TMP_ROOT/lib.json")" = "model.complete failed: Error: classifier model not found: zai/glm-flash" ] \
  && [ "$(jq -r '.[11].result.model' "$TMP_ROOT/lib.json")" = "zai/glm-flash" ]; then
  pass "without a default name the not-found failure keeps today's failed-call surface"
else
  fail "the no-default not-found surface drifted"
fi

if [ "$(jq -c '.[12].completeReqs | map(.model)' "$TMP_ROOT/lib.json")" = '["haiku"]' ] \
  && [ "$(jq -r '.[12].result.reason' "$TMP_ROOT/lib.json")" = "model.complete failed: Error: no quota left" ] \
  && [ "$(jq -r '.[12].result.model' "$TMP_ROOT/lib.json")" = "haiku" ]; then
  pass "a failure outside the not-found class never triggers the fallback"
else
  fail "the not-found-only fallback rule drifted"
fi

if [ "$(jq -c '.[13].completeReqs | map(.model)' "$TMP_ROOT/lib.json")" = '["haiku"]' ] \
  && [ "$(jq -r '.[13].result.verdict' "$TMP_ROOT/lib.json")" = "uncertain" ] \
  && [ "$(jq -r '.[13].result.model' "$TMP_ROOT/lib.json")" = "haiku" ]; then
  pass "a not-found default is not retried on itself"
else
  fail "the same-name fallback guard drifted"
fi

if [ "$(jq -c '.[14].completeReqs | map(.model)' "$TMP_ROOT/lib.json")" = '["haiku"]' ] \
  && [ "$(jq -r '.[14].result.verdict' "$TMP_ROOT/lib.json")" = "routine" ] \
  && [ "$(jq -r '.[14].result.model' "$TMP_ROOT/lib.json")" = "haiku" ]; then
  pass "an unconfigured classifier resolves the host's default before any completion call"
else
  fail "the host-default resolution drifted"
fi

# The system-prompt memo: one read for the whole plan, re-read after reset.
if [ "$(jq -r '.[15].count' "$TMP_ROOT/lib.json")" = "1" ] \
  && [ "$(jq -r '.[16].count' "$TMP_ROOT/lib.json")" = "2" ] \
  && [ "$(jq -r '.[15].count' "$TMP_ROOT/mod.json")" = "1" ]; then
  pass "the classifier system prompt is read once per module lifetime; the test reset clears it"
else
  fail "the system-prompt memo drifted (lib plan=$(jq -r '.[15].count' "$TMP_ROOT/lib.json") lib after reset=$(jq -r '.[16].count' "$TMP_ROOT/lib.json") mod=$(jq -r '.[15].count' "$TMP_ROOT/mod.json"))"
fi

# The classifier-pass covering rule, byte-pinned.
if [ "$(jq -r '.[17].summary' "$TMP_ROOT/lib.json")" = "Passed to main directly (classifier): needs human" ] \
  && [ "$(jq -c '.[17].argv' "$TMP_ROOT/lib.json")" = '["append","--task","ship-a","--verdict","captain","--summary","Passed to main directly (classifier): needs human","--silent","false","--wake","9:12"]' ]; then
  pass "the classifier-pass covering summary and outcome-store argv are byte-stable"
else
  fail "the classifier-pass covering rule drifted"
fi

