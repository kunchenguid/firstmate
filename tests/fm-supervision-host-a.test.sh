#!/usr/bin/env bash
# Behavior tests for the supervision host (bin/fm-supervision-host.sh,
# docs/supervision-host.md): one CI-cost-balanced half of the former combined
# suite. Cases cover the host loop, dialog mirror, latch, park, Stop-hook
# rewake, and report/drain surface against a stub engine. The complementary
# half lives in tests/fm-supervision-host-b.test.sh. Split by measured CI
# per-test cost so each portable serial shard stays under the job cap; see
# docs/fm-test-portable-shards.md.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/fm-supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-helpers.sh"

test_main_only_close_after_handled_turn_delivers_restore_failure() {
  assert_main_only_close_after_handled_turn refuse
  pass "host+hook: a refused inherited handling restore delivers a failure instead of silent success"
}

test_returned_driver_is_caught_away() {
  assert_returned_driver_is_caught away
  pass "host+hook: a driver returning to an idle worker is stale-handled while away"
}

test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn() {
  local home successor
  home=$(make_primary_home hook-successor-closed-before-outcome)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "closed successor: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 600 test -s "$home/stub-ready" || fail "closed successor: the engine did not reach its hold: hook=$(cat "$home/hook.err" 2>/dev/null) host=$(cat "$home/state/.supervision-host.log" 2>/dev/null) mode=$(cat "$home/stub-mode" 2>/dev/null) engine=$(find "$home" -maxdepth 1 -name 'engine-call.*' -exec sh -c 'cat "$1"' _ {} \; 2>/dev/null) errors=$(cat "$home"/engine-errors.* 2>/dev/null)"
  successor=$(cat "$home/state/.watch.lock/pid")
  append_status "$home" 'wake while the engine is handling'
  wait_until 600 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "closed successor: its watcher did not close during the engine turn"
  FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
    || fail "fixture: could not model the queued successor wake entering handling"
  assert_re '^pending:handling:' "$home/state/.watcher-down" \
    "fixture: the closed handling successor must leave the marker in handling before the host hands back"
  printf 'continue\n' > "$home/stub-release"
  wait_until 600 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=rewake ' "$home/state/.claude-autoarm-epoch" \
    "the hand-back must commit the rewake"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor that closes during a held engine turn does not suppress the branch-outcome rewake"
}

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

# The live failure (2026-09-27): a main-only pass-through confirmed a handling
# handoff before the close reached main's re-arm owner, so the Stop hook's
# rewake commit refused and it exited 0 in silence. An idle primary was never
# woken, and the detached successor's own later close reached no reader.
test_claude_stop_hook_delivers_a_main_only_pass_through() {
  local home
  home=$(make_primary_home hook-main-only)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "hook main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "hook main-only"
  assert_re '^signal: .*demo.status' "$home/hook.err" "the rewake must carry the close"
  watcher_live "$home" || fail "hook main-only: the pass-through left no successor watcher"
  pass "host+hook: an attended main-only pass-through rewakes main and keeps its successor watcher"
}

