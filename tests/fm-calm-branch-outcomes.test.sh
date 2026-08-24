#!/usr/bin/env bash
# Portable regression for Calm's collapsed presentation of a supervision-branch
# outcome read (.pi/extensions/lib/fm-calm-branch-outcomes.ts).
#
# Every input below is a real record produced by the real store writer
# (bin/fm-branch-outcome.sh), and the module under test is exercised through its
# own exported function with no Pi package present at all - the module takes no
# Pi import precisely so this can run anywhere CI runs node. What the rendered
# row then LOOKS like against real Pi is a harness-dependent verdict this test
# cannot answer; tests/fm-calm-branch-outcomes-live-e2e.test.sh owns that half.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Calm branch-outcome collapse regression"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-calm-branch-outcomes)
trap fm_test_cleanup EXIT

home="$TMP_ROOT/home"
mkdir -p "$home/state"

# Import the module from a directory with no node_modules of its own and none
# above it, so a Pi dependency added to it would fail this test loudly instead
# of quietly making the portable half unrunnable where CI runs.
MODULE="$TMP_ROOT/fm-calm-branch-outcomes.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-branch-outcomes.ts" "$MODULE"

outcome() { # <verdict> <task> <summary>
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    bash "$ROOT/bin/fm-branch-outcome.sh" append \
      --task "$2" --verdict "$1" --summary "$3" --wake "signal: $2" >/dev/null \
    || fail "the real outcome writer refused a $1 record for $2"
}

store_listing() { # <recent>
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    bash "$ROOT/bin/fm-branch-outcome.sh" list --recent "$1"
}

# Real records, written by the real store writer: two the branch handled itself
# and two that name the captain.
outcome routine task-9 "worker healthy, no action needed"
outcome captain task-12 "PR https://example.com/pr/12 checks green, ready for review"
outcome routine task-14 "worker healthy, no action needed"
outcome captain task-4 "blocked: cannot reach the forge, credentials rejected"

routine_only="$TMP_ROOT/routine-only.txt"
store_listing 1 > "$TMP_ROOT/latest.txt"
grep -q '"verdict":"captain"' "$TMP_ROOT/latest.txt" \
  || fail "the store fixture did not end on a captain record"
store_listing 4 > "$TMP_ROOT/mixed.txt"
[ "$(wc -l < "$TMP_ROOT/mixed.txt")" -eq 4 ] || fail "the store fixture did not produce 4 records"
grep '"verdict":"routine"' "$TMP_ROOT/mixed.txt" > "$routine_only" \
  || fail "the store fixture produced no routine records"

test_collapse_and_preserve() {
  local out status
  out=$(MODULE="$MODULE" MIXED="$TMP_ROOT/mixed.txt" ROUTINE="$routine_only" node --input-type=module <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { calmBranchOutcomeAttention } = await import(pathToFileURL(process.env.MODULE).href);
const mixed = readFileSync(process.env.MIXED, "utf8");
const routineOnly = readFileSync(process.env.ROUTINE, "utf8");
const check = (label, actual, expected) => {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${label}: expected ${e}, got ${a}`);
};

// A read the captain never has to act on collapses to nothing, exactly like
// every other tool row Calm hides.
check("routine-only store", calmBranchOutcomeAttention(routineOnly, false), []);
check("empty output", calmBranchOutcomeAttention("", false), []);
check("blank output", calmBranchOutcomeAttention("   \n\n", false), []);
check(
  "empty-store sentinel",
  calmBranchOutcomeAttention("(no branch outcomes recorded)", false),
  [],
);

// A captain-verdict outcome survives the collapse as one line; the routine
// records around it do not.
check("mixed store", calmBranchOutcomeAttention(mixed, false), [
  { glyph: true, text: "task-12: PR https://example.com/pr/12 checks green, ready for review" },
  { glyph: true, text: "task-4: blocked: cannot reach the forge, credentials rejected" },
]);

// A failed read is never collapsed away: the captain who cannot see the fleet
// has to be told, and the tool's own message is what says why.
check(
  "failed read",
  calmBranchOutcomeAttention("could not read the outcome store: exit 2", true),
  [{ glyph: true, text: "could not read the outcome store: exit 2" }],
);
check("failed read with no detail", calmBranchOutcomeAttention("", true), [
  { glyph: true, text: "could not read the outcome store" },
]);

// Output Calm does not recognize as the store's records is carried through
// byte-for-byte rather than swallowed by a format it has not been taught.
const unrecognized = [
  "not json at all",
  '{"seq":9}',
  '["task-1","captain","summary"]',
  '{"task":"task-7","verdict":"escalate","summary":"unknown verdict"}',
  '{"task":"task-8","verdict":"captain","summary":42}',
  "  ",
].join("\n");
check(
  "unrecognized output",
  calmBranchOutcomeAttention(unrecognized, false),
  [
    { glyph: false, text: "not json at all" },
    { glyph: false, text: '{"seq":9}' },
    { glyph: false, text: '["task-1","captain","summary"]' },
    { glyph: false, text: '{"task":"task-7","verdict":"escalate","summary":"unknown verdict"}' },
    { glyph: false, text: '{"task":"task-8","verdict":"captain","summary":42}' },
  ],
);

// A legacy record written before the store carried `silent` is still a valid
// record, and `silent` never decides what the captain gets to see.
check(
  "legacy record without silent",
  calmBranchOutcomeAttention(
    '{"seq":1,"epoch":1,"task":"task-3","wake":"stale: task-3","verdict":"captain","summary":"needs a decision"}',
    false,
  ),
  [{ glyph: true, text: "task-3: needs a decision" }],
);
check(
  "silent captain record",
  calmBranchOutcomeAttention(
    '{"seq":2,"epoch":1,"task":"fleet","wake":"heartbeat","verdict":"captain","summary":"still needs a decision","silent":true}',
    false,
  ),
  [{ glyph: true, text: "fleet: still needs a decision" }],
);

// Unrecognized output mixed in with real records keeps both.
check(
  "partial recognition",
  calmBranchOutcomeAttention(`${routineOnly.trim()}\nstore truncated`, false),
  [{ glyph: false, text: "store truncated" }],
);
console.log("COLLAPSE_OK");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Calm branch-outcome collapse regression failed: $out"
  assert_contains "$out" "COLLAPSE_OK" "Calm branch-outcome collapse regression did not run to completion"
  pass "Calm collapses a handled branch-outcome read to nothing and never swallows a failure, a captain-relevant outcome, or output it does not recognize"
}

test_collapse_and_preserve
