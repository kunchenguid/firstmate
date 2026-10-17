#!/usr/bin/env bash
# Behavior tests for the supervision host (bin/fm-supervision-host.sh,
# docs/supervision-host.md): its report surface (bin/fm-branch-report.sh), its dispatch entry
# (bin/fm-branch-dispatch.mjs), the drain's BRANCH OUTCOMES section, and the
# host loop's attended routing, engine bounding, held outcomes, and stand-down.
# tests/supervision-host-helpers.sh owns the shared fixture these cases drive.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# --- report surface -----------------------------------------------------------

test_report_surface_enforces_actor_turn_and_scope() {
  local home state out rc
  home="$TMP_ROOT/report"
  state="$home/state"
  mkdir -p "$state"
  printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' > "$state/.supervision-host-turn"

  out=$(FM_HOME="$home" "$REPORT" --task alpha --verdict routine --summary ok 2>&1); rc=$?
  expect_code 3 "$rc" "a report outside the branch actor must be refused"
  assert_contains "$out" "only the supervision branch reports outcomes" "actor refusal must say why"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t0 "$REPORT" --task alpha --verdict routine --summary ok 2>&1); rc=$?
  expect_code 3 "$rc" "a report for an ended turn must be refused"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task beta --verdict captain --summary 'from memory' 2>&1); rc=$?
  expect_code 3 "$rc" "a report for a task the wake did not name must be refused"
  assert_contains "$out" "names alpha, not beta" "scope refusal must name the wake's task"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task fleet --verdict routine --summary quiet 2>&1); rc=$?
  expect_code 3 "$rc" "a fleet report on a task-scoped wake must be refused"
  [ ! -e "$state/branch-outcomes.jsonl" ] || fail "a refused report touched the outcome store"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict captain --summary 'PR ready' --silent true 2>&1); rc=$?
  expect_code 2 "$rc" "a captain outcome with --silent true must be refused"
  [ ! -e "$state/branch-outcomes.jsonl" ] || fail "a refused silent captain outcome changed the durable store"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict captain --summary 'PR ready' 2>&1); rc=$?
  expect_code 0 "$rc" "an in-scope report must be recorded"
  assert_contains "$out" "recorded seq 1 [captain]" "the report must name its store sequence"
  assert_grep '"task":"alpha"' "$state/branch-outcomes.jsonl" "the outcome store did not receive the report"
  assert_grep '"wake":"signal: alpha.status"' "$state/branch-outcomes.jsonl" "the report did not default its wake to the turn's wake"
  [ "$(cat "$state/.supervision-host-receipts")" = "$(printf 't1\t1\tcaptain\talpha')" ] \
    || fail "the host receipt was not written: $(cat "$state/.supervision-host-receipts")"
  local wake_queue_before
  wake_queue_before=$(cat "$state/.wake-queue" 2>/dev/null || true)
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" \
    --task alpha --verdict routine --summary 'still busy, nothing new, no action taken' --silent true 2>&1); rc=$?
  expect_code 0 "$rc" "a task-level routine no-change outcome may be silent"
  assert_contains "$out" "silent outcome remains in the outcome store" "silent task outcome response lost its durability note"
  assert_grep '"task":"alpha","wake":"signal: alpha.status","verdict":"routine","summary":"still busy, nothing new, no action taken","silent":true' \
    "$state/branch-outcomes.jsonl" "the silent task outcome was not stored"
  [ "$(cat "$state/.wake-queue" 2>/dev/null || true)" = "$wake_queue_before" ] \
    || fail "a silent task outcome queued a captain notification"

  printf 'turn=t2\nrows=5\ntasks=\nunscoped=1\nwake=heartbeat\n' > "$state/.supervision-host-turn"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t2 "$REPORT" --task fleet --verdict routine --summary quiet --silent true 2>&1); rc=$?
  expect_code 0 "$rc" "an unscoped heartbeat turn must accept a silent fleet report"
  pass "report surface: only the branch actor's current turn may report, and only on the tasks its wake names"
}

# The return brief is rendered after the record is archived, so a non-silent
# report made after that may be missing from it: the report queues its relay
# for main, while a report made during the away window only waits for the brief.
test_report_after_the_return_is_queued_for_main() {
  local home state out rc drained queue_before
  home="$TMP_ROOT/report-return"
  state="$home/state"
  mkdir -p "$state"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet' >/dev/null 2>&1 || fail "fixture: could not record the away posture"
  printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' > "$state/.supervision-host-turn"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict routine --summary 'steered while away' 2>&1); rc=$?
  expect_code 0 "$rc" "a report during the away window must be recorded"
  assert_contains "$out" "it waits in the outcome store for MAIN" "a report during the away window waits for the return brief"
  ! grep -qs 'supervision-host-return' "$state/.wake-queue" || fail "a report during the away window must not be queued for main"

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict captain --summary 'PR ready for review' 2>&1); rc=$?
  expect_code 0 "$rc" "a report after the return must be recorded"
  assert_contains "$out" "recorded seq 2 [captain]; the captain has returned, so it is queued for MAIN to relay" \
    "a report after the return must say it is queued for main"
  assert_re $'\tcheck\tsupervision-host-return:2\tcheck: supervision-host outcome 2 for alpha \\[captain\\] was recorded after the captain returned.*relay it to the captain: PR ready for review$' \
    "$state/.wake-queue" "the late outcome must be a durable check wake for main"
  queue_before=$(cat "$state/.wake-queue")
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" \
    --task alpha --verdict routine --summary 'still building; nothing new has happened; no action was taken' --silent true 2>&1); rc=$?
  expect_code 0 "$rc" "a silent report after the return must be recorded"
  assert_contains "$out" "silent outcome remains in the outcome store" "the post-return silent report lost its durability note"
  assert_grep '"task":"alpha","wake":"signal: alpha.status","verdict":"routine","summary":"still building; nothing new has happened; no action was taken","silent":true' \
    "$state/branch-outcomes.jsonl" "the post-return silent outcome was not retained"
  [ "$(cat "$state/.wake-queue")" = "$queue_before" ] || fail "a silent report after the return queued another check wake"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 2 for alpha [captain] was recorded after the captain returned" \
    "main's drain must present the late outcome"
  assert_not_contains "$drained" 'still building; nothing new has happened' "main's drain rendered the post-return silent note"
  pass "report surface: visible late outcomes queue a relay, while silent outcomes remain stored without a wake or note"
}

