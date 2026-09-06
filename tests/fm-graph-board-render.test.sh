#!/usr/bin/env bash
# Behavior tests for the graph board renderer, exercised through a real
# fm-graph-board.sh build and a minimal DOM shim over the rendered page.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-graph-board.sh"
HARNESS="$ROOT/tests/assets/graph-board-render-harness.mjs"
ASSETS="$ROOT/tests/assets"
TMP_ROOT=$(fm_test_tmproot fm-graph-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

render() {
  local home=$1 fixture=$2
  cp "$ASSETS/$fixture" "$home/payload.json"
  FM_HOME="$home" "$BOARD" build "$home/payload.json" >/dev/null \
    || fail "the graph board did not build from $fixture"
  node "$HARNESS" "$home/.lavish/graph-board.html" \
    || fail "the graph board could not be rendered from $fixture"
}

render_pipe() {
  local home=$1 fixture=$2
  FM_HOME="$home" "$BOARD" build <(cat "$ASSETS/$fixture") >/dev/null \
    || fail "the graph board did not build through process substitution"
  node "$HARNESS" "$home/.lavish/graph-board.html" \
    || fail "the process-substitution board could not be rendered"
}

assert_rendered() {
  local out=$1 query=$2 message=$3
  printf '%s\n' "$out" | jq -e "$query" >/dev/null \
    || fail "$message: $out"
}

test_three_uninitialized_tasks_are_hollow_and_connected() {
  local home out
  home=$(make_home uninitialized)
  out=$(render "$home" graph-board-uninitialized.json)
  assert_rendered "$out" '
    (.tasks | length) == 3
    and ([.tasks[] | select((.boxes | length) > 0)] | length) == 3
    and ([.tasks[] | .boxes[] | select(.state != "uninitialized" or .current or (.duration != ""))] | length) == 0
    and ([.tasks[] | .edges[]] | length) == 21
    and ([.tasks[] | .edges[] | select((.x2 - .x1) != 20)] | length) == 0
    and ([.tasks[] | select((.banner | contains("no owner step recorded yet")))] | length) == 3
    and ([.tasks[] | select(.evidence == "unavailable")] | length) == 3
  ' "uninitialized tasks must remain hollow, connected, and explicit about unavailable evidence"
  pass "three uninitialized tasks render hollow boxes and structural edges"
}

test_recorded_dispatched_step_is_the_only_highlight() {
  local home out
  home=$(make_home dispatched)
  out=$(render_pipe "$home" graph-board-dispatched.json)
  assert_rendered "$out" '
    (.tasks | length) == 1
    and ([.tasks[0].boxes[] | select(.current)] | length) == 1
    and ([.tasks[0].boxes[] | select(.current and .step == "dispatched" and .state == "success" and .evidence == "meta:state/dispatched-row.meta")] | length) == 1
    and ([.tasks[0].boxes[] | select(.current | not)] | length) == 7
    and .tasks[0].evidence == "meta:state/dispatched-row.meta"
  ' "a dispatched artifact must highlight exactly its recorded step with its owner reference"
  pass "a dispatched artifact highlights exactly one step with verbatim evidence"
}

test_stale_banner_derives_its_threshold_from_payload() {
  local home out
  home=$(make_home stale)
  out=$(render "$home" graph-board-stale.json)
  assert_rendered "$out" '.stale.state == "stale" and (.stale.text | contains("board stale"))' \
    "a payload older than its check interval must show the board stale banner"
  pass "stale freshness derives from check_interval"
}

test_all_record_states_are_visible_and_distinct() {
  local home out
  home=$(make_home mixed)
  out=$(render "$home" graph-board-mixed.json)
  assert_rendered "$out" '
    (.tasks | length) == 3
    and ([.tasks[] | select(.recordState == "uninitialized" and (.banner | contains("no owner step recorded yet")))] | length) == 1
    and ([.tasks[] | select(.recordState == "refused:absent-meta-not-cleaned" and (.banner | contains("absent-meta-not-cleaned")))] | length) == 1
    and ([.tasks[] | select(.recordState == "ok" and .evidence == "meta:state/recorded-row.meta")] | length) == 1
    and ([.tasks[] | select(.recordState != "ok" and .evidence == "unavailable")] | length) == 2
  ' "uninitialized, refused, and recorded rows must remain visible and distinguishable"
  pass "all three owner record states render honestly in one board"
}

test_detail_control_reveals_owner_reference_without_fetching() {
  local home out
  home=$(make_home detail)
  out=$(render "$home" graph-board-dispatched.json)
  assert_rendered "$out" '
    .tasks[0].detailVisible
    and (.tasks[0].detail | contains("meta:state/dispatched-row.meta"))
    and (.tasks[0].detail | contains("record state: ok"))
  ' "the accessible detail control must reveal the owner reference and row facts"
  pass "detail control reveals owner evidence and row facts"
}

test_unknown_freshness_never_invents_duration() {
  local home fixture out mode known_now
  home=$(make_home unknown-freshness)
  fixture="$home/payload.json"
  known_now=1788724800
  for mode in missing invalid future zero; do
    case "$mode" in
      missing) jq 'del(.generated_epoch)' "$ASSETS/graph-board-dispatched.json" > "$fixture" ;;
      invalid) jq '.generated_epoch = "not-an-epoch"' "$ASSETS/graph-board-dispatched.json" > "$fixture" ;;
      future) jq --argjson now "$known_now" '.generated_epoch = ($now + 60)' "$ASSETS/graph-board-dispatched.json" > "$fixture" ;;
      zero) jq '.check_interval = 0' "$ASSETS/graph-board-dispatched.json" > "$fixture" ;;
    esac
    out=$(FM_HOME="$home" "$BOARD" build "$fixture" >/dev/null && FM_GRAPH_BOARD_NOW="$known_now" node "$HARNESS" "$home/.lavish/graph-board.html") \
      || fail "the graph board did not build an unknown-freshness payload for $mode"
    assert_rendered "$out" '.stale.state == "unknown" and ([.tasks[].boxes[] | select(.duration != "")] | length) == 0' \
      "unknown freshness must not invent duration for $mode"
  done
  jq --argjson now "$known_now" '.generated_epoch = ($now - 30) | .check_interval = 60' \
    "$ASSETS/graph-board-dispatched.json" > "$fixture"
  out=$(FM_HOME="$home" "$BOARD" build "$fixture" >/dev/null && FM_GRAPH_BOARD_NOW="$known_now" node "$HARNESS" "$home/.lavish/graph-board.html") \
    || fail "the graph board did not build a known fresh payload"
  assert_rendered "$out" '.stale.state == "fresh" and (.stale.text | contains("refresh interval 60s")) and ([.tasks[].boxes[] | select(.duration != "")] | length) == 1' \
    "a known valid clock must render fresh with a duration"

  jq --argjson now "$known_now" '.generated_epoch = ($now - 61) | .check_interval = 60' \
    "$ASSETS/graph-board-dispatched.json" > "$fixture"
  out=$(FM_HOME="$home" "$BOARD" build "$fixture" >/dev/null && FM_GRAPH_BOARD_NOW="$known_now" node "$HARNESS" "$home/.lavish/graph-board.html") \
    || fail "the graph board did not build a non-default interval payload"
  assert_rendered "$out" '.stale.state == "stale" and (.stale.text | contains("refresh interval 60s"))' \
    "a non-default interval boundary must control freshness"
  pass "freshness handles unknown clocks and a known, discriminating non-default interval table"
}

