#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [calls-json]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" --argjson calls "${6:-[]}" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$calls, underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_full_snapshot_question_reaches_the_rendered_decision() {
  local home a b reason snapshot calls out
  home=$(make_home full-decision-question)
  a='A: retain the existing workflow through the complete staged verification and preserve all current integrations until each dependency has reported its result.'
  b='B: defer the independent migration until the remaining review has finished, keeping the full fallback route and the final café / 東京 approval.'
  reason="Which route should proceed? $a $b"
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] scope-call - Choose rollout scope (repo: sample) (kind: captain) (hold: $reason) (hold-kind: captain)

## Done
EOF
  snapshot=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bearings-snapshot.sh" --json) \
    || fail "the decision snapshot failed"
  # Composition consumes the complete recorded question directly. Options are
  # authored explicitly here, never inferred by parsing the stored prose.
  calls=$(printf '%s' "$snapshot" | jq '[.decisions_open[] | {
    key:.key,type:"decision",repo:"sample",title:"Rollout scope",decide:.question,
    options:[{value:"a",label:"Retain the workflow"},{value:"b",label:"Defer the migration"}]}]')
  out=$(render_board "$home" '[]' '[]' 0 0 "$calls")
  printf '%s' "$out" | jq -e --arg question "Choose rollout scope: $reason" --arg a "$a" --arg b "$b" '
    .error == "" and (.captains_call | length) == 1
      and (.captains_call[0] | contains($question) and contains($a) and contains($b))
  ' >/dev/null || fail "the rendered call lost its full question or final option: $out"
  pass "the complete snapshot question and options reach rendered decision text"
}

test_full_snapshot_question_reaches_the_rendered_decision

# Build a board with the given Captain's Call keys and run it under the drafts
# harness against a storage file shared across builds.
build_call_board() {  # <home> <keys-json> [charted-json]
  local home=$1 data="$1/payload.json"
  jq -n --argjson keys "$2" --argjson charted "${3:-[]}" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:$charted, charted_more:0, charted_warning_more:0,
    captains_call:[$keys[] | {key:., type:"decision", title:("Card " + .), repo:"r",
      about:"a", decide:"d", allow_freeform:true,
      options:[{value:"a",label:"A"},{value:"b",label:"B"}]}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
}

test_a_rebuild_keeps_in_progress_answers_and_drops_only_departed_cards() {
  local home out
  home=$(make_home drafts)
  build_call_board "$home" '["k1","k2"]'
  node "$ROOT/tests/assets/board-drafts-harness.mjs" "$home/.lavish/bearings-board.html" "$home/storage.json" type >/dev/null \
    || fail "the first board could not be filled in"
  build_call_board "$home" '["k1","k3"]'
  out=$(node "$ROOT/tests/assets/board-drafts-harness.mjs" "$home/.lavish/bearings-board.html" "$home/storage.json") \
    || fail "the rebuilt board could not be rendered"
  printf '%s' "$out" | jq -e '
    (.cards | map(.key)) == ["k1","k3"]
      and .cards[0].selection == "a" and .cards[0].note == "typed k1"
      and .cards[1].selection == "" and .cards[1].note == ""
      and ((.storage | to_entries[0].value | fromjson | keys) == ["k1"])
  ' >/dev/null || fail "a rebuild lost or kept the wrong in-progress input: $out"
  pass "a rebuild keeps in-progress answers for surviving cards and drops departed ones"
}

# Run the built board under the browser harness: <home> <actions> [env...].
run_board() {  # <home> <actions>
  node "$ROOT/tests/assets/board-drafts-harness.mjs" "$1/.lavish/bearings-board.html" "$1/storage.json" "$2" \
    || fail "the board could not be exercised with: $2"
}

CHARTED_TWO='[{"id":"t1","repo":"r","title":"One","reason":"queued","dispatchable":true},
  {"id":"t2","repo":"r","title":"Two","reason":"queued","dispatchable":true}]'

test_dispatch_picks_survive_a_refresh_with_or_without_browser_storage() {
  local home out
  home=$(make_home picks)
  build_call_board "$home" '["k1"]' "$CHARTED_TWO"
  run_board "$home" "pick:t1,pick:t2" >/dev/null
  out=$(run_board "$home" "")
  printf '%s' "$out" | jq -e '.picks == ["t1","t2"] and .bar.disabled == false and (.bar.count | startswith("2 picked"))' >/dev/null \
    || fail "a refresh lost the dispatch picks held in browser storage: $out"
  # A sandboxed frame has no storage, so only Lavish's own restore can bring the picks back.
  home=$(make_home picks-sandboxed)
  build_call_board "$home" '["k1"]' "$CHARTED_TWO"
  NO_STORAGE=1 run_board "$home" "pick:t2" >/dev/null
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '.picks == ["t2"] and .bar.disabled == false and (.bar.count | startswith("1 picked"))' >/dev/null \
    || fail "a sandboxed refresh lost the dispatch picks: $out"
  # Picks for work that left the chart drop away.
  build_call_board "$home" '["k1"]' '[{"id":"t1","repo":"r","title":"One","reason":"queued","dispatchable":true}]'
  out=$(run_board "$home" "")
  printf '%s' "$out" | jq -e '.picks == []' >/dev/null || fail "a pick for departed work survived: $out"
  pass "dispatch picks survive a refresh, in a sandboxed frame too, and drop with departed work"
}

