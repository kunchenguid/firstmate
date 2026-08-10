#!/usr/bin/env bash
# tests/fm-captain-commitment.test.sh - behavior tests for durable follow-through
# on an explicit captain request.
#
# Reproduces the two real losses with synthetic content: a captain request left
# behind by operational work, and a captain request whose blocker cleared without
# anyone resuming it. Every case drives the real scripts and asserts on their
# printed output, exit status, and the durable record's own fields.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMITMENT="$ROOT/bin/fm-captain-commitment.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-commitment)

HAVE_TASKS_AXI=1
command -v tasks-axi >/dev/null 2>&1 || HAVE_TASKS_AXI=0
HAVE_NODE=1
command -v node >/dev/null 2>&1 || HAVE_NODE=0

needs_tasks_axi() {  # <case-name>
  [ "$HAVE_TASKS_AXI" -eq 1 ] && return 0
  echo "skip: tasks-axi not found for $1"
  return 1
}

# A genuine primary home: plain checkout (not a linked worktree), AGENTS.md, bin/,
# and a state dir, which is exactly what fm-primary-scope-lib.sh requires.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/bin"
  git init -q "$home"
  printf 'synthetic primary home\n' > "$home/AGENTS.md"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

fm() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$COMMITMENT" "$@"
}

task() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@" >/dev/null 2>&1)
}

record="state/captain-commitment/open"

# --- the interrupted captain request ----------------------------------------

# Loss #1: the captain asked for two packages, operational work arrived after the
# interim update, and the second package was never installed. The request must
# survive that interruption as ONE durable actionable item, and the record must
# never contain the captain's words.
test_deferred_request_becomes_one_actionable_item() {
  local home out rc body
  home=$(make_home deferred-request)

  fm "$home" open
  [ -f "$home/$record" ] || fail "a captain turn left no durable record"
  fm "$home" defer

  out=$(fm "$home" check 2>&1)
  rc=$?
  expect_code 2 "$rc" "a deferred captain request must refuse an ordinary turn end"
  assert_contains "$out" "OUTSTANDING CAPTAIN REQUEST" "the refusal must name the outstanding request"
  assert_contains "$out" "not stored anywhere" "the refusal must say the content was not stored"
  assert_contains "$out" "recover it from the visible session" "the refusal must say where to recover it"

  # Privacy: the durable record carries a schema tag, a timestamp, and a flag.
  body=$(cat "$home/$record")
  assert_contains "$body" "fm-captain-commitment.v1" "the record must carry its schema"
  assert_contains "$body" "deferred	yes" "the record must carry the deferred flag"
  if printf '%s' "$body" | grep -Eqv '^(schema|opened|deferred)	'; then
    fail "the durable record carries a field beyond schema/opened/deferred: $body"
  fi

  # One item, not a growing queue: repeated captain turns never fan out.
  fm "$home" open
  fm "$home" open
  [ "$(find "$home/state/captain-commitment" -maxdepth 1 -name open | wc -l | tr -d ' ')" = 1 ] \
    || fail "repeated captain turns produced more than one record"
  pass "a captain request deferred by operational work becomes one durable actionable item, storing no message text"
}

# The refusal must persist across turns, not fire once and forget. This is the
# whole point: the original loss happened because nothing survived the turn.
test_refusal_persists_until_disposed() {
  local home rc i
  home=$(make_home persists)
  fm "$home" open
  fm "$home" defer
  for i in 1 2 3; do
    fm "$home" check >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "turn $i must still refuse while the captain request is outstanding"
  done
  pass "the turn-end refusal persists across turns until the request is disposed"
}

# --- operational input is never captain work --------------------------------

# Watcher wakes, away-mode digests, and the guard's own follow-up must never
# manufacture a commitment, or the mechanism becomes noise that trains reflexive
# dismissal.
test_operational_injection_creates_no_commitment() {
  local home rc
  home=$(make_home operational-only)
  # An operational injection with no captain turn open is a no-op by construction:
  # only `open` creates a record, and only a real captain prompt calls it.
  fm "$home" defer
  [ -f "$home/$record" ] && fail "an operational injection created a captain commitment"
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "an operational-only session must not refuse a turn end"
  pass "a watcher or away-mode injection creates no captain commitment"
}

# --- same-turn completion stays clean ---------------------------------------