test_hostile_text_round_trips_as_text() {
  local home out
  home=$(make_home hostile)
  out=$(render "$home" graph-board-hostile.json)
  assert_rendered "$out" '
    (.tasks | length) == 1
    and (.tasks[0].detail | contains("</script>"))
    and (.tasks[0].detail | contains("<img src=x>"))
    and (.tasks[0].banner | contains("refused:"))
  ' "hostile owner text must render as inert text"
  pass "hostile owner text stays inert through build and render"
}

test_invalid_input_preserves_last_good_html() {
  local home before after invalid
  home=$(make_home rollback)
  render "$home" graph-board-dispatched.json >/dev/null
  before="$home/before.html"
  after="$home/.lavish/graph-board.html"
  cp "$after" "$before"
  invalid="$home/invalid.json"
  printf '%s\n' '{"schema":"fm-pipeline-board.v1","tasks":"not-an-array"}' > "$invalid"
  if FM_HOME="$home" "$BOARD" build "$invalid" >/dev/null 2>"$home/error"; then
    fail "malformed input unexpectedly replaced the graph board"
  fi
  cmp -s "$before" "$after" || fail "malformed input changed the last good graph board"
  rg -q 'fm-graph-board: board data does not satisfy fm-pipeline-board.v1' "$home/error" \
    || fail "malformed input did not report a named validation failure"

  cat "$ASSETS/graph-board-dispatched.json" "$ASSETS/graph-board-dispatched.json" > "$invalid"
  if FM_HOME="$home" "$BOARD" build "$invalid" >/dev/null 2>"$home/error"; then
    fail "concatenated valid payloads unexpectedly replaced the graph board"
  fi
  cmp -s "$before" "$after" || fail "concatenated valid payloads changed the last good graph board"
  rg -q 'fm-graph-board: board data does not satisfy fm-pipeline-board.v1' "$home/error" \
    || fail "concatenated valid payloads did not report a named validation failure"
  pass "malformed and concatenated input preserve the last good graph board byte-for-byte"
}

test_directory_destination_is_rejected_before_publish() {
  local home destination
  home=$(make_home destination-directory)
  destination="$home/.lavish/graph-board.html"
  cp "$ASSETS/graph-board-dispatched.json" "$home/payload.json"
  mkdir -p "$destination"
  printf '%s\n' sentinel > "$destination/sentinel"
  if FM_HOME="$home" "$BOARD" build "$home/payload.json" >/dev/null 2>"$home/error"; then
    fail "a directory destination unexpectedly counted as a published board"
  fi
  [ -d "$destination" ] || fail "directory destination was replaced"
  [ "$(cat "$destination/sentinel")" = sentinel ] || fail "directory destination contents changed"
  rg -q 'fm-graph-board: board destination is a directory:' "$home/error" \
    || fail "directory destination did not report a named refusal"
  pass "a directory at the stable board path is refused before publish"
}

test_three_uninitialized_tasks_are_hollow_and_connected
test_recorded_dispatched_step_is_the_only_highlight
test_stale_banner_derives_its_threshold_from_payload
test_all_record_states_are_visible_and_distinct
test_detail_control_reveals_owner_reference_without_fetching
test_unknown_freshness_never_invents_duration
test_hostile_text_round_trips_as_text
test_invalid_input_preserves_last_good_html
test_directory_destination_is_rejected_before_publish
