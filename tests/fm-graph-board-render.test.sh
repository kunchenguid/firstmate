#!/usr/bin/env bash
# Behavior tests for the graph board renderer, exercised through a real
# fm-graph-board.sh build and a minimal DOM shim over the rendered page.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BOARD="$ROOT/bin/fm-graph-board.sh"
PIPELINE="$ROOT/bin/fm-pipeline.sh"
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

assert_dispatched_render() {
  local rendered=$1 message=${2:-"a dispatched task was not highlighted"}
  printf '%s' "$rendered" | jq -e '
    (.tasks | length) == 1
    and ([.tasks[0].boxes[] | select(.current and .step == "dispatched" and .state == "success")] | length) == 1
  ' >/dev/null || fail "$message: $rendered"
}

board_generated_epoch() {
  node - "$1" <<'NODE'
const fs = require("node:fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const payload = html.split('<script id="graph-board-data" type="application/json">')[1].split("</script>")[0];
process.stdout.write(String(JSON.parse(payload).generated_epoch));
NODE
}

test_graph_board_arm_absent_is_private_registered_and_idempotent() {
  local home state check trust device rc=0 out
  home=$(make_home arm-absent)
  state="$home/state"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm) || rc=$?
  expect_code 0 "$rc" "arm must proceed when the disabled marker is absent"
  assert_contains "$out" 'armed: state/graph-board.check.sh' \
    "arm did not report the graph-board check"
  check="$state/graph-board.check.sh"
  trust="$state/graph-board.check-trust"
  [ -f "$check" ] || fail "arm did not create the graph-board check"
  [ -f "$trust" ] || fail "arm did not create the graph-board trust record"
  device=$(fm_pr_file_device "$state") || fail "could not inspect the fixture state device"
  fm_pr_private_file_valid "$check" 700 "$device" \
    || fail "the graph-board check is not a private mode-0700 file"
  fm_custom_check_registered "$state" graph-board \
    || fail "the graph-board check was not registered against its current bytes"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm) || rc=$?
  expect_code 0 "$rc" "repeated arm must remain idempotent"
  fm_custom_check_registered "$state" graph-board \
    || fail "repeated arm left an untrusted graph-board check"
  pass "graph-board arm proceeds without a marker and remains idempotent"
}

test_graph_board_check_is_quiet_and_confined() {
  local home state foreign out rendered rc=0
  home=$(make_home quiet-confined)
  state="$home/state"
  foreign="$TMP_ROOT/quiet-confined-foreign"
  mkdir -p "$foreign/tmp"
  printf 'kind=ship\nspawn_gen=gen-quiet\n' > "$state/dispatched-row.meta"
  printf 'working: started\n' > "$state/dispatched-row.status"
  printf 'decoy template\n' > "$foreign/decoy.html"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$PIPELINE" reconcile dispatched-row >/dev/null \
    || fail "could not create the dispatched record for the quiet check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm >/dev/null \
    || fail "could not arm the graph-board check"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_ROOT_OVERRIDE="$foreign/root" FM_DATA_OVERRIDE="$foreign/data" \
    FM_CONFIG_OVERRIDE="$foreign/config" TMPDIR="$foreign/tmp" \
    FM_GRAPH_BOARD_TEMPLATE="$foreign/decoy.html" \
    FM_PIPELINE_LOG="$state/pipeline-events.log" \
    "$state/graph-board.check.sh" 2>"$home/check.err") || rc=$?
  expect_code 0 "$rc" "a healthy graph-board check must succeed"
  [ -z "$out" ] || fail "a healthy graph-board check woke the watcher with: $out"
  [ "$(cat "$foreign/decoy.html")" = 'decoy template' ] \
    || fail "the ambient graph-board template was changed"
  [ -z "$(find "$state" -maxdepth 1 -name '.fm-graph-board-refresh.*' -print -quit)" ] \
    || fail "the graph-board check left its private scratch file behind"
  [ -s "$home/.lavish/graph-board.html" ] || fail "the quiet check did not publish the board"
  rendered=$(node "$HARNESS" "$home/.lavish/graph-board.html") \
    || fail "the quiet check's board did not render"
  assert_dispatched_render "$rendered" \
    "the quiet check did not publish a board with the dispatched box highlighted"
  pass "a healthy graph-board check is quiet, confined, cleans its scratch, and rebuilds the board"
}

