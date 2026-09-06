#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/treehouse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/treehouse-helpers.sh"

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
  fm_fake_exit0 "$fakebin" tmux no-mistakes gh gh-axi
  fm_test_write_active_treehouse_fake "$fakebin"
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

# Direct unit test on the pure resolution function: resolve_entry -> id or
# failure. fm-captain-hold.sh's own bottom dispatch would exit if the file
# were sourced whole, so resolve_entry and its full call chain (backlog and
# archive lookups) are extracted from the executable and evaluated in an
# isolated subshell process alongside the real backlog libraries they
# depend on, never through the CLI dispatch this file's other tests use.
run_resolve_entry_unit() {  # <home> <origin> <entry>
  local home=$1 origin=$2 entry=$3
  bash -c '
    set -eu
    FM_ROOT=$1; STATE=$2; DATA=$3; origin=$4; entry=$5
    . "$FM_ROOT/bin/fm-classify-lib.sh"
    . "$FM_ROOT/bin/fm-tasks-axi-lib.sh"
    . "$FM_ROOT/bin/fm-backlog-transition-lib.sh"
    eval "$(sed -n "/^fail() {/,/^}/p; /^task_show() {/,/^}/p; /^captain_done_archive_file() {/,/^}/p; /^archive_row_show() {/,/^}/p; /^archive_row_exists() {/,/^}/p; /^archive_unclassified_fail() {/,/^}/p; /^task_show_or_archived() {/,/^}/p; /^resolve_entry() {/,/^}/p" "$FM_ROOT/bin/fm-captain-hold.sh")"
    CAPTAIN_BACKLOG_FILE=$(fm_backlog_file "$DATA")
    resolve_entry "$origin" "$entry"
  ' _ "$ROOT" "$home/state" "$home/data" "$origin" "$entry"
}

# Direct unit test on the pure admission decision the keyed-answer intake's
# --captured-from gate runs: (binding-origin|absent, given-origin) -> admit
# or skip. Extracted the same way run_resolve_entry_unit is: the function
# (and the BINDING_ANY constant it compares against) evaluated in an isolated
# subshell process, never through the CLI dispatch this file's other tests use.
run_captured_admission_unit() {  # <binding-origin> <given-origin>
  local binding_origin=$1 given_origin=$2
  bash -c '
    set -eu
    FM_ROOT=$1; binding_origin=$2; given_origin=$3
    eval "$(sed -n "/^BINDING_ANY=/p; /^captured_admission() {/,/^}/p" "$FM_ROOT/bin/fm-captain-hold.sh")"
    captured_admission "$binding_origin" "$given_origin"
  ' _ "$ROOT" "$binding_origin" "$given_origin"
}

# The task's stored body, decoded from `show --full` exactly the way the
# owner itself decodes it (show_field_value), so a test-side parsing
# shortcut can never diverge from what the CLI actually reads back.
run_show_body_unit() {  # <show-output>
  local show_output=$1
  bash -c '
    set -eu
    FM_ROOT=$1; output=$2
    eval "$(sed -n "/^show_field() {/,/^}/p; /^decode_shown_value() {/,/^}/p; /^show_field_value() {/,/^}/p" "$FM_ROOT/bin/fm-captain-hold.sh")"
    show_field_value "$output" body
  ' _ "$ROOT" "$show_output"
}

