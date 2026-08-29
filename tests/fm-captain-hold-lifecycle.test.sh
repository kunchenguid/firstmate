#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# The archive read stages its parser-legible copy under TMPDIR. Nothing may
# survive the process that staged it, so a test points TMPDIR at a fixture
# directory of its own and asserts that directory is empty of views afterwards.
assert_no_staged_archive_view() {  # <tmpdir> <message>
  local tmpdir=$1 message=$2 leftover
  leftover=$(find "$tmpdir" -maxdepth 1 -name 'fm-archive-view.*' 2>/dev/null |
    LC_ALL=C sort | paste -sd' ' -)
  [ -z "$leftover" ] || fail "$message: $leftover"
}

sha256_of() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# Backlog retention MOVES a closed row rather than deleting it, so an answered
# captain call lives in the archive once enough work has closed behind it. The
# completion gate has to treat that as the recorded answer it is, or a finished
# investigation whose calls were all properly answered can never be cleaned up.
# Nothing here rescues a lost answer, because nothing was lost: this asserts the
# captain's exact words survive the move and that the gate reads where they went.
test_archived_captain_answer_still_completes_the_investigation() {
  local home id out
  home=$(make_home retention-archive)
  id=sample-retention-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the retention-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample retention review\n\nOne captain choice was needed and has been answered.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold sample-retention-call \
    --title "Choose the retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the captain-held task"
  printf 'Keep the sample retention window at thirty days.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-retention-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  run_captain "$home" complete "$id" sample-retention-call >/dev/null \
    || fail "completion failed on the answered inventory"
  out=$(run_captain "$home" verify "$id") || fail "verification failed before retention ran"
  case "$out" in
    *archived*) fail "nothing was archived yet, so the pass must not claim it was: $out" ;;
  esac

  # Retention, exactly as the backlog contract runs it: the answered row moves
  # out of the active backlog and into the archive, answer text and all.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  assert_no_grep "sample-retention-call" "$home/data/backlog.md" \
    "setup error: retention should have moved the answered call out of the active backlog"
  assert_grep "sample-retention-call" "$home/data/done-archive.md" \
    "retention lost the answered captain call instead of archiving it"
  assert_grep "Keep the sample retention window at thirty days." "$home/data/done-archive.md" \
    "the captain's exact words did not survive the move into the archive"

  out=$(run_captain "$home" verify "$id" 2> "$home/verify.err") \
    || fail "the completion gate refused an answered captain call the archive still holds: $(cat "$home/verify.err")"
  assert_contains "$out" "1 answered and archived" \
    "a pass on an archived answer must say so, not read like a looser check"

  # The retired command spelling delegates to the same gate, so pre-collapse
  # briefs reach the fix without being rewritten.
  run_shim "$home" verify "$id" >/dev/null 2> "$home/shim-verify.err" \
    || fail "the shim's verify still refused the archived answer: $(cat "$home/shim-verify.err")"

  # The gate's real consumer: cleanup of the finished investigation.
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "cleanup refused a finished investigation whose only captain call was answered: $(cat "$home/teardown.err")"
  assert_present "$home/data/$id/report.md" "cleanup must keep the investigation deliverable"
  pass "an answered captain call retention moved to the archive still completes and cleans up"
}

