#!/usr/bin/env bash
# Portable four-fold equivalence proof for the wake-eligibility and
# open-decision classification (the "branch fold"), which exists three times
# plus once as the shared extraction target:
#   - bin/fm-classify-lib.sh `status_open_decisions` (the authoritative v8
#     fold: needs-decision/blocked open a keyed decision, resolved/captain-held
#     close one, and a done:/failed: declaration clears the whole set when the
#     task's kind is ship or scout);
#   - the Pi extension's exported `scopeForUnreadWake`
#     (.pi/extensions/lib/fm-branch-dispatch.ts);
#   - the Claude mod's exported `scopeForUnreadWake`
#     (.claude/mods/fm-branch-mod/hooks/branch.ts), bound through its exported
#     `bind` - both exports are behavior-neutral and exist so this test can
#     drive the real implementation instead of a re-implementation;
#   - the shared module .claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts
#     (the bash v8 fold plus the guards the ports carry, one owner for the
#     fold the other three restate), driven through the repo wrapper's
#     (lib/fm-branch-eligibility.ts) scanStateDirectory and foldStatusLog
#     bindings. The lib leg must be byte-equal to the bash leg on every
#     fixture, including the drift cases below. The mod consumes the same
#     canonical module directly, bound via its host stat seam, so all three
#     TypeScript legs share one fold.
# One fixture set (status logs, wake-queue rows, task metas) is driven through
# all four, and the TypeScript legs must emit byte-identical normalised scope
# JSON wherever the folds agree. Bash contributes the fold truth alone:
# no bash-side eligible-row scan exists (the extension computes the eligible
# snapshot and bin/fm-wake-drain.sh consumes it), so the bash leg pins
# `status_open_decisions` output and the join between fold truth and scope.
# The Pi extension and the mod both consume the shared canonical module
# (A2/A3), so both are pinned byte-equal to bash on every fixture, drift
# cases included:
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-eligibility)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the branch-eligibility equivalence checks"; exit 0; }

# Pin the fold vocabulary and home overrides: an ambient FM_CLASSIFY_* export
# or home override would decide the verdicts this equivalence compares, so
# every leg runs with them cleared and the documented defaults in force.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB FM_CLASSIFY_RESERVED_KEY_PREFIXES

