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
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [captains_call-json]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} calls=${6:-[]} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" --argjson calls "$calls" '{
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

test_board_text_links_urls_and_previewed_reports_but_keeps_markup_as_text() {
  local home report out
  home=$(make_home links)
  report="$home/data/scout-1/report.md"
  mkdir -p "${report%/*}"
  printf '# Findings\n' > "$report"
  out=$(render_board "$home" "$(jq -n --arg report "$report" --arg missing "$home/data/gone/report.md" '[
    {"id":"t1","repo":"sample","name":"<b>scout-1</b>","state":"working","kind":"scout",
     "doing":("see https://gitlab.example.com/g/p/-/merge_requests/7, report " + $report + " and " + $missing)}
  ]')" '[
    {"id":"c1","repo":"sample","title":"Dashboard (http://127.0.0.1:4387/session/abc).","reason":"","dispatchable":false}
  ]')
  printf '%s' "$out" | jq -e --arg report "$report" '
    (.underway[0]
      | .title == "<b>scout-1</b>"
        and (.sub | startswith("see https://gitlab.example.com/g/p/-/merge_requests/7, report " + $report + " and "))
        and (.links | length) == 2
        and (.links[0] == {text: "https://gitlab.example.com/g/p/-/merge_requests/7",
          href: "https://gitlab.example.com/g/p/-/merge_requests/7", target: "_blank", rel: "noopener"})
        and (.links[1] | .text == $report and (.href | test("^bearings-board-reports/[0-9a-f]{16}[.]html$"))
          and .target == "_blank"))
    and (.charted[0].links == [{text: "http://127.0.0.1:4387/session/abc",
      href: "http://127.0.0.1:4387/session/abc", target: "_blank", rel: "noopener"}])
  ' >/dev/null || fail "board text did not link its URLs and previewed report while keeping markup as text: $out"
  [ -f "$home/.lavish/$(printf '%s' "$out" | jq -r '.underway[0].links[1].href')" ] \
    || fail "the report link points at a preview page the build did not write: $out"
  pass "board text links URLs and existing reports in new tabs, a missing report stays text, and markup stays text"
}

test_a_report_preview_keeps_balanced_parentheses_in_link_targets() {
  local home report out page
  home=$(make_home preview-parens)
  report="$home/data/scout-3/report.md"
  mkdir -p "${report%/*}"
  cat > "$report" <<'MD'
See [Foo](https://en.wikipedia.org/wiki/Foo_(bar)) and https://en.wikipedia.org/wiki/Baz_(qux).
(Also https://example.com/plain.)
MD
  render_board "$home" "$(jq -n --arg report "$report" '[
    {"id":"t3","repo":"sample","name":"scout-3","state":"working","kind":"scout","doing":("report " + $report)}
  ]')" '[]' > /dev/null
  page=$(find "$home/.lavish/bearings-board-reports" -name '*.html' | head -1)
  [ -n "$page" ] || fail "the build wrote no report preview page"
  out=$(node "$ROOT/tests/assets/report-preview-harness.mjs" "$page") \
    || fail "the report preview page could not be rendered"
  printf '%s' "$out" | jq -e '
    .blocks[0].text == "See Foo and https://en.wikipedia.org/wiki/Baz_(qux). (Also https://example.com/plain.)"
    and ([.blocks[0].children[] | {text, href}] == [
      {text: "Foo", href: "https://en.wikipedia.org/wiki/Foo_(bar)"},
      {text: "https://en.wikipedia.org/wiki/Baz_(qux)", href: "https://en.wikipedia.org/wiki/Baz_(qux)"},
      {text: "https://example.com/plain", href: "https://example.com/plain"}])
  ' >/dev/null || fail "a report preview cut a link target at a balanced parenthesis: $out"
  pass "a report preview keeps balanced parentheses in markdown and bare link targets and drops trailing punctuation"
}

test_decision_option_labels_link_their_urls() {
  local home out
  home=$(make_home option-links)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"sample-option-links","type":"decision","repo":"sample","title":"Pick a runbook",
     "about":"","decide":"Which?","allow_freeform":false,
     "options":[
       {"value":"a","label":"Follow https://docs.example.com/runbook"},
       {"value":"b","label":"<b>Skip</b>"}]}
  ]')
  printf '%s' "$out" | jq -e '
    .error == ""
    and .options[0:2] == [
      {text: "Follow https://docs.example.com/runbook", links: [{text: "https://docs.example.com/runbook",
        href: "https://docs.example.com/runbook", target: "_blank", rel: "noopener"}]},
      {text: "<b>Skip</b>", links: []}]
  ' >/dev/null || fail "a decision option label did not link its URL while keeping markup as text: $out"
  pass "decision option labels link their URLs in new tabs and keep markup as text"
}