test_graph_board_check_uses_the_configured_pipeline_log() {
  local home state custom rendered owner_json rc=0
  home=$(make_home configured-log)
  state="$home/state"
  custom="$state/custom-events.log"
  printf 'kind=ship\nspawn_gen=gen-configured\n' > "$state/dispatched-row.meta"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/dispatched-row.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PIPELINE_LOG="$custom" \
    "$PIPELINE" reconcile dispatched-row >/dev/null \
    || fail "could not create the configured-log record"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PIPELINE_LOG="$custom" \
    "$BOARD" arm >/dev/null \
    || fail "could not arm the graph-board check with a configured log"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PIPELINE_LOG="$custom" \
    "$PIPELINE" probe --task dispatched-row >/dev/null \
    || fail "could not create the configured-log probe evidence"
  owner_json=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PIPELINE_LOG="$custom" \
    "$PIPELINE" board-json) || fail "the owner board JSON refused its configured log"
  printf '%s' "$owner_json" | jq -e '.tasks[0].probe_last.verdict == "unknown"' >/dev/null \
    || fail "the owner board JSON lost its configured-log probe evidence"
  rendered=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PIPELINE_LOG="$custom" \
    "$state/graph-board.check.sh" 2>"$home/check.err") || rc=$?
  expect_code 0 "$rc" "the graph-board check must inherit the configured runtime log"
  rendered=$(node "$HARNESS" "$home/.lavish/graph-board.html") \
    || fail "the configured-log board did not render"
  printf '%s' "$rendered" | jq -e '.tasks[0].probe == "unknown"' >/dev/null \
    || fail "the generated board lost the configured-log probe evidence"
  pass "the graph-board check inherits the configured pipeline log"
}

test_graph_board_check_failure_preserves_last_good_and_cleans_scratch() {
  local home state fakebin jq_real before rc=0 out
  home=$(make_home check-failure)
  state="$home/state"
  printf 'kind=ship\nspawn_gen=gen-failure\n' > "$state/dispatched-row.meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$PIPELINE" reconcile dispatched-row >/dev/null \
    || fail "could not create the record for the failed check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm >/dev/null \
    || fail "could not arm the graph-board check before inducing failure"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$state/graph-board.check.sh" >/dev/null \
    || fail "could not publish the last-good board before inducing failure"
  before=$(cat "$home/.lavish/graph-board.html")
  chmod 0500 "$home/.lavish"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$state/graph-board.check.sh" 2>"$home/check.err") || rc=$?
  chmod 0700 "$home/.lavish"
  [ "$rc" -ne 0 ] || fail "the graph-board check succeeded after its publish directory became unwritable"
  out=$(cat "$home/check.err")
  assert_contains "$out" 'fm-graph-board: cannot stage the graph board' \
    "the failed graph-board check did not preserve the builder diagnostic"
  [ "$(cat "$home/.lavish/graph-board.html")" = "$before" ] \
    || fail "a failed graph-board check replaced the last-good board"
  [ -z "$(find "$state" -maxdepth 1 -name '.fm-graph-board-refresh.*' -print -quit)" ] \
    || fail "a failed graph-board check left its private scratch file behind"

  fakebin="$home/fakebin"
  jq_real=$(command -v jq)
  mkdir -p "$fakebin"
  cat > "$fakebin/jq" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -sc ] && [ ! -e $(printf '%q' "$fakebin/jq-used") ]; then
  : > $(printf '%q' "$fakebin/jq-used")
  exit 42
fi
exec $(printf '%q' "$jq_real") "\$@"
EOF
  chmod 0700 "$fakebin/jq"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$state/graph-board.check.sh" 2>"$home/check.err") || rc=$?
  [ "$rc" -ne 0 ] || fail "the graph-board check succeeded after board-json failed"
  [ "$(cat "$home/.lavish/graph-board.html")" = "$before" ] \
    || fail "a board-json failure replaced the last-good board"
  [ -z "$(find "$state" -maxdepth 1 -name '.fm-graph-board-refresh.*' -print -quit)" ] \
    || fail "a board-json failure left its private scratch file behind"
  pass "failed graph-board checks propagate errors and preserve the last-good board"
}

test_graph_board_marker_valid_refuses_and_force_clears() {
  local home state rc=0 out
  home=$(make_home marker-valid)
  state="$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm >/dev/null \
    || fail "could not arm before creating a valid disabled marker"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" disarm >/dev/null \
    || fail "could not disarm before testing a valid disabled marker"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a valid disabled marker"
  assert_contains "$out" 'run arm --force to clear it' \
    "the valid-marker refusal did not name arm --force"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm --force >/dev/null \
    || fail "arm --force did not clear a valid disabled marker"
  [ ! -e "$state/graph-board.disabled" ] || fail "arm --force left the valid marker"
  [ -f "$state/graph-board.check.sh" ] || fail "arm --force did not recreate the check"
  [ -f "$state/graph-board.check-trust" ] || fail "arm --force did not recreate trust"
  pass "a valid disabled marker refuses plain arm and force clears it"
}

