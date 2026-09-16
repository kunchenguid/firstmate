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
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

# Build Captain's Call cards and submit each control independently through the
# rendered board's public Lavish queue interface.
render_call_interactions() {  # <home> <captains-call-json>
  local home=$1 calls=$2 data="$1/payload.json"
  local freeform_render="$home/freeform-render.json" choice_render="$home/choice-render.json"
  jq -n --argjson calls "$calls" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$calls, underway:[], landed:[], charted:[]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the Captain's Call board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" --freeform-interactions > "$freeform_render" \
    || fail "the Captain's Call freeform controls could not be exercised"
  node "$HARNESS" "$home/.lavish/bearings-board.html" --choice-interactions > "$choice_render" \
    || fail "the Captain's Call choice controls could not be exercised"
  jq -n --slurpfile freeform "$freeform_render" --slurpfile choice "$choice_render" \
    '{freeform:$freeform[0], choice:$choice[0]}'
}

run_lavish_adapter() {  # <command> <result-file>
  "$ROOT/bin/fm-procevent-lavish.sh" "$1" "$2"
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

test_captains_call_freeform_is_context_not_a_decision() {
  local home out freeform_result choice_result read_out answer_out reconcile_out
  home=$(make_home call-freeform)
  out=$(render_call_interactions "$home" '[
    {"key":"ordinary-decision","type":"decision","repo":"sample","title":"Choose a route",
     "options":[{"value":"north","label":"Take the north route"},{"value":"south","label":"Take the south route"}]},
    {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge the sample change",
     "risk":"low","options":[{"value":"merge","label":"Merge now"},{"value":"hold","label":"Not yet"}]},
    {"key":"merge.single","type":"merge","repo":"sample","title":"Approve the single route",
     "risk":"low","options":[{"value":"approve","label":"Approve"}]},
    {"key":"credential.single","type":"credential","repo":"sample","title":"Provide a credential",
     "options":[{"value":"provide","label":"Provide it"}],"allow_freeform":true}
  ]')

  printf '%s' "$out" | jq -e '
    (.freeform.interactions | map({question, hasFreeform})) == [
      {question:"ordinary-decision", hasFreeform:true},
      {question:"merge.sample-task", hasFreeform:true},
      {question:"merge.single", hasFreeform:false},
      {question:"credential.single", hasFreeform:true}
    ]
    and ([.freeform.interactions[] | select(.hasFreeform)
      | .freeformLabel == "Ask a question or give another instruction"
        and .messageQueued
        and (.choiceQueued | not)
        and (.cardQueued | not)
        and (.cardAnswered | not)
        and (.stackStatus | contains("answered") | not)] | all)
  ' >/dev/null || fail "freeform controls had the wrong scope or counted as answers: $out"
  printf '%s' "$out" | jq -e '
    [.freeform.queuedPrompts[] | select(.tag == "prompt")
      | {question:.data.question, message:.data.message, schema:.data.schema}] == [
        {question:"ordinary-decision", message:"Need more context for ordinary-decision", schema:"fm-bearings-followup.v1"},
        {question:"merge.sample-task", message:"Need more context for merge.sample-task", schema:"fm-bearings-followup.v1"},
        {question:"credential.single", message:"Need more context for credential.single", schema:"fm-bearings-followup.v1"}
      ]
  ' >/dev/null || fail "freeform submissions lost card identity or supervisor text: $out"
  printf '%s' "$out" | jq -e '
    ([.choice.interactions[]
      | .choiceQueued
        and (.messageQueued | not)
        and (.cardQueued | not)
        and .cardAnswered] | all)
    and [.choice.interactions[].stackStatus] == [
      "card 1 of 4 · 1 answered",
      "card 1 of 4 · 2 answered",
      "card 1 of 4 · 3 answered",
      "card 1 of 4 · 4 answered"
    ]
  ' >/dev/null || fail "explicit choices did not keep separate queued and answered state: $out"

  freeform_result="$home/freeform.result"
  choice_result="$home/choice.result"
  printf '%s' "$out" | jq -r '.freeform.freeformLavishResult' > "$freeform_result"
  printf '%s' "$out" | jq -r '.choice.choiceLavishResult' > "$choice_result"
  read_out=$(run_lavish_adapter read "$freeform_result") \
    || fail "the adapter could not present the freeform capture"
  assert_contains "$read_out" "ordinary-decision" \
    "the supervisor presentation lost the ordinary card identity"
  assert_contains "$read_out" "Need more context for ordinary-decision" \
    "the supervisor presentation lost the ordinary freeform text"
  assert_contains "$read_out" "merge.sample-task" \
    "the supervisor presentation lost the merge card identity"
  assert_contains "$read_out" "Need more context for merge.sample-task" \
    "the supervisor presentation lost the merge freeform text"
  assert_contains "$read_out" "credential.single" \
    "the supervisor presentation lost the explicit single-option opt-in"
  answer_out=$(run_lavish_adapter answers "$freeform_result") \
    || fail "the adapter could not classify freeform answers"
  [ -z "$answer_out" ] || fail "freeform text entered keyed answers or merge authority: $answer_out"
  reconcile_out=$(run_lavish_adapter reconciles "$freeform_result") \
    || fail "the adapter could not classify freeform reconciliation"
  [ -z "$reconcile_out" ] || fail "freeform text created a reconcile request: $reconcile_out"

  answer_out=$(run_lavish_adapter answers "$choice_result") \
    || fail "the adapter could not classify explicit choices"
  [ "$answer_out" = "$(printf 'ordinary-decision\tnorth\tChoose a route -> north\nmerge.sample-task\tmerge\tMerge the sample change -> merge\nmerge.single\tapprove\tApprove the single route -> approve\ncredential.single\tprovide\tProvide a credential -> provide')" ] \
    || fail "explicit decision, merge, and credential controls changed behavior: $answer_out"
  pass "Captain's Call freeform stays separate from explicit answers"
}

test_captains_call_freeform_is_context_not_a_decision

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
