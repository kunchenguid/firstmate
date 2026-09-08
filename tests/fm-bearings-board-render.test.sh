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

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_payload "$1" "$(jq -n --argjson charted "$2" \
    --argjson more "${3:-0}" --argjson warning_more "${4:-0}" \
    '{charted:$charted, charted_more:$more, charted_warning_more:$warning_more}')"
}

# Build the board from a partial payload (merged over the minimal valid one) and
# return what the renderer produced.
render_payload() {  # <home> <payload-overrides-json>
  local home=$1 overrides=$2 data="$1/payload.json"
  jq -n --argjson overrides "$overrides" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], awaiting:[], landed:[],
    charted:[], awaiting_nudge_days:7} * $overrides' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","owner":"(main)","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","owner":"(main)","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
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
    {"id":"queued-one","repo":"sample","owner":"(main)","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","owner":"(main)","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","owner":"(main)","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
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
    {"id":"warn-only","repo":"sample","owner":"(main)","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
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
    {"id":"warn-visible","repo":"sample","owner":"(main)","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
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
    {"id":"with-reason","repo":"sample","owner":"(main)","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","owner":"(main)","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

# --- ownership -------------------------------------------------------------
# The captain's fleet and his second mate both work the SAME repository, so the
# repo column cannot tell their rows apart. Ownership is a payload field, and
# these pin that it reaches the board without anyone typing it into a title.

owners_of() {  # <render-json> <tile-label>
  printf '%s' "$1" | jq -r --arg l "$2" '.stats[] | select(.label == $l) | .owners'
}

test_underway_rows_name_their_home_when_the_repo_cannot() {
  local home out
  home=$(make_home owner-rows)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"Main fleet work"},
    {"id":"fm-self/b","repo":"firstmate","owner":"fm-self","kind":"ship","state":"working","doing":"Second mate work"}
  ]}')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 2
      and (.underway[0].sub | test("firstmate") and endswith("(main)"))
      and (.underway[1].sub | test("firstmate") and endswith("fm-self"))
  ' >/dev/null || fail "two same-repo rows did not name their different homes: $out"
  pass "an underway row names the home that owns it, not just its repo"
}

test_a_tile_owned_by_one_home_still_names_it() {
  local home out
  home=$(make_home owner-single)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"One"},
    {"id":"b","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"Two"}
  ]}')
  [ "$(owners_of "$out" underway)" = "2 (main)" ] \
    || fail "a tile owned entirely by one home refused to name it: $out"
  pass "a tile whose rows share one home still says which home"
}

# A truncated section must not let its breakdown imply a total it cannot see.
test_a_truncated_tile_says_its_breakdown_covers_only_the_shown_rows() {
  local home out
  home=$(make_home owner-truncated)
  out=$(render_payload "$home" '{"charted":[
    {"id":"a","repo":"firstmate","owner":"(main)","title":"One","reason":"gated","dispatchable":true},
    {"id":"b","repo":"firstmate","owner":"fm-self","title":"Two","reason":"gated","dispatchable":true}
  ],"charted_more":20}')
  [ "$(owners_of "$out" "charted next")" = "1 (main) · 1 fm-self shown" ] \
    || fail "a truncated tile implied its breakdown covered every row: $out"
  printf '%s' "$out" | jq -e '[.stats[] | select(.label == "charted next") | .n] == [22]' >/dev/null \
    || fail "the truncated tile lost its real total: $out"
  pass "a truncated tile counts every row but says its breakdown covers the shown ones"
}