test_a_report_preview_renders_the_markdown_and_keeps_markup_as_text() {
  local home report out page
  home=$(make_home preview)
  report="$home/data/scout-2/report.md"
  mkdir -p "${report%/*}"
  cat > "$report" <<'MD'
# Scout report

Found **two** issues, see [the MR](https://gitlab.example.com/g/p/-/merge_requests/9) and `fm-x.sh`.

- first <script>alert(1)</script>
- second
  - nested

| file | line |
| --- | --- |
| a.sh | 3 |

```
</script><b>code</b>
```
MD
  render_board "$home" "$(jq -n --arg report "$report" '[
    {"id":"t2","repo":"sample","name":"scout-2","state":"working","kind":"scout","doing":("report " + $report)}
  ]')" '[]' > /dev/null
  page=$(find "$home/.lavish/bearings-board-reports" -name '*.html' | head -1)
  [ -n "$page" ] || fail "the build wrote no report preview page"
  out=$(node "$ROOT/tests/assets/report-preview-harness.mjs" "$page") \
    || fail "the report preview page could not be rendered"
  printf '%s' "$out" | jq -e --arg report "$report" '
    .path == $report and .title == "report.md - report preview"
    and ([.blocks[] | .tag] == ["h1", "p", "ul", "div", "pre"])
    and .blocks[0].text == "Scout report"
    and (.blocks[1] | .text == "Found two issues, see the MR and fm-x.sh."
      and ([.children[] | .tag] == ["strong", "a", "code"])
      and .children[1].href == "https://gitlab.example.com/g/p/-/merge_requests/9")
    and (.blocks[2] | [.children[] | .tag] == ["li", "li"]
      and .children[0].text == "first <script>alert(1)</script>"
      and .children[1].children[0].tag == "ul"
      and .children[1].children[0].children[0].text == "nested")
    and (.blocks[3].children[0] | .tag == "table" and (.text | contains("a.sh")))
    and .blocks[4].text == "</script><b>code</b>"
  ' >/dev/null || fail "the report preview did not render the markdown as structured text: $out"
  pass "a report preview renders headings, inline marks, links, nested lists, tables, and code, with markup kept as text"
}

test_every_call_card_offers_free_text_whatever_allow_freeform_says() {
  local home out
  home=$(make_home freeform)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"sample-off","type":"decision","repo":"sample","title":"Freeform off","decide":"Which?",
     "allow_freeform":false,"options":[{"value":"a","label":"A"}]},
    {"key":"sample-hint","type":"decision","repo":"sample","title":"Hint only","decide":"Which?",
     "freeform_hint":"name the vehicle","options":[{"value":"a","label":"A"}]},
    {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge it","risk":"low",
     "options":[{"value":"merge","label":"Merge now"}]}
  ]')
  printf '%s' "$out" | jq -e '
    .error == ""
    and ([.cards[] | .freeform] == [
      [{name: "note", placeholder: "or answer in your own words…"}],
      [{name: "note", placeholder: "name the vehicle"}],
      [{name: "note", placeholder: "or answer in your own words…"}]])
  ' >/dev/null || fail "a Captain's Call card rendered without its free-text answer field: $out"
  pass "every Captain's Call card offers free text, with freeform_hint as its placeholder"
}

test_a_credential_card_warns_against_pasting_a_secret_unless_hinted() {
  local home out
  home=$(make_home credential)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"sample-login","type":"credential","repo":"sample","title":"Registry login","decide":"Log in?",
     "options":[{"value":"done","label":"Logged in"}]},
    {"key":"sample-token","type":"credential","repo":"sample","title":"Deploy token","decide":"Rotate?",
     "freeform_hint":"say where you stored it","options":[{"value":"done","label":"Rotated"}]}
  ]')
  printf '%s' "$out" | jq -e '
    .error == ""
    and ([.cards[] | .freeform] == [
      [{name: "note", placeholder: "say what you did - never paste a password, token, or key here"}],
      [{name: "note", placeholder: "say where you stored it"}]])
  ' >/dev/null || fail "a credential card did not warn against pasting a secret: $out"
  pass "a credential card warns against pasting a secret, and freeform_hint still wins"
}