test_same_turn_completion_leaves_nothing_behind() {
  local home rc out
  home=$(make_home same-turn)
  fm "$home" open
  fm "$home" "done"
  [ -f "$home/$record" ] && fail "a completed request left a durable record behind"

  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a request finished in the same response must not refuse the turn end"

  out=$(fm "$home" pending)
  [ -z "$out" ] || fail "a completed request printed a reminder: $out"

  # No backlog noise: the item count is unchanged from the empty starting board.
  assert_no_grep '- [' "$home/data/backlog.md" "a same-turn completed request created a backlog item"
  pass "a request finished in the same response creates no backlog item and no reminder"
}

test_completion_clears_the_reminder() {
  local home rc out
  home=$(make_home completion)
  fm "$home" open
  fm "$home" defer
  fm "$home" check >/dev/null 2>&1
  expect_code 2 "$?" "the deferred request must refuse before completion"

  fm "$home" "done"
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "completing the request must clear the refusal"
  out=$(fm "$home" pending)
  [ -z "$out" ] || fail "a completed request still printed a reminder: $out"
  assert_no_grep '- [' "$home/data/backlog.md" "completing the request left a stale work item"
  pass "completing the request clears the reminder and leaves no stale work item"
}

# --- linking to tracked work ------------------------------------------------

# `track` is what discharges the commitment by pointing at real work. It must
# refuse anything that would not actually carry the request forward.
test_track_refuses_work_that_cannot_carry_the_request() {
  needs_tasks_axi test_track_refuses_work_that_cannot_carry_the_request || return 0
  local home out rc
  home=$(make_home track-refusals)
  fm "$home" open

  out=$(fm "$home" track never-filed 2>&1)
  rc=$?
  expect_code 1 "$rc" "track must refuse a backlog item that does not exist"
  assert_contains "$out" "does not exist" "the refusal must name the missing item"

  task "$home" add cc-finished "already finished" --kind ship --body "next: nothing"
  task "$home" "done" cc-finished
  out=$(fm "$home" track cc-finished 2>&1)
  rc=$?
  expect_code 1 "$rc" "track must refuse a Done item"
  assert_contains "$out" "already Done" "the refusal must say the item is Done"

  # The brief requires a clear next action and completion criterion, and the body
  # is where tasks-axi keeps it. An item without one cannot discharge a request.
  task "$home" add cc-bodyless "no body at all" --kind ship
  out=$(fm "$home" track cc-bodyless 2>&1)
  rc=$?
  expect_code 1 "$rc" "track must refuse an item with no next action or completion criterion"
  assert_contains "$out" "has no body" "the refusal must name the missing body"
  assert_contains "$out" "completion criterion" "the refusal must name what is missing"

  [ -f "$home/$record" ] || fail "a refused track discarded the commitment anyway"
  [ -d "$home/state/captain-commitment/linked" ] \
    && [ -n "$(ls -A "$home/state/captain-commitment/linked" 2>/dev/null)" ] \
    && fail "a refused track left a partial link behind"
  pass "track refuses an absent, Done, or bodyless item and keeps the commitment open"
}

test_track_discharges_the_open_record() {
  needs_tasks_axi test_track_discharges_the_open_record || return 0
  local home out rc
  home=$(make_home track-ok)
  fm "$home" open
  fm "$home" defer
  task "$home" add cc-real "install the second package" --kind ship \
    --body "Next: install the second package. Done when it imports cleanly."

  fm "$home" track cc-real || fail "track refused a real item carrying a body"
  [ -f "$home/$record" ] && fail "track left the open record behind"
  [ -f "$home/state/captain-commitment/linked/cc-real" ] || fail "track recorded no link"

  # Still outstanding: the work is filed but dispatchable and not under way, which
  # is loss #2 - the request that was filed and then never resumed.
  out=$(fm "$home" check 2>&1)
  rc=$?
  expect_code 2 "$rc" "filed-but-not-under-way work must still refuse the turn end"
  assert_contains "$out" "tasks-axi done cc-real" "linked work must surface its actual completion command"

  task "$home" "done" cc-real
  out=$(fm "$home" pending)
  [ -z "$out" ] || fail "completed linked work still printed a reminder: $out"
  [ -f "$home/state/captain-commitment/linked/cc-real" ] && fail "completed linked work left a stale marker"
  pass "track keeps idle work outstanding until its surfaced completion command clears it"
}

