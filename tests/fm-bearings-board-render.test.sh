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
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0}
  render_payload "$1" "$(jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}')"
}

# Build the board from a whole <payload-json> and return what the renderer produced.
render_payload() {  # <home> <payload-json>
  local home=$1 data="$1/payload.json"
  printf '%s\n' "$2" > "$data"
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

# One payload carrying every optional milestone field, so a single build proves
# the project strip, Underway targets, and decision-card defaults together.
MILESTONE_PAYLOAD='{
  "schema":"fm-bearings-board.v1","home":"render-home","generated":"2026-10-03T12:00Z","prs_live":false,
  "projects":[
    {"repo":"crewhouse","release_goal":"Chief-only onboarding","release_date":"2026-10-10","health":"Y",
     "merges_today":3,"last_release":"v0.4.1","next_release":"v0.5.0","wip_count":4},
    {"repo":"muxr","health":"R"}
  ],
  "captains_call":[
    {"key":"pick-store-copy","type":"decision","repo":"crewhouse","title":"Store listing copy",
     "about":"Two drafts are ready","decide":"Which draft ships?",
     "options":[{"value":"short","label":"Short draft"},{"value":"long","label":"Long draft"}],
     "recommend_value":"short","default_if_silent":"long","decide_by":"2026-10-04",
     "reversible":false,"asked_at":"2026-10-03T09:15:00Z",
     "evidence_url":"https://example.com/evidence/store-copy"}
  ],
  "underway":[
    {"id":"ch-onboard","repo":"crewhouse","name":"Onboarding flow","state":"working","kind":"ship",
     "doing":"implementing","target":"18:30","range":"1.2-3.6 h","age":"2 h","health":"G",
     "evidence_url":"https://example.com/evidence/onboard"}
  ],
  "landed":[],"charted":[]
}'

test_milestone_fields_render_on_the_strip_rows_and_cards() {
  local home out
  home=$(make_home milestone)
  out=$(render_payload "$home" "$MILESTONE_PAYLOAD")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the milestone board rendered its error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    .projects == [
      {repo:"crewhouse", goal:"Chief-only onboarding", date:"release 2026-10-10",
       meta:"next v0.5.0 · last v0.4.1 · 3 merged today · 4 in progress",
       badges:[{tone:"warn", text:"at risk"}], board:[]},
      {repo:"muxr", goal:"", date:"", meta:"", badges:[{tone:"danger", text:"off track"}], board:[]}
    ]
  ' >/dev/null || fail "the project strip did not show release goal, date, and health: $out"
  printf '%s' "$out" | jq -e '
    .underway[0]
    | .aside == ["by 18:30", "1.2-3.6 h"]
      and (.sub | endswith(" · 2 h old"))
      and .badges == [{tone:"online", text:"working"}, {tone:"online", text:"on track"}]
      and .links == [{text:"evidence", href:"https://example.com/evidence/onboard"}]
  ' >/dev/null || fail "the underway row did not show target, range, health, and evidence: $out"
  printf '%s' "$out" | jq -e '
    .calls[0]
    | ([.ctx[] | select(.k == "if silent" or .k == "decide by" or .k == "reversible" or .k == "asked")]
        == [{k:"if silent", v:"Long draft"}, {k:"decide by", v:"2026-10-04"},
            {k:"reversible", v:"no - one-way"}, {k:"asked", v:"2026-10-03T09:15:00Z"}])
      and ([.options[] | select(.value == "short" or .value == "long")]
        == [{value:"short", markers:["rec"]}, {value:"long", markers:["default"]}])
      and (.links | map(.href) == ["https://example.com/evidence/store-copy"])
  ' >/dev/null || fail "the decision card did not show its default, deadline, and evidence: $out"
  pass "milestone fields render on the project strip, underway rows, and decision cards"
}

