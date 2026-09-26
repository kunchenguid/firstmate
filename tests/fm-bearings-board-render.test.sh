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
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [underway_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} underway_more=${6:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" --argjson underway_more "$underway_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more,
    underway_more:$underway_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_METRICS=off \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Like render_board, but also carries captains_call (so the Unanswered
# Questions table has real rows) and an optional metrics object.
render_full() {  # <home> <captains_call-json> <underway-json> <metrics-json>
  local home=$1 captains_call=$2 underway=$3 metrics=$4 charted=${5:-[]} data="$1/payload.json"
  jq -n --argjson captains_call "$captains_call" --argjson underway "$underway" \
    --argjson metrics "$metrics" --argjson charted "$charted" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$captains_call, underway:$underway, landed:[],
    charted:$charted, metrics:$metrics}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_METRICS=off \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more] [underway_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}" "${5:-0}"
}

test_unified_table_keeps_all_rows_and_maps_charted_states() {
  local home out
  home=$(make_home unified-all-rows)
  out=$(render "$home" '[
    {"id":"queued","repo":"sample","title":"Queued","reason":"","dispatchable":true},
    {"id":"blocked","repo":"sample","title":"Blocked","reason":"waiting for gate","dispatchable":true},
    {"id":"warning","repo":"sample","title":"Warning","reason":"integrity issue","dispatchable":false,"kind":"warning"}
  ]' 3 2 4)
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.tasks[].id] == ["queued","blocked","warning"])
    and ([.tasks[].state] == ["예정","대기","대기"])
    and ([.tasks[].blocker] == ["-","waiting for gate","integrity issue"])
    and ([.tasks[] | select(.id == "warning") | .alarm] == [true])
    and ([.tasks[] | select(.id == "warning") | .alarmText] == ["수리 필요"])
    and ([.stats[] | select(.label == "다음 예정") | .n] == [5])
    and (.legacyCopies == [])
    and (.omitted == "진행 중 +4건 더 · 다음 예정 +3건 더 · 수리 경고 +2건 더")
  ' >/dev/null || fail "unified task table truncated rows or kept duplicate list paths: $out"
  pass "the unified table discloses omitted rows and marks repair warnings"
}