test_work_under_way_is_quiet() {
  needs_tasks_axi test_work_under_way_is_quiet || return 0
  local home rc
  home=$(make_home under-way)
  fm "$home" open
  task "$home" add cc-moving "under way" --kind ship --body "Next: finish it."
  fm "$home" track cc-moving || fail "track refused a real item"
  task "$home" start cc-moving

  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "work already under way must not refuse the turn end"
  pass "a linked item that is under way is quiet"
}

# --- declared external waits ------------------------------------------------

# The mechanism must not loop, block supervision, or demand impossible progress
# while a declared external wait is open. One turn cannot prove that; several can.
test_declared_external_wait_stays_quiet_across_turns() {
  needs_tasks_axi test_declared_external_wait_stays_quiet_across_turns || return 0
  local home rc i out
  home=$(make_home external-wait)
  fm "$home" open
  fm "$home" defer
  task "$home" add cc-waiting "needs the vendor" --kind ship --body "Next: resume when the vendor replies."
  fm "$home" track cc-waiting || fail "track refused a real item"
  task "$home" hold cc-waiting --reason "waiting on the vendor" --kind external

  for i in 1 2 3 4; do
    fm "$home" check >/dev/null 2>&1
    rc=$?
    expect_code 0 "$rc" "turn $i must stay quiet during a declared external wait"
  done
  out=$(fm "$home" pending)
  [ -z "$out" ] || fail "a declared external wait printed a reminder: $out"

  # And it comes back the moment the wait clears, which is the loss the hold must
  # not become a permanent hiding place for.
  task "$home" unhold cc-waiting
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a cleared external wait must become outstanding again"
  pass "a declared external wait stays quiet across turns and reopens when it clears"
}

test_blocked_work_is_quiet() {
  needs_tasks_axi test_blocked_work_is_quiet || return 0
  local home rc
  home=$(make_home blocked-work)
  fm "$home" open
  task "$home" add cc-blocker "the blocker" --kind ship --body "Next: land it."
  task "$home" add cc-blocked "the request" --kind ship --body "Next: resume after the blocker."
  fm "$home" track cc-blocked || fail "track refused a real item"
  task "$home" block cc-blocked --by cc-blocker

  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a blocked item must not demand impossible progress"
  pass "a blocked linked item is quiet"
}

# --- restart, compaction, and reconciliation --------------------------------

# The record is a single file that `open` never replaces, so recovery is
# non-duplicating by construction rather than by comparing stored message text.
test_restart_retains_one_commitment_without_duplicating() {
  local home first second rc
  home=$(make_home restart)
  fm "$home" open
  first=$(awk -F'\t' '$1 == "opened" { print $2 }' "$home/$record")

  # A restart: session start marks the surviving record deferred, repeatedly.
  fm "$home" defer
  fm "$home" defer
  fm "$home" open
  fm "$home" defer
  second=$(awk -F'\t' '$1 == "opened" { print $2 }' "$home/$record")

  [ "$first" = "$second" ] || fail "recovery reset the request's open time ($first -> $second)"
  [ "$(find "$home/state/captain-commitment" -maxdepth 1 -name open | wc -l | tr -d ' ')" = 1 ] \
    || fail "recovery duplicated the commitment"
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "the commitment must survive restart recovery"
  pass "restart and compaction recovery retain exactly one commitment and do not duplicate it"
}