test_owner_labels_do_not_collide_with_inherited_properties() {
  local home out
  home=$(make_home owner-inherited-keys)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"One"},
    {"id":"b","repo":"firstmate","owner":"constructor","kind":"ship","state":"working","doing":"Two"},
    {"id":"c","repo":"firstmate","owner":"constructor","kind":"ship","state":"working","doing":"Three"},
    {"id":"d","repo":"firstmate","owner":"__proto__","kind":"ship","state":"working","doing":"Four"}
  ]}')
  [ "$(owners_of "$out" underway)" = "2 constructor · 1 (main) · 1 __proto__" ] \
    || fail "valid owner labels disappeared from the breakdown: $out"
  printf '%s' "$out" | jq -e '.stats[] | select(.label == "underway") | .n == 4' >/dev/null \
    || fail "the ownership breakdown disagrees with the underway total: $out"
  pass "all valid owner labels count even when they name inherited properties"
}

test_main_home_and_a_mate_named_main_remain_distinct() {
  local home out
  home=$(make_home main-owner-collision)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"One"},
    {"id":"b","repo":"firstmate","owner":"main","kind":"ship","state":"working","doing":"Two"}
  ]}')
  [ "$(owners_of "$out" underway)" = "1 (main) · 1 main" ] || fail "distinct homes were combined: $out"
  printf '%s' "$out" | jq -e '.underway[0].sub | endswith("(main)")' >/dev/null || fail "main owner was aliased"
  printf '%s' "$out" | jq -e '.underway[1].sub | endswith("· main")' >/dev/null || fail "mate owner was aliased"
  pass "the main home and a mate named main retain distinct structural labels"
}

test_nudge_submissions_bypass_task_answer_intake() {
  local home url overrides captured result answers nudges
  home=$(make_home nudge-answer-routing)
  url="https://gitlab.example/$(printf '%0170d' 1)/$(printf '%0170d' 2)/$(printf '%0170d' 3)/-/merge_requests/44"
  printf '## In flight\n\n## Queued\n- [ ] nudge.foo - Unrelated captain call (repo: firstmate) (kind: captain) (hold: choose a route) (hold-kind: captain)\n\n## Done\n' > "$home/data/backlog.md"
  overrides=$(jq -n --arg url "$url" '{captains_call:[{key:$url,type:"nudge",repo:"firstmate",title:"Nudge foo",
    age_days:23,pr_url:$url,options:[{value:"leave",label:"Leave it"}]}]}')
  render_payload "$home" "$overrides" >/dev/null
  captured=$(node "$HARNESS" "$home/.lavish/bearings-board.html" \
    "$(jq -nc --arg url "$url" '[{key:$url,selection:"leave",note:"still waiting"}]')") || fail "nudge submission failed"
  printf '%s' "$captured" | jq -e --arg url "$url" '
    [.prompts[] | {tag,data}] == [{tag:"nudge",data:{schema:"fm-bearings-nudge.v1",pr_url:$url,selection:"leave",note:"still waiting"}}]
  ' >/dev/null || fail "nudge used the task-answer schema or lost request identity: $captured"
  result="$home/nudge.result"
  printf 'prompts[1]{tag,text,prompt}:\n' > "$result"
  printf '%s' "$captured" | jq -r '.prompts[]
    | [.tag,.text,(.prompt + "\n\nContext data:\n" + (.data | tojson))]
    | map(tojson) | "  " + join(",")' >> "$result"
  answers=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result") || fail "answer extraction failed"
  [ -z "$answers" ] || fail "a nudge reached the task-answer intake: $answers"
  [ -z "$("$ROOT/bin/fm-procevent-lavish.sh" reconciles "$result")" ] || fail "a nudge reached reconcile intake"
  nudges=$("$ROOT/bin/fm-procevent-lavish.sh" nudges "$result") || fail "nudge extraction failed"
  printf '%s' "$nudges" | jq -e --arg url "$url" '.pr_url == $url and .selection == "leave" and .note == "still waiting"' \
    >/dev/null || fail "the separate nudge reader lost the long request or answer: $nudges"
  printf '%s' "$answers" | FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" answers '(any)' --source "nudge test" >/dev/null || fail "answer feed failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" open nudge.foo --distinguish-absent >/dev/null || fail "the unrelated captain hold was closed"
  printf 'prompts[1]{tag,text,prompt}:\n' > "$result"
  jq -nr '["choice","Ordinary task answer",("Context data:\n" +
    ({schema:"fm-bearings-answer.v1",question:"nudge.foo",selection:"leave",note:""} | tojson))]
    | map(tojson) | "  " + join(",")' >> "$result"
  answers=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result") || fail "ordinary task answer extraction failed"
  [ "${answers%%$'\t'*}" = nudge.foo ] || fail "separating nudges changed the task-answer key contract"
  [ -z "$("$ROOT/bin/fm-procevent-lavish.sh" nudges "$result")" ] || fail "a task answer entered the nudge route"
  pass "long request-keyed nudge submissions route separately and cannot close a task-shaped collision"
}