test_unified_table_discloses_underway_rows_and_no_omissions() {
  local home out
  home=$(make_home underway-omissions)
  out=$(render_board "$home" '[{"id":"run-task","repo":"sample","state":"working","kind":"ship","name":"Running","doing":"testing"}]' '[]' 0 0 2)
  printf '%s' "$out" | jq -e '.omitted == "진행 중 +2건 더" and .tasks[0].state == "진행중" and (.tasks[0].alarm == false)' >/dev/null \
    || fail "underway omitted count was not disclosed: $out"
  out=$(render_board "$home" '[]' '[]')
  printf '%s' "$out" | jq -e '.omitted == "" and .omittedHidden == true' >/dev/null \
    || fail "an empty omitted count was displayed: $out"
  pass "underway omissions are disclosed only when the producer reports a count"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.tasks | length) == 1
      and (.tasks[0] | .id == "fm-board-name-r1" and .state == "진행중"
        and .title == "Show task names on the board" and .blocker == "-")
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
    (.tasks | length) == 1
      and (.tasks[0] | .id == "mate/child-1" and .title == "mate/child-1" and .state == "진행중")
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
    [.tasks[].title] == ["Filed in August", "Filed in July", "Filed in June"]
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
    [.tasks[].title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_present_metrics_render_real_values_and_absent_ones_say_no_data() {
  local home out
  home=$(make_home metrics-mixed)
  out=$(render_full "$home" '[]' '[]' '{
    "quota_session_used_percent": 30.2,
    "quota_weekly_used_percent": 74,
    "cache_hit_rate": 72.5,
    "tool_error_rate": {"errors": 3, "total": 120}
  }')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.statsCost[] | select(.label == "5시간 쿼터 사용량") | .value] == ["30.2% / 100%"])
    and ([.statsCost[] | select(.label == "7일 쿼터 사용량") | .value] == ["74% / 100%"])
    and ([.statsCost[] | select(.label == "24시간 캐시 적중률") | .value] == ["72.5%"])
    and ([.statsCost[] | select(.label == "24시간 도구 오류율") | .value] == ["3 / 120 (2.5%)"])
    and ([.statsFleet[] | select(.label == "컨텍스트 읽기 누락") | .value] == ["데이터 없음"])
  ' >/dev/null || fail "present metrics did not render real values or absent ones were not honestly labeled: $out"
  pass "quota, cache, and tool metrics render sourced values while unobservable metrics say no data"
}

test_unanswered_questions_count_and_table_read_off_captains_call() {
  local home out
  home=$(make_home questions)
  out=$(render_full "$home" '[
    {"key":"decision-one","type":"decision","repo":"sample","title":"Adopt the new cache?",
     "options":[{"value":"yes","label":"Adopt"}]},
    {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge: sample change",
     "risk":"low","options":[{"value":"merge","label":"Merge now"}]}
  ]' '[]' '{}')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.statsFleet[] | select(.label == "미응답 질문") | .value] == ["2"])
    and (.questions | length) == 2
    and (.questions[0] == {id:"decision-one", question:"Adopt the new cache?", urgency:"-", action:"다음 예정 항목으로 이동"})
    and (.questions[1] == {id:"merge.sample-task", question:"Merge: sample change", urgency:"-", action:"PR 병합 보류"})
  ' >/dev/null || fail "the unanswered-questions count or table did not read off captains_call: $out"
  pass "the unanswered questions table reads real call data and reports unavailable urgency honestly"
}

test_merge_risk_badges_preserve_each_level() {
  local home out
  home=$(make_home merge-risk-labels)
  out=$(render_full "$home" '[
    {"key":"merge-low","type":"merge","repo":"sample","title":"Low","risk":"low","options":[{"value":"merge","label":"Merge"}]},
    {"key":"merge-medium","type":"merge","repo":"sample","title":"Medium","risk":"medium","options":[{"value":"merge","label":"Merge"}]},
    {"key":"merge-high","type":"merge","repo":"sample","title":"High","risk":"high","options":[{"value":"merge","label":"Merge"}]},
    {"key":"merge-unknown","type":"merge","repo":"sample","title":"Unknown","risk":"critical","options":[{"value":"merge","label":"Merge"}]}
  ]' '[]' '{}')
  printf '%s' "$out" | jq -e '
    [.calls[].badges[1]] == ["위험도 낮음", "위험도 보통", "위험도 높음", "위험도 critical"]
  ' >/dev/null || fail "merge risk labels did not preserve accepted levels: $out"
  pass "merge risk badges preserve canonical levels and unknown values"
}


test_unified_task_table_maps_real_states_and_question_urgency() {
  local home out filed_today
  home=$(make_home unified-table)
  filed_today=$(date -u +%Y-%m-%d)
  out=$(render_full "$home" '[
    {"key":"fresh","type":"decision","repo":"sample","title":"Fresh question?","filed":"'"$filed_today"'","blocking":false,"options":[{"value":"yes","label":"Yes"}]},
    {"key":"old-blocker","type":"decision","repo":"sample","title":"Old blocking question?","filed":"2026-09-20","blocking":true,"options":[{"value":"yes","label":"Yes"}]},
    {"key":"undated","type":"decision","repo":"sample","title":"Undated?","blocking":true,"options":[{"value":"yes","label":"Yes"}]}
    , {"key":"unknown-blocking","type":"decision","repo":"sample","title":"Unknown blocker?","filed":"'"$filed_today"'","options":[{"value":"yes","label":"Yes"}]}
  ]' '[
    {"id":"run-1","repo":"sample","name":"Running","state":"validating","kind":"ship","doing":"checking"}
  , {"id":"run-2","repo":"sample","name":"Blocked","state":"working","kind":"ship","doing":"waiting","blocker":"blocked by gate"}
  , {"id":"run-3","repo":"sample","name":"Blocked without reason","state":"blocked","kind":"ship","doing":"waiting"}
  ]' '{}' '[
    {"id":"queued","repo":"sample","title":"Queued","reason":"","dispatchable":true},
    {"id":"waiting","repo":"sample","title":"Waiting","reason":"not ready","dispatchable":true}
  ]')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and (.tasks | any(.[]; .id == "run-1" and .state == "진행중" and .title == "Running"))
    and (.tasks | any(.[]; .id == "queued" and .state == "예정"))
    and (.tasks | any(.[]; .id == "waiting" and .state == "대기"))
    and (.tasks | any(.[]; .id == "run-2" and .state == "대기" and .title == "Blocked" and .blocker == "blocked by gate"))
    and (.tasks | any(.[]; .id == "run-3" and .state == "차단됨" and .title == "Blocked without reason" and .blocker == "사유 미상"))
    and ([.questions[].urgency] == ["보통","높음","-","-"])
  ' >/dev/null || fail "task mapping or urgency did not match real fields: $out"
  pass "unified table maps underway states and urgency uses filed age/blocking"
}

test_zero_tool_calls_have_no_percentage() {
  local home out
  home=$(make_home zero-tool-calls)
  out=$(render_full "$home" '[]' '[]' '{"tool_error_rate":{"errors":0,"total":0}}')
  printf '%s' "$out" | jq -e '[.statsCost[] | select(.label == "24시간 도구 오류율") | .value] == ["0 / 0 (-)"]' >/dev/null \
    || fail "zero calls rendered a percentage: $out"
  pass "zero tool calls show unavailable percentage with real counts"
}

test_underway_and_charted_blocker_columns_render_real_or_honest_absence() {
  local home out
  home=$(make_home blocker-columns)
  out=$(render_board "$home" '[
    {"id":"blocked-task","repo":"sample","name":"Blocked task","state":"working","kind":"ship",
     "doing":"implementing","blocker":"waiting on decision-one"},
    {"id":"clear-task","repo":"sample","name":"Clear task","state":"working","kind":"ship",
     "doing":"implementing"}
  ]' '[
    {"id":"gated","repo":"sample","title":"Gated work","reason":"blocked on blocked-task","dispatchable":true},
    {"id":"free","repo":"sample","title":"Free work","reason":"","dispatchable":true}
  ]')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.tasks[] | select(.title == "Blocked task") | .blocker] == ["waiting on decision-one"])
    and ([.tasks[] | select(.title == "Clear task") | .blocker] == ["-"])
    and ([.tasks[] | select(.title == "Gated work") | .blocker] == ["blocked on blocked-task"])
    and ([.tasks[] | select(.title == "Free work") | .blocker] == ["-"])
  ' >/dev/null || fail "the blocker column did not render real text or honest absence: $out"
  pass "the blocker column shows real structured blocker text, and honestly labels no blocker rather than a placeholder"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_unified_table_keeps_all_rows_and_maps_charted_states
test_unified_table_discloses_underway_rows_and_no_omissions
test_present_metrics_render_real_values_and_absent_ones_say_no_data
test_unanswered_questions_count_and_table_read_off_captains_call
test_merge_risk_badges_preserve_each_level
test_underway_and_charted_blocker_columns_render_real_or_honest_absence
test_unified_task_table_maps_real_states_and_question_urgency
test_zero_tool_calls_have_no_percentage