# The live failure (2026-10-17): after the engine handled a routine wake, the
# host parked on the handling successor it started for that wake, and that
# successor never resurfaced a durable row appended later. Five captain inbox
# notes queued over half an hour reached the queue but woke no one until a
# stale close four hours later. A note queued while the host is parked on a
# handled wake's successor must rewake main.
test_claude_stop_hook_rewakes_main_for_an_inbox_note_after_a_handled_wake() {
  local home drained
  home=$(make_primary_home hook-inbox-after-handled)
  ln -s "$ROOT/.agents" "$home/.agents"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "inbox after handled: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 600 handled_at_least "$home" 1 \
    || fail "inbox after handled: the routine wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  wait_until 150 watcher_live "$home" || fail "inbox after handled: the host is not parked on a live successor"
  sleep 2
  hook_exited "$home" && fail "fixture: the handled routine wake reached main: $(cat "$home/hook.err")"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note "the captain sent this from Basecamp" >/dev/null \
    || fail "fixture: the inbox note was not saved and announced"
  assert_grep 'check: captain inbox note' "$home/state/.wake-queue" "fixture: the note queued no wake row"
  wait_until 600 hook_exited "$home" \
    || fail "inbox after handled: the queued inbox note never woke main: $(cat "$home/state/.supervision-host.log"; cat "$home/state/.watcher-down")"
  assert_rewoke_main "$home" "inbox after handled"
  assert_re '^check: rearm-resurface' "$home/hook.err" "the rewake must carry the recovery close for the queued note"
  [ "$(handled_count "$home")" -eq 1 ] || fail "inbox after handled: the engine took the main-only inbox close"
  drained=$(main_drain "$home")
  assert_contains "$drained" 'check: captain inbox note' "main's drain must present the queued inbox note"
  pass "host+hook: an inbox note queued while the host is parked on a handled wake's successor rewakes main"
}

# The live repro (2026-09-28): a quiet record live with no daemon flag parked a
# present Claude captain, whose worker's captain outcomes waited for a return.
# Through the real Stop hook the outcome now rewakes main, with no away note.
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record() {
  local home drained
  home=$(make_primary_home hook-quiet-record)
  # This case runs an engine turn from the primary root, whose prompt reads the skills.
  ln -s "$ROOT/.agents" "$home/.agents"
  FM_HOME="$home" FM_AFK_MODE=quiet "$CONTRACT" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  echo captain > "$home/stub-mode"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook quiet: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'ready for review'
  wait_until 250 hook_exited "$home" || fail "hook quiet: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_rewoke_main "$home" "hook quiet"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the rewake must carry the captain outcome"
  assert_no_grep 'not a return' "$home/hook.err" "a present captain's rewake must not call itself away-posture supervision"
  drained=$(main_drain "$home")
  assert_contains "$drained" " ago] demo: stub escalated: " "main's drain must present the captain outcome beside a quiet record"
  pass "host+hook: a captain outcome beside a quiet record rewakes the present captain with no away note"
}

# Default-on for Claude (docs/configuration.md "Supervision host"): through the
# real Stop hook and mirror writer, a Claude primary home with no
# config/supervision-host runs the host at the default engine, mirrors the
# captain's dialog, and keeps a routine attended wake off main; a home with
# config/supervision-host-off runs the plain watcher arm, mirrors nothing, and every wake
# reaches main as the arm printed it.
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out() {
  local home first
  home=$(make_primary_home hook-default-on)
  ln -s "$ROOT/.agents" "$home/.agents"
  rm -f "$home/config/supervision-host"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "default-on: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  assert_grep 'watch the fleet for me' "$home/state/.host-mirror.jsonl" "a Claude home without the file must mirror the captain's dialog"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "default-on: the wake was not handled on the engine: $(cat "$home/hook.err" 2>/dev/null; cat "$home/state/.supervision-host.log" 2>/dev/null)"
  first="$home/engine-call.1"
  assert_re '^arg=sonnet$' "$first" "a Claude home without the file must run the Claude engine at its default model"
  assert_re '^primary=claude$' "$first" "the engine must carry the Claude primary pin"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  [ ! -s "$home/hook.rc" ] || fail "a routine attended wake on a Claude home without the file reached main: $(cat "$home/hook.err")"
  watcher_live "$home" || fail "default-on: the host is not parked on a live successor"
  : > "$home/session.stop"
  stop_home_processes "$home"

  home=$(make_primary_home hook-opted-out)
  : > "$home/config/supervision-host-off"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "off: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "off: the Stop hook never closed"
  assert_rewoke_main "$home" "off"
  assert_re '^signal: .*demo.status' "$home/hook.err" "off: the rewake must carry the arm's close"
  assert_no_re '^supervision-host' "$home/hook.err" "off: the close must reach main exactly as the arm printed it"
  assert_absent "$home/state/.supervision-host.log" "a home opted out by config/supervision-host-off must never run the host"
  assert_absent "$home/state/.host-mirror.jsonl" "a home opted out by config/supervision-host-off must mirror nothing"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "a home opted out by config/supervision-host-off ran an engine turn"
  : > "$home/session.stop"
  stop_home_processes "$home"
  pass "host+hook: a Claude home without config/supervision-host runs the host at the default engine, and an off file restores the plain arm"
}