# The gate must not get looser in exchange. Reading the archive adds one place a
# record can legitimately live; it changes nothing about what counts as answered.
# Every failing shape must still fail, and each must say which one it is: the
# wording that said only "absent" is what sent a reader hunting for a lost
# captain answer instead of at the record right in front of them. That includes
# the two ways the archive read itself can fail, because reporting either as "no
# record" would restore exactly the false absent this change removes.
test_unanswered_and_absent_captain_calls_still_fail_distinguishably() {
  local home id absent_err closed_err archived_err unheld_err unstaged_err unreadable_err out
  home=$(make_home retention-gate-guard)
  id=sample-guarded-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the retention gate" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guarded-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guarded review\n\nThe captain calls below are deliberately unfinished.\n' \
    > "$home/data/$id/report.md"

  # (1) An inventory entry with no record in either file. Written straight into
  # the durable attestation, because `complete` refuses to attest one - which is
  # the point: an entry can only get here by outliving the task it named.
  printf 'decisions_reviewed=1\ndecision_keys=sample-vanished-call\n' >> "$home/state/$id.meta"
  if run_captain "$home" verify "$id" > "$home/absent.out" 2> "$home/absent.err"; then
    fail "verification passed an inventory entry with no record in either file"
  fi
  absent_err=$(cat "$home/absent.err")
  assert_contains "$absent_err" "has no record" \
    "a never-recorded call must be named as having no record at all"
  assert_contains "$absent_err" "$home/data/backlog.md" \
    "the no-record message must name the active backlog it searched"
  assert_contains "$absent_err" "$home/data/done-archive.md" \
    "the no-record message must name the archive it searched, so a reader stops hunting"

  # (2) A recorded call closed outside `answer`: the captain's word was never
  # written down, and the gate must still refuse it.
  tasks_in "$home" add sample-unanswered-call "Choose the guarded option" --repo sample >/dev/null \
    || fail "could not create the unanswered call"
  run_captain "$home" hold sample-unanswered-call --reason "captain guarded choice pending" >/dev/null \
    || fail "could not hold the unanswered call"
  printf 'decision_keys=sample-unanswered-call\n' >> "$home/state/$id.meta"
  tasks_in "$home" "done" sample-unanswered-call >/dev/null \
    || fail "could not close the call outside the answer path"
  if run_captain "$home" verify "$id" > "$home/closed.out" 2> "$home/closed.err"; then
    fail "verification passed a call closed with no recorded captain answer"
  fi
  closed_err=$(cat "$home/closed.err")
  assert_contains "$closed_err" "closed with no recorded captain answer" \
    "a recorded-but-unanswered call must be named as recorded and unanswered"
  assert_contains "$closed_err" "$home/data/backlog.md" \
    "the unanswered message must name the file the record was found in"

  # (3) The same unanswered call after retention archives it. Being in the
  # archive is not evidence of an answer, so this must fail exactly as (2) did
  # while naming the archive as where the record now is.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  assert_grep "sample-unanswered-call" "$home/data/done-archive.md" \
    "setup error: retention should have moved the unanswered call into the archive"
  if run_captain "$home" verify "$id" > "$home/archived.out" 2> "$home/archived.err"; then
    fail "verification passed an archived call that carries no captain answer"
  fi
  archived_err=$(cat "$home/archived.err")
  assert_contains "$archived_err" "closed with no recorded captain answer" \
    "an archived call with no answer must still be refused for the same reason"
  assert_contains "$archived_err" "$home/data/done-archive.md" \
    "the archived-and-unanswered message must name the archive as where the record is"

  # Cleanup is still refused while that call is unanswered, in either file, and
  # refused by the gate itself rather than incidentally.
  if run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"; then
    fail "cleanup erased an investigation whose captain call was never answered"
  fi
  assert_grep "has not passed the captain-call completion gate" "$home/teardown.err" \
    "cleanup was refused for some other reason, so this proves nothing about the gate"
  assert_present "$home/state/$id.meta" "a refused cleanup must preserve the investigation record"

  # (4) A recorded entry that is open but was never held for the captain. It is
  # not the captain's item at all, and dropping it from the inventory is the
  # repair rather than answering it, so it must say that in its own words.
  tasks_in "$home" add sample-unheld-call "Choose the unheld option" --repo sample >/dev/null \
    || fail "could not create the unheld call"
  printf 'decision_keys=sample-unheld-call\n' >> "$home/state/$id.meta"
  if run_captain "$home" verify "$id" > "$home/unheld.out" 2> "$home/unheld.err"; then
    fail "verification passed an inventory entry that is not held for the captain"
  fi
  unheld_err=$(cat "$home/unheld.err")
  assert_contains "$unheld_err" "is not held for the captain" \
    "a recorded but unheld entry must be named as not the captain's item"
  assert_contains "$unheld_err" "$home/data/backlog.md" \
    "the unheld message must name the file the record was found in"

  # Every pair of the three refusals must be tellable apart, which is the whole
  # repair here.
  [ "$absent_err" != "$closed_err" ] || fail "no record and unanswered read identically: $absent_err"
  [ "$closed_err" != "$archived_err" ] \
    || fail "the unanswered message does not distinguish which file holds the record"
  [ "$absent_err" != "$archived_err" ] \
    || fail "no record and an archived record with no answer read identically: $absent_err"
  [ "$unheld_err" != "$absent_err" ] && [ "$unheld_err" != "$closed_err" ] \
    && [ "$unheld_err" != "$archived_err" ] \
    || fail "the unheld refusal does not read differently from the other two: $unheld_err"

  # Recording the answer, once, is what actually clears the gate - and it clears
  # it for the backlog copy, so the pass is earned rather than assumed.
  tasks_in "$home" add sample-answered-call "Choose the guarded option" --repo sample >/dev/null \
    || fail "could not create the answerable call"
  run_captain "$home" hold sample-answered-call --reason "captain guarded choice pending" >/dev/null \
    || fail "could not hold the answerable call"
  printf 'decision_keys=sample-answered-call\n' >> "$home/state/$id.meta"
  printf 'Take the guarded option.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-answered-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  out=$(run_captain "$home" verify "$id") \
    || fail "verification refused a properly answered call"
  case "$out" in
    *archived*) fail "the answered call is in the active backlog; the pass must not claim otherwise: $out" ;;
  esac

  # (5) Retention moves that answered record into the archive, and then the copy
  # the read needs cannot be staged at all. Nothing was read, so the archive is
  # unexamined: this must blame the staging rather than the layout, and above all
  # must not read as an absent record.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  assert_grep "sample-answered-call" "$home/data/done-archive.md" \
    "setup error: retention should have moved the answered call into the archive"
  assert_no_grep "sample-answered-call" "$home/data/backlog.md" \
    "setup error: the archive read is only reached once retention has emptied the active backlog of that row"
  if (TMPDIR="$home/no-such-tmp"; export TMPDIR; run_captain "$home" verify "$id") \
    > "$home/unstaged.out" 2> "$home/unstaged.err"; then
    fail "verification passed a record it never managed to read"
  fi
  unstaged_err=$(cat "$home/unstaged.err")
  assert_contains "$unstaged_err" "$home/data/done-archive.md" \
    "the staging-failure refusal must name the archive it was trying to copy"
  assert_contains "$unstaged_err" "could be staged" \
    "the staging-failure refusal must say the copy could not be staged"
  assert_not_contains "$unstaged_err" "has no record" \
    "a record that could not be copied must never be reported as no record at all"
  assert_not_contains "$unstaged_err" "layout changed" \
    "nothing was read, so the staging failure must not be blamed on the archive layout"

  # (6) The archive still carries the entry, but its own section heading is no
  # longer one tasks-axi accepts, so the record cannot be read back. Only this
  # throwaway fixture is damaged, and only its heading: the entry line is left
  # intact so the read reaches the parse instead of stopping at "no entry".
  assert_grep "## Archived " "$home/data/done-archive.md" \
    "setup error: retention should have written a dated archive heading to damage"
  sed 's/^## Archived /## Retired /' "$home/data/done-archive.md" > "$home/damaged-archive.md" \
    || fail "could not write the damaged archive fixture"
  mv "$home/damaged-archive.md" "$home/data/done-archive.md"
  assert_no_grep "## Archived " "$home/data/done-archive.md" \
    "setup error: the damaged archive must carry no heading the read can still rewrite"
  grep -Eq "^- \[[ x]\] sample-answered-call - " "$home/data/done-archive.md" \
    || fail "setup error: the damaged archive must still carry the task entry, or nothing is proven about the parse"
  if run_captain "$home" verify "$id" > "$home/unreadable.out" 2> "$home/unreadable.err"; then
    fail "verification passed a record it could not read back out of the archive"
  fi
  unreadable_err=$(cat "$home/unreadable.err")
  assert_contains "$unreadable_err" "$home/data/done-archive.md" \
    "the unreadable-archive refusal must name the archive it could not read"
  assert_contains "$unreadable_err" "could not read that record" \
    "the unreadable-archive refusal must say the record could not be read back"
  assert_not_contains "$unreadable_err" "has no record" \
    "an archive that still holds the entry must never be reported as no record at all"

  # Both archive-read failures must also be tellable apart from each other and
  # from the three gate refusals, for the same reason those three are.
  [ "$unstaged_err" != "$absent_err" ] \
    || fail "a record that could not be copied reads as no record: $unstaged_err"
  [ "$unstaged_err" != "$closed_err" ] && [ "$unstaged_err" != "$archived_err" ] \
    || fail "a record that could not be copied reads as a recorded-but-unanswered call: $unstaged_err"
  [ "$unreadable_err" != "$absent_err" ] \
    || fail "an unreadable archive reads as no record: $unreadable_err"
  [ "$unreadable_err" != "$unstaged_err" ] \
    || fail "a layout the parser rejects and a copy that could not be staged read identically: $unreadable_err"
  [ "$unreadable_err" != "$closed_err" ] && [ "$unreadable_err" != "$archived_err" ] \
    || fail "an unreadable archive reads as a recorded-but-unanswered call: $unreadable_err"
  pass "no-record, recorded-but-unanswered, archived-but-unanswered, unheld, unstageable, and unreadable captain-call records all still fail, distinguishably"
}