build_fixtures() {
  local fx="$TMP_ROOT/fx"
  # Plain routine signal row for a working ship task.
  mkdir -p "$fx/routine"
  printf 'working: implementing the fix\n' >"$fx/routine/ship-a.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/routine/ship-a.meta"
  printf '1\t1\tsignal\tship-a.status\tsignal: working\n' >"$fx/routine/.wake-queue"
  # The v8 row: open needs-decision then a done: declaration (terminal close).
  mkdir -p "$fx/v8-ship"
  printf 'needs-decision [key=dep]: waiting on captain\ndone: PR https://example.com/pr/1 checks green\n' >"$fx/v8-ship/ship-b.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/v8-ship/ship-b.meta"
  printf '2\t2\tstale\tship-b\tstale: waiting too long\n' >"$fx/v8-ship/.wake-queue"
  # Scout terminal: open blocked then failed: (terminal close covers scout).
  mkdir -p "$fx/scout-terminal"
  printf 'blocked [key=deps]: upstream broke the API\nfailed: reproduced and reported upstream\n' >"$fx/scout-terminal/scout-c.status"
  printf 'kind=scout\nproject=demo\n' >"$fx/scout-terminal/scout-c.meta"
  printf '3\t3\tstale\tscout-c\tstale: waiting too long\n' >"$fx/scout-terminal/.wake-queue"
  # Symlinked status log over a log holding an open decision (bash truth:
  # refusal means an empty fold, so the stale row stays branch-eligible; a
  # read-through fold would mark it decision-owned instead).
  mkdir -p "$fx/symlink-log"
  printf 'needs-decision [key=dep]: pick\n' >"$fx/symlink-log/ship-d-real.status"
  ln -s ship-d-real.status "$fx/symlink-log/ship-d.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/symlink-log/ship-d.meta"
  printf '4\t4\tstale\tship-d\tstale: waiting too long\n' >"$fx/symlink-log/.wake-queue"
  # Torn epoch field in the queue row (non-numeric epoch, valid seq).
  mkdir -p "$fx/torn-epoch"
  printf 'working: on it\n' >"$fx/torn-epoch/ship-e.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/torn-epoch/ship-e.meta"
  printf 'torn\t5\tsignal\tship-e.status\tsignal: working\n' >"$fx/torn-epoch/.wake-queue"
  # Secondmate control: a secondmate's done: never clears an open decision.
  mkdir -p "$fx/secondmate-held"
  printf 'needs-decision [key=gate]: captain pick\ndone: unrelated cleanup finished\n' >"$fx/secondmate-held/mate-f.status"
  printf 'kind=secondmate\nproject=demo\n' >"$fx/secondmate-held/mate-f.meta"
  printf '6\t6\tstale\tmate-f\tstale: waiting too long\n' >"$fx/secondmate-held/.wake-queue"
  # Reserved-key namespace guard: a reserved key moves only when the note
  # speaks its own vocabulary. mate-g opens one properly (fold keeps it),
  # mate-h's non-speaking line is ignored entirely (fold stays empty), and
  # mate-i opens an ordinary key (fold keeps it).
  mkdir -p "$fx/reserved-prefix"
  printf 'needs-decision [key=pending-reply-m1]: pending-reply-m1: awaiting parent answer\n' >"$fx/reserved-prefix/mate-g.status"
  printf 'kind=secondmate\nproject=demo\n' >"$fx/reserved-prefix/mate-g.meta"
  printf 'needs-decision [key=pending-reply-m2]: captain pick\n' >"$fx/reserved-prefix/mate-h.status"
  printf 'kind=secondmate\nproject=demo\n' >"$fx/reserved-prefix/mate-h.meta"
  printf 'needs-decision [key=plain]: pick one\n' >"$fx/reserved-prefix/mate-i.status"
  printf 'kind=secondmate\nproject=demo\n' >"$fx/reserved-prefix/mate-i.meta"
  printf '7\t7\tstale\tmate-g\tstale: waiting too long\n8\t8\tstale\tmate-h\tstale: waiting too long\n9\t9\tstale\tmate-i\tstale: waiting too long\n' >"$fx/reserved-prefix/.wake-queue"
  # Verb overrides (FM_CLASSIFY_RESOLVE_VERB=ack, FM_CLASSIFY_CAPTAIN_HELD_VERB=hold):
  # the fold closes through ack, and the held declaration is hold.
  mkdir -p "$fx/overridden-verbs"
  printf 'needs-decision [key=swap]: pick a name\nack [key=swap]: decided\nhold: waiting on captain review\n' >"$fx/overridden-verbs/ship-h.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/overridden-verbs/ship-h.meta"
  printf '10\t10\tstale\tship-h\tstale: waiting too long\n' >"$fx/overridden-verbs/.wake-queue"
  printf '%s\n' "$fx"
}

FIXTURES=$(build_fixtures)

# The Pi leg: import the real extension module and classify the fixture state.
pi_scope() { # <state-dir> -> normalised scope JSON
  FM_ELIGIBILITY_ROOT="$ROOT" node "$TMP_ROOT/pi-scope.mjs" "$1"
}

# The mod leg: import the real hooks module, bind its module state to the
# fixture state through the exported bind, then classify.
mod_scope() { # <state-dir> -> normalised scope JSON
  FM_ELIGIBILITY_ROOT="$ROOT" FM_STATE_OVERRIDE="$1" node "$TMP_ROOT/mod-scope.mjs"
}

# The bash leg: the authoritative fold through its public entry point, with
# the kind resolved from the task's meta exactly as production resolves it.
bash_fold() { # <state-dir> <task> -> v8 open set, or empty
  bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2/$3.status"' _ "$ROOT" "$1" "$2"
}