# If the at-turn hand-back cannot publish downtime, the healthy successor
# cannot turn that undelivered close into a silent Stop-hook success.
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails() {
  local home real_mktemp
  home=$(make_primary_home hook-turns-main-only-write-fails)
  turn_main_only_at_second_offer "$home"
  real_mktemp=$(command -v mktemp)
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/state/.watcher-down.tmp.'*)
    [ "\$(cat "\$FM_HOME/offer-count" 2>/dev/null)" != 2 ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook write failure: no watcher started"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "hook write failure: the Stop hook did not finish"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close did not turn main-only at its turn"
  assert_re 'pass-through[[:space:]]+downtime-unrestored' "$home/state/.supervision-host.log" "fixture: downtime publication did not fail"
  assert_re '^(pending|announced):handling:' "$home/state/.watcher-down" "fixture: the marker unexpectedly became downtime"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must notify main instead of dropping the close"
  assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "main must receive the failure notification"
  assert_re 'outcome=failed ' "$home/state/.claude-autoarm-epoch" "the failure must be committed"
  pass "host+hook: failed at-turn downtime write notifies main despite a healthy successor"
}

# The successor a pass-through leaves closes while main's rewoken turn is still
# running, so no arm is attached to read it: the next turn end must still
# deliver that close instead of stranding it in the queue.
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end() {
  local home successor drained
  home=$(make_primary_home hook-successor-close)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "successor close: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "successor close: the first close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (first)"
  successor=$(cat "$home/state/.watch.lock/pid")
  main_drain "$home" >/dev/null
  append_status "$home" 'which region?' needs-decision
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" || fail "fixture: the successor did not close on the later decision"
  watcher_live "$home" && fail "the absent opt-in changed the default one-shot successor"
  [ ! -e "$home/state/.supervision-handoff-pending" ] || fail "the absent opt-in queued a hand-back receipt"
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "successor close: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 250 hook_exited "$home" || fail "successor close: the next turn end never closed: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (next turn end)"
  drained=$(main_drain "$home")
  assert_contains "$drained" 'which region?' "the successor's close must reach main's drain"
  watcher_live "$home" || fail "successor close: the next turn end left no watcher"
  pass "host+hook: a successor close that lands during main's turn is delivered at the next turn end"
}

# --- dialog mirror ------------------------------------------------------------

# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.
test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until 200 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}

# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.
test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then echo 120 > "\$FM_HOME/park-clock"; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  echo 0 > "$home/park-clock"
  # The park bound sits past every wall-clock check below, so a host that
  # ignored the test clock could never reach a boundary inside this case.
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  wait_until 250 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  wait_until 250 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  wait_until 250 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}

# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.
test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  wait_until 250 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until 250 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until 2000 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until 250 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until 250 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