test_a_queued_answer_shows_as_queued_after_a_refresh_and_is_not_queued_twice() {
  local home out
  home=$(make_home queued-badge)
  build_call_board "$home" '["k1","k2"]' "$CHARTED_TWO"
  NO_STORAGE=1 run_board "$home" "type,submit:k1,pick:t1,dispatch" >/dev/null
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    .calls == [] and .bar.queued == true
      and (.cards | map({key, queued}) == [{key:"k1",queued:true},{key:"k2",queued:false}])
      and (.queue | sort) == ["dispatch.charted","question:k1"]
  ' >/dev/null || fail "a refresh did not restore the queued badges, or queued an answer again: $out"
  pass "a refresh restores the queued badges and queues nothing a second time"
}

test_an_answer_the_chrome_already_sent_is_not_queued_again() {
  local home out
  home=$(make_home sent)
  build_call_board "$home" '["k1"]' "$CHARTED_TWO"
  run_board "$home" "type,submit:k1,pick:t1,dispatch,load" >/dev/null
  # The captain sends the queue from the chrome while the board is open.
  out=$(run_board "$home" "load,send")
  printf '%s' "$out" | jq -e '.cards[0].state == "sent" and .cards[0].queued == true and .bar.queued == true and .queue == []' >/dev/null \
    || fail "the board did not note that the chrome sent the answers: $out"
  # After a new tab (no chrome queue) the kept copies must not come back.
  rm -f "$home/storage.json.session.json"
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '.calls == [] and .queue == []' >/dev/null \
    || fail "an answer already sent was queued again: $out"
  # A refresh in the same tab keeps showing it as answered and still queues nothing.
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '.calls == [] and .queue == []' >/dev/null || fail "a refresh requeued a sent answer: $out"
  pass "an answer the chrome already sent is never queued again"
}

test_an_unsent_answer_is_queued_again_in_a_new_tab_exactly_once() {
  local home out
  home=$(make_home requeue)
  build_call_board "$home" '["k1"]' "$CHARTED_TWO"
  run_board "$home" "type,submit:k1,pick:t1,dispatch,load" >/dev/null
  # New tab: the chrome queue is gone, the browser store still has both answers.
  rm -f "$home/storage.json.session.json"
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    (.calls | length) == 2
      and ([.calls[].key] | sort) == ["dispatch.charted","question:k1"]
      and ([.calls[] | select(.key == "question:k1") | .data] == [{schema:"fm-bearings-answer.v1",question:"k1",selection:"a",note:"typed k1"}])
      and ([.calls[] | select(.key == "dispatch.charted") | .data] == [{question:"dispatch.charted",answer:"t1"}])
      and .cards[0].queued == true and .bar.queued == true
  ' >/dev/null || fail "an unsent answer was not queued again in a new tab: $out"
  # Reloading that same tab finds the answers still queued, so nothing more is queued.
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '.calls == []' >/dev/null || fail "the restored answers were queued twice: $out"
  pass "an unsent answer is queued again in a new tab exactly once"
}

test_a_kept_dispatch_order_is_dropped_when_its_work_left_the_chart() {
  local home out
  home=$(make_home requeue-departed)
  build_call_board "$home" '["k1","k2"]' "$CHARTED_TWO"
  run_board "$home" "type,submit:k1,submit:k2,pick:t1,pick:t2,dispatch,load" >/dev/null
  build_call_board "$home" '["k1"]' '[{"id":"t1","repo":"r","title":"One","reason":"queued","dispatchable":true}]'
  rm -f "$home/storage.json.session.json"
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    ([.calls[].key] == ["question:k1"]) and (.storage["fm-bearings-board.queued.v1"] | fromjson | keys) == ["card:k1"]
  ' >/dev/null || fail "a stale dispatch order or a departed card's answer was queued again: $out"
  pass "a kept answer for a departed card or for work that left the chart is dropped"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_rebuild_keeps_in_progress_answers_and_drops_only_departed_cards
test_dispatch_picks_survive_a_refresh_with_or_without_browser_storage
test_a_queued_answer_shows_as_queued_after_a_refresh_and_is_not_queued_twice
test_an_answer_the_chrome_already_sent_is_not_queued_again
test_an_unsent_answer_is_queued_again_in_a_new_tab_exactly_once
test_a_kept_dispatch_order_is_dropped_when_its_work_left_the_chart
