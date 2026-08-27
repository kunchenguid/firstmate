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

# Build a board from a full payload and return what the renderer produced.
render_payload() {  # <home> <payload-json>
  local home=$1 data="$1/payload.json"
  printf '%s' "$2" > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0}
  render_payload "$home" "$(jq -n \
    --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}')"
}

# Build a board whose only item is one merge call carrying <risk-json>, which is
# a JSON value so an absent field can be tested as well as an empty one.
render_merge_risk() {  # <home> <risk-json>
  local home=$1
  render_payload "$home" "$(jq -n --argjson risk "$2" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:[], charted_more:0,
    captains_call:[({
      key:"merge-one", type:"merge", repo:"sample", title:"Merge one",
      options:[{value:"merge", label:"Merge"}]
    } + (if $risk == null then {} else {risk:$risk} end))]}')"
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

test_a_composed_risk_leaves_only_the_level_on_the_pin() {
  local home out
  home=$(make_home risk-composed)
  out=$(render_merge_risk "$home" '"faible. Une vue derivee et un index par paragraphe"')
  printf '%s' "$out" | jq -e '
    (.calls | length) == 1
      and ([.calls[0].badges[] | .text] == ["checks green", "risk faible"])
      and (.calls[0].ctx == [{k:"risk", v:"Une vue derivee et un index par paragraphe"}])
  ' >/dev/null || fail "the justification did not move off the pin into the card: $out"
  pass "a composed risk keeps the level on the pin and reads its justification in the card"
}

test_a_bare_level_adds_no_context_row() {
  local home out
  home=$(make_home risk-bare)
  out=$(render_merge_risk "$home" '"faible"')
  printf '%s' "$out" | jq -e '
    ([.calls[0].badges[] | .text] == ["checks green", "risk faible"])
      and (.calls[0].ctx == [])
  ' >/dev/null || fail "a bare level produced an orphan row: $out"
  pass "a bare risk level renders as the pin alone, with no context row"
}

test_a_low_level_reads_as_low_in_either_language() {
  local home out tone
  for risk in '"faible"' '"  Faible  "' '"low"' '"LOW"'; do
    home=$(make_home "risk-low-$(printf '%s' "$risk" | tr -cd '[:alnum:]')")
    out=$(render_merge_risk "$home" "$risk")
    tone=$(printf '%s' "$out" | jq -r '[.calls[0].badges[] | select(.text | startswith("risk"))][0].tone')
    [ "$tone" = "neutral" ] \
      || fail "risk $risk wore the $tone tone instead of reading as low: $out"
  done
  pass "a low level reads as low in either language, whatever its casing or spacing"
}

test_an_unrecognised_level_keeps_the_alert_tone() {
  local home out
  home=$(make_home risk-unrecognised)
  out=$(render_merge_risk "$home" '"eleve. Touche la migration de donnees"')
  printf '%s' "$out" | jq -e '
    ([.calls[0].badges[] | select(.text | startswith("risk")) | .tone] == ["warn"])
  ' >/dev/null || fail "an unrecognised level lost the alert tone: $out"
  pass "an unrecognised level keeps the alert tone rather than erring toward calm"
}

test_a_blank_risk_wears_no_pin_at_all() {
  local home out
  home=$(make_home risk-blank)
  out=$(render_merge_risk "$home" '"   "')
  printf '%s' "$out" | jq -e '
    ([.calls[0].badges[] | .text] == ["checks green"]) and (.calls[0].ctx == [])
  ' >/dev/null || fail "a blank risk announced a risk the record never stated: $out"
  pass "a blank risk wears no pin and leaves no orphan row"
}

# A merge call with no risk at all never reaches the renderer, so the guarantee
# is asserted where it is actually enforced rather than assumed downstream.
test_a_merge_call_without_a_risk_is_refused_at_build() {
  local home data risk
  home=$(make_home risk-refused)
  for risk in 'null' '""'; do
    data="$home/refused.json"
    jq -n --argjson risk "$risk" '{
      schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
      prs_live:false, underway:[], landed:[], charted:[], charted_more:0,
      captains_call:[({key:"merge-one", type:"merge", repo:"sample", title:"Merge one",
        options:[{value:"merge", label:"Merge"}]}
        + (if $risk == null then {} else {risk:$risk} end))]}' > "$data"
    if PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      "$BOARD" build "$data" >/dev/null 2>&1; then
      fail "a merge call with risk $risk was built instead of refused"
    fi
  done
  pass "a merge call with no risk value is refused at build rather than rendered"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_composed_risk_leaves_only_the_level_on_the_pin
test_a_bare_level_adds_no_context_row
test_a_low_level_reads_as_low_in_either_language
test_an_unrecognised_level_keeps_the_alert_tone
test_a_blank_risk_wears_no_pin_at_all
test_a_merge_call_without_a_risk_is_refused_at_build
