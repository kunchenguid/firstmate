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

test_each_summary_tile_scrolls_to_the_section_it_counts() {
  local home out
  home=$(make_home tile-targets)
  out=$(render_board "$home" '[
    {"id":"uw-1","repo":"sample","name":"Running work","state":"working","kind":"ship","doing":"building"}
  ]' '[
    {"id":"queued-one","repo":"sample","title":"Queued","reason":"","dispatchable":true}
  ]')
  # The oracle is the heading the captain reads on each section, not the ids
  # the template happens to use.
  printf '%s' "$out" | jq -e '
    .error == ""
      and ([.stats[] | {label, scrolls_to}] == [
        {label:"need you", scrolls_to:["Captain'"'"'s Call"]},
        {label:"underway", scrolls_to:["Underway"]},
        {label:"landed recently", scrolls_to:["Recently Landed"]},
        {label:"charted next", scrolls_to:["Charted Next"]}])
      and all(.stats[]; .tag == "button" and .type == "button" and .prompts == 0)
  ' >/dev/null || fail "a summary tile did not scroll to the section it counts, or reached the agent: $out"
  pass "each summary tile is a button that scrolls to the section headed by what it counts and queues nothing"
}

test_every_captains_call_card_takes_the_tallest_cards_height() {
  local home out
  home=$(make_home call-height)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"merge.short","type":"merge","repo":"sample","title":"Merge: short","risk":"low",
     "options":[{"value":"merge","label":"Merge now"}]},
    {"key":"long-decision","type":"decision","repo":"sample","title":"A decision with a great deal of context to read before answering",
     "about":"This decision card carries a long about line that wraps across several lines of the card at any reasonable width, so its content is much taller than the short merge card that comes before it.",
     "decide":"Which of the several options below should the fleet adopt, given everything described above and the tradeoffs each option names in its hint?",
     "options":[
       {"value":"first","label":"First option","hint":"A hint long enough to wrap onto a second line inside the option row"},
       {"value":"second","label":"Second option","hint":"Another hint long enough to wrap onto a second line inside the option row"},
       {"value":"third","label":"Third option"}],
     "allow_freeform":true},
    {"key":"merge.medium","type":"merge","repo":"sample","title":"Merge: medium","risk":"high",
     "detail":"A detail line of moderate length that wraps once or twice.",
     "options":[{"value":"merge","label":"Merge now"},{"value":"hold","label":"Not yet"}]}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    def even($pages): ($pages | length) == 3
      and ([$pages[] | .natural] | unique | length) == 3
      and ([$pages[] | .height] | unique) == [([$pages[] | .natural] | max)];
    even(.call.wide) and even(.call.narrow)
      and (.call.wide[0].height != .call.narrow[0].height)
      and ([.call.wide[] | .title] == ["Merge: short",
        "A decision with a great deal of context to read before answering", "Merge: medium"])
  ' >/dev/null || fail "Captain's Call cards of different lengths did not all take the tallest card's height: $out"
  pass "every Captain's Call card takes the tallest card's height, and again after a resize"
}

test_every_captains_call_card_opens_a_full_screen_details_view() {
  local home out
  home=$(make_home call-details)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"explained","type":"decision","repo":"sample","title":"An explained call",
     "about":"One-line about.","decide":"One-line question?",
     "context":["First paragraph of context.",
       "See https://example.com/pr/1. A javascript:alert(1) string stays text."],
     "options":[
       {"value":"go","label":"Go ahead","hint":"short hint",
        "details":["What going ahead does.","What it costs."]},
       {"value":"wait","label":"Wait"}],
     "recommend_value":"go","allow_freeform":true},
    {"key":"merge.plain","type":"merge","repo":"sample","title":"Merge: plain","risk":"low",
     "options":[{"value":"merge","label":"Merge now"}]}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.call.details | length) == 2
      and all(.call.details[];
        .button == {tag:"button", type:"button", label:"Details", controls:"dialog"}
          and .was_closed and .open and .closed_after and .prompts == 0
          and .focus == {label:"Details", card:.title, visible:true})
      and ([.call.details[] | .title] == ["An explained call", "Merge: plain"])
  ' >/dev/null || fail "a card lacked a Details button, or it did not open and close a full-screen view without queuing anything and hand focus back to its button: $out"
  # Oracle: CSS Flexbox - a flex row lays every item on one line unless
  # flex-wrap is wrap, and a card that hides overflow then clips the last item.
  printf '%s' "$out" | jq -e '
    all(.call.details[]; .button_row == {buttons:["Queue answer","Details"], display:"flex", flex_wrap:"wrap"})
  ' >/dev/null || fail "the answer row holding Details does not wrap, so a narrow card clips Details: $out"
  printf '%s' "$out" | jq -e '
    .call.details[0] as $d
    | $d.ctx_rows == [["about","One-line about."],["decide","One-line question?"]]
      and $d.context == ["First paragraph of context.",
        "See https://example.com/pr/1. A javascript:alert(1) string stays text."]
      and $d.none == []
      and $d.links == ["https://example.com/pr/1"]
      and ($d.options | map(.label)) == ["Go ahead", "Wait", "Reconcile"]
      and $d.options[0] == {label:"Go ahead", rec:true, hint:"short hint",
        details:["What going ahead does.","What it costs."]}
      and $d.options[1] == {label:"Wait", rec:false, hint:null, details:[]}
  ' >/dev/null || fail "the Details view did not show the full context and every option with its details: $out"
  printf '%s' "$out" | jq -e '
    .call.details[1] as $d
    | $d.context == [] and $d.none == ["No further context was recorded for this call."]
      and ($d.options | map(.label)) == ["Merge now"]
  ' >/dev/null || fail "a card without context did not say so in its Details view: $out"
  pass "every Captain's Call card opens a full-screen Details view with its context and every option's details, queuing nothing"
}

