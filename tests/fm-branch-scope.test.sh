#!/usr/bin/env bash
# Drives the supervision-branch mod's eligible-rows scan orchestration
# (.claude/mods/fm-branch-mod/lib/fm-branch-scope.ts, the canonical copy
# the repo's lib/ symlinks to) over one fixture set of real state
# directories:
#   - the lib leg: scanScope through an IO layer built on node:fs with the
#     failure injections the fixtures name (an unreadable queue, an
#     unreadable meta, a torn status read), with the real eligibility core
#     passed in exactly as the hook binds it;
#   - the mod leg: the REAL hook's exported scopeForUnreadWake, driven
#     through bind() with a mocked host whose fs wraps the same directory
#     with the same injections.
# Both legs must agree on the exact scope JSON for every fixture, and the
# suite pins the orchestration's own refusal mapping: a missing queue is
# unsafe, an empty queue is empty, an unreadable meta refuses the scan, a
# torn epoch refuses the row set, a symlinked status log reads as refused
# (the bash truth), and a symlinked meta names no kind. The pure fold's
# verdicts are pinned by tests/fm-branch-eligibility.test.sh; this suite
# pins the orchestration that feeds it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-scope)

# Pin the fold vocabulary: an ambient FM_CLASSIFY_* export would decide the
# verdicts this comparison reads, so every leg runs with them cleared.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB FM_CLASSIFY_RESERVED_KEY_PREFIXES

build_fixtures() {
  local fx="$TMP_ROOT/fx"
  # Plain routine signal row for a working ship task.
  mkdir -p "$fx/routine"
  printf 'working: implementing the fix\n' >"$fx/routine/ship-a.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/routine/ship-a.meta"
  printf '100\t1\tsignal\tship-a.status\tsignal: working\n' >"$fx/routine/.wake-queue"
  # Empty queue: the file exists but names no row.
  mkdir -p "$fx/empty-queue"
  printf '\n\n' >"$fx/empty-queue/.wake-queue"
  printf 'kind=ship\nproject=demo\n' >"$fx/empty-queue/ship-a.meta"
  # No queue at all.
  mkdir -p "$fx/missing-queue"
  printf 'working: on it\n' >"$fx/missing-queue/ship-a.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/missing-queue/ship-a.meta"
  # Torn epoch field in the queue row.
  mkdir -p "$fx/torn-epoch"
  printf 'working: on it\n' >"$fx/torn-epoch/ship-e.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/torn-epoch/ship-e.meta"
  printf 'torn\t5\tsignal\tship-e.status\tsignal: working\n' >"$fx/torn-epoch/.wake-queue"
  # Open captain decision: the stale row is decision-owned, not eligible.
  mkdir -p "$fx/held"
  printf 'needs-decision [key=dep]: waiting on captain\n' >"$fx/held/ship-b.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/held/ship-b.meta"
  printf '101\t2\tstale\tship-b\tstale: waiting too long\n' >"$fx/held/.wake-queue"
  # Symlinked status log (bash truth: refusal, empty fold, stale row stays eligible).
  mkdir -p "$fx/symlink-log"
  printf 'needs-decision [key=dep]: pick\n' >"$fx/symlink-log/ship-d-real.status"
  ln -s ship-d-real.status "$fx/symlink-log/ship-d.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/symlink-log/ship-d.meta"
  printf '102\t3\tstale\tship-d\tstale: waiting too long\n' >"$fx/symlink-log/.wake-queue"
  # Symlinked meta: names no kind.
  mkdir -p "$fx/symlink-meta"
  printf 'working: on it\n' >"$fx/symlink-meta/ship-f.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/symlink-meta/ship-f-real.meta"
  ln -s ship-f-real.meta "$fx/symlink-meta/ship-f.meta"
  printf '103\t4\tsignal\tship-f.status\tsignal: working\n' >"$fx/symlink-meta/.wake-queue"
  # A task without a project: its rows fold no status log.
  mkdir -p "$fx/no-project"
  printf 'kind=ship\n' >"$fx/no-project/ship-g.meta"
  printf '104\t5\tsignal\tship-g.status\tsignal: working\n' >"$fx/no-project/.wake-queue"
  printf '%s\n' "$fx"
}

FIXTURES=$(build_fixtures)