test_reconcile_clears_only_verified_done_links() {
  needs_tasks_axi test_reconcile_clears_only_verified_done_links || return 0
  local home fakebin out rc
  home=$(make_home reconcile)
  task "$home" add cc-gone "will vanish" --kind ship --body "Next: do it."
  task "$home" add cc-finished2 "will finish" --kind ship --body "Next: do it."
  fm "$home" open
  fm "$home" track cc-gone cc-finished2 || fail "track refused real items"

  task "$home" "done" cc-finished2
  task "$home" rm cc-gone
  fm "$home" reconcile
  [ -f "$home/state/captain-commitment/linked/cc-finished2" ] && fail "a finished link was kept"
  [ -f "$home/state/captain-commitment/linked/cc-gone" ] || fail "a vanished link was discarded"
  out=$(fm "$home" pending)
  assert_contains "$out" "cc-gone" "a vanished linked item must remain visible"
  assert_contains "$out" "fm-captain-commitment.sh untrack cc-gone" "a vanished link must surface its disposal command"
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a vanished linked item must refuse an ordinary turn end"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 75
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" fm "$home" pending)
  assert_contains "$out" "cc-gone" "a transient task read failure must preserve the linked item"
  [ -f "$home/state/captain-commitment/linked/cc-gone" ] || fail "a transient read failure discarded the link"
  PATH="$fakebin:$PATH" fm "$home" untrack cc-gone >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "untrack must refuse when absence cannot be confirmed"
  [ -f "$home/state/captain-commitment/linked/cc-gone" ] || fail "refused untrack discarded the link"

  fm "$home" untrack cc-gone || fail "untrack refused a confirmed-absent linked item"
  [ -f "$home/state/captain-commitment/linked/cc-gone" ] && fail "untrack kept a confirmed-absent link"
  out=$(fm "$home" pending)
  [ -z "$out" ] || fail "untracked absent work still printed a reminder: $out"
  pass "reconcile and untrack clear only verified terminal links"
}

# --- inertness --------------------------------------------------------------

test_silent_while_away_mode_is_active() {
  local home rc out
  home=$(make_home away-mode)
  fm "$home" open
  fm "$home" defer
  : > "$home/state/.afk"

  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "away mode must not raise a turn-end refusal at the captain's absence"

  # The record itself is untouched, and the return path still sees it.
  out=$(fm "$home" pending)
  assert_contains "$out" "OUTSTANDING CAPTAIN REQUEST" "the away-mode return surface must still show the request"

  rm -f "$home/state/.afk"
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "leaving away mode must restore the refusal"
  pass "away mode silences the refusal without losing the request"
}

test_inert_outside_a_primary_home() {
  local home worktree rc
  home=$(make_home scope-primary)
  worktree="$TMP_ROOT/scope-child"
  (cd "$home" && git -c user.email=t@example.com -c user.name=t commit -qm init --allow-empty \
    && git worktree add -q -b child "$worktree") >/dev/null 2>&1 \
    || { echo "skip: git worktree unavailable"; return 0; }
  mkdir -p "$worktree/state" "$worktree/bin"
  printf 'child\n' > "$worktree/AGENTS.md"

  FM_ROOT_OVERRIDE="$worktree" FM_HOME="$worktree" FM_STATE_OVERRIDE="$worktree/state" \
    "$COMMITMENT" open
  [ -f "$worktree/state/captain-commitment/open" ] \
    && fail "a linked crewmate worktree recorded a captain commitment"
  FM_ROOT_OVERRIDE="$worktree" FM_HOME="$worktree" FM_STATE_OVERRIDE="$worktree/state" \
    "$COMMITMENT" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a linked crewmate worktree must never refuse a turn end"
  pass "the follow-through owner is inert outside a genuine primary home"
}

# --- the harness-neutral surface --------------------------------------------

# Every primary gets the durable surface through the drain, which is also what
# puts it in the session-start digest and on the away-mode return path.
test_wake_drain_surfaces_the_outstanding_request() {
  local home out
  home=$(make_home drain-surface)
  fm "$home" open
  fm "$home" defer

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>&1) \
    || fail "the drain failed with an outstanding captain request"
  assert_contains "$out" "OUTSTANDING CAPTAIN REQUEST" "the empty-queue drain must surface the request"

  printf 'signal: task1\n' > "$home/state/.wake-queue"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>&1) \
    || fail "the drain failed on the drained path"
  assert_contains "$out" "OUTSTANDING CAPTAIN REQUEST" "the drained path must surface the request too"

  fm "$home" "done"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>&1) \
    || fail "the drain failed after the request was completed"
  assert_not_contains "$out" "OUTSTANDING CAPTAIN REQUEST" "the drain must go silent once the request is done"
  pass "the wake drain surfaces the outstanding request on both paths and goes silent when it is done"
}


# --- the Pi primary integration ---------------------------------------------