# --- dispatch entry -----------------------------------------------------------

test_dispatch_entry_scopes_rows_and_renders_the_away_tail() {
  local home state out rc
  home="$TMP_ROOT/dispatch"
  state="$home/state"
  mkdir -p "$state"
  printf 'project=demo\nwindow=fm-demo\n' > "$state/demo.meta"
  append_wake "$state" signal demo.status "signal: $state/demo.status"
  append_wake "$state" check merge "check: merge landed: fixture"

  out=$(FM_HOME="$home" node "$DISPATCH" scope)
  assert_contains "$out" "status=safe" "an attended scan with a resolvable row must be safe"
  assert_contains "$out" "rows=1" "an attended scan must leave the check row to main"
  assert_contains "$out" "tasks=demo" "the signal row must resolve to its task"
  assert_contains "$out" "unscoped=0" "a task-local claim must be scoped"

  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" "rows=1 2" "an away scan must claim the check row too"
  assert_contains "$out" "unscoped=1" "a claimed check row names no task, so the claim is unscoped"

  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=0" "an attended check trigger must stay main's"
  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer --afk)
  assert_contains "$out" "eligible=1" "an away check trigger must be the branch's"
  out=$(printf 'signal: %s\n' "$state/demo.status" | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=1" "an attended signal trigger with a claimable row must be the branch's"
  assert_contains "$out" "rows=1" "the offer must carry the scope it judged"

  printf '[captain] keep it small\n[main] Will do.\n' > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_contains "$out" "MAIN DIALOG MIRROR (read-only context" "an attended wake prompt must open with the mirror header"
  assert_contains "$out" "[captain] keep it small" "the mirror must carry the captain's words"
  assert_not_contains "$out" "POSTURE: AWAY" "an attended wake prompt must carry no away tail"
  : > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_not_contains "$out" "MAIN DIALOG MIRROR" "an empty feed must add nothing"
  rm -f "$home/mirror"
  rc=0
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror" 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "a supplied mirror feed that cannot be read must exit 3, got $rc"
  [ -z "$out" ] || fail "a supplied mirror feed that cannot be read must render no prompt: $out"

  printf 'Away posture (recorded):\n  your words (verbatim):\n    merge nothing\n' > "$home/readback"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --away --readback-file "$home/readback")
  assert_contains "$out" "FIRSTMATE SUPERVISION WAKE: signal: demo.status" "the wake prompt must carry the reason"
  assert_contains "$out" "finish with the bin/fm-branch-report.sh command." "the wake prompt must name the host's report surface"
  assert_contains "$out" "POSTURE: AWAY." "an away wake prompt must carry the posture tail"
  assert_contains "$out" "    merge nothing" "the away tail must carry the record's read-back verbatim"
  pass "dispatch entry: the host reads branch eligibility, the offer rule, and the wake prompt from the Pi branch's own owner"
}

# --- host loop ----------------------------------------------------------------


# BRANCH OUTCOMES belongs to a home that runs the host off Pi: on a Claude
# primary that is the default and an `off` file opts out, while another
# primary still needs the file; wherever the home does not run the host the
# drain and the store's markers are exactly as before, and on Pi the branch
# extension owns the same outcomes.
test_branch_outcomes_only_on_a_host_home_off_pi() {
  local home drained fakes
  home="$TMP_ROOT/drain-scope"
  mkdir -p "$home/state" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record a captain outcome"
  fakes="$TMP_ROOT/drain-scope-fakes"
  mkdir -p "$fakes"
  ln -sf /bin/bash "$fakes/pi"
  ln -sf /bin/bash "$fakes/codex"

  : > "$home/config/supervision-host-off"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Claude home opted out by config/supervision-host-off must not present branch outcomes"
  assert_absent "$home/state/.branch-outcomes-cursor" "a Claude home opted out by config/supervision-host-off must keep the store's read cursor untouched"

  rm -f "$home/config/supervision-host" "$home/config/supervision-host-off"
  drained=$(FM_HOME="$home" "$fakes/codex" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Codex home without config/supervision-host must not present branch outcomes"
  assert_absent "$home/state/.branch-outcomes-cursor" "a Codex home without config/supervision-host must keep the store's read cursor untouched"
  drained=$(FM_HOME="$home" "$fakes/pi" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Pi primary's drain must leave captain outcomes to the branch extension"
  assert_absent "$home/state/.branch-outcomes-cursor" "a Pi primary's drain must not advance the store's read cursor"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1, recorded 0m ago] demo: PR ready for review" "a Claude home without config/supervision-host must present the captain outcome"

  : > "$home/config/supervision-host"
  drained=$(FM_HOME="$home" "$fakes/codex" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1, recorded 0m ago] demo: PR ready for review" "a Codex home with config/supervision-host must present the captain outcome"
  pass "drain: BRANCH OUTCOMES runs on a Claude home by default and on another primary with the file, never with off, and never on Pi"
}

# A fresh captain outcome is never hidden behind older routine outcomes: the
# captain rows come first whatever the routine backlog, the newest routine
# outcomes that fit the byte cap follow, and the older overflow collapses into
# a count that is marked read, so one drain clears the whole backlog.
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow() {
  local home drained pad n
  home="$TMP_ROOT/drain-cap"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  pad=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "x" }')
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record the captain outcome"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 13, recorded 0m ago] demo: PR ready for review" "the captain outcome must be presented despite the routine backlog"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 13" "the captain outcome must carry its acknowledgement"
  [ "$(printf '%s\n' "$drained" | grep -n 'PR ready for review' | cut -d: -f1)" -lt "$(printf '%s\n' "$drained" | grep -n 'routine 12' | cut -d: -f1)" ] \
    || fail "the captain outcome must come before the routine outcomes: $drained"
  assert_contains "$drained" "[seq 12] demo: routine 12" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 " "the oldest routine outcome must collapse into the count"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the routine overflow must collapse into one count"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 \
    || fail "main's acknowledgement of the presented captain outcome was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "one drain must clear the routine backlog, and an acknowledged store must present nothing"
  pass "drain: captain outcomes come first, and routine overflow collapses into a count one drain clears"
}

