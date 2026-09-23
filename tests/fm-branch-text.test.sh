#!/usr/bin/env bash
# Drives the supervision-branch mod's text builders and text-shaped parses
# (.claude/mods/fm-branch-mod/lib/fm-branch-text.ts, the canonical copy the
# repo's lib/ symlinks to) on one fixture set:
#   - the lib leg: the module through the repo's symlink, every pure
#     function byte-pinned (the rewake banner, the reason-line filter, the
#     monitor-event parse, the task-notice id, the Stop-hook wake
#     predicate, the new-status-lines note, the processing request, the
#     Bash actor command, the tool-text coercion, the version-probe
#     parsing) and the one seamed function (newStatusLinesNote) through an
#     injected readFile;
#   - the mod leg: the REAL hook's exported newStatusLinesNote binding,
#     driven through bind() with a mocked file surface, must agree with
#     the lib leg on the same fixtures.
# The pure builders' use inside the hook is pinned end to end by the mod's
# engine suite (tests/fm-branch-claude-mod-plugin.test.sh) and by
# tests/fm-branch-routing.test.sh; this suite pins the module's own bytes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-text)

# ---------- fixture plan ------------------------------------------------------
# The note fixtures name file contents by key; "absent" keys make the
# injected readFile reject (the $.fs.read contract for a missing file).
PLAN='[
 {"name":"fresh-lines","tasks":["ship-a"],
  "files":{"ship-a.index":"fm-branch-outcome-index-v1\t9\t12\tident","ship-a.status":"0123456789x done: compiled the fleet chart\nblocked: waiting on the tide tables\n"}},
 {"name":"no-earlier-outcome","tasks":["ship-a"],
  "files":{"ship-a.index":"absent","ship-a.status":"done: first outcome ever\n"}},
 {"name":"missing-status","tasks":["ship-a"],
  "files":{"ship-a.index":"fm-branch-outcome-index-v1\t7\t12\tident","ship-a.status":"absent"}},
 {"name":"twelve-line-cap","tasks":["ship-a"],
  "files":{"ship-a.index":"fm-branch-outcome-index-v1\t1\t0\tident",
           "ship-a.status":"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nfourteen\n"}},
 {"name":"two-tasks","tasks":["ship-a","ship-b"],
  "files":{"ship-a.index":"fm-branch-outcome-index-v1\t3\t5\tident","ship-a.status":"01234working: on it\n",
           "ship-b.index":"absent","ship-b.status":"done: b finished\n"}},
 {"name":"bad-index-header","tasks":["ship-a"],
  "files":{"ship-a.index":"something-else\t9\t40","ship-a.status":"done: x\n"}},
 {"name":"no-tasks","tasks":[],"files":{}}
]'

# ---------- node drivers ------------------------------------------------------
cat > "$TMP_ROOT/text-run.mjs" <<'DRIVER'
// Drives the text module's every function over the fixture plan and the
// fixed parse table, emitting one JSON array of results.
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const plan = JSON.parse(process.argv[3]);
const state = "/fm/home/state";
const m = await import(pathToFileURL(modulePath).href);
const out = [];

// The reason-line filter.
out.push({
  name: "reason-lines",
  lines: m.reasonLines(
    "alarm: watcher exited badly\n" +
      "signal: 123\t45\tkey\tpayload line\n" +
      "  stale: ship-a stopped responding  \n" +
      "check: startup-network finished\n" +
      "heartbeat: fleet review\n" +
      "heartbeat\n" +
      "prose that is not a reason\n",
  ),
});

// The rewake banner, byte-pinned through one reason.
out.push({ name: "rewake-banner", banner: m.rewakeBanner("signal: one row needs a turn") });

// The monitor-event parse table.
const description = "fm-branch-mod watcher continuity";
out.push({
  name: "monitor-events",
  cases: [
    { label: "not-ours", text: "<task-notification>some other monitor</task-notification>", got: m.parseMonitorEvent("<task-notification>some other monitor</task-notification>", description) },
    { label: "real-events", text: "x", got: m.parseMonitorEvent(`<task-notification>${description}</task-notification><event>signal: 1 row</event><event>quiet: nothing</event>`, description) },
    { label: "expired-rode-along", got: m.parseMonitorEvent(`<task-notification>${description}</task-notification><event>[Monitor expired after 30m with 2 events delivered.]</event><event>check: poll done</event>`, description) },
    { label: "rotate-notice", got: m.parseMonitorEvent(`<task-notification>${description}</task-notification><event>rotate: loop exiting ahead of the monitor timeout</event>`, description) },
    { label: "no-events-at-all", got: m.parseMonitorEvent(`<task-notification>${description}</task-notification>`, description) },
  ],
});