test_graph_board_marker_invalid_refuses_and_force_preserves() {
  local home state rc=0 out
  home=$(make_home marker-invalid)
  state="$home/state"
  ln -s /dev/null "$state/graph-board.disabled"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a symlink disabled marker"
  assert_contains "$out" 'inspect and remove or repair it by hand, then arm' \
    "the invalid-marker refusal did not name its repair"
  [ -L "$state/graph-board.disabled" ] || fail "plain arm deleted an invalid marker"
  rc=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm --force >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "arm --force accepted an invalid symlink marker"
  [ -L "$state/graph-board.disabled" ] || fail "arm --force deleted an invalid symlink marker"

  home=$(make_home marker-invalid-mode)
  state="$home/state"
  printf 'disabled\n' > "$state/graph-board.disabled"
  chmod 0644 "$state/graph-board.disabled"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a mode-0644 disabled marker"
  assert_contains "$out" 'not a private regular file' \
    "a mode-0644 marker was not classified as invalid"
  [ -f "$state/graph-board.disabled" ] || fail "plain arm deleted a mode-0644 marker"

  home=$(make_home marker-invalid-directory)
  state="$home/state"
  mkdir "$state/graph-board.disabled"
  rc=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm --force >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "arm --force accepted a directory marker"
  [ -d "$state/graph-board.disabled" ] || fail "arm --force deleted a directory marker"
  pass "invalid symlink, wrong-mode, and directory markers refuse arm and stay intact"
}

test_graph_board_disarm_records_intent_when_retire_fails() {
  local home state rc=0 out
  home=$(make_home disarm-retire-failure)
  state="$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" arm >/dev/null \
    || fail "could not arm before forcing a retire failure"
  rm -f "$state/graph-board.check-trust"
  mkdir "$state/graph-board.check-trust"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$BOARD" disarm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "disarm succeeded despite a forced retire failure"
  [ -f "$state/graph-board.disabled" ] || fail "disarm lost its disable intent"
  [ -f "$state/graph-board.check.sh" ] || fail "failed retire removed the check"
  [ -d "$state/graph-board.check-trust" ] || fail "failed retire removed the trust collision"
  assert_contains "$out" 'the registered check was NOT retired' \
    "failed disarm did not report the unretired check"
  assert_contains "$out" 'fm-check-register.sh retire graph-board' \
    "failed disarm did not name the repair command"
  pass "disarm records disable intent and reports an unretired check honestly"
}