# Repeated captain outcomes for one task collapse to its newest, one line per
# task; when the byte cap holds rows back, the section shows only the oldest
# contiguous run its acknowledgement covers - a shown task's newer row that
# follows a held-back one waits too, so no presented situation repeats - and
# the next drain shows the rest.
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task() {
  local home drained pad n task
  home="$TMP_ROOT/drain-collapse"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  for n in 1 2 3; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still blocked $n" >/dev/null \
      || fail "fixture: could not record alpha outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 3, newest of 3 for this task, recorded 0m ago] alpha: alpha still blocked 3" "repeated outcomes for one task must collapse to its newest"
  assert_not_contains "$drained" "alpha still blocked 1" "an older outcome for the same task must not be repeated"
  assert_contains "$drained" "[seq 4, recorded 0m ago] beta: beta ready to merge" "another task's outcome must keep its own line"
  assert_contains "$drained" "mark-processed --through 4;" "one acknowledgement must cover every presented task"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 4 >/dev/null 2>&1 || fail "the acknowledgement was refused"

  pad=$(awk 'BEGIN { for (i = 0; i < 535; i++) printf "y" }')
  for n in 1 2 3 4 5 6 7 8; do
    task=task-$n
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "$task" --verdict captain --summary "$task $pad" >/dev/null \
      || fail "fixture: could not record $task"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task task-1 --verdict captain --summary 'task-1 changed again' >/dev/null \
    || fail "fixture: could not record the later task-1 outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES: 3 newer captain outcome(s) are held back (byte cap); they follow on the next drain once these are acknowledged" \
    "the section must count every held-back captain row"
  assert_contains "$drained" "[seq 5, recorded 0m ago] task-1: task-1 $pad" "the first task must show its newest outcome the acknowledgement covers"
  assert_not_contains "$drained" "task-1 changed again" "a row after a held-back one must wait, since the acknowledgement cannot cover it"
  assert_not_contains "$drained" "task-7:" "the cap must hold back the rows past the contiguous run"
  assert_contains "$drained" "mark-processed --through 10;" "the acknowledgement must cover exactly the presented run"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 10 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "task-8: task-8" "a held-back task must follow once the shown tasks are acknowledged"
  assert_contains "$drained" "[seq 13, recorded 0m ago] task-1: task-1 changed again" "the held-back row of a shown task must follow once the run is acknowledged"
  assert_not_contains "$drained" "held back" "the rest must fit once the run is acknowledged"
  assert_contains "$drained" "mark-processed --through 13;" "the acknowledgement must cover the rest"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged situation must not be presented again"
  pass "drain: repeated captain outcomes collapse per task, and the byte cap presents only the run its acknowledgement covers"
}

# The reference experience after a long away window: the drain is the only
# presenter, so the first drain once the away record is gone shows the window
# once - each task's captain outcomes collapsed to one line, routine ones past
# the section's limit as a count - and once main acknowledges them, a second
# drain shows nothing from the window.
test_branch_outcomes_present_a_long_away_window_once() {
  local home drained pad n target
  home="$TMP_ROOT/drain-away-window"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  pad=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf "z" }')
  for n in $(seq 1 40); do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "task-$((n % 4))" --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
    case "$n" in
      10|20|30)
        FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still needs review $n" >/dev/null \
          || fail "fixture: could not record alpha outcome $n" ;;
    esac
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a drain while away must leave the window's outcomes for the return"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 33, newest of 3 for this task, recorded 0m ago] alpha: alpha still needs review 30" "a task's repeated captain outcomes must collapse to its newest"
  [ "$(printf '%s\n' "$drained" | grep -c '] alpha: ')" -eq 1 ] || fail "a task's captain outcomes must take one line: $drained"
  assert_contains "$drained" "[seq 44, recorded 0m ago] beta: beta ready to merge" "another task's captain outcome must keep its own line"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the window's routine overflow must collapse into one count"
  assert_contains "$drained" "routine 40 $pad" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 $pad" "the oldest routine outcome must collapse into the count"
  [ "${#drained}" -lt 8000 ] || fail "a long away window must cost one short drain, got ${#drained} bytes"
  target=$(printf '%s\n' "$drained" | sed -n 's/.*mark-processed --through \([0-9]*\);.*/\1/p')
  [ "$target" = 44 ] || fail "one acknowledgement must cover every captain outcome of the window, got '${target:-none}'"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$target" >/dev/null 2>&1 || fail "the acknowledgement was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a second drain must show nothing from the window"
  pass "drain: a long away window costs one short drain, captain outcomes collapsed per task and routine overflow counted, and nothing from it is shown again"
}