# The siblings that share the same lookup. Reading the archive is not permission
# to write it: tasks-axi writes the active backlog and nothing else, so an
# archived record can be reported on and replayed, never changed or duplicated.
test_archived_records_are_readable_but_never_written() {
  local home out err
  home=$(make_home retention-archive-writes)
  tasks_in "$home" add sample-archived-call "Choose the archived option" --repo sample >/dev/null \
    || fail "could not create the call"
  run_captain "$home" hold sample-archived-call --reason "captain archived choice pending" >/dev/null \
    || fail "could not hold the call"
  printf 'Take the archived option.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-archived-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not run backlog retention"
  cp "$home/data/done-archive.md" "$home/archive-before.md"
  cp "$home/data/backlog.md" "$home/backlog-before.md"

  # An exact replay is the same idempotent no-op it was before retention ran.
  out=$(run_captain "$home" answer sample-archived-call --decision-file "$home/answer.txt") \
    || fail "an exact answer replay failed once the record was archived"
  assert_contains "$out" "answered: sample-archived-call" \
    "the replay must report the same recorded answer it did before retention"
  cmp -s "$home/data/done-archive.md" "$home/archive-before.md" \
    || fail "the replay wrote to the archive"
  cmp -s "$home/data/backlog.md" "$home/backlog-before.md" \
    || fail "the replay resurrected the archived row in the active backlog"

  # A different answer, or a release, has nowhere to go and must say so.
  printf 'Take a different option after all.\n' > "$home/other.txt"
  if run_captain "$home" answer sample-archived-call --decision-file "$home/other.txt" \
    > "$home/drift.out" 2> "$home/drift.err"; then
    fail "a drifted answer was accepted against an archived record"
  fi
  err=$(cat "$home/drift.err")
  assert_contains "$err" "$home/data/done-archive.md" \
    "the refusal must name the archive as where the record is"
  assert_contains "$err" "not writable" \
    "the refusal must say the archive cannot take the change, not that the task is absent"
  cmp -s "$home/data/done-archive.md" "$home/archive-before.md" \
    || fail "a refused answer still wrote to the archive"

  # The release is the same answer the archive already records, so only its close
  # mode differs: lifting a hold is a write, and the archive takes no writes.
  if run_captain "$home" answer sample-archived-call --decision-file "$home/answer.txt" --release \
    > "$home/release.out" 2> "$home/release.err"; then
    fail "--release was accepted against an archived record that was never reopened"
  fi
  err=$(cat "$home/release.err")
  assert_contains "$err" "$home/data/done-archive.md" \
    "the release refusal must name the archive as where the record is"
  assert_not_contains "$err" "has no record" \
    "a release against an archived record must not be refused as if the task were absent"
  cmp -s "$home/data/done-archive.md" "$home/archive-before.md" \
    || fail "a refused release still wrote to the archive"
  cmp -s "$home/data/backlog.md" "$home/backlog-before.md" \
    || fail "a refused release resurrected the archived row in the active backlog"

  # Holding the same id again would mint a second row for a call the captain has
  # already answered, splitting one identity across the two files.
  if run_captain "$home" hold sample-archived-call --title "Choose again" \
    --reason "captain archived choice pending" > "$home/hold.out" 2> "$home/hold.err"; then
    fail "hold created a duplicate row for a call the archive already closed"
  fi
  assert_grep "already closed and archived" "$home/hold.err" \
    "the refusal must name retention as the reason, not a missing task"
  assert_no_grep "sample-archived-call" "$home/data/backlog.md" \
    "the refused hold left a duplicate row in the active backlog"

  # The keyed intake reaches the same record. A delivery whose answer it recorded
  # itself replays as closed after retention moves the row, so a channel that
  # redelivers an old answer does not read it as a new unrecorded one.
  tasks_in "$home" add sample-keyed-call "Choose the keyed option" --repo sample >/dev/null \
    || fail "could not create the keyed call"
  run_captain "$home" hold sample-keyed-call --reason "captain keyed choice pending" >/dev/null \
    || fail "could not hold the keyed call"
  out=$(printf 'sample-keyed-call\tTake the keyed option.\tcaptain reply\n' \
    | run_captain "$home" answers --source "test channel") \
    || fail "the keyed intake could not record the answer: $out"
  assert_contains "$out" "closed: sample-keyed-call" "the keyed intake did not record the answer"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not run backlog retention"
  assert_grep "sample-keyed-call" "$home/data/done-archive.md" \
    "setup error: retention should have moved the keyed answer into the archive"
  cp "$home/data/done-archive.md" "$home/archive-before-keyed.md"
  cp "$home/data/backlog.md" "$home/backlog-before-keyed.md"
  out=$(printf 'sample-keyed-call\tTake the keyed option.\tcaptain reply\n' \
    | run_captain "$home" answers --source "test channel") \
    || fail "the keyed intake failed on a replayed archived answer: $out"
  assert_contains "$out" "closed: sample-keyed-call" \
    "a replayed delivery for an archived answer must report it closed, not absent"
  cmp -s "$home/data/done-archive.md" "$home/archive-before-keyed.md" \
    || fail "the replayed keyed delivery wrote to the archive"
  cmp -s "$home/data/backlog.md" "$home/backlog-before-keyed.md" \
    || fail "the replayed keyed delivery resurrected the archived row in the active backlog"

  # A key that names nothing is skipped, naming both files it searched so it is
  # not mistaken for a captain answer that went missing.
  out=$(printf 'sample-nowhere-call\tSome answer.\tcaptain reply\n' \
    | run_captain "$home" answers --source "test channel" 2>&1) || true
  assert_contains "$out" "skipped: sample-nowhere-call" \
    "a key naming no task must be skipped"
  assert_contains "$out" "$home/data/done-archive.md" \
    "the skip must name the archive it searched so the key is not mistaken for a lost answer"
  pass "archived captain-call records are readable, replayable, and never written or duplicated"
}