# The lib leg: the shared module bound to the fixture state directory. Its
# fold output must be byte-equal to bash_fold's on every fixture, and its
# scope normalises to the same shape the two port legs emit.
lib_scope() { # <state-dir> -> normalised scope JSON
  FM_ELIGIBILITY_ROOT="$ROOT" node "$TMP_ROOT/lib-scope.mjs" "$1"
}
lib_fold() { # <state-dir> <task> -> v8 open-set bytes, or empty
  FM_ELIGIBILITY_ROOT="$ROOT" node "$TMP_ROOT/lib-fold.mjs" "$1" "$2"
}

write_runners() {
  # Normalised scope shape shared by all three TS legs: the mod Scope carries
  # eligibleWakeKey/allSeqs and the Pi scope carries projects/checkSeqs/
  # heartbeatSeqs/taskByWakeKey, which have no counterpart on the other side;
  # the compared fields are the ones all three expose with the same meaning.
  cat >"$TMP_ROOT/pi-scope.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const { scopeForUnreadWake } = await import(pathToFileURL(`${root}/.pi/extensions/lib/fm-branch-dispatch.ts`).href);
const norm = (s) => JSON.stringify({
  status: s.status,
  eligible: s.eligible,
  corrupted: s.corrupted,
  eligibleSeqs: [...new Set(s.eligibleSeqs)].sort(),
  eligibleTasks: [...new Set(s.eligibleTasks)].sort(),
  needsDecision: [...new Set(s.needsDecisionKeys)].sort(),
});
for (const dir of process.argv.slice(2)) {
  process.stdout.write(`${norm(scopeForUnreadWake(dir, false, false))}\n`);
}
JS
  cat >"$TMP_ROOT/mod-scope.mjs" <<'JS'
import { existsSync, lstatSync, readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const stateDir = process.env.FM_STATE_OVERRIDE;
if (!stateDir) throw new Error("FM_STATE_OVERRIDE required");
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
// The host seam the fold reads through, backed by node:fs with its documented
// read/list/exists behavior; stat carries the host's lstat shape (isLink true
// for the link itself, the target's size/mtime when it resolves) and throws
// ENOENT on a missing path. The fs methods are awaited exactly as the mod
// awaits the host they stand in for.
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  session: { cwd: async () => process.cwd() },
  env: { get: async (name) => process.env[name] ?? "" },
  fs: {
    read: async (path) => {
      if (!existsSync(path)) throw new Error(`ENOENT: ${path}`);
      return readFileSync(path, "utf8");
    },
    stat: async (path) => {
      const st = lstatSync(path);
      if (st.isSymbolicLink()) return { kind: "other", size: st.size, mtimeMs: st.mtimeMs, isLink: true };
      return {
        kind: st.isFile() ? "file" : st.isDirectory() ? "dir" : "other",
        size: st.size,
        mtimeMs: st.mtimeMs,
        isLink: false,
      };
    },
    list: async (dir) => readdirSync(dir, { withFileTypes: true }),
    exists: async (path) => existsSync(path),
  },
};
if (typeof mod.bind !== "function") throw new Error("branch.ts does not export bind");
if (typeof mod.scopeForUnreadWake !== "function") throw new Error("branch.ts does not export scopeForUnreadWake");
await mod.bind($, process.cwd());
const norm = (s) => JSON.stringify({
  status: s.status,
  eligible: s.eligible,
  corrupted: s.corrupted,
  eligibleSeqs: [...new Set(s.eligibleSeqs)].sort(),
  eligibleTasks: [...new Set(s.eligibleTasks)].sort(),
  needsDecision: [...new Set(s.needsDecisionTasks)].sort(),
});
process.stdout.write(`${norm(await mod.scopeForUnreadWake($, false))}\n`);
JS
  cat >"$TMP_ROOT/lib-scope.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const { scanStateDirectory } = await import(pathToFileURL(`${root}/lib/fm-branch-eligibility.ts`).href);
const norm = (s) => JSON.stringify({
  status: s.status,
  eligible: s.eligible,
  corrupted: s.corrupted,
  eligibleSeqs: [...new Set(s.eligibleSeqs)].sort(),
  eligibleTasks: [...new Set(s.eligibleTasks)].sort(),
  needsDecision: [...new Set(s.needsDecisionTasks)].sort(),
});
for (const dir of process.argv.slice(2)) {
  process.stdout.write(`${norm(scanStateDirectory(dir))}\n`);
}
JS
  cat >"$TMP_ROOT/lib-fold.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const { foldStatusLog } = await import(pathToFileURL(`${root}/lib/fm-branch-eligibility.ts`).href);
const [dir, task] = process.argv.slice(2);
process.stdout.write(foldStatusLog(dir, task));
JS
}