test_graph_board_refreshes_with_sequential_delayed_probe() {
  local dir state fakebin out foreign entries original pid i start end generated rendered
  local graph_start graph_end probe_start probe_end rc=0
  dir=$(make_case graph-board-sequential-refresh)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  foreign="$dir/foreign"
  mkdir -p "$foreign/tmp"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/dispatched-row.status"
  printf 'kind=ship\nspawn_gen=gen-dispatched\n' > "$state/dispatched-row.meta"
  prime_status_seen "$state" "$state/dispatched-row.status" \
    || fail "could not prime the delayed probe status marker"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$PIPELINE" reconcile dispatched-row >/dev/null \
    || fail "could not create the dispatched record before the check cycle"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$PIPELINE" arm >/dev/null \
    || fail "could not register the probe check"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$BOARD" arm >/dev/null \
    || fail "could not register the graph-board check"
  entries="$state/check-entries"
  original="$dir/graph-board-original.check.sh"
  cp "$state/graph-board.check.sh" "$original"
  chmod 0700 "$original"
  cat > "$state/graph-board.check.sh" <<EOF
#!/usr/bin/env bash
set -u
printf 'graph-board-start pid=%s\\n' "\$\$" >> $(printf '%q' "$entries")
rc=0
FM_HOME=$(printf '%q' "$dir") FM_STATE_OVERRIDE=$(printf '%q' "$state") $(printf '%q' "$original") || rc=\$?
printf 'graph-board-end pid=%s rc=%s\\n' "\$\$" "\$rc" >> $(printf '%q' "$entries")
exit "\$rc"
EOF
  chmod 0700 "$state/graph-board.check.sh"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" graph-board >/dev/null \
    || fail "could not bind the graph-board identity fixture"

  cat > "$state/pipeline-probe.check.sh" <<EOF
#!/usr/bin/env bash
set -u
printf 'pipeline-probe-start pid=%s\\n' "\$\$" >> $(printf '%q' "$entries")
sleep 20
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TMPDIR
FM_HOME=$(printf '%q' "$dir") FM_STATE_OVERRIDE=$(printf '%q' "$state") $(printf '%q' "$PIPELINE") probe
printf 'pipeline-probe-end pid=%s\\n' "\$\$" >> $(printf '%q' "$entries")
EOF
  chmod 0700 "$state/pipeline-probe.check.sh"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" pipeline-probe >/dev/null \
    || fail "could not bind the delayed probe fixture"
  fm_custom_check_registered "$state" pipeline-probe \
    || fail "the delayed probe fixture was not registered"
  fm_custom_check_registered "$state" graph-board \
    || fail "the graph-board fixture was not registered"

  start=$(date +%s)
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_CHECK_INTERVAL=25 FM_CHECK_TIMEOUT=30 \
    FM_PIPELINE_DEADLINE=0 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    FM_PIPELINE_LOG="$state/pipeline-events.log" "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 450 ] && {
    [ ! -s "$state/pipeline-events.log" ] || [ ! -s "$dir/.lavish/graph-board.html" ] \
      || ! rg -F 'graph-board-end pid=' "$entries" >/dev/null 2>&1 \
      || ! rg -F 'pipeline-probe-end pid=' "$entries" >/dev/null 2>&1
  }; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$state/pipeline-events.log" ] || [ ! -s "$dir/.lavish/graph-board.html" ] \
    || ! rg -F 'graph-board-end pid=' "$entries" >/dev/null 2>&1 \
    || ! rg -F 'pipeline-probe-end pid=' "$entries" >/dev/null 2>&1; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the 20-second probe fixture did not let both registered checks complete"
  fi
  end=$(date +%s)
  rg -F 'pipeline-probe-start pid=' "$entries" >/dev/null \
    || fail "the delayed probe did not enter as its own registered check"
  rg -F 'pipeline-probe-end pid=' "$entries" >/dev/null \
    || fail "the delayed probe did not complete as its own registered check"
  graph_start=$(awk '$1 == "graph-board-start" { pid=$2 } END { sub(/^pid=/, "", pid); print pid }' "$entries")
  graph_end=$(awk '$1 == "graph-board-end" { pid=$2 } END { sub(/^pid=/, "", pid); print pid }' "$entries")
  probe_start=$(awk '$1 == "pipeline-probe-start" { pid=$2 } END { sub(/^pid=/, "", pid); print pid }' "$entries")
  probe_end=$(awk '$1 == "pipeline-probe-end" { pid=$2 } END { sub(/^pid=/, "", pid); print pid }' "$entries")
  [ -n "$graph_start" ] && [ "$graph_start" = "$graph_end" ] \
    || fail "the graph-board check did not retain one process identity: $graph_start/$graph_end"
  [ -n "$probe_start" ] && [ "$probe_start" = "$probe_end" ] \
    || fail "the delayed probe did not retain one process identity: $probe_start/$probe_end"
  [ "$graph_start" != "$probe_start" ] \
    || fail "the sequential checks were recorded with one process identity: $graph_start"
  rg -F 'wait=ext:vendor-release' "$state/pipeline-events.log" >/dev/null \
    || fail "the delayed probe did not produce its real pipeline observation"
  generated=$(board_generated_epoch "$dir/.lavish/graph-board.html") \
    || fail "could not read the generated epoch from the published board"
  [ "$generated" -ge "$start" ] && [ "$generated" -le "$end" ] \
    || fail "generated_epoch=$generated fell outside the observed check window $start..$end"
  rendered=$(node "$HARNESS" "$dir/.lavish/graph-board.html") \
    || fail "the sequentially rebuilt board did not render"
  assert_dispatched_render "$rendered" \
    "the sequentially rebuilt board did not highlight the dispatched box"
  out=$(cat "$out" "$state/.wake-queue" 2>/dev/null || true)
  assert_not_contains "$out" 'graph-board.check.sh' \
    "a successful graph-board check ended the cycle with a wake"
  assert_not_contains "$out" 'check: ' \
    "the two successful checks emitted an unexpected check wake"
  [ -z "$(find "$state" -maxdepth 1 -name '.fm-graph-board-refresh.*' -print -quit)" ] \
    || fail "the sequential graph-board check left a scratch file"
  printf 'done: finished\n' >> "$state/dispatched-row.status"
  wait_for_exit "$pid" 40 || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher did not exit after the post-cycle status signal"
  }
  pass "sequential registered checks both complete through a 20-second probe without a board-success wake"
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
test_graph_board_arm_absent_is_private_registered_and_idempotent
test_graph_board_check_is_quiet_and_confined
test_graph_board_check_uses_the_configured_pipeline_log
test_graph_board_check_failure_preserves_last_good_and_cleans_scratch
test_graph_board_marker_valid_refuses_and_force_clears
test_graph_board_marker_invalid_refuses_and_force_preserves
test_graph_board_disarm_records_intent_when_retire_fails
test_graph_board_refreshes_with_sequential_delayed_probe