# The section's budgets count bytes: a multibyte summary is cut by whole
# characters so each item and the routine list stay inside their byte caps.
test_branch_outcomes_budgets_count_bytes() {
  local home drained wide n routine_block locale
  wide=$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "\342\234\223" }')
  for locale in '' C; do
    home="$TMP_ROOT/drain-bytes-${locale:-inherited}"
    mkdir -p "$home/state" "$home/config"
    : > "$home/config/supervision-host"
    for n in 1 2 3 4 5 6; do
      FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "wide-$n" --verdict routine --summary "$wide" >/dev/null \
        || fail "fixture: could not record routine outcome $n"
    done
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task wide-cap --verdict captain --summary "$wide" >/dev/null \
      || fail "fixture: could not record the captain outcome"
    drained=$(LC_ALL=$locale FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    assert_contains "$drained" "wide-cap: " "the captain outcome must be presented (locale '$locale')"
    printf '%s\n' "$drained" | LC_ALL=C awk '/^\[seq [0-9]+[^]]*\] wide-/ && length($0) > 599 { bad = 1 } END { exit bad }' \
      || fail "an item exceeded its 599-byte cap (locale '$locale'): $drained"
    printf '%s\n' "$drained" | grep '^\[seq [0-9]*[^]]*\] wide-' | grep -qv ' \[truncated\]$' \
      && fail "an over-long multibyte item was not cut with the truncation marker (locale '$locale'): $drained"
    printf '%s\n' "$drained" | grep '^\[seq [0-9]*[^]]*\] wide-' | perl -ne 'utf8::decode($_) or exit 1' \
      || fail "an item was cut inside a character (locale '$locale')"
    routine_block=$(printf '%s\n' "$drained" | sed -n '/^BRANCH OUTCOMES, ROUTINE/,$p' | grep '^\[seq [0-9]*\] wide-[0-9]')
    [ "$(printf '%s\n' "$routine_block" | LC_ALL=C wc -c | tr -d ' ')" -le 2000 ] \
      || fail "the routine list exceeded its 2000-byte budget (locale '$locale'): $routine_block"
    assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
      "the routine rows past the byte budget must collapse into a count (locale '$locale')"
  done
  pass "drain: the BRANCH OUTCOMES budgets count bytes, cutting multibyte summaries by whole characters in any locale"
}

# A drain whose projection of the store fails has rendered nothing it can
# vouch for, so it marks nothing read and exits nonzero for the return's gate.
test_branch_outcomes_stay_unread_when_a_projection_fails() {
  local home drained rc
  home="$TMP_ROOT/drain-projection"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  : > "$home/config/supervision-host"
  printf '#!/usr/bin/env bash\ncase "$*" in *"newest of"*) exit 5 ;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$home/bin/jq"
  chmod +x "$home/bin/jq"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task cap --verdict captain --summary 'needs your merge call' >/dev/null \
    || fail "fixture: could not record the captain outcome"
  rc=0
  drained=$(PATH="$home/bin:$PATH" FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain whose projection failed must exit nonzero: $drained"
  assert_contains "$drained" "BRANCH OUTCOMES SKIPPED: the outcome store could not be projected safely" \
    "a failed projection must be reported"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "a routine outcome behind a failed projection must follow on the next drain"
  assert_contains "$drained" "[seq 2, recorded 0m ago] cap: needs your merge call" "a captain outcome behind a failed projection must follow on the next drain"
  pass "drain: branch outcomes stay unread when a projection of the store fails"
}

# Without jq the drain cannot present the store, so it marks nothing read and
# exits nonzero for the return's gate.
test_branch_outcomes_stay_unread_without_jq() {
  local home drained rc dir entry path=''
  home="$TMP_ROOT/drain-no-jq"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/jq" ]; then
      mkdir -p "$home/no-jq$dir"
      for entry in "$dir"/*; do
        [ "${entry##*/}" = jq ] || ln -s "$entry" "$home/no-jq$dir/" 2>/dev/null || true
      done
      dir="$home/no-jq$dir"
    fi
    path="${path:+$path:}$dir"
  done <<DIRS
$(printf '%s\n' "$PATH" | tr ':' '\n')
DIRS
  PATH="$path" command -v jq >/dev/null 2>&1 && fail "fixture: jq is still reachable"
  rc=0
  drained=$(PATH="$path" FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain without jq over a non-empty store must exit nonzero: $drained"
  assert_contains "$drained" "BRANCH OUTCOMES SKIPPED: jq is not installed" "a drain without jq must say it could not present the store"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "an outcome a drain without jq could not present must follow on the next drain"
  pass "drain: branch outcomes stay unread and the drain fails when jq is missing"
}

# A drain that cannot print the section, because its output is already
# closed, has presented nothing, so the rows stay unread for the next drain.
test_branch_outcomes_stay_unread_when_the_drain_cannot_print() {
  local home drained
  home="$TMP_ROOT/drain-closed"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" >&- 2>/dev/null' "$ROOT/bin/fm-wake-drain.sh" || true
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "a routine outcome a drain could not print must follow on the next drain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "merged the docs fix" "a routine outcome a drain printed must not repeat"
  pass "drain: branch outcomes stay unread when the drain cannot print them"
}

# One store row exactly as bin/fm-branch-outcome.sh append writes it, at a
# chosen epoch, so a case can hold outcomes recorded days before the drain.
outcome_row() {  # <seq> <epoch> <task> <verdict> <summary>
  printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"signal: %s.status","verdict":"%s","summary":"%s","silent":false,"statusEndpoint":0,"statusIdent":"-"}\n' \
    "$1" "$2" "$3" "$3" "$4" "$5"
}