test_the_tiles_break_down_by_owner_without_a_tile_of_their_own() {
  local home out
  home=$(make_home owner-breakdown)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"One"},
    {"id":"fm-self/b","repo":"firstmate","owner":"fm-self","kind":"ship","state":"working","doing":"Two"},
    {"id":"fm-self/c","repo":"firstmate","owner":"fm-self","kind":"ship","state":"working","doing":"Three"}
  ]}')
  [ "$(owners_of "$out" underway)" = "2 fm-self · 1 (main)" ] \
    || fail "the underway tile did not break its count down by owner: $out"
  printf '%s' "$out" | jq -e '[.stats[] | .label] | index("owner") == null' >/dev/null \
    || fail "ownership took a tile of its own instead of a sub-line: $out"
  pass "the tiles carry an ownership sub-line rather than an ownership tile"
}

# THE INVIOLABLE RULE. What needs the captain needs him wherever it came from.
# The needs-you tile must never be split by owner and never filtered by owner:
# a partitioned tile is exactly how a second mate's call would end up in a
# corner nobody reads. If a refactor ever splits or filters it, this fails.
test_the_needs_you_tile_is_never_split_or_filtered_by_owner() {
  local home out call_tiles
  home=$(make_home needs-you-whole)
  out=$(render_payload "$home" '{"captains_call":[
    {"key":"main-call","type":"decision","repo":"firstmate","owner":"(main)","title":"Main home call",
     "options":[{"value":"go","label":"Go"}]},
    {"key":"mate-call","type":"decision","repo":"firstmate","owner":"fm-self","title":"Second mate call",
     "options":[{"value":"go","label":"Go"}]},
    {"key":"third-call","type":"decision","repo":"other","owner":"fm-self","title":"Another mate call",
     "options":[{"value":"go","label":"Go"}]}
  ]}')
  call_tiles=$(printf '%s' "$out" | jq '[.stats[] | select(.label | test("need you"))] | length')
  [ "$call_tiles" = 1 ] \
    || fail "the needs-you tile was split into $call_tiles tiles: $out"
  printf '%s' "$out" | jq -e '
    .error == ""
      and ([.stats[] | select(.label == "need you")] | length) == 1
      and ([.stats[] | select(.label == "need you") | .n] == [3])
      and ([.stats[] | select(.label == "need you") | .owners] == [""])
      and (.call | length) == 3
  ' >/dev/null || fail "the needs-you tile dropped, filtered, or split a home's calls: $out"
  pass "the needs-you tile counts every home's calls in one undivided tile"
}

# --- delivered, waiting on a maintainer ------------------------------------

test_a_delivered_row_leads_with_its_age_and_its_request_link() {
  local home out
  home=$(make_home delivered-rows)
  out=$(render_payload "$home" '{"awaiting":[
    {"id":"young","repo":"firstmate","owner":"(main)","what":"Newer delivery","age_days":1,
     "pr_url":"https://github.com/o/r/pull/11"},
    {"id":"older","repo":"firstmate","owner":"fm-self","what":"Older delivery","age_days":5,
     "pr_url":"https://github.com/o/r/pull/22"}
  ]}')
  printf '%s' "$out" | jq -e '
    (.awaiting | length) == 2
      and (.awaiting[0] | .title == "Older delivery" and .age == "5d"
        and .pr.href == "https://github.com/o/r/pull/22" and (.sub | endswith("waiting on a merge we do not control")))
      and (.awaiting[1] | .title == "Newer delivery" and .age == "1d"
        and .pr.href == "https://github.com/o/r/pull/11")
  ' >/dev/null || fail "a delivered row lost its age, its link, or its order: $out"
  printf '%s' "$out" | jq -e '[.stats[] | select(.label == "delivered") | .n] == [2]' >/dev/null \
    || fail "the delivered rows were not counted in their own tile: $out"
  pass "delivered rows lead with the wait, carry their request link, and count separately"
}