# The raw (still TOON-escaped, not JSON-decoded) stored body field. Command
# substitution strips trailing newlines from both a decoded actual value and
# a decoded expected value alike, so a decoded-only equality cannot see a
# trailing-newline drift the owner never produces but the contract still
# names: a raw escaped value carries that drift as literal trailing "\n"
# text, which command substitution never touches.
run_show_body_raw_unit() {  # <show-output>
  local show_output=$1
  bash -c '
    set -eu
    FM_ROOT=$1; output=$2
    eval "$(sed -n "/^show_field() {/,/^}/p" "$FM_ROOT/bin/fm-captain-hold.sh")"
    show_field "$output" body
  ' _ "$ROOT" "$show_output"
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

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  mkdir -p "$home/projects/sample"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "treehouse_lease=lease-$id" \
    "treehouse_slot=slot-fixture" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
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
    fm_wake_status_mark_current "$2" "$3"
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
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux no-mistakes gh gh-axi
  fm_test_write_active_treehouse_fake "$fakebin"
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
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    "$channel" "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    "$channel" "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    "$channel" "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    "$channel" "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    "$channel" "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
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

# Unit test on the pure resolution function itself: resolve_entry -> id or
# failure, called directly (not through the CLI), against a live backlog
# row, an answered archived row, and an entry that exists nowhere.
test_resolve_entry_direct_unit_backlog_and_archive() {
  local home out
  home=$(make_home resolve-entry-unit)

  tasks_in "$home" add sample-unit-backlog-call "Backlog unit call" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the backlog fixture"
  out=$(run_resolve_entry_unit "$home" "" "sample-unit-backlog-call") \
    || fail "resolve_entry did not resolve a live backlog row"
  [ "$out" = "sample-unit-backlog-call" ] \
    || fail "resolve_entry returned the wrong id for a live backlog row: $out"

  run_captain "$home" hold sample-unit-archived-call --title "Unit archived call" \
    --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not hold the archive fixture"
  printf 'Unit test decision.\n' > "$home/unit-decision.txt"
  run_captain "$home" answer sample-unit-archived-call --decision-file "$home/unit-decision.txt" >/dev/null \
    || fail "could not answer the archive fixture"
  tasks_in "$home" "done" sample-unit-archived-call --keep 0 >/dev/null \
    || fail "could not archive the answered fixture"
  out=$(run_resolve_entry_unit "$home" "" "sample-unit-archived-call") \
    || fail "resolve_entry did not resolve an answered archived row"
  [ "$out" = "sample-unit-archived-call" ] \
    || fail "resolve_entry returned the wrong id for an archived row: $out"

  if out=$(run_resolve_entry_unit "$home" "" "sample-unit-missing-anywhere" 2>"$home/unit-missing.err"); then
    fail "resolve_entry resolved an entry that exists nowhere: $out"
  fi
  assert_grep "no captain-held task sample-unit-missing-anywhere" "$home/unit-missing.err" \
    "resolve_entry must fail for a genuinely absent entry"

  pass "resolve_entry resolves directly from both the backlog and the archive, and fails for a genuinely absent entry"
}

# Ordinary Done retention archives an answered captain call into
# data/done-archive.md under a real `## Archived <date>` heading; verify and
# complete must still resolve it there, read-only, and the archive itself
# must stay byte-identical (mutation stays impossible). A done row without a
# resolution record fails closed instead of being treated as durable (the
# held branch never covers an archived row), and answer refuses to touch an
# archived row instead of replaying or reopening it.
test_archived_answer_resolves_for_verify_and_complete() {
  local home id before after backlog_before backlog_after archive_view_before archive_view_after
  home=$(make_home archived-answer)
  id=sample-archive-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample archive resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archive-gate origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample archive review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-archive-call \
    --title "Choose the sample archive path" --reason "captain archive choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-archive-call >/dev/null \
    || fail "completion failed before the answer"
  printf 'Captain chose the north archive path.\n' > "$home/archive-decision.txt"
  run_captain "$home" answer sample-archive-call --decision-file "$home/archive-decision.txt" >/dev/null \
    || fail "could not answer the captain-held task"
  tasks_in "$home" "done" sample-archive-call --keep 0 >/dev/null \
    || fail "could not archive the answered captain call"
  rg '^## Archived ' "$home/data/done-archive.md" >/dev/null \
    || fail "the fixture did not produce a real Archived heading"
  rg '^- \[x\] sample-archive-call - ' "$home/data/done-archive.md" >/dev/null \
    || fail "the answered captain call was not archived"
  ! rg '^- \[[ x]\] sample-archive-call - ' "$home/data/backlog.md" >/dev/null \
    || fail "the answered captain call remained in the live backlog after archiving"

  before=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  run_captain "$home" verify "$id" >/dev/null \
    || fail "verify did not resolve an answered call archived under a real Archived heading"
  after=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "resolving an archived call mutated the archive"
  # Each normalized view is private to the call that built it and removed
  # before that call returns, so none may survive past the command that
  # built it.
  [ -z "$(find "$home/state" -maxdepth 1 -name 'fm-captain-hold-archive.*' 2>/dev/null)" ] \
    || fail "verify left a normalized archive view file behind in state"

  # complete's OWN inventory verification (fm-captain-hold.sh :895-904), not
  # only verify's, must resolve an entry that retention has already archived.
  before=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  run_captain "$home" complete "$id" sample-archive-call >/dev/null \
    || fail "complete did not resolve an answered call archived under a real Archived heading"
  after=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "complete's inventory check mutated the archive"

  tasks_in "$home" add sample-unanswered-call "Choose without answering" --repo sample --start >/dev/null \
    || fail "could not create the unanswered archive fixture"
  run_captain "$home" hold sample-unanswered-call --reason "captain choice pending" >/dev/null \
    || fail "could not hold the unanswered archive fixture"
  run_captain "$home" complete "$id" sample-unanswered-call >/dev/null \
    || fail "could not inventory the unanswered archive fixture"
  tasks_in "$home" "done" sample-unanswered-call --keep 0 >/dev/null \
    || fail "could not archive the unanswered captain call"
  if run_captain "$home" verify "$id" > "$home/unanswered-verify.out" 2> "$home/unanswered-verify.err"; then
    fail "verify accepted a done archived row with no recorded answer"
  fi
  assert_grep "neither held for the captain nor closed with a recorded captain answer" \
    "$home/unanswered-verify.err" \
    "an unanswered archived row must fail closed with the existing durability message"

  # A done archived row without a recorded answer is not proof "nothing is
  # owed": the mutation-path refusal must never claim that for the exact row
  # this fixture proves is unanswered, and must not create a duplicate over it.
  printf 'Would-be captain decision.\n' > "$home/unanswered-decision.txt"
  if run_captain "$home" answer sample-unanswered-call --decision-file "$home/unanswered-decision.txt" \
    > "$home/unanswered-answer.out" 2> "$home/unanswered-answer.err"; then
    fail "answer accepted a done archived row with no recorded answer"
  fi
  assert_no_grep "nothing is owed" "$home/unanswered-answer.err" \
    "answer must never claim nothing is owed for a done-but-unanswered archived row"
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/unanswered-answer.err" \
    "answer against a done-but-unanswered archived row must give the restore-or-repair reason"
  if run_captain "$home" hold sample-unanswered-call --title "Choose without answering" \
    --reason "captain choice pending" --repo sample \
    > "$home/unanswered-hold.out" 2> "$home/unanswered-hold.err"; then
    fail "hold created a duplicate over a done-but-unanswered archived row"
  fi
  assert_no_grep "nothing is owed" "$home/unanswered-hold.err" \
    "hold must never claim nothing is owed for a done-but-unanswered archived row"
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/unanswered-hold.err" \
    "hold against a done-but-unanswered archived row must give the restore-or-repair reason"
  assert_no_grep "sample-unanswered-call - Choose without answering" "$home/data/backlog.md" \
    "hold must not have created a duplicate task in the live backlog"

  # Prose alone ("nothing is owed") is not proof nothing was actually
  # written: snapshot both backing files and the row's own reader state
  # before the refusal and assert byte-for-byte and state-for-state identity
  # after, so a refusal that quietly wrote anyway would fail this case.
  backlog_before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  before=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  sed 's/^## Archived .*$/## Done/' "$home/data/done-archive.md" > "$home/archive-view-before.md"
  archive_view_before=$(tasks-axi show sample-archive-call --full --file "$home/archive-view-before.md")
  if run_captain "$home" answer sample-archive-call --decision-file "$home/archive-decision.txt" \
    > "$home/answer-archived.out" 2> "$home/answer-archived.err"; then
    fail "answer mutated or replayed against an archived task"
  fi
  assert_grep "is archived (" "$home/answer-archived.err" \
    "answer against an archived row must name the archive, never a mutation"
  assert_grep "nothing is owed" "$home/answer-archived.err" \
    "answer against an archived row must say nothing is owed"
  backlog_after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  after=$(shasum -a 256 "$home/data/done-archive.md" | awk '{print $1}')
  sed 's/^## Archived .*$/## Done/' "$home/data/done-archive.md" > "$home/archive-view-after.md"
  archive_view_after=$(tasks-axi show sample-archive-call --full --file "$home/archive-view-after.md")
  [ "$backlog_before" = "$backlog_after" ] \
    || fail "an archived-answer refusal must never mutate the live backlog"
  [ "$before" = "$after" ] \
    || fail "an archived-answer refusal must never mutate the archive"
  [ "$archive_view_before" = "$archive_view_after" ] \
    || fail "an archived-answer refusal must never change the row's own reader state"

  pass "archived answers still resolve read-only for verify and complete, without a false positive on an unanswered row"
}

# Fail-closed paths around the archive fallback: a genuinely absent entry is
# never misreported, an unresolved hold archived by mistake is never read as
# an open or done task (the real reader returns NOT_FOUND, never a
# manufactured state), a structurally broken archive fails naming its own
# path, and a genuinely unreadable backlog fails naming the backlog path
# without ever touching an archive that would otherwise resolve.
test_archive_fallback_fails_closed_on_broken_records() {
  local home id
  home=$(make_home archive-fail-closed)
  id=sample-archive-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard archive resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guard origin"
  write_origin_meta "$home" "$id"

  cat >> "$home/data/done-archive.md" <<'EOF'

## Archived 2026-09-04
- [ ] sample-mistaken-hold - Held but archived by mistake (repo: sample) (hold: captain choice pending) (hold-kind: captain)
  Some body text, never a resolution record.

## Queued
- [ ] sample-nondone-archived-row - A row under a heading normalization never rewrites (repo: sample) (hold: captain choice pending) (hold-kind: captain)
  Some body text, also never a resolution record.
EOF

  if run_captain "$home" complete "$id" sample-truly-nothing \
    > "$home/nothing.out" 2> "$home/nothing.err"; then
    fail "completion accepted an entry that names no task anywhere"
  fi
  assert_no_grep "cannot be read as an answered call" "$home/nothing.err" \
    "a genuinely absent entry must not be misreported as an unclassifiable archived row"

  if run_captain "$home" complete "$id" sample-mistaken-hold \
    > "$home/mistaken.out" 2> "$home/mistaken.err"; then
    fail "completion accepted an unresolved hold archived by mistake"
  fi
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/mistaken.err" \
    "an unclassifiable archived row must fail closed instead of being read as open or done"

  # A row under a heading normalization never touches (anything but the real
  # `## Archived <date>` form) reads back with a real, non-done state - not
  # NOT_FOUND - and is exactly as unclassifiable as the unchecked case above,
  # never the generic "neither held nor closed" wording.
  if run_captain "$home" complete "$id" sample-nondone-archived-row \
    > "$home/nondone.out" 2> "$home/nondone.err"; then
    fail "completion accepted a readable non-done archived row"
  fi
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/nondone.err" \
    "a readable non-done archived row must give the restore-or-repair reason, not the generic durability message"
  assert_no_grep "neither held for the captain nor closed with a recorded captain answer" \
    "$home/nondone.err" \
    "a readable non-done archived row must not get the backlog-style generic message"

  # Mutation-path presence alone is not proof of an answer: a row that
  # exists in the archive but cannot be classified must never be told
  # "nothing is owed", since it may still be genuinely open.
  printf 'Would-be captain decision.\n' > "$home/mistaken-decision.txt"
  if run_captain "$home" answer sample-mistaken-hold --decision-file "$home/mistaken-decision.txt" \
    > "$home/mistaken-answer.out" 2> "$home/mistaken-answer.err"; then
    fail "answer accepted an unresolved hold archived by mistake"
  fi
  assert_no_grep "nothing is owed" "$home/mistaken-answer.err" \
    "an unclassifiable archived row must never be told nothing is owed"
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/mistaken-answer.err" \
    "answer against an unclassifiable archived row must fail closed with the same restore-or-repair message"
  if run_captain "$home" hold sample-mistaken-hold --title "Choose the mistaken path" \
    --reason "captain choice pending" --repo sample \
    > "$home/mistaken-hold.out" 2> "$home/mistaken-hold.err"; then
    fail "hold recreated a task id that is an unresolved hold archived by mistake"
  fi
  assert_no_grep "nothing is owed" "$home/mistaken-hold.err" \
    "hold must never claim nothing is owed for an unclassifiable archived row"
  assert_grep "cannot be read as an answered call; restore the row to the backlog or repair the archive by hand" \
    "$home/mistaken-hold.err" \
    "hold against an unclassifiable archived row must fail closed with the same restore-or-repair message"

  rm -f "$home/data/done-archive.md"
  mkdir -p "$home/data/done-archive.md"
  if run_captain "$home" complete "$id" sample-missing-anywhere \
    > "$home/broken-archive.out" 2> "$home/broken-archive.err"; then
    fail "completion consulted a directory standing in for the archive instead of failing"
  fi
  assert_grep "$home/data/done-archive.md" "$home/broken-archive.err" \
    "a structurally broken archive must fail naming its own path"

  # A structural archive failure must never be swallowed into an ordinary
  # miss: hold must refuse rather than silently creating a fresh task over
  # an id it could not actually clear.
  if run_captain "$home" hold sample-broken-archive-fresh-id \
    --title "Choose a path" --reason "captain choice pending" --repo sample \
    > "$home/broken-archive-hold.out" 2> "$home/broken-archive-hold.err"; then
    fail "hold created a task while the archive was structurally unreadable"
  fi
  assert_grep "$home/data/done-archive.md" "$home/broken-archive-hold.err" \
    "hold must fail naming the broken archive path instead of proceeding"
  assert_no_grep "sample-broken-archive-fresh-id" "$home/data/backlog.md" \
    "hold must not have created the task despite the archive read failure"
  # The admission check's staging temp is cleaned by the EXIT trap even when
  # a nested fail() inside archive_row_show ends the process before
  # archive_row_answered's own rm -f line can run; this must hold on every
  # structural-failure path, not just the ones exercised as non-root above.
  [ -z "$(find "$home/state" -maxdepth 1 -name 'fm-captain-hold-check.*' 2>/dev/null)" ] \
    || fail "a structurally broken archive left an admission check temp file behind in state"
  rmdir "$home/data/done-archive.md"

  if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable-archive case skipped as root"
  else
    printf '\n## Archived 2026-09-04\n- [x] sample-unreadable-archive-row - Title (repo: sample) (done 2026-09-04)\n' \
      > "$home/data/done-archive.md"
    chmod 000 "$home/data/done-archive.md"
    if run_captain "$home" hold sample-unreadable-archive-fresh-id \
      --title "Choose a path" --reason "captain choice pending" --repo sample \
      > "$home/unreadable-archive-hold.out" 2> "$home/unreadable-archive-hold.err"; then
      chmod 644 "$home/data/done-archive.md"
      fail "hold created a task while the archive was unreadable"
    fi
    chmod 644 "$home/data/done-archive.md"
    assert_grep "$home/data/done-archive.md" "$home/unreadable-archive-hold.err" \
      "hold must fail naming the unreadable archive path instead of proceeding"
    assert_no_grep "sample-unreadable-archive-fresh-id" "$home/data/backlog.md" \
      "hold must not have created the task despite the unreadable archive"
    [ -z "$(find "$home/state" -maxdepth 1 -name 'fm-captain-hold-check.*' 2>/dev/null)" ] \
      || fail "an unreadable archive left an admission check temp file behind in state"
  fi

  # A dangling symlink at the archive path is structurally broken, never
  # evidence the archive was never created.
  rm -f "$home/data/done-archive.md"
  ln -s "$home/data/nonexistent-archive-target.md" "$home/data/done-archive.md"
  if run_captain "$home" hold sample-dangling-symlink-fresh-id \
    --title "Choose a path" --reason "captain choice pending" --repo sample \
    > "$home/dangling-hold.out" 2> "$home/dangling-hold.err"; then
    fail "hold created a task while the archive was a dangling symlink"
  fi
  assert_grep "$home/data/done-archive.md" "$home/dangling-hold.err" \
    "hold must fail naming the dangling-symlink archive path instead of proceeding"
  assert_no_grep "sample-dangling-symlink-fresh-id" "$home/data/backlog.md" \
    "hold must not have created the task despite the dangling-symlink archive"
  rm -f "$home/data/done-archive.md"

  if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable-backlog case skipped as root"
  else
    run_captain "$home" hold sample-real-archived-call \
      --title "Choose the real archived path" --reason "captain choice pending" --repo sample >/dev/null \
      || fail "could not register the would-resolve archived fixture"
    run_captain "$home" complete "$id" sample-real-archived-call >/dev/null \
      || fail "could not inventory the would-resolve archived fixture"
    printf 'Captain chose the would-resolve archive path.\n' > "$home/would-resolve.txt"
    run_captain "$home" answer sample-real-archived-call --decision-file "$home/would-resolve.txt" >/dev/null \
      || fail "could not answer the would-resolve archived fixture"
    tasks_in "$home" "done" sample-real-archived-call --keep 0 >/dev/null \
      || fail "could not archive the would-resolve fixture"
    rg -q '^- \[x\] sample-real-archived-call - ' "$home/data/done-archive.md" \
      || fail "the would-resolve fixture was not actually archived"
    chmod 000 "$home/data/backlog.md"
    if run_captain "$home" verify "$id" > "$home/unreadable.out" 2> "$home/unreadable.err"; then
      chmod 644 "$home/data/backlog.md"
      fail "verify treated an unreadable backlog as permission to fall back to the archive"
    fi
    chmod 644 "$home/data/backlog.md"
    assert_grep "$home/data/backlog.md" "$home/unreadable.err" \
      "an unreadable backlog must fail naming the backlog path"
    assert_no_grep "done-archive" "$home/unreadable.err" \
      "an unreadable backlog must never consult the archive"
  fi

  pass "the archive fallback fails closed on an unclassifiable row, a broken archive, and an unreadable backlog, without a false positive on a genuinely absent entry"
}

# The existing keyed-answer intake (command_answers) wraps resolve_entry in a
# command substitution with stderr discarded; a structural archive failure
# reaching it must still be named, not silently converted into the same
# "skipped: ... missing" line a genuine miss gets. A live backlog row must
# stay answerable through an unrelated broken archive, since resolve_entry
# only ever consults the archive on a true backlog miss.
test_answers_keyed_intake_names_archive_failures() {
  local home id backlog_before backlog_after show
  home=$(make_home answers-archive-failure)
  id=sample-answers-archive-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard keyed-answer archive resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guard origin"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-answers-live-call --title "Choose the live path" \
    --reason "captain choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the live-hit fixture"

  rm -f "$home/data/done-archive.md"
  mkdir -p "$home/data/done-archive.md"

  printf 'sample-answers-live-call\tgo with the live path\tlabel\n' \
    | run_captain "$home" answers --source fixture > "$home/live-hit.out" 2> "$home/live-hit.err"
  assert_contains "$(cat "$home/live-hit.out")" "closed: sample-answers-live-call" \
    "a live backlog row must still answer despite an unrelated broken archive"
  show=$(tasks_in "$home" show sample-answers-live-call --full)
  assert_contains "$show" "state: done" \
    "the live-hit answer said closed but left the row's own state open"
  assert_contains "$show" "Answer: go with the live path" \
    "the live-hit answer said closed but never recorded the captain's actual answer"

  backlog_before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  set +e
  printf 'sample-answers-missing-anywhere\tgo\tlabel\n' \
    | run_captain "$home" answers --source fixture > "$home/broken.out" 2> "$home/broken.err"
  set -e
  assert_no_grep "no captain-held task with that id" "$home/broken.out" \
    "a structural archive failure reaching the keyed intake must not read as an ordinary missing-key"
  assert_grep "$home/data/done-archive.md" "$home/broken.out" \
    "a structural archive failure reaching the keyed intake must name the archive path"
  backlog_after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$backlog_before" = "$backlog_after" ] \
    || fail "a structural archive failure reaching the keyed intake must never mutate the backlog"

  rmdir "$home/data/done-archive.md"

  set +e
  printf 'sample-answers-genuinely-absent\tgo\tlabel\n' \
    | run_captain "$home" answers --source fixture > "$home/genuine-miss.out" 2> "$home/genuine-miss.err"
  set -e
  assert_grep "skipped: sample-answers-genuinely-absent" "$home/genuine-miss.out" \
    "a genuine miss with no archive at all must still report the ordinary skipped line"

  pass "the keyed-answer intake names a structural archive failure instead of a generic missing-key skip"
}

# task_show_or_archived's contract says any non-NOT_FOUND backlog error fails
# naming the backlog and never consults the archive, but a bare "return 1"
# made that indistinguishable from a genuine absence: a transient backend
# failure (never NOT_FOUND) could let hold silently create a duplicate over
# an id it never actually cleared, and let verify silently fall back to the
# archive for a row that might still be live.
test_backlog_read_error_never_reads_as_a_miss() {
  local home id origin backlog_before backlog_after
  home=$(make_home backlog-read-error)
  id=sample-backend-failure-id
  origin=sample-backend-failure-origin
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: backend unavailable\n' >&2
  exit 73
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  backlog_before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  if TASKS_AXI_FAIL_SHOW_ID="$id" run_captain "$home" hold "$id" \
    --title "Choose a path" --reason "captain choice pending" --repo sample \
    > "$home/hold.out" 2> "$home/hold.err"; then
    fail "hold created a task while the backlog read a non-NOT_FOUND error"
  fi
  assert_grep "$home/data/backlog.md" "$home/hold.err" \
    "hold must fail naming the backlog path instead of treating a read error as absence"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "hold must not have created the task despite the backlog read error"
  backlog_after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$backlog_before" = "$backlog_after" ] \
    || fail "hold must never mutate the backlog when it could not read the target id"

  # The entry must exist and be inventoried WHILE the backlog is still
  # healthy - the read failure is injected only afterward, for verify's own
  # later resolution attempt.
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Guard backlog read-error resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guard origin"
  write_origin_meta "$home" "$origin"
  run_captain "$home" hold "$id" --title "Choose the live path" \
    --reason "captain choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "could not register the live fixture before injecting the read error"
  run_captain "$home" complete "$origin" "$id" >/dev/null \
    || fail "could not inventory the live fixture before injecting the read error"

  if TASKS_AXI_FAIL_SHOW_ID="$id" run_captain "$home" verify "$origin" \
    > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify treated a backlog read error as permission to fall back to the archive"
  fi
  assert_grep "$home/data/backlog.md" "$home/verify.err" \
    "verify must fail naming the backlog path instead of treating a read error as absence"
  assert_no_grep "done-archive" "$home/verify.err" \
    "verify must never consult the archive when the backlog read itself failed"

  pass "a non-NOT_FOUND backlog read error fails naming the backlog, never reading as a miss"
}

# The all-fail stub above only ever exercises task_show_or_archived: hold's
# own outer "if show=$(task_show "$id"); then ... else" and command_answer's
# equivalent read the FIRST task_show result directly and, on any failure at
# all, unconditionally enter the archive/create branch, which then makes its
# OWN, second and independent task_show attempt (via archive_row_answered).
# A stub that fails every call cannot tell a fixed inner helper from a still-
# open outer boundary, since both make the second attempt fail too. A stub
# that fails only the FIRST call and succeeds afterward isolates it: the
# second attempt then reads a genuine NOT_FOUND, and an unfixed outer
# boundary creates the task anyway.
test_hold_and_answer_refuse_on_a_one_shot_backlog_read_error() {
  local home id origin backlog_before backlog_after counter archive_queries
  home=$(make_home one-shot-read-error)
  id=sample-one-shot-failure-id
  origin=sample-one-shot-failure-origin
  counter="$home/one-shot-counter"
  archive_queries="$home/archive-query-counter"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_ONE_SHOT_FAIL_ID:-}" ]; then
  n=0
  [ -f "${TASKS_AXI_ONE_SHOT_COUNTER:?}" ] && n=$(cat "$TASKS_AXI_ONE_SHOT_COUNTER")
  n=$((n + 1))
  printf '%s' "$n" > "$TASKS_AXI_ONE_SHOT_COUNTER"
  if [ "$n" -eq 1 ]; then
    printf 'error: backend unavailable\n' >&2
    exit 73
  fi
fi
if [ "${1:-}" = show ] && [ -n "${TASKS_AXI_ARCHIVE_QUERY_COUNTER:-}" ]; then
  prev=''
  for arg in "$@"; do
    # Every ordinary backlog read also passes --file (pointing at
    # backlog.md), so bare presence of the flag cannot tell an archive query
    # apart from an ordinary one. Only the VALUE distinguishes them: the
    # archive's own normalized view is always a fresh mktemp matching
    # archive_row_show's own fm-captain-hold-archive.* pattern.
    if [ "$prev" = --file ]; then
      case "$arg" in
        */fm-captain-hold-archive.*)
          m=0
          [ -f "$TASKS_AXI_ARCHIVE_QUERY_COUNTER" ] && m=$(cat "$TASKS_AXI_ARCHIVE_QUERY_COUNTER")
          m=$((m + 1))
          printf '%s' "$m" > "$TASKS_AXI_ARCHIVE_QUERY_COUNTER"
          ;;
      esac
      break
    fi
    prev=$arg
  done
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  backlog_before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  : > "$counter"
  if TASKS_AXI_ONE_SHOT_FAIL_ID="$id" TASKS_AXI_ONE_SHOT_COUNTER="$counter" run_captain "$home" hold "$id" \
    --title "Choose a path" --reason "captain choice pending" --repo sample \
    > "$home/hold.out" 2> "$home/hold.err"; then
    fail "hold created a task after a single transient backlog read error, on the strength of the second, incidental read"
  fi
  assert_grep "$home/data/backlog.md" "$home/hold.err" \
    "a one-shot backlog read error must fail naming the backlog, not fall through on the second read"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "hold must not have created the task despite the one-shot backlog read error"
  backlog_after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$backlog_before" = "$backlog_after" ] \
    || fail "hold must never mutate the backlog over a one-shot read error"

  # Build a genuinely archived, UNRELATED row first, so the "zero archive
  # queries" assertion below is meaningful: a done-archive.md that does not
  # exist at all short-circuits archive_row_show before any tasks-axi call
  # (archive_row_show's own [ -e "$archive" ] || return 1), which would make
  # a zero reading pass trivially regardless of whether the fix works. This
  # same fixture also doubles as the positive control below, proving the
  # counter itself actually counts.
  mkdir -p "$home/data/sample-one-shot-control-origin"
  tasks_in "$home" add sample-one-shot-control-origin "Archive-counter control origin" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archive-counter control origin"
  write_origin_meta "$home" sample-one-shot-control-origin
  run_captain "$home" hold sample-one-shot-control-archived --title "Archived control" \
    --reason "captain choice pending" --repo sample --origin sample-one-shot-control-origin >/dev/null \
    || fail "could not hold the archive-counter control fixture"
  run_captain "$home" complete sample-one-shot-control-origin sample-one-shot-control-archived >/dev/null \
    || fail "could not inventory the archive-counter control fixture"
  printf 'Captain chose the control path.\n' > "$home/control-decision.txt"
  run_captain "$home" answer sample-one-shot-control-archived --decision-file "$home/control-decision.txt" >/dev/null \
    || fail "could not answer the archive-counter control fixture"
  tasks_in "$home" "done" sample-one-shot-control-archived --keep 0 >/dev/null \
    || fail "could not archive the answered control fixture"
  rg -q '^## Archived ' "$home/data/done-archive.md" \
    || fail "the archive-counter control fixture did not produce a real archive to query against"

  # Read-only caller control, same one-shot failure, now against a home that
  # genuinely has an archive: verify must fail naming the backlog and must
  # never consult that archive on a transient error alone.
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Guard one-shot resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the guard origin"
  write_origin_meta "$home" "$origin"
  run_captain "$home" hold "$id" --title "Choose the live path" \
    --reason "captain choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "could not register the live fixture before injecting the one-shot error"
  run_captain "$home" complete "$origin" "$id" >/dev/null \
    || fail "could not inventory the live fixture before injecting the one-shot error"

  : > "$counter"
  rm -f "$archive_queries"
  if TASKS_AXI_ONE_SHOT_FAIL_ID="$id" TASKS_AXI_ONE_SHOT_COUNTER="$counter" \
    TASKS_AXI_ARCHIVE_QUERY_COUNTER="$archive_queries" run_captain "$home" verify "$origin" \
    > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify treated a one-shot backlog read error as permission to fall back to the archive"
  fi
  assert_grep "$home/data/backlog.md" "$home/verify.err" \
    "verify must fail naming the backlog path over a one-shot read error"
  # Before the fix, resolve_entry's own failure only ended its command-
  # substitution subshell, so verify_hold_durable ran again with an empty
  # id and printed a SECOND, misleading diagnostic on top of the correct
  # first one. The fix must leave exactly the one, correct message behind.
  assert_no_grep "Missing id" "$home/verify.err" \
    "verify's stderr must carry only the real backend error, not a second empty-id diagnostic"
  [ "$(wc -l < "$home/verify.err" | tr -d ' ')" -le 1 ] \
    || fail "verify's stderr must be a single failure line, not resolve_entry's message plus a second one: $(cat "$home/verify.err")"
  # A silent grep for "done-archive" in stderr is not proof the archive was
  # never queried: a SUCCESSFUL archive read prints nothing there either. Count
  # the actual normalized-view reads (every archive query passes --file) instead.
  # A real archive already exists (built above), so a zero reading here is
  # meaningful rather than trivial.
  [ ! -f "$archive_queries" ] || [ "$(cat "$archive_queries")" = 0 ] \
    || fail "verify must never consult the archive on a one-shot read error, but it queried it $(cat "$archive_queries") time(s)"

  # Positive control: the counter itself must actually count. Verifying the
  # genuinely archived row built above, through the real fallback (no
  # one-shot failure injected), must register at least one archive query.
  rm -f "$archive_queries"
  TASKS_AXI_ARCHIVE_QUERY_COUNTER="$archive_queries" \
    run_captain "$home" verify sample-one-shot-control-origin >/dev/null \
    || fail "verify did not resolve the genuinely archived control fixture"
  [ -f "$archive_queries" ] && [ "$(cat "$archive_queries")" -ge 1 ] \
    || fail "the archive-query counter never incremented for a real archive fallback; the counter mechanism itself is broken"

  # Normal-creation control: a different id, never named by the wrapper's
  # target, is completely unaffected by this fix.
  run_captain "$home" hold sample-one-shot-control-id --title "Ordinary creation" \
    --reason "captain choice pending" --repo sample >/dev/null \
    || fail "an ordinary hold with no injected failure must still succeed"
  assert_grep "sample-one-shot-control-id" "$home/data/backlog.md" \
    "the ordinary control task must have been created"

  pass "hold and verify both refuse a one-shot backlog read error instead of accepting the second, incidental read"
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

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  set +e
  PATH="$home/fakebin:$PATH" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