# The last sibling that shared the backlog-only lookup: the ownership check
# `complete` runs over the ORIGIN. A row retention has archived is still this
# home's own record of it, so a long-finished investigation can attest a later
# review pass instead of being disowned by the home that ran it. An archive that
# cannot be opened leaves ownership unknown, which is not the same answer as not
# owned, so that refuses in its own words rather than naming another home.
test_archived_origin_still_owns_a_later_review_pass() {
  local home id call out err
  home=$(make_home retention-archived-origin)
  id=sample-archived-origin
  call=sample-later-review-call
  tasks_in "$home" add "$id" "Investigate the archived origin" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the origin"
  tasks_in "$home" add "$call" "Choose the later option" --repo sample >/dev/null \
    || fail "could not create the captain call"
  run_captain "$home" hold "$call" --reason "captain later choice pending" >/dev/null \
    || fail "could not hold the captain call"
  printf 'Take the later option.\n' > "$home/answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the origin"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not run backlog retention"

  # Ownership rests on the archived row alone here: no attestation metadata was
  # ever written and there is no report deliverable to answer it first, so a
  # backlog-only lookup has nothing left to find.
  assert_absent "$home/state/$id.meta" \
    "setup error: attestation metadata would answer ownership before the archive read"
  assert_absent "$home/data/$id" \
    "setup error: a report deliverable would answer ownership before the archive read"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "setup error: retention should have moved the origin row out of the active backlog"
  assert_grep "$id" "$home/data/done-archive.md" \
    "setup error: retention should have moved the origin row into the archive"

  out=$(run_captain "$home" complete "$id" "$call" 2>&1) \
    || fail "completion disowned an origin whose own row retention archived: $out"
  assert_contains "$out" "captain-call inventory reviewed" \
    "the later review pass over an archived origin was not recorded"

  # And the fail-closed half: an archive path that cannot be opened must not be
  # read as evidence that some other home owns this origin.
  mv "$home/data/done-archive.md" "$home/archive-elsewhere.md"
  ln -s "$home/archive-elsewhere.md" "$home/data/done-archive.md"
  if run_captain "$home" complete "$id" "$call" > "$home/origin.out" 2> "$home/origin.err"; then
    fail "completion attested an origin while the archive could not be searched"
  fi
  err=$(cat "$home/origin.err")
  assert_contains "$err" "not a readable regular file" \
    "the refusal must name the archive it could not search"
  assert_not_contains "$err" "is not owned by the active home" \
    "an archive that was never searched must not read as a disowned origin"
  assert_contains "$err" "investigation origin $id" \
    "the refusal must name the origin as an origin, because that is the record to look at"
  assert_not_contains "$err" "captain call $id" \
    "the refusal must not send the operator hunting a captain call by the origin's id"
  pass "an origin whose own row retention archived still owns a later review pass"
}

# Reading the archive and being able to open it are different questions. A path
# that exists and is not a readable regular file leaves it unknown whether the
# record is in there, so it has to stop the gate in its own words instead of
# reading as "no record", and it has to stop `hold` from minting a second row for
# a call the archive may already hold. No archive file at all is the opposite
# case and stays quiet, because a home that has never had a row trimmed is
# healthy rather than broken.
test_unopenable_archive_refuses_instead_of_reading_as_absent() {
  local home id out err
  home=$(make_home retention-archive-unopenable)
  id=sample-unopenable-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the archive read" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guarded-read origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard the archive read\n\nOne captain choice was needed and has been answered.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold sample-unopenable-call --title "Choose the guarded option" \
    --reason "captain guarded choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  printf 'Take the guarded option.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-unopenable-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  run_captain "$home" complete "$id" sample-unopenable-call >/dev/null \
    || fail "completion failed on the answered inventory"

  # Nothing has been trimmed yet, so the record is still in the live backlog and
  # there is no archive file at all. A young home like that must not be refused.
  # On its own this does not reach the archive read, because the backlog answers
  # first; the genuine no-archive-file case is driven a few lines below.
  assert_absent "$home/data/done-archive.md" \
    "setup error: retention has not run, so no archive file should exist yet"
  run_captain "$home" verify "$id" >/dev/null 2> "$home/no-archive.err" \
    || fail "a home with no archive file at all was refused: $(cat "$home/no-archive.err")"

  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  out=$(run_captain "$home" verify "$id") || fail "verification failed on the archived answer"
  assert_contains "$out" "1 answered and archived" \
    "setup error: the record should now be read out of the archive"

  # The record now lives ONLY in the archive, so the archive read is genuinely on
  # the path. Take the archive file away and an archive that does not exist has
  # to stay QUIET: "no record", never "the archive could not be read", because a
  # home that has simply never had a row trimmed has no archive file either. This
  # is the boundary the symlink case below contrasts with, and it is the
  # assertion a change making an absent archive loud has to fail.
  mv "$home/data/done-archive.md" "$home/archive-taken-away.md"
  if run_captain "$home" verify "$id" > "$home/absent.out" 2> "$home/absent.err"; then
    fail "verification passed while the answered record was in neither file"
  fi
  err=$(cat "$home/absent.err")
  assert_contains "$err" "has no record" \
    "an archive file that does not exist must read as no record at all"
  assert_not_contains "$err" "not a readable regular file" \
    "a missing archive file must stay quiet rather than being called unreadable"
  mv "$home/archive-taken-away.md" "$home/data/done-archive.md"

  # The archive path becomes a symlink, which this read deliberately refuses to
  # follow. The record is still in there, which is exactly why the refusal must
  # not read as an absent record.
  mv "$home/data/done-archive.md" "$home/archive-elsewhere.md"
  ln -s "$home/archive-elsewhere.md" "$home/data/done-archive.md"
  if run_captain "$home" verify "$id" > "$home/unopenable.out" 2> "$home/unopenable.err"; then
    fail "verification passed while the archive could not be opened at all"
  fi
  err=$(cat "$home/unopenable.err")
  assert_contains "$err" "$home/data/done-archive.md" \
    "the refusal must name the archive path it could not open"
  assert_contains "$err" "not a readable regular file" \
    "the refusal must say the archive could not be read, not that the record is gone"
  assert_not_contains "$err" "has no record" \
    "an archive that was never searched must not be reported as holding no record"

  # The mirror of the origin-ownership subject: here the record really is a
  # captain call, so the refusal has to say so. Wiring the two subjects backwards
  # has to fail on this line as well as on the ownership one.
  assert_contains "$err" "captain call sample-unopenable-call" \
    "an inventory entry's refusal must name the captain call it could not settle"
  assert_not_contains "$err" "investigation origin" \
    "a captain call's refusal must not be reported as an origin-ownership failure"

  # And `hold` must not mint a second row for a call the archive may already
  # hold, which is the split identity that guard exists to prevent.
  if run_captain "$home" hold sample-unopenable-call --title "Choose the guarded option" \
    --reason "captain guarded choice pending" > "$home/hold.out" 2> "$home/hold.err"; then
    fail "hold created a row for an archived call while the archive could not be read"
  fi
  assert_grep "not a readable regular file" "$home/hold.err" \
    "the refused hold must name the unreadable archive rather than a missing task"
  assert_no_grep "sample-unopenable-call" "$home/data/backlog.md" \
    "the refused hold minted a second row for a call the archive may already hold"

  # Non-vacuity: the same gate passes again the moment the archive is readable.
  rm -f "$home/data/done-archive.md"
  mv "$home/archive-elsewhere.md" "$home/data/done-archive.md"
  out=$(run_captain "$home" verify "$id") \
    || fail "the gate stayed refused once the archive was readable again"
  assert_contains "$out" "1 answered and archived" \
    "the restored archive must be read exactly as it was before"
  pass "an archive path that cannot be opened refuses loudly and blocks a duplicate hold"
}