# ---------- node drivers ------------------------------------------------------
cat > "$TMP_ROOT/scope-run.mjs" <<'DRIVER'
// Drives scanScope over each fixture through an injected IO layer on
// node:fs, with the failure injections the step names. The step's "expect"
// array lists paths whose reads reject; "torn" lists status paths whose
// stat version changes after the read (the torn check fires).
import { pathToFileURL } from "node:url";
import { readFileSync, readdirSync, lstatSync } from "node:fs";
const root = process.env.FM_RS_ROOT;
const scope = await import(pathToFileURL(`${root}/lib/fm-branch-scope.ts`).href);
const eligibility = await import(pathToFileURL(`${root}/lib/fm-branch-eligibility.ts`).href);
const steps = JSON.parse(process.argv[2]);
const out = [];
for (const step of steps) {
  const state = step.state;
  const fail = new Set(step.expect ?? []);
  const torn = new Set(step.torn ?? []);
  const statOf = (path, bump) => {
    const s = lstatSync(path);
    return { isLink: s.isSymbolicLink(), size: s.size, mtimeMs: s.mtimeMs + (bump ? 1_000 : 0) };
  };
  const deps = {
    readFile: async (path) => {
      if (fail.has(path)) throw new Error("injected unreadable");
      return readFileSync(path, "utf8");
    },
    listDir: async (path) => readdirSync(path, { withFileTypes: true }).map((e) => ({ name: e.name })),
    stat: async (path) => {
      if (fail.has(path)) throw new Error("injected unreadable");
      return statOf(path, false);
    },
    vocabulary: async () => eligibility.foldVocabularyFromEnv((name) => process.env[name]),
    core: {
      statusKindFromMetaText: eligibility.statusKindFromMetaText,
      scopeForUnreadWake: eligibility.scopeForUnreadWake,
    },
  };
  // The torn injection: the first stat of a torn path answers the plain
  // version, any later stat answers a bumped one, so the read-then-stat
  // check sees the change.
  const seen = new Set();
  const plainStat = deps.stat;
  deps.stat = async (path) => {
    const r = await plainStat(path);
    if (torn.has(path)) {
      const v = seen.has(path);
      seen.add(path);
      return v ? { ...r, mtimeMs: r.mtimeMs + 1_000 } : r;
    }
    return r;
  };
  const got = await scope.scanScope(deps, state, step.heartbeat ?? false);
  out.push({ name: step.name, scope: got });
}
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-scope-one.mjs" <<'DRIVER'
// One fixture, one fresh module instance: bind() to the mocked host with
// FM_STATE_OVERRIDE pointing at the fixture, then export the scope.
import { pathToFileURL } from "node:url";
import { readFileSync, readdirSync, lstatSync } from "node:fs";
const root = process.env.FM_RS_ROOT;
const step = JSON.parse(process.argv[2]);
process.env.FM_STATE_OVERRIDE = step.state;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const fail = new Set(step.expect ?? []);
const torn = new Set(step.torn ?? []);
const seen = new Set();
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => process.cwd() },
  fs: {
    exists: async () => false,
    read: async (path) => {
      if (fail.has(String(path))) throw new Error("injected unreadable");
      return readFileSync(String(path), "utf8");
    },
    write: async () => {},
    append: async () => {},
    mkdir: async () => {},
    rm: async () => {},
    readDir: async () => [],
    list: async (path) => readdirSync(String(path), { withFileTypes: true }).map((e) => ({ name: e.name })),
    stat: async (path) => {
      if (fail.has(String(path))) throw new Error("injected unreadable");
      const s = lstatSync(String(path));
      let r = { isLink: s.isSymbolicLink(), size: s.size, mtimeMs: s.mtimeMs };
      if (torn.has(String(path))) {
        const v = seen.has(String(path));
        seen.add(String(path));
        if (v) r = { ...r, mtimeMs: r.mtimeMs + 1_000 };
      }
      return r;
    },
  },
  ui: { log: () => {} },
  prompt: { submit: async () => {} },
  process: { run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) },
  model: { complete: async () => "" },
  clock: { now: async () => 0 },
};
await mod.bind($, process.cwd());
console.log(JSON.stringify({ name: step.name, scope: await mod.scopeForUnreadWake($, step.heartbeat ?? false) }));
DRIVER