write_runners

test_routine_signal_row_agrees_across_all_folds() {
  local dir="$FIXTURES/routine" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "routine: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "routine: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-a")
  lib=$(lib_scope "$dir") || fail "routine: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "ship-a")
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["1"],"eligibleTasks":["ship-a"],"needsDecision":[]}' "$pi" "routine: pi scope"
  assert_equals "$pi" "$mod" "routine: pi and mod scopes must be byte-identical"
  assert_equals "$pi" "$lib" "routine: lib scope agrees with the ports"
  assert_equals "" "$fold" "routine: bash fold must be empty (nothing holds ship-a)"
  assert_equals "$fold" "$libfold" "routine: lib fold is byte-equal to the bash fold"
  pass "a plain routine signal row classifies identically in bash, the Pi extension, the mod, and the shared lib"
}

test_ship_terminal_declaration_agrees_across_all_folds() {
  # Bash truth: done: on a ship task clears the whole open set, so nothing
  # holds ship-b and its stale row stays branch-eligible. The Pi extension
  # consumes the shared module, so it applies the same terminal close as
  # bash, the mod, and the lib; the drift this case once asserted retired
  # when the Pi fold adopted the rule.
  local dir="$FIXTURES/v8-ship" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "v8: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "v8: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-b")
  lib=$(lib_scope "$dir") || fail "v8: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "ship-b")
  assert_equals "" "$fold" "v8: bash truth - the terminal done: must empty the fold for a ship task"
  assert_equals "$fold" "$libfold" "v8: lib fold is byte-equal to the bash fold"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["2"],"eligibleTasks":["ship-b"],"needsDecision":[]}' "$pi" "v8: pi applies the terminal close (row branch-eligible)"
  assert_equals "$pi" "$mod" "v8: pi and mod scopes must be byte-identical"
  assert_equals "$pi" "$lib" "v8: lib scope agrees with the ports"
  pass "a ship task's terminal done: classifies identically in bash, the Pi extension, the mod, and the shared lib"
}

test_scout_blocked_then_failed_agrees_across_all_folds() {
  # Bash truth: failed: on a scout task clears the open blocked key, so the
  # stale row stays branch-eligible. The Pi extension consumes the shared
  # module, so its fold applies the same terminal close for a scout kind.
  local dir="$FIXTURES/scout-terminal" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "scout: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "scout: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "scout-c")
  lib=$(lib_scope "$dir") || fail "scout: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "scout-c")
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["3"],"eligibleTasks":["scout-c"],"needsDecision":[]}' "$pi" "scout: pi scope"
  assert_equals "$pi" "$mod" "scout: pi and mod scopes must be byte-identical"
  assert_equals "$pi" "$lib" "scout: lib scope agrees with the ports"
  assert_equals "" "$fold" "scout: bash truth - the terminal failed: must empty the fold for a scout task"
  assert_equals "$fold" "$libfold" "scout: lib fold is byte-equal to the bash fold"
  pass "a scout task with open blocked then failed: classifies identically in bash, the Pi extension, the mod, and the shared lib"
}