// The task-notice id parse.
out.push({
  name: "task-notice-id",
  cases: [
    { label: "found", got: m.taskNoticeId("<task-notification><task-id>abc123</task-id></task-notification>") },
    { label: "absent", got: m.taskNoticeId("<task-notification>no id</task-notification>") },
  ],
});

// The Stop-hook wake predicate.
out.push({
  name: "stop-hook-wake",
  cases: [
    { label: "wake", got: m.isStopHookWakeText('<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\nStop hook blocking error from command "Stop": firstmate watcher wake - one event.') },
    { label: "summary-only", got: m.isStopHookWakeText("<summary>Stop hook feedback</summary>\nunrelated") },
    { label: "marker-only", got: m.isStopHookWakeText("firstmate watcher wake without the summary") },
  ],
});

// The deterministic note, through the injected readFile seam.
for (const step of plan) {
  const files = new Map(Object.entries(step.files ?? {}));
  const deps = {
    readFile: async (path) => {
      for (const task of step.tasks) {
        if (path === `${state}/.${task}.branch-outcome-index`) {
          const v = files.get(`${task}.index`);
          if (v === "absent") throw new Error("no file");
          if (v !== undefined) return v;
        }
        if (path === `${state}/${task}.status`) {
          const v = files.get(`${task}.status`);
          if (v === "absent") throw new Error("no file");
          if (v !== undefined) return v;
        }
      }
      throw new Error("no file");
    },
  };
  out.push({ name: `note:${step.name}`, note: await m.newStatusLinesNote(deps, state, step.tasks) });
}

// The processing request, byte-pinned.
out.push({ name: "processing-request", text: m.processingRequest(12, "ship-a", "the fix landed", "branch verdict captain") });

// The tool-text coercion.
out.push({
  name: "tool-text",
  cases: [
    { label: "text", got: m.toolText({ text: "a" }) },
    { label: "result", got: m.toolText({ result: "b" }) },
    { label: "empty", got: m.toolText(undefined) },
  ],
});

// The Bash actor command, byte-pinned for a pinned and an empty holder.
out.push({
  name: "bash-actor",
  cases: [
    { label: "holder", got: m.bashActorCommand("echo hi", "4242", { home: "/fm/home", state: "/fm/home/state", config: "/fm/home/config" }) },
    { label: "no-holder", got: m.bashActorCommand("echo hi", "", { home: "/fm/home", state: "/fm/home/state", config: "/fm/home/config" }) },
  ],
});

// The version-probe parsing.
out.push({
  name: "version-parse",
  cases: [
    { label: "shaped", token: m.versionToken("2.1.278 (Claude Code)"), shaped: m.isVersionShaped("2.1.278") },
    { label: "prefix-shape", token: m.versionToken("2.1.278-x custom"), shaped: m.isVersionShaped("2.1.278-x") },
    { label: "unshaped", token: m.versionToken("unreadable (Error: x)"), shaped: m.isVersionShaped("unreadable") },
    { label: "empty", token: m.versionToken(""), shaped: m.isVersionShaped("") },
  ],
});

console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-text-run.mjs" <<'DRIVER'
// Drives the REAL mod hook's exported newStatusLinesNote through bind()
// with a mocked file surface, over the same plan.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const plan = JSON.parse(process.argv[2]);
const HOME = "/fm/home";
const STATE = `${HOME}/state`;
process.env.FM_HOME = HOME;
const out = [];
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => process.cwd() },
  fs: {
    exists: async () => false,
    read: async (path) => {
      for (const step of plan) {
        // The last matching fixture wins only within the step being driven;
        // the driver sets the active step through the module-level queue.
        const active = queue;
        if (!active) break;
        for (const task of active.tasks) {
          if (path === `${STATE}/.${task}.branch-outcome-index`) {
            const v = (active.files ?? {})[`${task}.index`];
            if (v === "absent") throw new Error("no file");
            if (v !== undefined) return v;
          }
          if (path === `${STATE}/${task}.status`) {
            const v = (active.files ?? {})[`${task}.status`];
            if (v === "absent") throw new Error("no file");
            if (v !== undefined) return v;
          }
        }
      }
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
  process: { run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) },
  model: { complete: async () => "" },
  clock: { now: async () => 0 },
};
let queue = null;
await mod.bind($, process.cwd());
for (const step of plan) {
  queue = step;
  out.push({ name: `note:${step.name}`, note: await mod.newStatusLinesNote($, step.tasks) });
}
console.log(JSON.stringify(out));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
PLAN_ARG="$(cat "$TMP_ROOT/plan.json")"
node --experimental-strip-types "$TMP_ROOT/text-run.mjs" "$ROOT/lib/fm-branch-text.ts" "$PLAN_ARG" > "$TMP_ROOT/lib.json"
node --experimental-strip-types "$TMP_ROOT/mod-text-run.mjs" "$PLAN_ARG" > "$TMP_ROOT/mod.json"
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg text driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