# Oracle: the GFM autolink rule - a trailing ")" belongs to the URL only when
# the URL holds a matching "(", trailing punctuation and the emphasis markers
# "*", "_" and "~" stay text, and a code-span backtick is never part of a URL.
test_a_details_link_keeps_balanced_parentheses_and_drops_trailing_punctuation() {
  local home out para markup
  home=$(make_home call-details-links)
  para='Background is at https://en.wikipedia.org/wiki/Foo_(bar) (see https://example.com/x).'
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the paragraph.
  markup='See `https://github.com/o/r/pull/1`. Also **https://example.com/y**.'
  out=$(render_board "$home" '[]' '[]' 0 0 "$(jq -n --arg p "$para" --arg m "$markup" '[
    {key:"linked",type:"decision",repo:"sample",title:"A linked call",
     context:[$p,$m],options:[{value:"go",label:"Go ahead"}]}]')")
  printf '%s' "$out" | jq -e --arg p "$para" --arg m "$markup" '
    .error == ""
      and .call.details[0].links == ["https://en.wikipedia.org/wiki/Foo_(bar)", "https://example.com/x",
        "https://github.com/o/r/pull/1", "https://example.com/y"]
      and .call.details[0].context == [$p, $m]
  ' >/dev/null || fail "a Details paragraph cut a URL at its own parenthesis or linked trailing punctuation or Markdown markers: $out"
  pass "a Details link keeps a balanced closing parenthesis and leaves trailing punctuation and Markdown markers as text"
}

# Oracle: the WAI-ARIA dialog pattern - closing a dialog returns focus to the
# control that opened it, or to a logical control when that one is gone. Here
# the queued answer has dealt the next card, so the opener is hidden.
test_closing_details_after_the_deal_advances_focuses_the_shown_cards_details() {
  local home out
  home=$(make_home call-details-advance)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"merge.first","type":"merge","repo":"sample","title":"Merge: first","risk":"low",
     "options":[{"value":"merge","label":"Merge now"}]},
    {"key":"merge.second","type":"merge","repo":"sample","title":"Merge: second","risk":"low",
     "options":[{"value":"merge","label":"Merge now"}]}
  ]')
  printf '%s' "$out" | jq -e '
    .error == ""
      and .call.advance == {answered:"Merge: first", shown:"Merge: second",
        focus:{label:"Details", card:"Merge: second", visible:true}}
  ' >/dev/null || fail "closing Details after the deal advanced left focus off the shown card's Details button: $out"
  pass "closing Details after a queued answer dealt the next card focuses that card's Details button"
}

test_an_empty_captains_call_still_shows_its_empty_state() {
  local home out
  home=$(make_home call-empty)
  out=$(render_board "$home" '[]' '[]')
  printf '%s' "$out" | jq -e '
    .call.wide == [] and .call.narrow == []
      and .call.empty == ["Nothing needs your action right now."]
  ' >/dev/null || fail "an empty Captain's Call lost its empty-state line: $out"
  pass "an empty Captain's Call still shows its empty-state line"
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
test_every_captains_call_card_takes_the_tallest_cards_height
test_every_captains_call_card_opens_a_full_screen_details_view
test_a_details_link_keeps_balanced_parentheses_and_drops_trailing_punctuation
test_closing_details_after_the_deal_advances_focuses_the_shown_cards_details
test_an_empty_captains_call_still_shows_its_empty_state
test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_each_summary_tile_scrolls_to_the_section_it_counts