test_symlinked_status_log_is_bash_truth_in_all_four_legs() {
  # Bash truth: status_open_decisions refuses a symlinked status log outright,
  # which names an empty fold - nothing holds ship-d and its stale row stays
  # branch-eligible. The lib takes bash's outcome, the Pi extension consumes
  # the lib, and the mod consumes the canonical module whose host stat seam
  # refuses a symlinked log the same way, so all four agree.
  local dir="$FIXTURES/symlink-log" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "symlink: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "symlink: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-d")
  lib=$(lib_scope "$dir") || fail "symlink: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "ship-d")
  assert_equals "" "$fold" "symlink: bash truth - the refusal must name an empty fold"
  assert_equals "$fold" "$libfold" "symlink: lib fold is byte-equal to the bash fold"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["4"],"eligibleTasks":["ship-d"],"needsDecision":[]}' "$lib" "symlink: lib takes bash's outcome (empty fold, row branch-eligible)"
  assert_equals "$lib" "$pi" "symlink: pi takes bash's outcome through the shared module"
  assert_equals "$lib" "$mod" "symlink: the mod takes bash's outcome through the canonical module and the host stat seam"
  pass "the symlink refusal names bash truth (branch-eligible); the Pi extension and the mod agree through the shared fold"
}

test_torn_epoch_row_refuses_the_scan_in_every_queue_scanner() {
  # The mod, the lib, and the Pi extension through the shared module all
  # validate the epoch field digit-wise and refuse the scan on a torn row.
  # Bash has no queue scan to contribute; its fold on the task's own log
  # names the empty truth, which the lib's fold is byte-equal to.
  local dir="$FIXTURES/torn-epoch" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "epoch: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "epoch: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-e")
  lib=$(lib_scope "$dir") || fail "epoch: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "ship-e")
  assert_equals "" "$fold" "epoch: the task's own log holds no decision"
  assert_equals "$fold" "$libfold" "epoch: lib fold is byte-equal to the bash fold"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":true,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":[]}' "$pi" "epoch: pi refuses the scan on the non-numeric epoch"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":true,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":[]}' "$mod" "epoch: the mod refuses the scan on the non-numeric epoch"
  assert_equals "$mod" "$lib" "epoch: lib joins the mod's stricter epoch validation (bash has no queue opinion)"
  assert_equals "$pi" "$mod" "epoch: pi and mod scopes must be byte-identical"
  pass "a torn-epoch queue row refuses the scan in the Pi extension, the mod, and the lib alike"
}

test_secondmate_terminal_declaration_does_not_close_the_decision_anywhere() {
  # A secondmate's done: may describe unrelated work, so no fold clears an
  # open decision on it: bash keeps the key, the mod skips the clear for a
  # secondmate kind, the lib's bash-truth fold keeps it, and pi never clears.
  # All four must agree the row is decision-owned and the scope is
  # main-owned (unsafe, nothing eligible).
  local dir="$FIXTURES/secondmate-held" pi mod fold lib libfold
  pi=$(pi_scope "$dir") || fail "secondmate: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "secondmate: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "mate-f")
  lib=$(lib_scope "$dir") || fail "secondmate: lib leg failed: $lib"
  libfold=$(lib_fold "$dir" "mate-f")
  assert_equals "$(printf 'gate\tneeds-decision\tcaptain pick')" "$fold" "secondmate: bash keeps the open key across the terminal line"
  assert_equals "$fold" "$libfold" "secondmate: lib fold is byte-equal to the bash fold"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":false,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":["mate-f"]}' "$pi" "secondmate: pi scope"
  assert_equals "$pi" "$mod" "secondmate: pi and mod scopes must be byte-identical"
  assert_equals "$pi" "$lib" "secondmate: lib scope agrees with the ports"
  pass "a secondmate's terminal declaration holds the open decision in bash, the Pi extension, the mod, and the lib alike"
}