# Table test on the pure decision: absent binding, a mismatched concrete
# origin, an exact match, the any-origin marker, and the any-origin marker
# against an empty given origin (the --any-origin caller shape) all resolve
# to the one right verdict with no task, backlog, or filesystem state at all.
test_captured_admission_decision_table() {
  local case_row expected binding_origin given_origin actual
  for case_row in \
    'skip||origin-a' \
    'skip|origin-a|origin-b' \
    'admit|origin-a|origin-a' \
    'admit|(any)|origin-a' \
    'admit|(any)|' \
  ; do
    IFS='|' read -r expected binding_origin given_origin <<<"$case_row"
    actual=$(run_captured_admission_unit "$binding_origin" "$given_origin")
    [ "$actual" = "$expected" ] \
      || fail "captured_admission(binding=$binding_origin given=$given_origin) = $actual, want $expected"
  done
  pass "the pure captured-source admission decision matches its table for absent, mismatched, exact, and any-origin bindings"
}

# The head-contract cases (a)-(f) from V4a.md: a captured source bound to
# another origin, an unbound source, a source bound to the given origin, a
# source bound any-origin, a wrong-schema binding record, and the direct
# owner path with no --captured-from at all. Real captain-held tasks and the
# real intake, no fixture wrapper: the race itself is proven separately
# against the real caller in the procevent suite.
test_captured_from_gates_the_keyed_intake() {
  local home out show rc expected_decision_body expected_decision_body_raw
  local expected_decision_body_digest actual_decision_body actual_decision_body_raw
  home=$(make_home captured-from-gate)
  run_captain "$home" hold call-a --title "Call A" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" hold call-b --title "Call B" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" hold call-c --title "Call C" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" hold call-d --title "Call D" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" hold call-e --title "Call E" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" hold call-f --title "Call F" --reason "captain choice pending" --repo sample >/dev/null

  # (a) bound to a different concrete origin than the one given: skipped, held.
  # A skipped key still reports the ordinary nonzero skip status (the same
  # discipline every other skip in this intake follows); the captured caller
  # (feed_keyed_answers) consumes that status to gate its own "answers-fed"
  # line, but capture publication and acknowledgement continue regardless
  # (best-effort continuation, not an ignored status).
  run_captain "$home" bind src-a origin-x >/dev/null
  set +e
  out=$(printf 'call-a\tyes\t\n' \
    | run_captain "$home" answers origin-y --captured-from src-a --source "gate fixture a" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a captured skip reported success: $out"
  assert_contains "$out" "skipped: call-a (captured source src-a is not bound for this origin)" \
    "a captured source bound to a different origin closed the call"
  show=$(tasks_in "$home" show call-a --full)
  assert_contains "$show" "state: queued" "case (a) closed a call it should have skipped"
  assert_contains "$show" "held: yes" "case (a) released a call it should have left held"

  # (b) no binding at all: skipped, held.
  set +e
  out=$(printf 'call-b\tyes\t\n' \
    | run_captain "$home" answers origin-y --captured-from src-b --source "gate fixture b" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a captured skip reported success: $out"
  assert_contains "$out" "skipped: call-b (captured source src-b is not bound for this origin)" \
    "an unbound captured source closed the call"
  show=$(tasks_in "$home" show call-b --full)
  assert_contains "$show" "state: queued" "case (b) closed a call it should have skipped"
  assert_contains "$show" "held: yes" "case (b) released a call it should have left held"

  # (g) --captured-from present with an EMPTY value must not alias the flag
  # being absent: an explicit empty source id is refused before any close, the
  # same as an invalid one, never silently treated as the direct owner path.
  run_captain "$home" hold call-g --title "Call G" --reason "captain choice pending" --repo sample >/dev/null
  set +e
  out=$(printf 'call-g\tyes\t\n' \
    | run_captain "$home" answers origin-y --captured-from "" --source "gate fixture g" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an empty --captured-from value closed a call: $out"
  assert_contains "$out" "source-id must be a non-empty privacy-safe slug" \
    "an empty --captured-from value was not refused as an invalid source id"
  assert_not_contains "$out" "closed: call-g" "an empty --captured-from value aliased the direct owner path"
  show=$(tasks_in "$home" show call-g --full)
  assert_contains "$show" "state: queued" "an empty --captured-from value closed a call anyway"
  assert_contains "$show" "held: yes" "an empty --captured-from value released a call anyway"

  # (c) bound to the given origin exactly: closes as today.
  run_captain "$home" bind src-c origin-y >/dev/null
  out=$(printf 'call-c\tyes\t\n' \
    | run_captain "$home" answers origin-y --captured-from src-c --source "gate fixture c") \
    || fail "a matching-origin captured answer did not close: $out"
  assert_contains "$out" "closed: call-c" "case (c) did not close a matching-origin captured answer"

  # (d) bound any-origin: closes regardless of the given origin.
  run_captain "$home" bind src-d >/dev/null
  out=$(printf 'call-d\tyes\t\n' \
    | run_captain "$home" answers origin-z --captured-from src-d --source "gate fixture d") \
    || fail "an any-origin captured answer did not close: $out"
  assert_contains "$out" "closed: call-d" "case (d) did not close an any-origin captured answer"

  # (e) a wrong-schema binding record: fails loudly naming the path, closes nothing.
  mkdir -p "$home/state/decision-bindings"
  printf 'schema=bogus\norigin=origin-y\n' > "$home/state/decision-bindings/src-e.origin"
  set +e
  out=$(printf 'call-e\tyes\t\n' \
    | run_captain "$home" answers origin-y --captured-from src-e --source "gate fixture e" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema binding record did not fail loudly"
  assert_contains "$out" "decision binding has an incompatible schema" \
    "the schema failure did not name the corrupt binding record"
  assert_contains "$out" "$home/state/decision-bindings/src-e.origin" \
    "the schema failure did not name the corrupt binding record's actual path"
  show=$(tasks_in "$home" show call-e --full)
  assert_contains "$show" "state: queued" "a wrong-schema binding closed a call anyway"
  assert_contains "$show" "held: yes" "a wrong-schema binding released a call anyway"

  # (f) no --captured-from: the direct owner path, unchanged. Driven exactly
  # as bin/fm-send.sh:626-627 does (--source only, no legacy-origin argument).
  # Asserted by exact equality against a fixed literal captured once from the
  # real base owner (ae39804d) for this exact input, never derived by calling
  # back into the same functions under test (that would let a shared bug in
  # both sides cancel out) and never a substring (a substring match cannot
  # tell a stored answer from one with the same prefix and different or
  # extra trailing content). The literal's own SHA-256 is asserted too, so a
  # reviewer can cross-check it independently without re-running the base.
  # Two equalities, not one: the decoded body (show_field_value) passes
  # through a command substitution on both the actual and the fixed-literal
  # side, and command substitution strips trailing newlines identically on
  # both, so a stored value with extra trailing newline bytes would still
  # match there. The raw, still-escaped field (show_field, before JSON
  # decoding) carries a trailing-newline drift as literal trailing "\n" text
  # instead, which command substitution never touches, so it is asserted too.
  out=$(printf 'call-f\tyes\t\n' | run_captain "$home" answers --source "gate fixture f") \
    || fail "the direct owner path regressed: $out"
  assert_contains "$out" "closed: call-f" "case (f) did not close without --captured-from"
  expected_decision_body=$'Resolution recorded by fm-captain-hold.\nDecision digest: d5230c6fecfe812c6bed59b36503ae2c891a4883b12a7c9dca93d53d7a97cc1c\nResolution mode: answered\n\nCaptain decision:\nCaptain answered this call through gate fixture f.\nTask: call-f\nAnswer: yes'
  expected_decision_body_raw='"Resolution recorded by fm-captain-hold.\nDecision digest: d5230c6fecfe812c6bed59b36503ae2c891a4883b12a7c9dca93d53d7a97cc1c\nResolution mode: answered\n\nCaptain decision:\nCaptain answered this call through gate fixture f.\nTask: call-f\nAnswer: yes"'
  if command -v shasum >/dev/null 2>&1; then
    expected_decision_body_digest=$(printf '%s' "$expected_decision_body" | shasum -a 256 | awk '{print $1}')
  else
    expected_decision_body_digest=$(printf '%s' "$expected_decision_body" | sha256sum | awk '{print $1}')
  fi
  [ "$expected_decision_body_digest" = 58d2868237a0e881b8528e42709d68424cd6b09422e7b2c6f02e59c86f353ca6 ] \
    || fail "the fixed base-owner literal in this test no longer matches its own recorded SHA-256"
  show=$(tasks_in "$home" show call-f --full)
  actual_decision_body=$(run_show_body_unit "$show")
  [ "$actual_decision_body" = "$expected_decision_body" ] \
    || fail "the direct owner path's decision record is not byte-identical to the base owner's: got $(printf '%q' "$actual_decision_body"), want $(printf '%q' "$expected_decision_body")"
  actual_decision_body_raw=$(run_show_body_raw_unit "$show")
  [ "$actual_decision_body_raw" = "$expected_decision_body_raw" ] \
    || fail "the direct owner path's raw stored field is not byte-identical to the base owner's: got $(printf '%q' "$actual_decision_body_raw"), want $(printf '%q' "$expected_decision_body_raw")"

  pass "the captured-from admission gate skips a mismatched, absent, or explicitly empty binding while leaving the call held, admits a matching or any-origin one, fails loudly on a corrupt record, and leaves the direct owner path unchanged"
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
test_secondmate_home_publishes_holds_and_answers
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_resolve_entry_direct_unit_backlog_and_archive
test_archived_answer_resolves_for_verify_and_complete
test_archive_fallback_fails_closed_on_broken_records
test_answers_keyed_intake_names_archive_failures
test_backlog_read_error_never_reads_as_a_miss
test_hold_and_answer_refuse_on_a_one_shot_backlog_read_error
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_teardown_never_closes_a_captain_held_task
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_captured_admission_decision_table
test_captured_from_gates_the_keyed_intake