# The archive read stages one copy of the archive per process and reuses it
# across lookups, and the archive GROWS underneath that copy: `tasks-axi done`
# trims by default, so closing one call inside a batch moves an older closed row
# into the archive between two lookups of the same process. A copy staged before
# that move must not answer for the row the move added. If it does, a record that
# is right there in the archive reads as an archive the parser cannot read, which
# is a false alarm about the file's layout raised over a perfectly healthy file.
test_a_row_archived_mid_batch_is_still_read_out_of_the_archive() {
  local home out
  home=$(make_home retention-archive-midbatch)
  # A one-row window, so closing one call trims the previously closed one. Under
  # the tracked ten-row window nothing moves mid-batch and this proves nothing.
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 1\n' \
    > "$home/.tasks.toml"

  # An answered call the archive already holds, so the batch's FIRST row is an
  # archive read and the copy it stages is the one the later rows inherit.
  tasks_in "$home" add sample-early-call "Choose the early option" --repo sample >/dev/null \
    || fail "could not create the early call"
  run_captain "$home" hold sample-early-call --reason "captain early choice pending" >/dev/null \
    || fail "could not hold the early call"
  printf 'Take the early option.\n' > "$home/early.txt"
  run_captain "$home" answer sample-early-call --decision-file "$home/early.txt" >/dev/null \
    || fail "could not record the early answer"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention over the early call"
  assert_grep "sample-early-call" "$home/data/done-archive.md" \
    "setup error: retention should have moved the early call into the archive"

  # An answered call still sitting in the backlog's Done section. This is the row
  # the batch itself archives, and the row a later lookup in that same batch asks
  # for once it has moved.
  tasks_in "$home" add sample-mid-call "Choose the middle option" --repo sample >/dev/null \
    || fail "could not create the middle call"
  run_captain "$home" hold sample-mid-call --reason "captain middle choice pending" >/dev/null \
    || fail "could not hold the middle call"
  printf 'Take the middle option.\n' > "$home/mid.txt"
  run_captain "$home" answer sample-mid-call --decision-file "$home/mid.txt" >/dev/null \
    || fail "could not record the middle answer"
  assert_grep "sample-mid-call" "$home/data/backlog.md" \
    "setup error: the middle call must still be in the backlog, or nothing moves mid-batch"

  # And a live call for the batch to close, which is what triggers the trim.
  tasks_in "$home" add sample-late-call "Choose the late option" --repo sample >/dev/null \
    || fail "could not create the late call"
  run_captain "$home" hold sample-late-call --reason "captain late choice pending" >/dev/null \
    || fail "could not hold the late call"

  out=$(printf 'sample-early-call\tTake the early option.\tcaptain reply\nsample-late-call\tTake the late option.\tcaptain reply\nsample-mid-call\tTake the middle option.\tcaptain reply\n' \
    | run_captain "$home" answers --source "test channel" 2>&1) || true
  assert_contains "$out" "skipped: sample-early-call (already closed and archived" \
    "setup error: the first row must read the archive, or no copy is staged before the trim"
  assert_contains "$out" "closed: sample-late-call" \
    "setup error: the live call must close, because closing it is what trims the middle one"
  assert_grep "sample-mid-call" "$home/data/done-archive.md" \
    "setup error: closing the late call should have trimmed the middle one into the archive"
  assert_no_grep "sample-mid-call" "$home/data/backlog.md" \
    "setup error: the middle call must be out of the backlog, or its lookup never reaches the archive"

  # The row the batch archived a moment ago is still read out of the archive, as
  # the closed-and-archived record it is.
  assert_contains "$out" "skipped: sample-mid-call (already closed and archived" \
    "a row the batch itself archived must still be read out of the archive"
  assert_not_contains "$out" "could not be read" \
    "a healthy archive that grew mid-batch must not be reported as an unreadable layout"
  assert_contains "$out" "answers: closed=1 skipped=2" \
    "only the two already-answered deliveries may be skipped"
  pass "a row archived mid-batch is still read out of the archive"
}

# An archive read that FAILED is not an archive that answered no. The path guards
# settle whether the file can be opened, but the read can still break after it
# opens, and the ownership check treats "no entry" as "another home owns this
# origin", so a read error arriving as an answer disowns a home from its own
# investigation. That is the same wrong-confident lookup the whole two-file read
# exists to remove, so it has to refuse in the words it uses for an archive it
# could not read.
test_an_archive_read_error_never_disowns_the_origin() {
  local home id call real_grep err out
  home=$(make_home retention-archive-read-error)
  id=sample-read-error-origin
  call=sample-read-error-call
  tasks_in "$home" add "$id" "Investigate the read error" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the origin"
  tasks_in "$home" add "$call" "Choose the read-error option" --repo sample >/dev/null \
    || fail "could not create the captain call"
  run_captain "$home" hold "$call" --reason "captain read-error choice pending" >/dev/null \
    || fail "could not hold the captain call"
  printf 'Take the read-error option.\n' > "$home/answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the origin"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not run backlog retention"

  # Ownership rests on the archived row alone, so the archive read is the only
  # thing that can answer it and a failed read is the only thing under test.
  assert_absent "$home/state/$id.meta" \
    "setup error: attestation metadata would answer ownership before the archive read"
  assert_absent "$home/data/$id" \
    "setup error: a report deliverable would answer ownership before the archive read"
  assert_grep "$id" "$home/data/done-archive.md" \
    "setup error: retention should have moved the origin row into the archive"

  # The archive stays a perfectly ordinary readable file; the READ is what fails.
  # A grep that reports a read error for that file and only that file reproduces
  # an EIO, a stale network handle, or a file unlinked under the open, and leaves
  # every other grep in the script alone so the refusal cannot come from anywhere
  # else.
  real_grep=$(command -v grep) || fail "could not resolve the real grep"
  mkdir -p "$home/grepfail"
  cat > "$home/grepfail/grep" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */done-archive.md) exit 2 ;;
  esac