# The mod's note binding agrees with the module on every fixture.
if [ "$(jq -c 'map(select(.name | startswith("note:")))' "$TMP_ROOT/lib.json")" = "$(jq -c 'map(select(.name | startswith("note:")))' "$TMP_ROOT/mod.json")" ]; then
  pass "the mod hook's status-note binding routes the shared module byte-identically"
else
  fail "the mod hook's status-note binding diverges from the shared module"
fi

# The reason-line filter.
if [ "$(jq -c '.[0].lines' "$TMP_ROOT/lib.json")" = '["signal: 123\t45\tkey\tpayload line","stale: ship-a stopped responding","check: startup-network finished","heartbeat: fleet review","heartbeat"]' ]; then
  pass "the reason-line filter keeps signal, stale, check, and heartbeat lines, trimmed, dropping prose and alarms"
else
  fail "the reason-line filter drifted"
fi

# The rewake banner, byte-pinned.
EXPECTED_BANNER='<task-notification>
<summary>Stop hook feedback</summary>
</task-notification>
<system-reminder>
Stop hook blocking error from command "Stop": firstmate watcher wake - one supervision event needs a handling turn now.
signal: one row needs a turn
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
</system-reminder>'
if [ "$(jq -r '.[1].banner' "$TMP_ROOT/lib.json")" = "$EXPECTED_BANNER" ]; then
  pass "the rewake banner keeps the Stop hook's exact shape and bytes"
else
  fail "the rewake banner drifted"
fi

# The monitor-event parse table.
check_case() {
  local label=$1 want=$2 what=$3
  if [ "$(jq -c --arg l "$label" '.[2].cases[] | select(.label == $l) | .got' "$TMP_ROOT/lib.json")" = "$want" ]; then
    pass "$what"
  else
    fail "$what (got $(jq -c --arg l "$label" '.[2].cases[] | select(.label == $l) | .got' "$TMP_ROOT/lib.json"))"
  fi
}
check_case not-ours '{"ours":false,"expired":false,"reasons":[]}' "a text without the monitor description is not ours"
check_case real-events '{"ours":true,"expired":false,"reasons":["signal: 1 row"]}' "a monitor event block parses to its reason lines"
check_case expired-rode-along '{"ours":true,"expired":true,"reasons":["check: poll done"]}' "an expiry notice riding the event stream expires the monitor and keeps the real events"
check_case rotate-notice '{"ours":true,"expired":true,"reasons":[]}' "a lone rotate notice expires the monitor with no reasons"
check_case no-events-at-all '{"ours":true,"expired":true,"reasons":[]}' "an eventless notification counts as expired"

# The task-notice id.
if [ "$(jq -r '.[3].cases[0].got' "$TMP_ROOT/lib.json")" = "abc123" ] && [ "$(jq -r '.[3].cases[1].got' "$TMP_ROOT/lib.json")" = "" ]; then
  pass "the task-notice id parse finds the id or answers empty"
else
  fail "the task-notice id parse drifted"
fi