# Builds a synthetic repo carrying the real extension, the real operational-input
# classifier, and stubs for everything the extension spawns. The commitment stub
# logs the subcommand it was asked for, which is what these cases assert on.
# Each driver script is written to a file rather than piped through a here-document
# inside a command substitution, because Bash 3.2 mis-parses a quoted here-document
# body there as soon as it contains an apostrophe or a backtick.
make_pi_repo() {  # <name> <guard-exit> <commitment-exit>
  local repo="$TMP_ROOT/$1" guard_exit=$2 commitment_exit=$3
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$TMP_ROOT/$1-home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  cat > "$repo/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "\${FM_GUARD_LOG:?}"
printf 'synthetic supervision failure\n' >&2
exit $guard_exit
SH
  cat > "$repo/bin/fm-captain-commitment.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FM_COMMITMENT_LOG:?}"
[ "\$1" = check ] || exit 0
printf 'A captain request from 2026-08-09T00:00:00Z has no recorded completion.\n' >&2
exit $commitment_exit
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-captain-commitment.sh" \
    "$repo/bin/fm-arm-pretool-check.sh"
  printf '%s\n' "$repo"
}

run_pi_driver() {  # <repo> <home> <driver-path>
  PLUGIN="$1/.pi/extensions/fm-primary-turnend-guard.ts" FM_HOME="$2" \
    FM_COMMITMENT_LOG="$2.commitment.log" FM_GUARD_LOG="$2.guard.log" \
    node "$3" 2>&1
}

# Classification happens on the raw submitted prompt and nowhere else, so an
# operational injection can never be mistaken for captain work whatever its body
# says, and a real captain message needs no magic tag or special command.
test_pi_extension_opens_only_on_a_real_captain_message() {
  local repo home driver out status
  [ "$HAVE_NODE" -eq 1 ] || { echo "skip: node not found for the Pi integration"; return 0; }
  repo=$(make_pi_repo pi-classify 0 0)
  home="$TMP_ROOT/pi-classify-home"
  driver="$TMP_ROOT/pi-classify.mjs"
  cat > "$driver" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, async sendUserMessage() {} };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

const start = handlers.get("before_agent_start");
if (!start) throw new Error("before_agent_start handler was not registered");

const captain = "install both pi packages please";
const injections = [
  ["⁣FIRSTMATE_OP: v1 watcher: signal: task1", "watcher"],
  ["⁣FIRSTMATE_OP: v1 away-supervisor: batched digest", "away-supervisor"],
  ["⁣FIRSTMATE_OP: v1 turn-end-guard: TURN WOULD END BLIND", "turn-end-guard"],
  ["⁣FIRSTMATE_OP: v1 session-start: digest", "session-start"],
  ["[fm-from-firstmate]⁣routed work", "from-firstmate"],
];

await start({ type: "before_agent_start", prompt: captain }, {});
for (const [prompt] of injections) {
  await start({ type: "before_agent_start", prompt }, {});
}
await handlers.get("session_compact")?.({ type: "session_compact" }, {});

const seen = readFileSync(process.env.FM_COMMITMENT_LOG, "utf8").trim().split("\n");
const expected = ["open"].concat(injections.map((i) => "defer " + i[1]), ["defer"]);
if (seen.join(",") !== expected.join(",")) {
  throw new Error("classification produced " + seen.join(",") + ", expected " + expected.join(","));
}
JS
  out=$(run_pi_driver "$repo" "$home" "$driver")
  status=$?
  expect_code 0 "$status" "the Pi extension must open only on a real captain message"
  [ -z "$out" ] || fail "Pi classification test printed output: $out"
  pass ".pi primary extension: only a real captain message opens a commitment; each injection defers with its kind"
}

# A wake lands within seconds of most captain turns in a busy fleet. If every
# operational kind counted as displacement the guard would refuse at the end of
# nearly every turn, and a reminder dismissed reflexively stops catching the one
# that mattered. A session-start nudge and this mechanism's own turn-end follow-up
# are structurally not displacement, so they must leave the record alone.
test_defer_ignores_kinds_that_do_not_displace() {
  local home rc kind
  home=$(make_home defer-kinds)

  fm "$home" open
  fm "$home" defer session-start
  fm "$home" defer turn-end-guard
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a startup nudge and the guard's own follow-up must not defer"

  fm "$home" defer watcher
  fm "$home" check >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a watcher interruption must defer the open record"

  # away-mode traffic displaces, and an unrecognized kind fails toward remembering
  # the request rather than silently dropping it.
  for kind in away-supervisor legacy-operational; do
    fm "$home" "done"
    fm "$home" open
    fm "$home" defer "$kind"
    fm "$home" check >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "$kind must defer the open record"
  done
  pass "only operational work that displaces a captain request marks the record deferred"
}