done
exec $real_grep "\$@"
SH
  chmod +x "$home/grepfail/grep"

  if (PATH="$home/grepfail:$PATH"; export PATH; run_captain "$home" complete "$id" "$call") \
    > "$home/read-error.out" 2> "$home/read-error.err"; then
    fail "completion attested an origin whose archive read never completed"
  fi
  err=$(cat "$home/read-error.err")
  assert_not_contains "$err" "is not owned by the active home" \
    "an archive read that failed must never read as a disowned origin"
  assert_contains "$err" "the archive could not be searched" \
    "the refusal must say the archive could not be read"
  assert_contains "$err" "$home/data/done-archive.md" \
    "the refusal must name the archive whose read failed"

  # Two different things reach this refusal and the archive's mode is fine in this
  # one, so it must not assert a cause it cannot know. Naming a mode or a symlink
  # to repair sends the operator at a file that is not broken, which is the same
  # confidently-wrong direction the old "absent" wording sent them in.
  assert_contains "$err" "or the read of it did not complete" \
    "the refusal must allow for a read that broke, not assert an unreadable path"
  assert_not_contains "$err" "symlink" \
    "a read that failed must not tell the operator to repair a symlink"
  assert_not_contains "$err" "unreadable mode" \
    "a read that failed must not tell the operator to repair a file mode"

  # And it must name the right KIND of record. The subject here is an
  # investigation origin, so calling it a captain call would send the operator
  # looking for a captain-held task by an id no captain call ever had.
  assert_contains "$err" "investigation origin $id" \
    "an ownership failure must name the origin as an origin"
  assert_not_contains "$err" "captain call $id" \
    "an ownership failure must not send the operator hunting a captain call by the origin's id"

  # Non-vacuity: the same gate passes the moment the read works again, so the
  # refusal above is the failed read and not the fixture.
  out=$(run_captain "$home" complete "$id" "$call" 2>&1) \
    || fail "completion stayed refused once the archive read worked again: $out"
  assert_contains "$out" "captain-call inventory reviewed" \
    "the later review pass over an archived origin was not recorded"
  pass "an archive read that fails refuses in its own words instead of disowning the origin"
}

# The legacy fallback runs only when the first probe genuinely MISSED, never when
# it could not be settled, and this pair pins that because the reasoning beside it
# does not survive a refactor. The two probes name different records, so ruling on
# the legacy one while the keyed one is unreadable can pass a captain call that was
# never answered. The fixture is one where the legacy record is real, live, and
# answered, so falling through would look right and be wrong; only the archive's
# readability differs between the halves, which is what makes the refusal
# attributable to the archive read and to nothing else.
test_an_unsettled_archive_read_outranks_the_legacy_identity() {
  local home id key legacy out err
  home=$(make_home retention-archive-legacy-fallback)
  id=sample-fallback-origin
  key=laterpick
  legacy="$id-decision-$key"

  # An unrelated closed row, trimmed by real retention, so this home HAS an
  # archive file whose readability can be flipped without touching the record
  # under test.
  tasks_in "$home" add sample-fallback-filler "Trim this row" --repo sample >/dev/null \
    || fail "could not create the filler row"
  tasks_in "$home" "done" sample-fallback-filler >/dev/null \
    || fail "could not close the filler row"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  assert_grep "sample-fallback-filler" "$home/data/done-archive.md" \
    "setup error: retention should have built the archive out of the filler row"

  # The record the gate would rule on if it fell through: the LEGACY derived
  # identity, alive in the backlog and carrying a real recorded captain answer.
  tasks_in "$home" add "$legacy" "Choose the fallback option" --repo sample >/dev/null \
    || fail "could not create the legacy call"
  run_captain "$home" hold "$legacy" --reason "captain fallback choice pending" >/dev/null \
    || fail "could not hold the legacy call"
  printf 'Take the fallback option.\n' > "$home/answer.txt"
  run_captain "$home" answer "$legacy" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  assert_grep "$legacy" "$home/data/backlog.md" \
    "setup error: the answered legacy record must stay in the live backlog"
  assert_no_grep "$legacy" "$home/data/done-archive.md" \
    "setup error: the legacy record must not be archived, or the fallback is not what reaches it"

  # Pre-collapse metadata names the bare key, and nothing anywhere is that key, so
  # the fallback is the only thing that can resolve the entry.
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$home/state/$id.meta"
  if tasks_in "$home" show "$key" --full >/dev/null 2>&1; then
    fail "setup error: the bare key must name no task, or the fallback is never reached"
  fi

  # Half one, the quiet no-entry boundary: no archive file at all, so the read
  # settles as a miss, the fallback runs, and the answered legacy record passes.
  # This half is what proves the record really is reachable and answered, which is
  # what makes the refusal in half two mean something.
  mv "$home/data/done-archive.md" "$home/archive-parked.md" \
    || fail "could not park the archive fixture"
  out=$(run_captain "$home" verify "$id" 2>&1) \
    || fail "the gate refused an answered legacy record while no archive existed: $out"
  assert_contains "$out" "verified: $id captain-call inventory" \
    "the fallback did not rule on the answered legacy record it reached"

  # Half two, the same fixture with only the archive's readability changed: the
  # first probe cannot be settled, so the gate must refuse rather than rule on a
  # record other than the one it was asked about.
  ln -s "$home/archive-parked.md" "$home/data/done-archive.md" \
    || fail "could not make the archive unreadable"
  if run_captain "$home" verify "$id" > "$home/fallback.out" 2> "$home/fallback.err"; then
    fail "the gate ruled on the legacy identity while the keyed record's archive read was unsettled"
  fi
  err=$(cat "$home/fallback.err")
  assert_contains "$err" "the archive could not be searched" \
    "the refusal must name the archive read rather than a missing decision"
  assert_contains "$err" "$home/data/done-archive.md" \
    "the refusal must name the archive it could not search"
  assert_not_contains "$err" "has no record" \
    "an unsettled archive read must never read as a decision that is simply absent"

  # And the flip back: readable again, and the same fixture passes again, so the
  # refusal was the archive read and not something the symlink step disturbed.
  rm -f "$home/data/done-archive.md"
  mv "$home/archive-parked.md" "$home/data/done-archive.md" \
    || fail "could not restore the archive fixture"
  out=$(run_captain "$home" verify "$id" 2>&1) \
    || fail "the gate stayed refused once the archive was readable again: $out"
  assert_contains "$out" "verified: $id captain-call inventory" \
    "the restored archive must leave the fallback ruling exactly as it did before"
  pass "an archive read that cannot be settled outranks an answered legacy identity"
}