# The Stop-hook wake predicate.
if [ "$(jq -r '.[4].cases[0].got' "$TMP_ROOT/lib.json")" = "true" ] && [ "$(jq -r '.[4].cases[1].got' "$TMP_ROOT/lib.json")" = "false" ] && [ "$(jq -r '.[4].cases[2].got' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "the Stop-hook wake predicate needs both the summary and the watcher marker"
else
  fail "the Stop-hook wake predicate drifted"
fi

# The note fixtures.
note_of() { jq -r --arg n "note:$1" '.[] | select(.name == $n) | .note' "$TMP_ROOT/lib.json"; }
if [ "$(note_of fresh-lines)" = "$(printf '\n\nStatus lines of ship-a appended since your last outcome (seq 9):\n  done: compiled the fleet chart\n  blocked: waiting on the tide tables')" ]; then
  pass "the note slices the status log from the outcome index endpoint"
else
  fail "the fresh-lines note drifted: $(note_of fresh-lines)"
fi
if [ "$(note_of no-earlier-outcome)" = "$(printf '\n\nNo earlier outcome exists for ship-a: the whole status log is new for this wake.')" ]; then
  pass "a missing outcome index reads as no earlier outcome"
else
  fail "the no-earlier-outcome note drifted"
fi
if [ "$(note_of missing-status)" = "$(printf '\n\nStatus lines of ship-a appended since your last outcome (seq 7):\n  (none - only a turn-end or pane signal)')" ]; then
  pass "a missing status log contributes no lines"
else
  fail "the missing-status note drifted"
fi
if [ "$(note_of twelve-line-cap | grep -cE '^  (one|two)$')" = "0" ] && [ "$(note_of twelve-line-cap | grep -cE '^  [a-z]+$')" = "12" ]; then
  pass "the note keeps at most the last twelve fresh lines"
else
  fail "the twelve-line cap drifted"
fi
if [ "$(note_of two-tasks | grep -c 'Status lines of ship-a')" = "1" ] && [ "$(note_of two-tasks | grep -c 'No earlier outcome exists for ship-b')" = "1" ]; then
  pass "a multi-task note carries one part per task in order"
else
  fail "the two-task note drifted"
fi
if [ "$(note_of bad-index-header)" = "$(printf '\n\nNo earlier outcome exists for ship-a: the whole status log is new for this wake.')" ]; then
  pass "an index with a foreign header reads as no earlier outcome"
else
  fail "the bad-index note drifted"
fi
if [ "$(note_of no-tasks)" = "" ]; then
  pass "no tasks answer an empty note"
else
  fail "the no-tasks note drifted"
fi

# The processing request, byte-pinned.
EXPECTED_REQUEST='This is a supervision processing request delivered automatically by the supervision branch (branch verdict captain). It was not typed by the captain. The outcome below is already stored durably; the fleet event is already handled, so do not re-drain, re-run, or acknowledge the wake. Process it now as firstmate: tell the captain the outcome in one sentence. Then call fm_branch_processed with through=12 exactly once.

[seq 12] ship-a: the fix landed'
if [ "$(jq -r '.[12].text' "$TMP_ROOT/lib.json")" = "$EXPECTED_REQUEST" ]; then
  pass "the processing request keeps its exact bytes"
else
  fail "the processing request drifted"
fi

# The tool-text coercion.
if [ "$(jq -r '.[13].cases[0].got' "$TMP_ROOT/lib.json")" = "a" ] && [ "$(jq -r '.[13].cases[1].got' "$TMP_ROOT/lib.json")" = "b" ] && [ "$(jq -r '.[13].cases[2].got' "$TMP_ROOT/lib.json")" = "" ]; then
  pass "the tool-text coercion prefers text, then result, then empty"
else
  fail "the tool-text coercion drifted"
fi

# The Bash actor command, byte-pinned.
EXPECTED_BASH_HOLDER='export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=4242 FM_HOME="/fm/home" FM_STATE_OVERRIDE="/fm/home/state" FM_CONFIG_OVERRIDE="/fm/home/config"
(
echo hi
)'
EXPECTED_BASH_NOHOLDER='export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ FM_HOME="/fm/home" FM_STATE_OVERRIDE="/fm/home/state" FM_CONFIG_OVERRIDE="/fm/home/config"
(
echo hi
)'
if [ "$(jq -r '.[14].cases[0].got' "$TMP_ROOT/lib.json")" = "$EXPECTED_BASH_HOLDER" ] && [ "$(jq -r '.[14].cases[1].got' "$TMP_ROOT/lib.json")" = "$EXPECTED_BASH_NOHOLDER" ]; then
  pass "the Bash actor command wraps the original command with the identity exports"
else
  fail "the Bash actor command drifted"
fi

# The version-probe parsing.
if [ "$(jq -r '.[15].cases[0].token' "$TMP_ROOT/lib.json")" = "2.1.278" ] && [ "$(jq -r '.[15].cases[0].shaped' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[15].cases[1].shaped' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[15].cases[2].shaped' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[15].cases[3].shaped' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "the version-probe parse takes the first token and accepts three dot-separated numbers"
else
  fail "the version-probe parse drifted"
fi