# The latch lives only in the opted-in host's away path: an attended close in a
# latched session and a home that dropped config/supervision-host both reach
# main exactly as they do without it.
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes() {
  local home health
  home=$(make_home latch-scope away)
  trip_latch "$home"
  health=$(cat "$home/state/.supervision-host-health")

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  park_again "$home"
  append_status "$home" 'attended while latched'
  wait_until 250 host_exited "$home" || fail "latch scope: the attended close did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "an attended close in a latched session must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "an attended close in a latched session must reach main exactly as the arm printed it"
  [ "$(cat "$home/state/.supervision-host-health")" = "$health" ] || fail "an attended close changed the latch"
  main_drain_and_ack "$home"

  : > "$home/config/supervision-host-off"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture again"
  park_again "$home"
  append_status "$home" 'away after opting out'
  wait_until 250 host_exited "$home" || fail "latch scope: the close after the opt-out did not reach main"
  assert_re '^supervision-host: the home no longer runs the supervision host$' "$home/host.out" \
    "a home opted out by config/supervision-host-off must hand the close back as the opt-out, not the latch"
  assert_no_re 'paused' "$home/host.out" "a home opted out by config/supervision-host-off must not read the latch"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "an engine ran after the latch tripped"
  pass "host: an attended close in a latched session reaches main as the arm printed it and leaves the latch as it was, and a home that opted out with off never reads it"
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

# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed. The bound also stays well past every
# wall-clock check in the case: a host that ignored the test clock would start
# the second turn instead of silently passing at a wall-clock boundary.
test_park_boundary_holds_under_back_to_back_closes() {
  # The turn bound is the one wall-clock bound left: it must cover the stub's
  # report work after release, so the product never kills the held turn.
  local home park=300 turn=19 grace=1
  home=$(make_home boundary-busy away)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  echo 0 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-busy: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'the first of many'
  wait_until 450 sh -c '[ -e "$1/engine-call.1" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-busy: the host never started the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -e "$home/engine-call.1" ] \
    || fail "boundary-busy: the host exited without starting the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  append_status "$home" 'queued while the first close is still handled'
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/stub-release"
  printf 'release\n' >&3
  wait_until 450 host_exited "$home" \
    || fail "the host kept handling back-to-back closes past its park boundary: $(cat "$home/state/.supervision-host.log")"
  exec 3>&-
  ! grep -q '	failed	' "$home/state/.supervision-host.log" \
    || fail "the held turn hit its turn bound or failed: $(cat "$home/state/.supervision-host.log")"
  [ "$(handled_count "$home")" -eq 1 ] || fail "the held turn did not complete once released: $(cat "$home/state/.supervision-host.log")"
  [ ! -e "$home/engine-call.2" ] || fail "a close waiting at the boundary still got an engine turn"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "a close read at the boundary must be printed ahead of the boundary line: $(cat "$home/host.out")"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close waiting at the boundary must stay queued for main"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  pass "host: waiting closes cannot carry the park past its boundary"
}

# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards. The
# park bound stays past the case's wall-clock checks, so an ignored test clock
# would let the turn run and the engine-call assertions catch it.
test_park_boundary_rechecked_just_before_the_engine_turn() {
  local home real_node pid park=120 turn=3 grace=1
  home=$(make_home boundary-late away)
  real_node=$(command -v node)
  mkfifo "$home/render-release"
  echo 0 > "$home/park-clock"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ]; then
  cp "\$FM_HOME/state/.supervision-host" "\$FM_HOME/host-record-at-render" 2>/dev/null
  read -r _ < "\$FM_HOME/render-release"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-late: the host never started a watcher cycle"
  append_status "$home" 'arrives with just enough margin'
  wait_until 300 sh -c '[ -s "$1/host-record-at-render" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-late: the host neither reached the wake render nor exited: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -s "$home/host-record-at-render" ] \
    || fail "the close was stopped before the successor started: $(cat "$home/host.out")"
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/render-release"
  printf 'release\n' >&3
  wait_until 300 host_exited "$home" || fail "boundary-late: the host did not end its park"
  exec 3>&-
  assert_re '^signal: .*demo.status' "$home/host.out" "the close read at the boundary must reach main"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "the close must be printed ahead of the boundary line: $(cat "$home/host.out")"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "an engine turn started that could run past the boundary"
  assert_no_re '	(handled|failed)	turn=' "$home/state/.supervision-host.log" "no engine turn may be logged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close refused at the boundary must stay queued for main"
  while IFS= read -r pid; do
    kill -0 "$pid" 2>/dev/null && fail "the boundary left the successor arm $pid running"
  done < <(awk -F '\t' '$1 == "arm" { print $2 }' "$home/host-record-at-render")
  watcher_live "$home" && fail "the boundary left the watcher running"
  pass "host: a close whose margin runs out while the successor starts reaches main at the boundary without a turn"
}