# A legacy key resolves through the composed `<origin>-decision-<key>` identity,
# and that identity is what reaches the archive. An archive-read skip therefore
# has to name the id that was probed: naming the bare key sends a reader hunting a
# row nothing ever archived, which is the same misdirection the old "absent"
# wording cost real time on.
test_an_archive_skip_names_the_probed_legacy_identity() {
  local home id key legacy out
  home=$(make_home retention-archive-legacy-skip)
  id=sample-legacy-skip-origin
  key=laterpick
  legacy="$id-decision-$key"
  tasks_in "$home" add "$legacy" "Choose the legacy option" --repo sample >/dev/null \
    || fail "could not create the legacy call"
  run_captain "$home" hold "$legacy" --reason "captain legacy choice pending" >/dev/null \
    || fail "could not hold the legacy call"
  printf 'Take the legacy option.\n' > "$home/answer.txt"
  run_captain "$home" answer "$legacy" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"

  # The archive still carries the legacy row, but its own section heading is no
  # longer one tasks-axi accepts, so the record cannot be read back and the read
  # reaches the archive-failure skip rather than resolving.
  sed 's/^## Archived /## Retired /' "$home/data/done-archive.md" > "$home/damaged-archive.md" \
    || fail "could not write the damaged archive fixture"
  mv "$home/damaged-archive.md" "$home/data/done-archive.md"
  assert_grep "$legacy" "$home/data/done-archive.md" \
    "setup error: the damaged archive must still carry the legacy entry"
  assert_no_grep "## Archived " "$home/data/done-archive.md" \
    "setup error: the damaged archive must carry no heading the read can still rewrite"

  # The delivered key names no task in either file; the composed identity is the
  # one that actually hit the archive.
  out=$(printf '%s\tTake the legacy option.\tcaptain reply\n' "$key" \
    | run_captain "$home" answers "$id" --source "test channel" 2>&1) || true
  assert_contains "$out" "skipped: $legacy (archived in" \
    "the skip must name the identity that actually reached the archive"
  assert_not_contains "$out" "skipped: $key (archived in" \
    "the skip must not name a key nothing ever archived"
  pass "an archive-read skip names the probed legacy identity, not the delivered key"
}

# The staged copy of the archive outlives the call that made it, so something has
# to remove it before the process ends or every archived lookup leaves a file in
# TMPDIR. Both reader entry points are covered because they are opposite shapes:
# bin/fm-captain-hold.sh already owns an EXIT trap of its own that the removal
# must not displace, and bin/fm-decision-hold.sh owns none.
test_no_staged_archive_view_survives_a_reader() {
  local home id call viewtmp out hold digest body
  home=$(make_home retention-archive-view-leak)
  id=sample-view-leak-review
  call=sample-view-leak-call
  viewtmp="$home/viewtmp"
  mkdir -p "$viewtmp" "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the staged view" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Staged view review\n\nOne captain choice was needed and has been answered.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose the staged option" \
    --reason "captain staged choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  printf 'Take the staged option.\n' > "$home/answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the captain's answer"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion failed on the answered inventory"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention"
  assert_no_grep "$call" "$home/data/backlog.md" \
    "setup error: the archive read is only reached once the backlog no longer holds that row"

  # The gate, whose only copy of the record is the archived one. Reporting the
  # archived count proves the archive read genuinely ran, so the emptiness below
  # is about the removal and not about a view that was never staged.
  out=$( (TMPDIR="$viewtmp"; export TMPDIR; run_captain "$home" verify "$id") 2>&1 ) \
    || fail "the gate refused an answered captain call the archive holds: $out"
  assert_contains "$out" "1 answered and archived" \
    "setup error: the record must be read out of the archive, or nothing was staged"
  assert_no_staged_archive_view "$viewtmp" \
    "the gate left its staged copy of the archive behind"

  # And the same for the shim's `resolve`, the one command there that reads a
  # record in its own process rather than handing off. A pre-collapse routed
  # record, archived, replays exactly, which only happens if the archive answered.
  hold=$(run_shim "$home" hold "$id" routedpick --title "Routed pick" \
    --reason "captain routed pick pending" --repo sample) \
    || fail "could not register the legacy routed call"
  tasks_in "$home" add sample-view-leak-work "Apply the routed pick" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the routed work"
  printf 'Use the routed answer.\n' > "$home/route.txt"
  digest=$(sha256_of "$(cat "$home/route.txt")")
  body="$home/route-body.txt"
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-view-leak-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-view-leak-work\n' \
    "$digest" "$(cat "$home/route.txt")" > "$body"
  tasks_in "$home" update "$hold" --body-file "$body" --archive-body >/dev/null \
    || fail "could not record the pre-collapse routed body"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the legacy routed call"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention over the legacy routed call"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "setup error: the shim's archive read is only reached once the live backlog stops answering for that row"
  fi
  assert_grep "$hold" "$home/data/done-archive.md" \
    "setup error: retention should have moved the legacy routed call into the archive"

  out=$( (TMPDIR="$viewtmp"; export TMPDIR; run_shim "$home" resolve "$id" routedpick \
    --decision-file "$home/route.txt" --routed-to sample-view-leak-work) 2>&1 ) \
    || fail "the shim did not replay a routed record the archive holds: $out"
  assert_contains "$out" "resolved: $hold" \
    "setup error: the replay must reach the archived record, or nothing was staged"
  assert_no_staged_archive_view "$viewtmp" \
    "the shim left its staged copy of the archive behind"
  pass "no staged copy of the archive survives either reader entry point"
}