test_a_call_card_context_box_shows_its_dossier_fields_as_text() {
  local home report out
  home=$(make_home dossier)
  report="$home/data/scout-4/report.md"
  mkdir -p "${report%/*}"
  printf '# Findings\n' > "$report"
  out=$(render_board "$home" '[]' '[]' 0 0 "$(jq -n --arg report "$report" --arg missing "$home/data/gone/report.md" '[
    {"key":"sample-dossier","type":"decision","repo":"sample","title":"CMS sync","about":"short line",
     "decide":"How to sync?","options":[{"value":"a","label":"A"}],
     "background":"<b>Main</b> is ahead, see https://gitlab.example.com/g/p/-/merge_requests/1",
     "stakes":"The next release reintroduces the finding.","opened":"2026-08-23",
     "links":[
       {"kind":"mr","label":"lambda !316","url":"https://gitlab.example.com/g/l/-/merge_requests/316","state":"open"},
       {"kind":"report","label":"sync report","path":$report},
       {"kind":"report","label":"old report","path":$missing}],
     "history":[{"date":"2026-08-20","text":"Hotfix landed"},{"date":"2026-08-24","text":"Conflict found"}]}
  ]')")
  printf '%s' "$out" | jq -e '
    .error == ""
    and (.cards[0]
      | .dossier
        and .rows == ["about", "decide"]
        and .context.age == "open 3 days"
        and ([.context.sections[] | .name] == ["background", "stakes", "links", "history"])
        and .context.sections[0].text == "Background<b>Main</b> is ahead, see https://gitlab.example.com/g/p/-/merge_requests/1"
        and .context.sections[1].text == "If this waitsThe next release reintroduces the finding."
        and .context.sections[3].text == "History20 AugHotfix landed24 AugConflict found"
        and (.context.links | length) == 3
        and .context.links[0] == {kind: "MR", label: "lambda !316",
          href: "https://gitlab.example.com/g/l/-/merge_requests/316", state: "open"}
        and (.context.links[1] | .kind == "report" and .label == "sync report"
          and (.href | test("^bearings-board-reports/[0-9a-f]{16}[.]html$")))
        and .context.links[2] == {kind: "report", label: "old report", href: null, state: null})
  ' >/dev/null || fail "the Context box did not show the card dossier as text: $out"
  [ -f "$home/.lavish/$(printf '%s' "$out" | jq -r '.cards[0].context.links[1].href')" ] \
    || fail "a context report link points at a preview page the build did not write: $out"
  pass "a card's Context box shows background, stakes, typed links with state and previews, history, and its age"
}

test_a_call_card_without_dossier_fields_falls_back_or_collapses() {
  local home out
  home=$(make_home dossier-fallback)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"sample-about","type":"decision","repo":"sample","title":"About only","about":"Lambda already synced",
     "decide":"Sync CMS?","options":[{"value":"a","label":"A"}]},
    {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge it","risk":"low",
     "detail":"validation green","pr_url":"https://github.com/example/sample/pull/1",
     "options":[{"value":"merge","label":"Merge now"}]},
    {"key":"sample-bare","type":"decision","repo":"sample","title":"Bare","decide":"Go?",
     "options":[{"value":"a","label":"A"}]}
  ]')
  printf '%s' "$out" | jq -e '
    .error == ""
    and (.cards[0] | .dossier and .rows == ["decide"]
      and .context.sections == [{name: "background", text: "BackgroundLambda already synced"}])
    and (.cards[1] | .dossier and .rows == []
      and ([.context.sections[] | .name] == ["background", "links"])
      and .context.sections[0].text == "Backgroundvalidation green"
      and .context.links == [{kind: "PR", label: "https://github.com/example/sample/pull/1",
        href: "https://github.com/example/sample/pull/1", state: null}])
    and (.cards[2] | (.dossier | not) and .context == null and .rows == ["decide"])
  ' >/dev/null || fail "a card without dossier fields did not fall back to its about, detail, and PR, or collapse: $out"
  pass "a card without dossier fields shows its about, or merge detail and PR, in the Context box, and collapses with none"
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
test_board_text_links_urls_and_previewed_reports_but_keeps_markup_as_text
test_decision_option_labels_link_their_urls
test_a_report_preview_keeps_balanced_parentheses_in_link_targets
test_a_report_preview_renders_the_markdown_and_keeps_markup_as_text
test_every_call_card_offers_free_text_whatever_allow_freeform_says
test_a_credential_card_warns_against_pasting_a_secret_unless_hinted
test_a_call_card_context_box_shows_its_dossier_fields_as_text
test_a_call_card_without_dossier_fields_falls_back_or_collapses