test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default() {
  park_outcome park-28799 28799
  [ "$PARK_OUTCOME" = handled ] || fail "a park just under the registration must be honored"
  park_outcome park-28800 28800
  [ "$PARK_OUTCOME" = boundary ] || fail "a park at the registration must fall back to the default"
  park_outcome park-huge 100000000000000000000
  [ "$PARK_OUTCOME" = boundary ] || fail "a park far beyond the registration must fall back to the default"
  pass "host: a park at or beyond the Stop-hook registration falls back to the default boundary"
}

# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.
test_first_cycle_status_streams_and_owner_options_reach_it() {
  local home stale fresh generation predecessor
  home=$(make_home stream attended pi)
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" \
    || fail "stream: the first cycle's status did not reach the owner before a close: $(cat "$home/host.out")"
  host_exited "$home" && fail "stream: the host exited before any close: $(cat "$home/host.out")"
  append_status "$home" 'fixture finished' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the attended close did not reach main"
  [ "$(grep -c '^watcher: ' "$home/host.out")" -eq 1 ] || fail "stream: the status line must be printed once: $(cat "$home/host.out")"
  [ "$(sed -n '1p' "$home/host.out" | cut -c1-17)" = 'watcher: started ' ] || fail "stream: the status line must come first"
  assert_re '^signal: .*demo.status' "$home/host.out" "stream: the close must follow the status line"
  # Main handles that close, so the next cycle has no episode to resurface.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$home/drain.err" || fail "stream: main's drain failed"
  ack_drain_err "$home/state" "$home/drain.err" >/dev/null 2>&1 || fail "stream: main's acknowledgement failed: $(cat "$home/drain.err")"
  # Pass-through can leave a successor watcher running. Retire that cycle so
  # the orphan-arm fixture below owns the watcher we later ask --restart to replace.
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null || fail "stream: could not stop the prior cycle"

  # A watcher a dead arm left behind, holding this home's watcher lock.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-watch-arm.sh" \
    > "$home/stale-arm.out" 2>&1 &
  wait_until 150 grep -qs '^watcher: started pid=' "$home/stale-arm.out" \
    || fail "stream: the fixture arm never started its watcher: $(cat "$home/stale-arm.out")"
  wait_until 150 watcher_live "$home" || fail "stream: the fixture watcher never started"
  kill -KILL "$!" 2>/dev/null || true
  wait "$!" 2>/dev/null || true
  stale=$(cat "$home/state/.watch.lock/pid")
  rm -f "$home/host.out" "$home/host.rc"
  start_host "$home" --restart
  # Stopping the old watcher opens a downtime episode, so the fresh cycle may
  # close on its resurface before the arm confirms it, and the arm then prints
  # only that close (bin/fm-watch-arm.sh): either order is the owner's cycle.
  wait_until 150 sh -c 'grep -qs "^watcher: started pid=" "$1/host.out" || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "stream: the restarting host never reported its cycle: $(cat "$home/host.out" "$home/claude.err" 2>/dev/null)"
  fresh=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$home/host.out")
  [ "$fresh" != "$stale" ] || fail "stream: --restart attached to the watcher it should have replaced"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$stale" || fail "stream: --restart left the old watcher running"
  wait_until 200 host_exited "$home" || append_status "$home" 'second close' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the restarting host's close did not reach main"
  assert_re '^(signal: .*demo.status|check: rearm-resurface)$' "$home/host.out" "stream: the restarting host's close must reach main"

  # That close left an unacknowledged downtime episode; a host the owner starts
  # as the closed arm's successor takes it over as a handling successor
  # instead of re-announcing it.
  generation=$(sed -n 's/^[a-z]*:[a-z]*://p' "$home/state/.watcher-down")
  [ -n "$generation" ] || fail "fixture: the close left no downtime episode: $(cat "$home/state/.watcher-down")"
  predecessor=$(sed -n '1p' "$home/claude-pids")
  rm -f "$home/host.out" "$home/host.rc"
  FM_WATCH_PREDECESSOR_ARM_PID=$predecessor start_host "$home" --restart
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" || fail "stream: the successor host never reported its cycle"
  assert_re "^watcher: started pid=[0-9]+ \\(beacon fresh\\) recovery-generation=$generation\$" "$home/host.out" \
    "the owner's predecessor must make the first cycle a handling successor of the pending generation"
  sleep 3
  host_exited "$home" && fail "a handling successor re-announced the pending episode: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "stream: the successor host did not stop on TERM"
  pass "host: the first cycle's status streams once, --restart replaces a stale watcher, and an owner predecessor makes a handling successor"
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

test_tagged_lock_holder_reaches_the_engine_whole() {
  local home first
  home=$(make_home tagged-holder away)
  echo hold-lease > "$home/stub-mode"
  # A Windows/Git Bash home: uname reports MINGW and ps -W lists the session
  # harness the lock names as win:7204; every other ps question is the real one.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" MINGW64_NT-10.0-26200\n' > "$home/fakebin/uname"
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
[ "$*" = -W ] || exec /bin/ps "$@"
printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
printf '%s\n' '  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe'
SH
  chmod +x "$home/fakebin/uname" "$home/fakebin/ps"
  printf 'win:7204\n' > "$home/state/.lock"
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    CLAUDE_PID=7204 CLAUDE_CODE_SESSION_ID=tagged-session \
    bash -c '"$0" park > "$FM_HOME/host.out" 2>&1; printf "%s\n" "$?" > "$FM_HOME/host.rc"' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "tagged: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "tagged: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^holder=win:7204$' "$first" "the engine's lease holder must be the tagged session-lock holder, whole"
  assert_re '^branch win:7204 [0-9]+ live$' "$home/engine-lease.log" \
    "the engine's lease must record the tagged holder whole and read live"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "tagged: the host did not stop on TERM"
  pass "host: a Windows-tagged session-lock holder reaches the engine's lease whole"
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


test_lost_boundary_handoff() { assert_lost_handoff_keeps_watching boundary; }

# The transport fixture exercises the existing busy/composer/submit readers,
# not a Claude run: live continuation acceptance remains a documented limit.
test_handoff_retry_respects_the_receiving_pane() {
  local home doorbell record real_ps
  home=$(make_primary_home handoff-doorbell)
  real_ps=$(command -v ps)
  cat > "$home/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\$1:\$2" = '-o:pgid=,tpgid=' ]; then
  if [ -f "\$FM_HOME/background-session" ]; then printf '77 88\\n'; else printf '77 77\\n'; fi
  exit 0
fi
exec "$real_ps" "\$@"
SH
  chmod +x "$home/fakebin/ps"
  : > "$home/config/supervision-handoff-ack"
  printf '❯ human draft\n' > "$home/screen"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'%77'*) ;; *) exit 1 ;; esac
