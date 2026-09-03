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
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0} data="$1/payload.json"
  jq -n --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
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

# Build the board from a complete <payload-json> and replay [clicks-json]
# (an array the harness feeds to filter chips / the clear button) against
# the rendered page before returning what it produced.
render_payload() {  # <home> <payload-json> [clicks-json]
  local home=$1 payload=$2 clicks=${3:-[]} data="$1/payload.json"
  printf '%s' "$payload" > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$clicks" \
    || fail "the built board could not be rendered"
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

# A payload sized to match the real complaint: many Captain's Call cards
# spread across a few repos and card types, plus matching Underway/Landed/
# Charted rows, so the filter menu's counts and narrowing can be checked
# against the real template rather than a toy fixture.
multi_repo_payload() {
  jq -n '
    def call_item($i;$repo;$type):
      {key:("call-"+$repo+"-"+$type+"-"+($i|tostring)),
       type:$type, repo:$repo, title:("Card "+$repo+" "+$type+" "+($i|tostring)),
       options:[{value:"yes",label:"Yes"},{value:"no",label:"No"}]}
      + (if $type == "merge" then {risk:"low"} else {} end);
    {
      schema:"fm-bearings-board.v1", home:"filter-home", generated:"2026-08-26T00:00Z",
      prs_live:false,
      captains_call:
        ([range(0;6) | call_item(.; "jt2627s"; "decision")])
        + ([range(0;2) | call_item(.; "jt2627s"; "merge")])
        + ([range(0;1) | call_item(.; "jt2627s"; "credential")])
        + ([range(0;3) | call_item(.; "interactp"; "decision")])
        + [{key:"call-norepo-1", type:"decision", repo:null, title:"No-repo card",
            options:[{value:"yes",label:"Yes"}]}],
      underway:
        [{id:"uw-jt-1", repo:"jt2627s", state:"working", doing:"Doing jt work", kind:"ship"},
         {id:"uw-ip-1", repo:"interactp", state:"working", doing:"Doing ip work", kind:"ship"}],
      landed:
        [{id:"ld-jt-1", repo:"jt2627s", what:"Landed jt work", owner:"main"}],
      charted:
        [{id:"ch-jt-1", repo:"jt2627s", title:"Charted jt work", reason:"", dispatchable:true},
         {id:"ch-ip-1", repo:"interactp", title:"Charted ip work", reason:"", dispatchable:true}],
      charted_more:0, charted_warning_more:0
    }'
}

stack_total() {  # <render-json> - the "Y" in the deck's "card X of Y" text
  printf '%s' "$1" | jq -r '.deck.stackText | capture("of (?<y>[0-9]+)").y'
}

test_filter_menu_shows_counted_repo_and_type_choices() {
  local home payload out
  home=$(make_home filter-counts)
  payload=$(multi_repo_payload)
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.filterbar.chips | map(select(.group == "repo" and .key == "jt2627s")) | .[0].count) == 9
      and (.filterbar.chips | map(select(.group == "repo" and .key == "interactp")) | .[0].count) == 3
      and (.filterbar.chips | map(select(.group == "repo" and .key == "no repo")) | .[0].count) == 1
      and (.filterbar.chips | map(select(.group == "type" and .key == "decision")) | .[0].count) == 10
      and (.filterbar.chips | map(select(.group == "type" and .key == "merge")) | .[0].count) == 2
      and (.filterbar.chips | map(select(.group == "type" and .key == "credential")) | .[0].count) == 1
      and (.filterbar.clearHidden == true)
  ' >/dev/null || fail "filter chip counts were wrong: $out"
  [ "$(stack_total "$out")" = 13 ] || fail "unfiltered stack should cover all 13 cards: $out"
  pass "the filter menu shows every project/type choice with its real count"
}