# The cutover a home made when this section first shipped: its away return
# briefs had shown every outcome without advancing the read cursor, so the
# first drain on the new code found days-old outcomes unread. They are still
# presented and never adopted as processed, but each says how long ago it was
# recorded and the section asks for the current state first, so a PR that was
# merged since cannot read as newly ready.
test_branch_outcomes_date_a_legacy_backlog_without_adopting_it() {
  local home now drained
  home="$TMP_ROOT/drain-legacy"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  now=$(date +%s)
  {
    outcome_row 1 $((now - 6 * 86400)) alpha captain 'alpha PR https://github.com/example/repo/pull/101 is green and ready to merge'
    outcome_row 2 $((now - 6 * 86400 + 60)) alpha routine 'alpha rebased'
    outcome_row 3 $((now - 3 * 86400)) beta captain 'beta PR https://github.com/example/repo/pull/102 is green and ready to merge'
  } > "$home/state/branch-outcomes.jsonl"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1, recorded 6d ago] alpha: alpha PR https://github.com/example/repo/pull/101" \
    "a days-old captain outcome must say when it was recorded"
  assert_contains "$drained" "[seq 3, recorded 3d ago] beta: beta PR" "every captain outcome must say when it was recorded"
  assert_contains "$drained" "check the task's current state first" "the section must ask main to check the current state before acting"
  assert_contains "$drained" "your reply to the captain covers only those, as if the settled ones had never been listed, and a settled one needs only the acknowledgement" \
    "the section must keep settled outcomes out of the reply to the captain"
  assert_contains "$drained" "mark-processed --through 3;" "the backlog must still carry its acknowledgement"
  [ -n "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "the drain adopted a legacy captain outcome as processed"
  pass "drain: a legacy backlog is presented with each outcome's age and a check-first instruction, never adopted"
}

# A newer settled branch line must not close an older keyed status decision.
test_branch_ack_keeps_older_keyed_decision_open() {
  local home drained
  home="$TMP_ROOT/drain-older-decision"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold?\n' > "$home/state/held.status"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task held --verdict captain --summary 'needs merge decision' >/dev/null || fail "fixture: older outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task held --verdict captain --summary 'CI is now green' >/dev/null || fail "fixture: newer outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" 'OPEN DECISIONS' "the status decision must appear in the first drain"
  assert_contains "$drained" 'held [key=merge-153] needs-decision: merge PR 153 now or hold?' "the older decision must remain open"
  assert_contains "$drained" '[seq 2, newest of 2 for this task' "the branch line must collapse to the newest outcome"
  assert_contains "$drained" "including its still-open decisions listed above under OPEN DECISIONS" "the check-first instruction must include the older keyed decision"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >/dev/null || fail "fixture: acknowledgement refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" 'held [key=merge-153] needs-decision: merge PR 153 now or hold?' "acknowledging the newer branch line closed the older keyed decision"
  assert_not_contains "$drained" 'CI is now green' "acknowledged branch outcome repeated"
  pass "drain: a keyed decision survives acknowledgement through a newer outcome for its task"
}