test_pi_extension_surfaces_the_outstanding_request_once() {
  local repo home driver out status
  [ "$HAVE_NODE" -eq 1 ] || { echo "skip: node not found for the Pi integration"; return 0; }
  repo=$(make_pi_repo pi-surface 0 2)
  home="$TMP_ROOT/pi-surface-home"
  driver="$TMP_ROOT/pi-surface.mjs"
  cat > "$driver" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) {
      throw new Error("untyped operational prompt: " + message);
    }
    if (!message.includes("TURN WOULD LEAVE A CAPTAIN REQUEST UNFINISHED")) {
      throw new Error("unexpected prompt: " + message);
    }
    if (!message.includes("has no recorded completion")) {
      throw new Error("prompt dropped the reason the owner gave: " + message);
    }
    if (options?.deliverAs !== "followUp") throw new Error("prompt was not a follow-up");
    // The generated follow-up settles inside this call, exactly as Pi does.
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error("one logical run injected " + prompts + " follow-ups");
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error("the next logical run injected " + (prompts - 1) + " follow-ups");

const checks = readFileSync(process.env.FM_COMMITMENT_LOG, "utf8").trim().split("\n");
if (checks.length !== 2) throw new Error("predicate ran " + checks.length + " times for two logical runs");
const guards = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (guards.length !== 2) throw new Error("guard ran " + guards.length + " times for two logical runs");
JS
  out=$(run_pi_driver "$repo" "$home" "$driver")
  status=$?
  expect_code 0 "$status" "the Pi extension must surface an outstanding request once per logical run"
  [ -z "$out" ] || fail "Pi surfacing test printed output: $out"
  pass ".pi primary extension: an outstanding captain request injects exactly one bounded follow-up per logical run"
}

# A blind turn end has to be repaired first. When that follow-up settles, the
# commitment predicate must run without checking supervision a second time.
test_pi_extension_keeps_supervision_precedence() {
  local repo home driver out status
  [ "$HAVE_NODE" -eq 1 ] || { echo "skip: node not found for the Pi integration"; return 0; }
  repo=$(make_pi_repo pi-precedence 2 2)
  home="$TMP_ROOT/pi-precedence-home"
  driver="$TMP_ROOT/pi-precedence.mjs"
  cat > "$driver" <<'JS'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  async sendUserMessage(message) {
    prompts += 1;
    if (prompts === 1 && !message.includes("TURN WOULD END BLIND")) {
      throw new Error("supervision was not surfaced first: " + message);
    }
    if (prompts === 2 && !message.includes("TURN WOULD LEAVE A CAPTAIN REQUEST UNFINISHED")) {
      throw new Error("commitment was not surfaced after supervision recovery: " + message);
    }
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("agent_settled")({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error("expected supervision then commitment follow-ups, saw " + prompts);
const log = process.env.FM_COMMITMENT_LOG;
if (!existsSync(log) || readFileSync(log, "utf8").trim() !== "check") {
  throw new Error("the follow-through predicate did not run exactly once after supervision recovery");
}
const guards = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (guards.length !== 1) throw new Error("supervision predicate ran " + guards.length + " times");
JS
  out=$(run_pi_driver "$repo" "$home" "$driver")
  status=$?
  expect_code 0 "$status" "supervision must keep precedence over the follow-through check"
  [ -z "$out" ] || fail "Pi precedence test printed output: $out"
  pass ".pi primary extension: supervision precedes follow-through without suppressing it"
}

test_deferred_request_becomes_one_actionable_item
test_refusal_persists_until_disposed
test_operational_injection_creates_no_commitment
test_defer_ignores_kinds_that_do_not_displace
test_same_turn_completion_leaves_nothing_behind
test_completion_clears_the_reminder
test_track_refuses_work_that_cannot_carry_the_request
test_track_discharges_the_open_record
test_work_under_way_is_quiet
test_declared_external_wait_stays_quiet_across_turns
test_blocked_work_is_quiet
test_restart_retains_one_commitment_without_duplicating
test_reconcile_clears_only_verified_done_links
test_silent_while_away_mode_is_active
test_inert_outside_a_primary_home
test_wake_drain_surfaces_the_outstanding_request
test_pi_extension_opens_only_on_a_real_captain_message
test_pi_extension_surfaces_the_outstanding_request_once
test_pi_extension_keeps_supervision_precedence