test_project_filter_narrows_the_stack_and_the_other_sections() {
  local home payload out
  home=$(make_home filter-narrow)
  payload=$(multi_repo_payload)
  out=$(render_payload "$home" "$payload" '[{"selector":".bb-chip","match":{"group":"repo","key":"jt2627s"}}]')
  [ "$(stack_total "$out")" = 9 ] \
    || fail "picking a project must narrow the stack counter to that project's cards: $out"
  printf '%s' "$out" | jq -e '
    (.filterbar.chips | map(select(.group == "repo" and .key == "jt2627s")) | .[0].active) == true
      and (.filterbar.clearHidden == false)
      and (.sections.underway.rows | map(select(.repo == "jt2627s"))[0].hidden) == false
      and (.sections.underway.rows | map(select(.repo == "interactp"))[0].hidden) == true
      and (.sections.landed.rows[0].repo == "jt2627s" and .sections.landed.rows[0].hidden == false)
      and (.sections.charted.rows | map(select(.repo == "jt2627s"))[0].hidden) == false
      and (.sections.charted.rows | map(select(.repo == "interactp"))[0].hidden) == true
  ' >/dev/null || fail "the project filter did not narrow Underway/Landed/Charted the same way: $out"
  pass "picking a project narrows the Captain's Call stack and the other three sections together"
}

test_type_filter_narrows_only_the_stack_not_the_other_sections() {
  local home payload out
  home=$(make_home filter-type-only)
  payload=$(multi_repo_payload)
  out=$(render_payload "$home" "$payload" '[
    {"selector":".bb-chip","match":{"group":"repo","key":"jt2627s"}},
    {"selector":".bb-chip","match":{"group":"type","key":"merge"}}
  ]')
  [ "$(stack_total "$out")" = 2 ] \
    || fail "combining project + type filters did not intersect correctly: $out"
  printf '%s' "$out" | jq -e '
    (.sections.underway.rows | map(select(.repo == "jt2627s"))[0].hidden) == false
  ' >/dev/null || fail "a type filter must not touch Underway rows, which have no card type: $out"
  pass "type and project filters combine on the stack while Underway stays project-only"
}

test_clear_filters_restores_everything() {
  local home payload out
  home=$(make_home filter-clear)
  payload=$(multi_repo_payload)
  out=$(render_payload "$home" "$payload" '[
    {"selector":".bb-chip","match":{"group":"repo","key":"interactp"}},
    {"selector":".bb-filter__clear"}
  ]')
  [ "$(stack_total "$out")" = 13 ] \
    || fail "the clear-filters control did not restore the full stack: $out"
  printf '%s' "$out" | jq -e '
    (.filterbar.clearHidden == true)
      and ([.filterbar.chips[] | select(.active)] | length) == 0
      and (.sections.underway.rows | map(select(.repo == "jt2627s"))[0].hidden) == false
  ' >/dev/null || fail "the clear-filters control left stale filter state behind: $out"
  pass "the clear-filters control is an obvious, working way back to everything"
}

test_a_filter_combination_with_no_matches_stays_graceful() {
  local home payload out
  home=$(make_home filter-empty)
  payload=$(multi_repo_payload)
  out=$(render_payload "$home" "$payload" '[
    {"selector":".bb-chip","match":{"group":"repo","key":"interactp"}},
    {"selector":".bb-chip","match":{"group":"type","key":"credential"}}
  ]')
  printf '%s' "$out" | jq -e '
    (.deck.empty | length) == 1
      and (.deck.empty[0] | test("No Captain.s Call cards match"))
      and (.error == "")
      and (.sections.underway.rows | map(select(.repo == "interactp"))[0].hidden) == false
  ' >/dev/null || fail "an empty filter result must show a plain empty state, not break the board: $out"
  pass "a filter combination with no matches degrades to a plain empty state"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_filter_menu_shows_counted_repo_and_type_choices
test_project_filter_narrows_the_stack_and_the_other_sections
test_type_filter_narrows_only_the_stack_not_the_other_sections
test_clear_filters_restores_everything
test_a_filter_combination_with_no_matches_stays_graceful