# A switch off Pi hands the drain an outcome the branch delivered but main
# never acknowledged; it comes back with its age instead of as news, and is
# still not adopted.
test_branch_outcomes_date_an_outcome_carried_across_a_switch_off_pi() {
  local home drained fakepi
  home="$TMP_ROOT/drain-switch-off-pi"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  fakepi="$TMP_ROOT/fakepi"
  mkdir -p "$fakepi"
  ln -sf /bin/bash "$fakepi/pi"
  outcome_row 1 $(( $(date +%s) - 2 * 86400 )) gamma captain 'gamma needs your decision on the schema migration' \
    > "$home/state/branch-outcomes.jsonl"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 \
    || fail "fixture: could not record the Pi branch's delivery"
  drained=$(FM_HOME="$home" "$fakepi/pi" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Pi primary's drain must leave the outcome to the branch extension"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1, recorded 2d ago] gamma: gamma needs your decision" \
    "an outcome delivered on Pi but never acknowledged must come back with its age"
  [ -n "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "the switch adopted an unacknowledged captain outcome as processed"
  pass "drain: an outcome carried across a switch off Pi comes back with its age, never adopted"
}

# The state a legacy backlog shares with a freshly opted-in home: no read
# cursor, no processed marker, and a captain outcome nothing has shown yet. Any
# cutover skip keyed on those markers would drop this first outcome; it must be
# presented until acknowledged, and a repeated acknowledgement changes nothing.
test_branch_outcomes_keep_an_unshown_outcome_until_acknowledged() {
  local home drained rc
  home="$TMP_ROOT/drain-unshown"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task delta --verdict captain --summary 'delta failed CI twice; needs a call' >/dev/null \
    || fail "fixture: could not record the captain outcome"
  assert_absent "$home/state/.branch-outcomes-cursor" "fixture: the read cursor must start absent"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "delta: delta failed CI twice; needs a call" "the first drain must present an outcome nothing has shown"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "delta: delta failed CI twice; needs a call" "an unacknowledged outcome must keep coming back"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null 2>&1 \
    || fail "the acknowledgement was refused"
  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a repeated acknowledgement must be refused, not re-applied"
  [ "$(cat "$home/state/.branch-outcomes-processed")" = 1 ] || fail "a repeated acknowledgement moved the processed marker"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged outcome must not come back"
  pass "drain: an outcome nothing has shown is presented until acknowledged, and a repeated acknowledgement changes nothing"
}

# A host home whose drain has presented a captain outcome twice without an
# acknowledgement: the read cursor is past it and the processed marker is
# still absent. Sets PRESENTED_HOME.
present_unacknowledged_outcome_twice() {  # <name>
  local drained
  PRESENTED_HOME="$TMP_ROOT/$1"
  mkdir -p "$PRESENTED_HOME/state" "$PRESENTED_HOME/config"
  : > "$PRESENTED_HOME/config/supervision-host"
  FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" append --task epsilon --verdict captain \
    --summary 'epsilon PR is ready to merge' >/dev/null || fail "fixture: could not record the captain outcome"
  for _ in 1 2; do
    drained=$(FM_HOME="$PRESENTED_HOME" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    assert_contains "$drained" "epsilon: epsilon PR is ready to merge" "fixture: the drain must present the captain outcome"
  done
  [ "$(cat "$PRESENTED_HOME/state/.branch-outcomes-cursor")" = 1 ] || fail "fixture: the drain did not advance the read cursor"
  assert_absent "$PRESENTED_HOME/state/.branch-outcomes-processed" "fixture: nothing acknowledged the outcome"
}

# A switch to Pi runs processed-init before reading unprocessed rows. The row
# the host drain presented but main never acknowledged must stay unprocessed
# rather than being adopted from the read cursor.
test_branch_outcomes_keep_a_drain_presented_outcome_across_a_switch_to_pi() {
  present_unacknowledged_outcome_twice drain-switch-to-pi
  FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" processed-init \
    || fail "processed-init failed as the Pi reconciliation runs it"
  assert_contains "$(FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" '"seq":1' \
    "a switch to Pi adopted a drain-presented, unacknowledged outcome as processed"
  pass "drain: an outcome the host drain presented but main never acknowledged stays unprocessed across a switch to Pi"
}

# A lost index-ready marker makes the next drain's status backstop run
# processed-init under the outcome lock before BRANCH OUTCOMES. That repair
# must not adopt the presented but unacknowledged row either.
test_branch_outcomes_keep_a_drain_presented_outcome_across_an_index_repair() {
  local drained
  present_unacknowledged_outcome_twice drain-index-repair
  rm -f "$PRESENTED_HOME/state/.branch-outcome-index-ready"
  printf 'working: rebasing onto main\n' > "$PRESENTED_HOME/state/epsilon.status"
  drained=$(FM_HOME="$PRESENTED_HOME" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  [ -f "$PRESENTED_HOME/state/.branch-outcome-index-ready" ] || fail "the drain's status backstop did not repair the outcome index"
  assert_contains "$drained" "epsilon: epsilon PR is ready to merge" \
    "an index repair adopted a drain-presented, unacknowledged outcome as processed"
  assert_contains "$(FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" '"seq":1' \
    "an index repair left the unacknowledged outcome processed"
  pass "drain: an outcome the host drain presented but main never acknowledged survives an outcome index repair"
}

test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main() {
  local home first drained
  home=$(make_home attended-routine attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "attended: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the attended engine must run as the branch actor"
  assert_no_re '^POSTURE: AWAY' "$first" "an attended wake must carry no away tail"
  assert_re '^(arg=)?FIRSTMATE SUPERVISION WAKE: signal: ' "$first" "the attended wake must carry the close"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "the engine's routine report did not reach the store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended report must queue no return wake for main"
  assert_grep 'it waits in the outcome store for MAIN' "$home/engine-report.log" "an attended routine report must say it stays in the store"
  [ ! -s "$home/host.rc" ] || fail "a routine attended outcome reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a routine attended outcome printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor after an attended wake"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain" \
    "main's next drain must list the routine outcome for awareness"
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "the routine listing must carry the outcome"
  assert_not_contains "$drained" "mark-processed" "a routine outcome must ask for no acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "[seq 1]" "a routine outcome must be listed only once"
  pass "host: an attended wake the branch may take is handled on the engine, and its routine outcome never wakes main"
}

test_attended_captain_outcome_reaches_main_through_branch_outcomes() {
  local home drained
  home=$(make_home attended-captain attended)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "captain: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until 250 host_exited "$home" || fail "captain: the captain outcome did not wake main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a captain-outcome exit must exit 0 for the owner to deliver"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row and send main to its drain"
  assert_no_re '^signal:' "$home/host.out" "the close the engine handled must not reach main as a wake"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "an attended captain report must say main processes it"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended captain report must queue no return wake"
  watcher_live "$home" && fail "the host left its successor cycle running when it woke main"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome"
  assert_contains "$drained" "[seq 1, recorded " "the section must carry the outcome's row and when it was recorded"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome's task and summary"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 1" "the section must print its exact acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub escalated: " "an unacknowledged captain outcome must be presented again"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null \
    || fail "main's acknowledgement of the presented outcome was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged captain outcome must not be presented again"
  pass "host: an attended captain outcome wakes main once and stays in its drain until main acknowledges it"
}

test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return() {
  local home drained
  home=$(make_home attended-go-away attended)
  echo go-away > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "go-away: the host never started a watcher cycle"
  append_status "$home" 'finished while the captain left'
  wait_until 250 handled_at_least "$home" 1 || fail "go-away: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  [ -f "$home/state/.afk-contract" ] || fail "fixture: the stub did not record the away posture"
  [ ! -s "$home/host.rc" ] || fail "a captain outcome recorded after the captain left woke main: $(cat "$home/host.out")"
  assert_grep '"verdict":"captain"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "captain outcomes must wait for the return while the away record exists"
  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub handled demo" "after the return the drain must present the away window's captain outcome"
  pass "host: a captain outcome recorded after the captain left waits for the return, then reaches main's drain"
}

# A quiet record left without its daemon (no state/.afk) is a present captain,
# not an away one: the host runs attended beside it, so a captain outcome wakes
# main and reaches its drain instead of waiting for a return that never comes,
# and a decision close reaches main as the plain arm delivers it.
test_quiet_record_without_its_daemon_is_a_present_captain() {
  local home drained
  home=$(make_home quiet-captain quiet)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until 250 host_exited "$home" || fail "quiet: the captain outcome did not wake the present captain's main: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_no_re '^POSTURE: AWAY' "$home/engine-call.1" "a turn beside a quiet record must carry no away tail"
  assert_re 'MAIN DIALOG MIRROR' "$home/engine-call.1" "a turn beside a quiet record must carry the captain's dialog"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "a captain report beside a quiet record must say main processes it"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row for the present captain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome beside a quiet record"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome"
  [ -f "$home/state/.afk-contract" ] || fail "the host must leave quiet mode's record in place"

  home=$(make_home quiet-main-only quiet)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "quiet main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_re '^signal: .*demo.status' "$home/host.out" "the decision close must reach main as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "quiet main-only: the engine took a decision close from a present captain"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record the attended main-only pass-through"
  pass "host: a quiet record without its daemon is a present captain, so outcomes and decisions reach main"
}

test_attended_main_only_close_passes_straight_to_main() {
  local home
  home=$(make_home attended-main-only attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "main-only: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  pass "host: an attended decision close stays main's exactly as the plain arm delivers it"
}

# The file is read at every wake (docs/configuration.md "Supervision host"), so
# an off written while the host is parked sends the next attended close to main
# exactly as the arm printed it, with the ledger naming the opt-out.
test_off_written_while_parked_passes_the_next_attended_close_to_main() {
  local home
  home=$(make_home attended-off-while-parked attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "off while parked: the host never started a watcher cycle"
  : > "$home/config/supervision-host-off"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "off while parked: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close on a home that opted out must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "off while parked: the engine ran after the home opted out"
  assert_re '	pass-through	attended	the home does not run the supervision host	signal:' "$home/state/.supervision-host.log" \
    "the ledger must name the opt-out as why the close went to main"
  stop_home_processes "$home"
  pass "host: an off written while the host is parked sends the next attended close to main, naming the opt-out"
}

# The live failure this guards: a main-only pass-through used to exit without
# a watcher, so nothing restarted short-lived listeners until the session
# armed again. The close still reaches main unchanged, and the successor
# cycle stays up for the session's next arm to attach to.
test_main_only_pass_through_leaves_the_successor_watcher_running() {
  local home pid
  home=$(make_home main-only-successor attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "successor: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "successor: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "successor: the engine ran for a decision close"
  watcher_live "$home" || fail "successor: the pass-through left no live watcher: $(cat "$home/state/.supervision-host.log")"
  [ "$(marker_kind "$home")" = downtime ] \
    || fail "successor: the pass-through claimed the close was being handled, so main's re-arm owner would not deliver it: $(cat "$home/state/.watcher-down")"
  pid=$(cat "$home/state/.watch.lock/pid")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "successor: the watcher exited after the pass-through (pid $pid)"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "successor: the watcher lock moved after the pass-through"
  pass "host: a main-only pass-through leaves the successor watcher running and the close undelivered for main"
}

# The session-lock holder's process identity cannot be read (its proc entry
# is truncated), so no main-session key exists: the close reaches main exactly
# as the arm printed it, before any mirror feed or engine turn.
test_attended_close_with_unidentified_main_session_passes_to_main() {
  local home
  home=$(make_home attended-unidentified attended)
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s (claude) S\n" "$$" > "$FM_HOME/proc/$$/stat"
      printf "claude\0" > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc"
      "$0" park > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "unidentified: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "unidentified: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close for an unidentified main session must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "unidentified: the engine ran without a main-session key"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_re '	pass-through	attended	the main session could not be identified	signal:' "$home/state/.supervision-host.log" \
    "the ledger must record why the close went to main"
  pass "host: an attended close whose main session cannot be identified reaches main and runs no engine turn"
}

# The close is accepted attended as routine, then its task turns main-only (a
# decision is recorded) while the successor starts: the turn meets the offer
# rule again, so the close reaches main exactly as the arm printed it and no
# engine turn runs on the stale offer.
test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home
  home=$(make_home attended-turns-main-only attended)
  turn_main_only_at_second_offer "$home"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
}

# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.
test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_restarted_host_stops_what_a_killed_predecessor_left() {
  local home first_host arm watcher
  home=$(make_home away-crash away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "crash: the host never started a watcher cycle"
  first_host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$first_host"
  sleep 1
  kill -0 "$arm" 2>/dev/null || fail "crash: fixture error: the arm died with its host, so this case proves nothing"
  start_host "$home"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$arm" "$watcher" \
    || fail "a restarted host left its killed predecessor's arm or watcher running"
  wait_until 100 sh -c 'grep -q "	start	gen=host-" "$1" && [ "$(grep -c "	start	" "$1")" -ge 2 ]' _ "$home/state/.supervision-host.log" \
    || fail "the restarted host did not start"
  pass "host: a restarted host stops, by recorded identity, the cycle a killed predecessor left running"
}

# The 2026-09-25 away-window flood: a held, green PR on a finished task was
# re-escalated on every inactive-outcome cadence, because the branch
# acknowledgement consumed the check row but left its terminal-outcome receipt
# pending, so each later scan re-queued the same fingerprint. Through the real
# watcher cadence, host, report surface, and drain, that unchanged situation
# now reaches the captain exactly once, and a new event on the same task - a
# decision - still reaches the captain path afterwards.
scan_marker_age() {  # <home> -> seconds since the last inactive-outcome scan
  perl -e 'my @s = stat $ARGV[0] or exit 1; print time - $s[9]' "$1/state/.inactive-outcome-reconcile"
}
scan_ran() { [ "$(scan_marker_age "$1" 2>/dev/null || echo 999999)" -lt 60 ]; }
scan_idle() {  # <home>
  [ ! -e "$1/state/.inactive-outcome-reconcile.lock" ] && [ ! -L "$1/state/.inactive-outcome-reconcile.lock" ]
}
captain_rows() {  # <home>
  local rows
  rows=$(grep -c '"verdict":"captain"' "$1/state/branch-outcomes.jsonl" 2>/dev/null)
  printf '%s\n' "${rows:-0}"
}
captain_rows_at_least() { [ "$(captain_rows "$1")" -ge "$2" ]; }
flood_signal() {  # <home>
  captain_rows_at_least "$1" 2 || grep -qs '	inactive-outcome:' "$1/state/.wake-queue"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    wait_until 150 scan_idle "$home" || fail "held: cadence $cycle never finished its scan"
    ! wait_until 10 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}

test_host_outside_the_lock_owner_stands_down() {
  local home out rc other
  home=$(make_home not-owner attended)
  "$FAKE_CLAUDE" -c 'sleep 30' &
  other=$!
  printf '%s\n' "$other" >> "$home/claude-pids"
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$home/fakebin:$PATH" "$HOST" park 2>&1); rc=$?
  expect_code 0 "$rc" "a host that does not own supervision exits 0"
  assert_contains "$out" "supervision-host stood down: this session does not own supervision" "the stand-down must say why"
  watcher_live "$home" && fail "a host that does not own supervision started a watcher"
  kill -TERM "$other" 2>/dev/null || true
  pass "host: a host outside the session-lock owner stands down without arming"
}

test_superseded_host_leaves_the_owner_untouched() {
  local home owner watcher lock_pid
  home=$(make_home superseded away)
  # One fake harness runs the owner host, then, on a signal file, a second host
  # under an auto-arm generation the ledger has already superseded.
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      "$0" park > "$FM_HOME/host.out" 2>&1 &
      while [ ! -e "$FM_HOME/go-second" ]; do sleep 0.1; done
      FM_SUPERVISION_HOST_AUTOARM_GEN=1 FM_SUPERVISION_HOST_OWNER_PID=$$ "$0" park > "$FM_HOME/host2.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host2.rc"
      wait
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "superseded: the owner host never started a watcher cycle"
  owner=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  lock_pid=$(cat "$home/state/.lock")
  printf 'epoch=2 owner_pid=%s outcome=arming\n' "$lock_pid" > "$home/state/.claude-autoarm-epoch"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$lock_pid" "$LEASE" claim demo >/dev/null 2>&1 \
    || fail "fixture: could not hold a branch lease"
  : > "$home/go-second"
  wait_until 200 sh -c '[ -s "$1" ]' _ "$home/host2.rc" || fail "superseded: the second host did not return"
  expect_code 0 "$(cat "$home/host2.rc")" "a superseded host exits 0"
  assert_grep 'supervision-host stood down: this session does not own supervision' "$home/host2.out" "the stand-down must say why"
  kill -0 "$owner" 2>/dev/null || fail "a superseded host stopped the owner host"
  [ "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")" = "$owner" ] \
    || fail "a superseded host took the owner's host record"
  if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
    fail "a superseded host stopped the owner's watcher"
  fi
  FM_HOME="$home" "$LEASE" check demo 2>/dev/null | grep -q '^branch ' || fail "a superseded host released the owner's branch leases"
  kill -TERM "$owner"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$owner" "$watcher" \
    || fail "superseded: the owner host did not stop on TERM"
  pass "host: a host under a superseded auto-arm generation stands down without touching the owner"
}

test_report_surface_enforces_actor_turn_and_scope
test_report_after_the_return_is_queued_for_main
test_dispatch_entry_scopes_rows_and_renders_the_away_tail
test_branch_outcomes_only_on_a_host_home_off_pi
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task
test_branch_outcomes_present_a_long_away_window_once
test_branch_outcomes_budgets_count_bytes
test_branch_outcomes_stay_unread_when_a_projection_fails
test_branch_outcomes_stay_unread_without_jq
test_branch_outcomes_stay_unread_when_the_drain_cannot_print
test_branch_outcomes_date_a_legacy_backlog_without_adopting_it
test_branch_ack_keeps_older_keyed_decision_open
test_branch_outcomes_date_an_outcome_carried_across_a_switch_off_pi
test_branch_outcomes_keep_an_unshown_outcome_until_acknowledged
test_branch_outcomes_keep_a_drain_presented_outcome_across_a_switch_to_pi
test_branch_outcomes_keep_a_drain_presented_outcome_across_an_index_repair
test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main
test_attended_captain_outcome_reaches_main_through_branch_outcomes
test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return
test_quiet_record_without_its_daemon_is_a_present_captain
test_attended_main_only_close_passes_straight_to_main
test_off_written_while_parked_passes_the_next_attended_close_to_main
test_main_only_pass_through_leaves_the_successor_watcher_running
test_attended_close_with_unidentified_main_session_passes_to_main
test_close_accepted_away_that_turns_attended_passes_to_main
test_attended_close_that_turns_main_only_before_its_turn_passes_to_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
test_host_outside_the_lock_owner_stands_down
test_superseded_host_leaves_the_owner_untouched