test_delivered_work_is_no_longer_counted_as_underway() {
  local home out
  home=$(make_home delivered-not-underway)
  out=$(render_payload "$home" '{"underway":[
    {"id":"a","repo":"firstmate","owner":"(main)","kind":"ship","state":"working","doing":"Still moving"}
  ],"awaiting":[
    {"id":"b","repo":"firstmate","owner":"(main)","what":"Delivered","age_days":2,
     "pr_url":"https://github.com/o/r/pull/33"}
  ]}')
  printf '%s' "$out" | jq -e '
    ([.stats[] | select(.label == "underway") | .n] == [1])
      and ([.stats[] | select(.label == "delivered") | .n] == [1])
      and ((.underway | length) == 1)
  ' >/dev/null || fail "a delivered row still inflated the underway count: $out"
  pass "a delivered row counts once, in the delivered tile, not as work in the air"
}

test_an_empty_delivered_box_still_renders_its_state() {
  local home out
  home=$(make_home delivered-empty)
  out=$(render_payload "$home" '{}')
  printf '%s' "$out" | jq -e '
    (.awaitingEmpty | length) == 1
      and (.awaitingEmpty[0] | test("Nothing is waiting on a merge we do not control"))
      and ([.stats[] | select(.label == "delivered") | .n] == [0])
  ' >/dev/null || fail "the delivered section vanished when it was empty: $out"
  pass "the delivered section always renders, with its own empty state"
}

test_an_aged_delivery_reaches_the_captain_as_a_nudge_card() {
  local home out
  home=$(make_home delivered-nudge)
  out=$(render_payload "$home" '{"captains_call":[
    {"key":"https://github.com/o/r/pull/44","type":"nudge","repo":"firstmate","title":"Nudge the maintainer",
     "age_days":23,"pr_url":"https://github.com/o/r/pull/44",
     "detail":"Green and complete for 23 days; only the maintainer can merge it.",
     "options":[{"value":"nudge","label":"Nudge them"},{"value":"leave","label":"Leave it"}]}
  ]}')
  printf '%s' "$out" | jq -e '
    .error == ""
      and (.call | length) == 1
      and (.call[0].title == "Nudge the maintainer")
      and ([.call[0].badges[] | .text] | index("waiting 23d") != null)
      and (.call[0].link == "https://github.com/o/r/pull/44")
      and ([.stats[] | select(.label == "need you") | .n] == [1])
  ' >/dev/null || fail "an aged delivery did not surface as a needs-you nudge: $out"
  pass "an aged delivery rises into the captain's call carrying its wait and its link"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_underway_rows_name_their_home_when_the_repo_cannot
test_the_tiles_break_down_by_owner_without_a_tile_of_their_own
test_owner_labels_do_not_collide_with_inherited_properties
test_main_home_and_a_mate_named_main_remain_distinct
test_nudge_submissions_bypass_task_answer_intake
test_a_tile_owned_by_one_home_still_names_it
test_a_truncated_tile_says_its_breakdown_covers_only_the_shown_rows
test_the_needs_you_tile_is_never_split_or_filtered_by_owner
test_a_delivered_row_leads_with_its_age_and_its_request_link
test_delivered_work_is_no_longer_counted_as_underway
test_an_empty_delivered_box_still_renders_its_state
test_an_aged_delivery_reaches_the_captain_as_a_nudge_card