test_an_old_payload_renders_no_milestone_surfaces() {
  local home out
  home=$(make_home milestone-old)
  out=$(render_payload "$home" "$(printf '%s' "$MILESTONE_PAYLOAD" | jq '
    del(.projects)
    | .captains_call[0] |= del(.default_if_silent, .decide_by, .reversible, .asked_at, .evidence_url)
    | .underway[0] |= del(.target, .range, .age, .health, .evidence_url)')")
  printf '%s' "$out" | jq -e '
    .error == "" and .projects == []
      and .underway[0].aside == [] and .underway[0].links == []
      and .underway[0].badges == [{tone:"online", text:"working"}]
      and (.underway[0].sub | test("old") | not)
      and ([.calls[0].ctx[] | .k] == ["about", "decide"])
      and ([.calls[0].options[] | .markers[]] == ["rec"])
      and .calls[0].links == []
  ' >/dev/null || fail "a payload without milestone fields rendered milestone surfaces: $out"
  pass "a payload without milestone fields renders exactly the pre-milestone board"
}

# Home-board links on project cards plus image and non-image evidence on every
# row type that carries evidence_url.
LINKS_PAYLOAD='{
  "schema":"fm-bearings-board.v1","home":"render-home","generated":"2026-10-03T12:00Z","prs_live":false,
  "projects":[
    {"repo":"ownvoice","health":"G","board_url":"http://extreme.tail0de54.ts.net:4387/session/8e1e7e6e94d5f4b9"},
    {"repo":"takeone","health":"Y"}
  ],
  "captains_call":[
    {"key":"pick-hero","type":"decision","repo":"ownvoice","title":"Hero shot","decide":"Which?",
     "options":[{"value":"a","label":"A"},{"value":"b","label":"B"}],
     "evidence_url":"https://example.com/evidence/hero.JPEG?v=2"}
  ],
  "underway":[
    {"id":"ov-rec","repo":"ownvoice","name":"Recorder","state":"working","kind":"ship","doing":"implementing",
     "evidence_url":"http://extreme.tail0de54.ts.net:8080/recorder.webp"},
    {"id":"to-clip","repo":"takeone","name":"Clip export","state":"working","kind":"ship","doing":"implementing",
     "evidence_url":"https://example.com/evidence/clip.mp4"}
  ],
  "landed":[
    {"id":"ov-login","repo":"ownvoice","what":"Login","owner":"ship","evidence_url":"http://extreme.tail0de54.ts.net:8080/login.png"},
    {"id":"to-page","repo":"takeone","what":"Evidence page","owner":"ship","evidence_url":"https://example.com/evidence/page"},
    {"id":"to-none","repo":"takeone","what":"No evidence","owner":"ship"},
    {"id":"ov-local","repo":"ownvoice","what":"Local proof","owner":"ship","evidence_url":"evidence/local-proof.gif"},
    {"id":"ov-clip","repo":"ownvoice","what":"Local clip","owner":"ship","evidence_url":"evidence/clip.mp4"}
  ],
  "charted":[]
}'

test_project_cards_link_home_boards_and_image_evidence_shows_thumbnails() {
  local home out
  home=$(make_home links)
  out=$(render_payload "$home" "$LINKS_PAYLOAD")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the links board rendered its error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    [.projects[] | {repo, board}] == [
      {repo:"ownvoice", board:[{text:"open board ↗",
        href:"http://extreme.tail0de54.ts.net:4387/session/8e1e7e6e94d5f4b9", target:"_blank", rel:"noopener"}]},
      {repo:"takeone", board:[]}
    ]
  ' >/dev/null || fail "project cards did not link their home board in a new tab, or linked one without board_url: $out"
  printf '%s' "$out" | jq -e '
    def thumb($u): [{href:$u, target:"_blank", src:$u, loading:"lazy"}];
    .calls[0].thumbs == thumb("https://example.com/evidence/hero.JPEG?v=2")
      and .underway[0].thumbs == thumb("http://extreme.tail0de54.ts.net:8080/recorder.webp")
      and .landed[0].thumbs == thumb("http://extreme.tail0de54.ts.net:8080/login.png")
      and .landed[3].thumbs == thumb("evidence/local-proof.gif")
  ' >/dev/null || fail "image evidence did not render as a lazy new-tab thumbnail of the full image: $out"
  printf '%s' "$out" | jq -e '
    .underway[1].thumbs == [] and .underway[1].links == [{text:"evidence", href:"https://example.com/evidence/clip.mp4"}]
      and .landed[1].thumbs == [] and .landed[1].links == [{text:"evidence", href:"https://example.com/evidence/page"}]
      and .landed[2].thumbs == [] and .landed[2].links == []
      and .landed[4].thumbs == [] and .landed[4].links == [{text:"evidence", href:"evidence/clip.mp4"}]
  ' >/dev/null || fail "non-image or absent evidence did not keep the plain link or nothing: $out"
  pass "project cards link home boards and image evidence renders as thumbnails"
}

test_milestone_fields_render_on_the_strip_rows_and_cards
test_project_cards_link_home_boards_and_image_evidence_shows_thumbnails
test_an_old_payload_renders_no_milestone_surfaces
test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