case "$1:$*" in
  display-message:*'#{pane_pid}'*)
    if [ -f "$FM_HOME/foreign-pane" ]; then printf '999999\n'; else cat "$FM_HOME/state/.lock"; fi ;;
  display-message:*'#{cursor_y}'*) printf '0\n' ;;
  capture-pane:*) cat "$FM_HOME/screen" ;;
  send-keys:*) printf '%s\n' "$*" >> "$FM_HOME/submits" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  TMUX_PANE=%77 FM_SUPERVISION_HANDOFF_RETRY_SECONDS=3 start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "doorbell: no initial watcher"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "doorbell: no hand-back"
  wait_until 150 grep -q 'retry' "$home/state/.supervision-handoff.log" || fail "doorbell: no retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry overwrote human input"
  printf '❯ \n' > "$home/screen"
  : > "$home/foreign-pane"
  # Observe a complete new retry while the pane does not own this session.
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no foreign-pane retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached another session's pane"
  rm "$home/foreign-pane"
  : > "$home/background-session"
  cp "$home/state/.supervision-handoff.log" "$home/retries-before"
  wait_until 150 bash -c '! cmp -s "$1/retries-before" "$1/state/.supervision-handoff.log"' _ "$home" \
    || fail "doorbell: no background-session retry"
  [ ! -s "$home/submits" ] || fail "doorbell: retry reached a different foreground conversation"
  rm "$home/background-session"
  wait_until 150 grep -q $'\tretry\t.*\tempty$' "$home/state/.supervision-handoff.log" \
    || fail "doorbell: the submit helper did not confirm the idle owning pane's retry"
  [ -s "$home/submits" ] || fail "doorbell: idle owning pane received no retry"
  assert_grep 'Enter' "$home/submits" "the retry must submit, not merely type"
  doorbell=$(grep -- '-l ' "$home/submits" | head -1)
  record=$(printf '%s\n' "$doorbell" | grep -o '/[^ ]*/operational-inbox/[^ ]*\.msg')
  [ -n "$record" ] && [ -f "$record" ] || fail "doorbell: no durable operational record"
  assert_grep 'watcher: check: supervision-handoff' "$record" "the retry must be operational watcher input"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "doorbell: submission was mistaken for acknowledgement"
  stop_home_processes "$home"
  pass "host+hook: hand-back retry submits only to the idle owning pane without replacing human input"
}