# The archive is only found through this home's own `[markdown]` table, so every
# spelling of that table tasks-axi itself honors has to be recognized. Each home
# here configures a NON-default archive, so a form this read failed to match would
# fall back to the tracked default, find no archive there, and report the answered
# record as absent all over again.
# tasks-axi is the file's real reader, so it decides which spellings are in scope,
# and it honors a single-quoted TOML literal string for the value as readily as a
# double-quoted one, so both value forms belong here too. The spellings tasks-axi
# ignores get the opposite guarantee, in
# test_config_forms_tasks_axi_ignores_fall_back_the_same_way below.
test_markdown_config_forms_all_locate_the_archive() {
  local home form archive=data/retired-rows.md out index=0
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    index=$((index + 1))
    home=$(make_home "markdown-config-$index")
    case "$form" in
      CRLF)
        form='[markdown]'
        printf 'backend = "markdown"\r\n\r\n%s\r\npath = "data/backlog.md"\r\narchive = "%s"\r\ndone_keep = 10\r\n' \
          "$form" "$archive" > "$home/.tasks.toml"
        form='[markdown] with carriage returns'
        ;;
      SINGLE_QUOTED_VALUES)
        printf "backend = \"markdown\"\n\n[markdown]\npath = 'data/backlog.md'\narchive = '%s'\ndone_keep = 10\n" \
          "$archive" > "$home/.tasks.toml"
        form="[markdown] with single-quoted literal values"
        ;;
      *)
        printf 'backend = "markdown"\n\n%s\npath = "data/backlog.md"\narchive = "%s"\ndone_keep = 10\n' \
          "$form" "$archive" > "$home/.tasks.toml"
        ;;
    esac
    tasks_in "$home" add sample-header-call "Choose the header option" --repo sample >/dev/null \
      || fail "could not create the call under header form <$form>"
    run_captain "$home" hold sample-header-call --reason "captain header choice pending" >/dev/null \
      || fail "could not hold the call under header form <$form>"
    printf 'Take the header option.\n' > "$home/answer.txt"
    run_captain "$home" answer sample-header-call --decision-file "$home/answer.txt" >/dev/null \
      || fail "could not record the answer under header form <$form>"
    tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
      || fail "could not run backlog retention under header form <$form>"
    assert_grep "sample-header-call" "$home/$archive" \
      "setup error: retention should have used the configured archive under header form <$form>"
    assert_absent "$home/data/done-archive.md" \
      "setup error: the tracked default archive must stay unused, or this proves nothing"

    # The exact replay only reaches its record if the configured archive was the
    # file that got searched.
    out=$(run_captain "$home" answer sample-header-call --decision-file "$home/answer.txt" 2>&1) \
      || fail "the configured [markdown] archive was not found under header form <$form>: $out"
    assert_contains "$out" "answered: sample-header-call" \
      "the archived answer must replay under header form <$form>"
  done <<'EOF'
[markdown]
[markdown] # the markdown backend
[ markdown ]
CRLF
SINGLE_QUOTED_VALUES
EOF
  [ "$index" = 5 ] || fail "not every config form was exercised: $index"
  pass "every [markdown] config form tasks-axi honors still locates the configured archive"
}

# The mirror of the test above, and the guarantee that keeps this read from
# resolving a path retention never writes. tasks-axi does NOT honor a quoted
# `["markdown"]` table key: it ignores that table entirely and falls back to its
# own defaults. This read has to fall back too. If it honored the quoted key it
# would resolve the CONFIGURED archive while retention wrote somewhere else, so
# the lookup would search a file that is never written and an answered record
# would read as absent again - the exact failure this whole change removes,
# restored for one config spelling.
test_config_forms_tasks_axi_ignores_fall_back_the_same_way() {
  local home out
  home=$(make_home markdown-config-quoted-key)
  printf 'backend = "markdown"\n\n["markdown"]\npath = "data/live-rows.md"\narchive = "data/retired-rows.md"\ndone_keep = 0\n' \
    > "$home/.tasks.toml"

  tasks_in "$home" add sample-quoted-call "Choose the quoted option" --repo sample >/dev/null \
    || fail "could not create the call under a quoted table key"
  run_captain "$home" hold sample-quoted-call --reason "captain quoted choice pending" >/dev/null \
    || fail "could not hold the call under a quoted table key"
  printf 'Take the quoted option.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-quoted-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the answer under a quoted table key"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not run backlog retention under a quoted table key"

  # tasks-axi ignored the quoted table, so neither configured file was ever
  # written; it fell back and archived into this home's default archive instead.
  assert_absent "$home/data/live-rows.md" \
    "setup error: tasks-axi is expected to ignore a quoted table key, so the configured backlog must stay unwritten"
  assert_absent "$home/data/retired-rows.md" \
    "setup error: tasks-axi is expected to ignore a quoted table key, so the configured archive must stay unwritten"
  assert_grep "sample-quoted-call" "$home/data/done-archive.md" \
    "setup error: retention should have fallen back to this home's default archive"

  # So this read has to fall back to that same file. Honoring the quoted key would
  # point it at the configured archive instead, which retention never wrote, and
  # the exact replay below would then find no record at all.
  out=$(run_captain "$home" answer sample-quoted-call --decision-file "$home/answer.txt" 2>&1) \
    || fail "the fallback archive tasks-axi actually wrote was not the file this read searched: $out"
  assert_contains "$out" "answered: sample-quoted-call" \
    "an archived answer must replay out of the same fallback archive tasks-axi wrote"
  pass "a config form tasks-axi ignores falls back here exactly as it does there"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_archived_captain_answer_still_completes_the_investigation
test_unanswered_and_absent_captain_calls_still_fail_distinguishably
test_archived_records_are_readable_but_never_written
test_a_row_archived_mid_batch_is_still_read_out_of_the_archive
test_archived_origin_still_owns_a_later_review_pass
test_unopenable_archive_refuses_instead_of_reading_as_absent
test_an_archive_read_error_never_disowns_the_origin
test_an_unsettled_archive_read_outranks_the_legacy_identity
test_an_archive_skip_names_the_probed_legacy_identity
test_no_staged_archive_view_survives_a_reader
test_markdown_config_forms_all_locate_the_archive
test_config_forms_tasks_axi_ignores_fall_back_the_same_way