test_reserved_key_namespace_guard_agrees_across_all_folds() {
  # A reserved key moves only when the note speaks its namespace's own
  # vocabulary: mate-g's speaking note opens the decision (fold keeps it, row
  # decision-owned), mate-h's non-speaking line is ignored entirely (fold
  # stays empty, row branch-eligible), and mate-i's ordinary key opens
  # normally (fold keeps it, row decision-owned). All four implementations
  # carry the rule with the documented defaults.
  local dir="$FIXTURES/reserved-prefix" pi mod lib
  pi=$(pi_scope "$dir") || fail "reserved: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "reserved: mod leg failed: $mod"
  lib=$(lib_scope "$dir") || fail "reserved: lib leg failed: $lib"
  assert_equals "$(printf 'pending-reply-m1\tneeds-decision\tpending-reply-m1: awaiting parent answer')" "$(bash_fold "$dir" "mate-g")" "reserved: bash keeps mate-g's properly opened reserved key"
  assert_equals "$(bash_fold "$dir" "mate-g")" "$(lib_fold "$dir" "mate-g")" "reserved: lib fold is byte-equal to the bash fold for mate-g"
  assert_equals "" "$(bash_fold "$dir" "mate-h")" "reserved: bash ignores mate-h's non-speaking reserved-key line"
  assert_equals "$(bash_fold "$dir" "mate-h")" "$(lib_fold "$dir" "mate-h")" "reserved: lib fold is byte-equal to the bash fold for mate-h"
  assert_equals "$(printf 'plain\tneeds-decision\tpick one')" "$(bash_fold "$dir" "mate-i")" "reserved: bash keeps mate-i's ordinary key"
  assert_equals "$(bash_fold "$dir" "mate-i")" "$(lib_fold "$dir" "mate-i")" "reserved: lib fold is byte-equal to the bash fold for mate-i"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["8"],"eligibleTasks":["mate-h"],"needsDecision":["mate-g","mate-i"]}' "$pi" "reserved: pi scope"
  assert_equals "$pi" "$mod" "reserved: pi and mod scopes must be byte-identical"
  assert_equals "$pi" "$lib" "reserved: lib scope agrees with the ports"
  pass "the reserved-key namespace guard classifies identically in bash, the Pi extension, the mod, and the lib"
}

test_verb_overrides_reach_the_bash_and_lib_folds_alike() {
  # FM_CLASSIFY_RESOLVE_VERB/FM_CLASSIFY_CAPTAIN_HELD_VERB reach the bash
  # fold and the lib's environment alike: under ack/hold the swap decision is
  # closed and ship-h is decision-owned through the held declaration; under
  # the documented defaults the same log keeps swap open. The mod hardcodes
  # its vocabulary, so it has no leg here.
  local dir="$FIXTURES/overridden-verbs" fold lib libfold dflt dfltlibfold libscope
  fold=$(FM_CLASSIFY_RESOLVE_VERB=ack FM_CLASSIFY_CAPTAIN_HELD_VERB=hold bash_fold "$dir" "ship-h")
  libfold=$(FM_CLASSIFY_RESOLVE_VERB=ack FM_CLASSIFY_CAPTAIN_HELD_VERB=hold lib_fold "$dir" "ship-h")
  libscope=$(FM_CLASSIFY_RESOLVE_VERB=ack FM_CLASSIFY_CAPTAIN_HELD_VERB=hold lib_scope "$dir")
  dflt=$(bash_fold "$dir" "ship-h")
  dfltlibfold=$(lib_fold "$dir" "ship-h")
  assert_equals "" "$fold" "verbs: bash closes swap through the ack override"
  assert_equals "$fold" "$libfold" "verbs: lib fold is byte-equal to the bash fold under the override"
  assert_equals "$(printf 'swap\tneeds-decision\tpick a name')" "$dflt" "verbs: bash keeps swap open under the documented defaults"
  assert_equals "$dflt" "$dfltlibfold" "verbs: lib fold is byte-equal to the bash fold under the defaults"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":false,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":["ship-h"]}' "$libscope" "verbs: lib scope is decision-owned through the overridden held declaration"
  pass "the FM_CLASSIFY_* verb overrides reach the bash fold and the lib alike, in the fold and the held-declaration verdict"
}

test_routine_signal_row_agrees_across_all_folds
test_ship_terminal_declaration_agrees_across_all_folds
test_scout_blocked_then_failed_agrees_across_all_folds
test_symlinked_status_log_is_bash_truth_in_all_four_legs
test_torn_epoch_row_refuses_the_scan_in_every_queue_scanner
test_secondmate_terminal_declaration_does_not_close_the_decision_anywhere
test_reserved_key_namespace_guard_agrees_across_all_folds
test_verb_overrides_reach_the_bash_and_lib_folds_alike