# ---------- fixture steps -----------------------------------------------------
STEPS="[
 {\"name\":\"routine\",\"state\":\"$FIXTURES/routine\"},
 {\"name\":\"heartbeat-flag\",\"state\":\"$FIXTURES/routine\",\"heartbeat\":true},
 {\"name\":\"empty-queue\",\"state\":\"$FIXTURES/empty-queue\"},
 {\"name\":\"missing-queue\",\"state\":\"$FIXTURES/missing-queue\"},
 {\"name\":\"unreadable-queue\",\"state\":\"$FIXTURES/routine\",\"expect\":[\"$FIXTURES/routine/.wake-queue\"]},
 {\"name\":\"unreadable-meta\",\"state\":\"$FIXTURES/routine\",\"expect\":[\"$FIXTURES/routine/ship-a.meta\"]},
 {\"name\":\"torn-epoch\",\"state\":\"$FIXTURES/torn-epoch\"},
 {\"name\":\"held-decision\",\"state\":\"$FIXTURES/held\"},
 {\"name\":\"symlink-log\",\"state\":\"$FIXTURES/symlink-log\"},
 {\"name\":\"symlink-meta\",\"state\":\"$FIXTURES/symlink-meta\"},
 {\"name\":\"no-project\",\"state\":\"$FIXTURES/no-project\"},
 {\"name\":\"torn-status\",\"state\":\"$FIXTURES/routine\",\"torn\":[\"$FIXTURES/routine/ship-a.status\"]}
]"
echo "$STEPS" > "$TMP_ROOT/steps.json"

export FM_RS_ROOT="$ROOT"
node --experimental-strip-types "$TMP_ROOT/scope-run.mjs" "$(cat "$TMP_ROOT/steps.json")" > "$TMP_ROOT/lib.json"
: > "$TMP_ROOT/mod-lines.json"
i=0
total=$(jq 'length' "$TMP_ROOT/steps.json")
while [ "$i" -lt "$total" ]; do
  step=$(jq -c ".[$i]" "$TMP_ROOT/steps.json")
  node --experimental-strip-types "$TMP_ROOT/mod-scope-one.mjs" "$step" >> "$TMP_ROOT/mod-lines.json"
  i=$((i + 1))
done
# One JSON object per process above; fold the lines into the array shape
# the lib leg emitted.
jq -s . "$TMP_ROOT/mod-lines.json" > "$TMP_ROOT/mod.json"
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg scope driver produced no usable output"
  fi
done

# ---------- assertions -------------------------------------------------------

# Every fixture: the mod hook's binding agrees with the module, exactly.
if [ "$(jq -S -c . "$TMP_ROOT/lib.json")" = "$(jq -S -c . "$TMP_ROOT/mod.json")" ]; then
  pass "the mod hook's scan binding routes the shared module identically on every fixture"
else
  fail "the mod hook's scan binding diverges from the shared module"
fi

scope_of() { jq -c --arg n "$1" '.[] | select(.name == $n) | .scope' "$TMP_ROOT/lib.json"; }
if [ "$(scope_of routine | jq -r '.status')" = "safe" ] && [ "$(scope_of routine | jq -r '.eligibleSeqs | join(",")')" = "1" ] && [ "$(scope_of routine | jq -r '.eligibleWakeKey')" = "100:1" ] && [ "$(scope_of routine | jq -r '.eligibleTasks | join(",")')" = "ship-a" ]; then
  pass "a working ship task's signal row scans safe and eligible with its wake key"
else
  fail "the routine scan drifted: $(scope_of routine)"
fi
if [ "$(scope_of empty-queue | jq -r '.status')" = "empty" ] && [ "$(scope_of empty-queue | jq -r '.corrupted')" = "false" ]; then
  pass "an empty queue scans empty before any metadata enumeration can fail"
else
  fail "the empty-queue scan drifted"
fi
if [ "$(scope_of missing-queue | jq -r '.status')" = "unsafe" ] && [ "$(scope_of unreadable-queue | jq -r '.status')" = "unsafe" ] && [ "$(scope_of unreadable-meta | jq -r '.status')" = "unsafe" ]; then
  pass "a missing queue, an unreadable queue, and an unreadable meta each refuse the scan"
else
  fail "the refusal mapping drifted"
fi
if [ "$(scope_of torn-epoch | jq -r '.status')" = "unsafe" ]; then
  pass "a torn epoch field refuses the row set"
else
  fail "the torn-epoch scan drifted"
fi
if [ "$(scope_of held-decision | jq -r '.eligibleSeqs | length')" = "0" ] && [ "$(scope_of held-decision | jq -r '.needsDecisionTasks | join(",")')" = "ship-b" ]; then
  pass "an open captain decision makes the stale row decision-owned, not eligible"
else
  fail "the held-decision scan drifted: $(scope_of held-decision)"
fi
if [ "$(scope_of symlink-log | jq -r '.status')" = "safe" ] && [ "$(scope_of symlink-log | jq -r '.eligibleSeqs | join(",")')" = "3" ]; then
  pass "a symlinked status log reads as refused, so the stale row stays eligible (bash truth)"
else
  fail "the symlink-log scan drifted: $(scope_of symlink-log)"
fi
if [ "$(scope_of no-project | jq -r '.status')" = "unsafe" ]; then
  pass "a task without a project leaves its row key unresolvable, so the scan refuses"
else
  fail "the no-project scan drifted: $(scope_of no-project)"
fi
if [ "$(scope_of torn-status | jq -r '.status')" = "safe" ]; then
  pass "a torn status read completes the scan instead of refusing it"
else
  fail "the torn-status scan drifted: $(scope_of torn-status)"
fi