test_main_only_close_after_handled_turn_delivers_restore_failure
test_returned_driver_is_caught_away
test_lost_boundary_handoff
test_handoff_retry_respects_the_receiving_pane
test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn
test_report_surface_enforces_actor_turn_and_scope
test_report_after_the_return_is_queued_for_main
test_branch_outcomes_only_on_a_host_home_off_pi
test_branch_outcomes_budgets_count_bytes
test_branch_outcomes_stay_unread_when_a_projection_fails
test_branch_outcomes_date_a_legacy_backlog_without_adopting_it
test_branch_outcomes_keep_an_unshown_outcome_until_acknowledged
test_branch_outcomes_keep_a_drain_presented_outcome_across_a_switch_to_pi
test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main
test_attended_captain_outcome_reaches_main_through_branch_outcomes
test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return
test_quiet_record_without_its_daemon_is_a_present_captain
test_attended_main_only_close_passes_straight_to_main
test_attended_close_with_unidentified_main_session_passes_to_main
test_close_accepted_away_that_turns_attended_passes_to_main
test_claude_stop_hook_delivers_a_main_only_pass_through
test_claude_stop_hook_rewakes_main_for_an_inbox_note_after_a_handled_wake
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end
test_primary_without_a_verified_mirror_runs_away_only
test_attended_wake_carries_the_dialog_mirror
test_undelivered_dialog_is_fed_again_on_the_next_turn
test_attended_wake_with_an_unreadable_mirror_reaches_main
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_large_turn_relays_an_early_visible_outcome
test_report_without_acknowledgement_hands_the_wake_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes
test_restarted_host_stops_what_a_killed_predecessor_left
test_park_boundary_holds_under_back_to_back_closes
test_park_boundary_rechecked_just_before_the_engine_turn
test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
test_first_cycle_status_streams_and_owner_options_reach_it
test_host_outside_the_lock_owner_stands_down
test_tagged_lock_holder_reaches_the_engine_whole
test_superseded_host_leaves_the_owner_untouched
