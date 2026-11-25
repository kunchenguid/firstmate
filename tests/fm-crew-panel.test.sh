#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-panel.sh: the fleet panel, the worker panel,
# and the automatic Herdr panels with their config/crew-panel switch.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-crew-panel-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-crew-panel-fixture.sh"

PANEL="$ROOT/bin/fm-crew-panel.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-panel)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FX="$TMP_ROOT/fx"
crew_panel_fixture "$FX" || fail "the fixture could not be built"

panel() {  # <args...>: render from the fixture at the fixed time
  TZ=UTC PATH="$FX/fakebin:$PATH" FM_HOME="$FX/home" \
    "$PANEL" --snapshot "$FX/snapshot.json" --now "$CREW_PANEL_NOW" --name tsg --no-color "$@"
}

# card_ids: the task id on each card's first line, in panel order.
card_ids() {
  awk 'prev_blank_or_rule && /^▌/ { sub(/^▌/, ""); print $1 } { prev_blank_or_rule = ($0 == "" || $0 ~ /^─/) }'
}

# max_width: the widest line, counted in characters, not bytes.
max_width() {
  jq -R -s 'split("\n") | map(length) | max'
}

# fleet_card: the fleet card text of one task id.
fleet_card() {
  panel | awk -v id="$1" '$1 == "▌" id { on = 1 } /^$/ { on = 0 } on { print }'
}

test_a_scout_with_a_report_and_no_newer_work_shows_report_ready() {
  local card out
  card=$(fleet_card arc-history-errors)
  assert_contains "$card" "REPORT READY" "the fleet card shows report ready"
  out=$(panel --task arc-history-errors)
  assert_contains "$out" "REPORT READY" "the worker panel shows report ready"
  pass "a scout with a report and no newer work shows report ready"
}

test_a_scout_in_a_second_round_shows_working_not_report_ready() {
  local card out
  card=$(fleet_card arc-round2-scout)
  assert_contains "$card" "WORKING" "the fleet card shows working"
  assert_not_contains "$card" "REPORT READY" "the fleet card is not report ready"
  assert_contains "$card" "2/8" "the fleet card shows the current step of the new plan"
  assert_contains "$card" "Open the page" "the fleet card names the current step"
  out=$(panel --task arc-round2-scout)
  assert_contains "$out" "WORKING" "the worker panel shows working"
  assert_not_contains "$out" "REPORT READY" "the worker panel is not report ready"
  pass "a scout in a second round shows working, not report ready"
}

test_a_second_round_plan_list_marks_only_earlier_steps_done() {
  local out
  out=$(panel --task arc-round2-scout)
  assert_contains "$out" "PLAN" "the plan section shows"
  assert_contains "$out" "2/8" "the plan counts the new plan"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '✓ [0-9]')" "one step is done"
  assert_contains "$out" "✓ 1 Start the app" "step 1 is done"
  assert_contains "$out" "▶ 2 Open the page" "step 2 is current"
  assert_contains "$out" "· 3 Sign in" "step 3 has not started"
  assert_contains "$out" "· 8 Write round 2" "step 8 has not started"
  pass "a second round plan list marks only earlier steps done"
}

test_a_second_round_step_times_come_from_the_new_plan_only() {
  local out
  out=$(panel --task arc-round2-scout)
  # step 1 ran 900s -> 300s ago (10m); step 2 has run 300s (5m).
  assert_contains "$(printf '%s\n' "$out" | grep '✓ 1 Start the app')" "10m" "step 1 time is from the new plan"
  assert_contains "$(printf '%s\n' "$out" | grep '▶ 2 Open the page')" "5m" "step 2 time runs until now"
  assert_equals "" "$(printf '%s\n' "$out" | grep '· 3 Sign in' | grep -E '[0-9]+[ms]$')" "an unstarted step has no time"
  pass "a second round's step times come from the new plan only"
}

test_card_order_puts_a_decision_first() {
  local out first
  out=$(panel) || fail "the fleet panel did not render"
  first=$(printf '%s\n' "$out" | card_ids | head -n 1)
  assert_equals arc-tokens-wave2 "$first" "the card that needs a decision is first"
  pass "card order puts a decision first"
}

test_card_order_follows_the_groups() {
  local got
  got=$(panel | card_ids | tr '\n' ' ')
  assert_equals "arc-tokens-wave2 arc-5083-history arc-memo-dedupe arc-5700-stopped-review arc-history-errors arc-5601-role-access arc-5595-styles arc-round2-scout arc-5673-toolbar-spacing arc-5677-editor-toolbar arc-5680-upload-limit " \
    "$got" "cards go needs you, no reply, ready, verifying and checking, working, starting; the oldest first inside a group"
  pass "card order follows the groups, oldest first inside a group"
}

test_a_ship_whose_review_was_stopped_after_its_done_report_shows_pr_ready() {
  local card out
  card=$(fleet_card arc-5700-stopped-review)
  assert_contains "$card" "PR READY" "the fleet card shows PR ready"
  assert_contains "$card" "waits for your merge" "the fleet card says it waits for the merge"
  assert_not_contains "$card" "CHECKING" "the fleet card is not checking"
  out=$(panel --task arc-5700-stopped-review)
  assert_contains "$out" "PR READY" "the worker panel shows PR ready"
  assert_contains "$out" "waits for your merge" "the worker panel says it waits for the merge"
  assert_not_contains "$out" "CHECKING" "the worker panel is not checking"
  pass "a ship whose review was stopped after its done report shows PR ready"
}

test_the_verifier_folds_into_its_ship_card() {
  local out
  out=$(panel)
  assert_not_contains "$(printf '%s\n' "$out" | card_ids)" "-verify" "no verifier has a card of its own"
  assert_contains "$out" "Verifier: Check each page" "the ship card shows the verifier step"
  assert_contains "$out" "risk: auth" "the ship card shows the risk area"
  pass "the verifier folds into its ship card"
}

test_the_plan_list_shows_every_step_name_before_the_step_starts() {
  local out
  out=$(panel --task arc-5673-toolbar-spacing)
  assert_contains "$out" "▶ 3 Write the spacing fix" "the current step is marked"
  assert_contains "$out" "· 4 Run the tests" "a step that has not started shows its name"
  assert_contains "$out" "· 5 Write the PR text" "the last step shows its name"
  assert_contains "$out" "✓ 1 Read the toolbar code" "a done step has a tick"
  pass "the plan list shows every step name before the step starts"
}

test_the_verifier_steps_show_in_the_ships_worker_panel() {
  local out
  out=$(panel --task arc-5601-role-access)
  assert_contains "$out" "VERIFIER · pstack" "the verifier section shows"
  assert_contains "$out" "▶ 3 Check each page" "the running verifier step is marked"
  assert_contains "$out" "· 4 Write the report" "a verifier step that has not started shows its name"
  assert_contains "$out" "✓ viewer cannot open admin" "a passed scenario shows"
  assert_contains "$out" "▶ admin can delete" "a running scenario shows"
  assert_contains "$out" "https://github.com/acme/arc/pull/5601" "the full PR link shows"
  pass "the verifier steps show in the ship's worker panel"
}

test_the_question_shows_first_in_the_worker_panel() {
  local out first
  out=$(panel --task arc-tokens-wave2)
  first=$(printf '%s\n' "$out" | sed -n 4p)
  assert_contains "$first" "QUESTION FOR YOU" "the question is the first section"
  assert_contains "$out" "old names as aliases for one release?" "the question text shows"
  assert_contains "$out" "Start with the color tokens." "the firstmate message shows"
  pass "the question shows first in the worker panel"
}

test_the_review_steps_show_while_checking() {
  local out
  out=$(panel --task arc-5595-styles)
  assert_contains "$out" "REVIEW                                 4/9" "the review counts its steps"
  assert_contains "$out" "▶ tests" "the running review step is marked"
  assert_contains "$out" "PLAN                              3/3 done" "the plan is all done"
  pass "the review steps show while checking"
}

test_a_review_from_another_branch_does_not_show() {
  local out
  sed -i.bak 's#branch: fm/arc-5595-styles#branch: fm/someone-else#' "$FX/wt/arc-5595-styles/.nm-axi-status"
  out=$(panel --task arc-5595-styles)
  mv "$FX/wt/arc-5595-styles/.nm-axi-status.bak" "$FX/wt/arc-5595-styles/.nm-axi-status"
  assert_not_contains "$out" "REVIEW" "a run on another branch is not this worker's review"
  pass "a review from another branch does not show"
}

test_a_section_with_no_data_is_left_out() {
  local out
  out=$(panel --task arc-5680-upload-limit)
  assert_not_contains "$out" "PLAN" "no plan was recorded"
  assert_not_contains "$out" "QUESTION FOR YOU" "there is no question"
  assert_not_contains "$out" "REVIEW" "there is no review"
  assert_not_contains "$out" "FROM FIRST MATE" "there are no messages"
  assert_contains "$out" "○ STARTING" "the worker panel still shows the state"
  pass "a section with no data is left out"
}

test_no_line_passes_a_fixed_width() {
  local w t widest
  for w in 30 36 44 60; do
    widest=$(panel --width "$w" | max_width)
    [ "$widest" -le "$w" ] || fail "the fleet panel at width $w has a line of $widest characters"
    for t in arc-5673-toolbar-spacing arc-tokens-wave2 arc-5595-styles arc-5601-role-access \
      arc-memo-dedupe arc-history-errors arc-5083-history arc-5680-upload-limit arc-5677-editor-toolbar; do
      widest=$(panel --width "$w" --task "$t" | max_width)
      [ "$widest" -le "$w" ] || fail "the $t panel at width $w has a line of $widest characters"
    done
  done
  pass "no line passes a fixed width"
}

test_color_adds_no_visible_width() {
  local plain colored
  plain=$(panel --width 44 | max_width)
  colored=$(panel --width 44 --color | sed $'s/\033\\[[0-9;]*m//g' | max_width)
  assert_equals "$plain" "$colored" "color codes change no visible width"
  pass "color adds no visible width"
}

# --- automatic panels -----------------------------------------------------------

# A stateful fake herdr: panes live in $HERDR_FAKE_DIR/panes as
# "<pane> <tab> <workspace> <label>" lines. FM_FAKE_SPLIT_FAIL=1 fails a split.
# A pane's foreground process is $HERDR_FAKE_DIR/proc.<pane>, one argv word per
# line, with "-zsh" (the login shell) when the file is absent. `pane run` writes
# the argv that the run command execs. FM_FAKE_PROCINFO_FAIL=1 fails
# `pane process-info`.
make_fake_herdr() {  # <dir>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
db="$HERDR_FAKE_DIR/panes"
printf '%s\n' "$*" >> "$HERDR_FAKE_DIR/calls"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane get")
    awk -v p="$3" '$1 == p { printf "{\"result\":{\"pane\":{\"pane_id\":\"%s\",\"tab_id\":\"%s\",\"workspace_id\":\"%s\"}}}\n", $1, $2, $3; f = 1 } END { exit !f }' "$db"
    ;;
  "pane list")
    awk 'BEGIN { printf "{\"result\":{\"panes\":[" } { printf "%s{\"pane_id\":\"%s\",\"tab_id\":\"%s\",\"workspace_id\":\"%s\",\"label\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2, $3, $4 } END { print "]}}" }' "$db"
    ;;
  "pane split")
    [ "${FM_FAKE_SPLIT_FAIL:-}" = 1 ] && { echo "split refused" >&2; exit 1; }
    n=$(( $(wc -l < "$db") + 1 ))
    awk -v p="$3" -v n="$n" '$1 == p { print "new" n, $2, $3, "-" }' "$db" >> "$db"
    printf '{"result":{"pane":{"pane_id":"new%s"}}}\n' "$n"
    ;;
  "pane rename")
    awk -v p="$3" -v l="$4" '$1 == p { $4 = l } { print }' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
    ;;
  "pane run")
    eval "set -- $4"
    while [ $# -gt 0 ]; do
      case "$1" in exec|env|*=*) shift ;; *) break ;; esac
    done
    { printf 'bash\n'; printf '%s\n' "$@"; } > "$HERDR_FAKE_DIR/proc.$3"
    ;;
  "pane process-info")
    [ "${FM_FAKE_PROCINFO_FAIL:-}" = 1 ] && { echo "process-info refused" >&2; exit 1; }
    pane=$4
    if [ -f "$HERDR_FAKE_DIR/proc.$pane" ]; then argv=$(jq -R . "$HERDR_FAKE_DIR/proc.$pane" | jq -s .)
    else argv='["-zsh"]'; fi
    jq -n --arg pane "$pane" --argjson argv "$argv" \
      '{result: {process_info: {pane_id: $pane, shell_pid: 100,
        foreground_processes: [{pid: 100, name: ($argv[0] | ltrimstr("-") | split("/") | last), argv0: $argv[0], argv: $argv}]}}}'
    ;;
  "pane close")
    awk -v p="$3" '$1 != p' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/herdr"
}

herdr_world() {  # <name>: a home with one firstmate pane and one worker pane
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/config" "$w/herdr"
  make_fake_herdr "$w/bin"
  printf 'p-main t-main w-main -\np-work t-work w-work -\n' > "$w/herdr/panes"
  : > "$w/herdr/calls"
  printf 'backend=herdr\nkind=ship\nherdr_session=lab\nherdr_pane_id=p-work\n' > "$w/home/state/arc-1.meta"
  printf '%s\n' "$w"
}

open_panel() {  # <world> <open-args...>
  local w=$1
  shift
  env -u TMUX HERDR_FAKE_DIR="$w/herdr" PATH="$w/bin:$PATH" FM_HOME="$w/home" \
    HERDR_ENV=1 HERDR_SESSION=lab HERDR_PANE_ID=p-main "$PANEL" "$@"
}

label_pane() {  # <world> <pane> <tab> <workspace>: a labelled pane that Herdr restored
  printf '%s %s %s fm-crew-panel\n' "$2" "$3" "$4" >> "$1/herdr/panes"
}

set_pane_process() {  # <world> <pane> <argv...>: the pane's foreground process
  local w=$1 pane=$2
  shift 2
  printf '%s\n' "$@" > "$w/herdr/proc.$pane"
}

panel_count() {  # <world> <tab>
  awk -v t="$2" '$2 == t && $4 == "fm-crew-panel"' "$1/herdr/panes" | wc -l | tr -d ' '
}

test_the_fleet_panel_opens_beside_firstmate() {
  local w
  w=$(herdr_world fleet-open)
  open_panel "$w" open-fleet || fail "open-fleet failed"
  assert_equals 1 "$(panel_count "$w" t-main)" "one panel opens in the firstmate tab"
  assert_grep "pane split p-main --direction right" "$w/herdr/calls" "the panel splits to the right of firstmate"
  assert_grep "--no-focus" "$w/herdr/calls" "the split leaves the focus on firstmate"
  pass "the fleet panel opens beside firstmate"
}

test_a_second_session_start_opens_no_second_fleet_panel() {
  local w
  w=$(herdr_world fleet-twice)
  open_panel "$w" open-fleet || fail "the first open-fleet failed"
  open_panel "$w" open-fleet || fail "the second open-fleet failed"
  assert_equals 1 "$(panel_count "$w" t-main)" "a second start finds the panel and opens no other"
  pass "a second session start opens no second fleet panel"
}

test_a_restored_panel_pane_with_only_a_shell_gets_the_panel_started() {
  local w
  w=$(herdr_world restored-shell)
  label_pane "$w" p-old t-main w-main
  open_panel "$w" open-fleet || fail "open-fleet failed on a restored panel pane"
  assert_equals 1 "$(panel_count "$w" t-main)" "the firstmate tab keeps one panel pane"
  assert_no_grep "pane split" "$w/herdr/calls" "no second pane is split"
  grep -F "pane run p-old " "$w/herdr/calls" > "$w/run" || fail "the panel starts in the restored pane"
  assert_grep "fm-crew-panel.sh --watch" "$w/run" "the restored pane runs the panel in watch mode"
  assert_no_grep "--task" "$w/herdr/calls" "the fleet panel starts, not a worker panel"
  assert_no_grep "pane close" "$w/herdr/calls" "no pane is closed"
  label_pane "$w" p-work-old t-work w-work
  open_panel "$w" open-task arc-1 || fail "open-task failed on a restored panel pane"
  grep -F "pane run p-work-old " "$w/herdr/calls" > "$w/run" || fail "the worker panel starts in its restored pane"
  assert_grep "--task arc-1" "$w/run" "the restored worker pane runs that worker's panel"
  pass "a restored panel pane with only a shell gets the panel started"
}

test_a_labelled_pane_running_the_panel_gets_no_second_start() {
  local w
  w=$(herdr_world running-panel)
  label_pane "$w" p-old t-main w-main
  set_pane_process "$w" p-old bash "$ROOT/bin/fm-crew-panel.sh" --watch --name crew
  open_panel "$w" open-fleet || fail "open-fleet failed beside a running panel"
  assert_no_grep "pane split" "$w/herdr/calls" "no pane is split"
  assert_no_grep "pane run" "$w/herdr/calls" "the running panel is not started again"
  label_pane "$w" p-work-old t-work w-work
  set_pane_process "$w" p-work-old bash "$ROOT/bin/fm-crew-panel.sh" --watch --task arc-1 --name crew
  open_panel "$w" open-task arc-1 || fail "open-task failed beside a running panel"
  assert_no_grep "pane run" "$w/herdr/calls" "the running worker panel is not started again"
  pass "a labelled pane running the panel gets no second start"
}

test_a_labelled_pane_running_another_program_is_left_alone() {
  local w rc
  w=$(herdr_world other-program)
  label_pane "$w" p-old t-main w-main
  set_pane_process "$w" p-old vim notes.md
  open_panel "$w" open-fleet 2>"$w/err"
  rc=$?
  expect_code 1 "$rc" "open-fleet beside a labelled pane that runs another program"
  assert_grep "runs another program" "$w/err" "the reason is printed"
  assert_no_grep "pane run" "$w/herdr/calls" "nothing starts in that pane"
  assert_no_grep "pane split" "$w/herdr/calls" "no pane is split"
  assert_no_grep "pane close" "$w/herdr/calls" "no pane is closed"
  rm -f "$w/herdr/proc.p-old"
  : > "$w/herdr/calls"
  FM_FAKE_PROCINFO_FAIL=1 open_panel "$w" open-fleet 2>"$w/err"
  rc=$?
  expect_code 1 "$rc" "open-fleet when process-info fails"
  assert_grep "could not read" "$w/err" "the failed read is printed"
  assert_no_grep "pane run" "$w/herdr/calls" "nothing starts when the pane cannot be read"
  pass "a labelled pane running another program is left alone"
}

test_the_worker_panel_opens_in_the_worker_tab() {
  local w
  w=$(herdr_world task-open)
  open_panel "$w" open-task arc-1 || fail "open-task failed"
  assert_equals 1 "$(panel_count "$w" t-work)" "one panel opens in the worker tab"
  assert_equals 0 "$(panel_count "$w" t-main)" "the firstmate tab gets no worker panel"
  assert_grep "--task arc-1" "$w/herdr/calls" "the worker panel shows that worker"
  open_panel "$w" open-task arc-1 || fail "the second open-task failed"
  assert_equals 1 "$(panel_count "$w" t-work)" "a second open finds the panel and opens no other"
  pass "the worker panel opens in the worker tab"
}

test_the_switch_off_opens_no_panel() {
  local w
  w=$(herdr_world switch-off)
  printf 'off\n' > "$w/home/config/crew-panel"
  open_panel "$w" open-fleet || fail "open-fleet must exit 0 when the switch is off"
  open_panel "$w" open-task arc-1 || fail "open-task must exit 0 when the switch is off"
  assert_equals 0 "$(panel_count "$w" t-main)" "no fleet panel opens"
  assert_equals 0 "$(panel_count "$w" t-work)" "no worker panel opens"
  assert_no_grep "pane split" "$w/herdr/calls" "no split is made"
  printf 'maybe\n' > "$w/home/config/crew-panel"
  open_panel "$w" open-fleet 2>"$w/err" || fail "an unknown switch value must exit 0"
  assert_grep "not on or off" "$w/err" "an unknown switch value warns"
  assert_equals 0 "$(panel_count "$w" t-main)" "an unknown switch value counts as off"
  printf ' on \n' > "$w/home/config/crew-panel"
  open_panel "$w" open-fleet || fail "open-fleet failed with the switch on"
  assert_equals 1 "$(panel_count "$w" t-main)" "the switch on opens the panel"
  pass "the switch off opens no panel"
}

test_other_backends_open_no_panel() {
  local w out rc
  w=$(herdr_world tmux)
  out=$(HERDR_FAKE_DIR="$w/herdr" PATH="$w/bin:$PATH" FM_HOME="$w/home" env -u HERDR_ENV "$PANEL" open-fleet 2>&1)
  rc=$?
  expect_code 0 "$rc" "open-fleet outside Herdr"
  assert_equals "" "$out" "open-fleet outside Herdr prints nothing"
  sed -i.bak 's/^backend=herdr/backend=tmux/' "$w/home/state/arc-1.meta"
  open_panel "$w" open-task arc-1 || fail "open-task on tmux must exit 0"
  assert_no_grep "pane split" "$w/herdr/calls" "no split is made on other backends"
  pass "other backends open no panel"
}

test_a_failed_split_reports_and_exits_1() {
  local w rc
  w=$(herdr_world split-fail)
  FM_FAKE_SPLIT_FAIL=1 open_panel "$w" open-task arc-1 2>"$w/err"
  rc=$?
  expect_code 1 "$rc" "a failed split"
  assert_grep "could not split" "$w/err" "a failed split says why"
  assert_equals 0 "$(panel_count "$w" t-work)" "a failed split leaves no panel"
  pass "a failed split reports and exits 1"
}

test_a_worker_panel_stops_when_its_task_moves_to_a_new_pane() {
  local w pid
  w=$(herdr_world moved)
  FM_HOME="$w/home" PATH="$FX/fakebin:$PATH" "$PANEL" --task arc-1 --watch --interval 1 --no-color >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || fail "the worker panel stopped before its task moved"
  sed -i.bak 's/^herdr_pane_id=p-work$/herdr_pane_id=p-new/' "$w/home/state/arc-1.meta"
  for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    fail "the worker panel still runs after its task moved to a new pane"
  fi
  pass "a worker panel stops when its task moves to a new pane"
}

test_a_worker_panel_stops_when_its_task_record_goes() {
  local w pid
  w=$(herdr_world record-gone)
  FM_HOME="$w/home" PATH="$FX/fakebin:$PATH" "$PANEL" --task arc-1 --watch --interval 1 --no-color >/dev/null 2>&1 &
  pid=$!
  sleep 1
  rm -f "$w/home/state/arc-1.meta"
  for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    fail "the worker panel still runs after its task record was removed"
  fi
  pass "a worker panel stops when its task record goes"
}

# The Herdr backend reads pane lists that can now hold a crew panel. These
# drive the backend functions against a canned pane list.
backend_with_panes() {  # <panes-json> <log> <function> <args...>
  local panes=$1 log=$2
  shift 2
  FM_FAKE_PANES=$panes FM_FAKE_LOG=$log bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      shift
      printf "%s\n" "$*" >> "$FM_FAKE_LOG"
      case "$1 $2" in
        "tab list") printf "%s\n" "{\"result\":{\"tabs\":[{\"tab_id\":\"w2:t2\"}]}}" ;;
        "pane list") printf "%s\n" "$FM_FAKE_PANES" ;;
        "pane close") [ "${FM_FAKE_CLOSE_FAIL:-}" != 1 ] ;;
        *) return 1 ;;
      esac
    }
    "$@"
  ' "$ROOT" "$@"
}

test_the_task_close_closes_the_panel_so_the_workspace_still_empties() {
  local log="$TMP_ROOT/plan.log" panes out
  panes='{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"},{"pane_id":"w2:p3","tab_id":"w2:t2","label":"fm-crew-panel"}]}}'
  : > "$log"
  out=$(backend_with_panes "$panes" "$log" fm_backend_herdr_emptying_close_plan lab w2:p2 w2 w2:t2 w1)
  assert_grep "pane close w2:p3" "$log" "the panel in the task tab is closed"
  assert_no_grep "pane close w2:p2" "$log" "the plan itself never closes the task pane"
  assert_grep "workspace list" "$log" "with the panel gone the task pane counts as the only pane"
  assert_equals plain "$out" "the canned workspace list fails, so the plan ends plain"
  : > "$log"
  out=$(FM_FAKE_CLOSE_FAIL=1 backend_with_panes "$panes" "$log" fm_backend_herdr_emptying_close_plan lab w2:p2 w2 w2:t2 w1)
  assert_equals plain "$out" "a panel that does not close plans the plain close"
  assert_no_grep "workspace list" "$log" "a panel that does not close stops the plan"
  pass "the task close closes the panel so the workspace still empties"
}

test_a_panel_pane_is_never_the_task_pane() {
  local log="$TMP_ROOT/pft.log" panes out
  panes='{"result":{"panes":[{"pane_id":"w2:p3","tab_id":"w2:t2","label":"fm-crew-panel"},{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}'
  : > "$log"
  out=$(backend_with_panes "$panes" "$log" fm_backend_herdr_pane_for_tab lab w2 w2:t2)
  assert_equals w2:p2 "$out" "the tab's task pane is the pane that is not the panel"
  pass "a panel pane is never the task pane"
}

# session_start_with_panel <exit-code>: run a real session start from a copied
# bin whose fm-crew-panel.sh only records its arguments and exits <exit-code>.
# The lock is stubbed so the start owns its home. Prints the session-start rc,
# then its stderr.
session_start_with_panel() {
  local code=$1 root="$TMP_ROOT/ss-$1" rc=0 err
  rm -rf "$root"
  mkdir -p "$root/home/state" "$root/home/data" "$root/home/config"
  cp -R "$ROOT/bin" "$root/bin"
  printf '%s\n' manual > "$root/home/config/backlog-backend"
  cat > "$root/bin/fm-crew-panel.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$root/panel.trace"
exit $code
SH
  printf '#!/usr/bin/env bash\nprintf "lock acquired\\n"\n' > "$root/bin/fm-lock.sh"
  chmod +x "$root/bin/fm-crew-panel.sh" "$root/bin/fm-lock.sh"
  err=$(FM_HOME="$root/home" FM_ROOT_OVERRIDE="$root" FM_BOOTSTRAP_NETWORK=skip \
    "$root/bin/fm-session-start.sh" 2>&1 >/dev/null) || rc=$?
  printf '%s\n%s\n' "$rc" "$err"
}

test_session_start_opens_the_fleet_panel() {
  local out
  out=$(session_start_with_panel 0)
  assert_equals 0 "$(printf '%s\n' "$out" | head -1)" "session start succeeds"
  assert_equals open-fleet "$(cat "$TMP_ROOT/ss-0/panel.trace" 2>/dev/null)" "session start asks for the fleet panel once"
  pass "session start opens the fleet panel"
}

test_a_failed_fleet_panel_does_not_stop_session_start() {
  local out
  out=$(session_start_with_panel 1)
  assert_equals 0 "$(printf '%s\n' "$out" | head -1)" "session start still succeeds"
  assert_contains "$out" "the crew panel did not open" "session start warns"
  pass "a failed fleet panel does not stop session start"
}

test_a_scout_with_a_report_and_no_newer_work_shows_report_ready
test_a_scout_in_a_second_round_shows_working_not_report_ready
test_a_second_round_plan_list_marks_only_earlier_steps_done
test_a_second_round_step_times_come_from_the_new_plan_only
test_card_order_puts_a_decision_first
test_card_order_follows_the_groups
test_a_ship_whose_review_was_stopped_after_its_done_report_shows_pr_ready
test_the_verifier_folds_into_its_ship_card
test_the_plan_list_shows_every_step_name_before_the_step_starts
test_the_verifier_steps_show_in_the_ships_worker_panel
test_the_question_shows_first_in_the_worker_panel
test_the_review_steps_show_while_checking
test_a_review_from_another_branch_does_not_show
test_a_section_with_no_data_is_left_out
test_no_line_passes_a_fixed_width
test_color_adds_no_visible_width
test_the_fleet_panel_opens_beside_firstmate
test_a_second_session_start_opens_no_second_fleet_panel
test_a_restored_panel_pane_with_only_a_shell_gets_the_panel_started
test_a_labelled_pane_running_the_panel_gets_no_second_start
test_a_labelled_pane_running_another_program_is_left_alone
test_the_worker_panel_opens_in_the_worker_tab
test_the_switch_off_opens_no_panel
test_other_backends_open_no_panel
test_a_failed_split_reports_and_exits_1
test_a_worker_panel_stops_when_its_task_moves_to_a_new_pane
test_a_worker_panel_stops_when_its_task_record_goes
test_the_task_close_closes_the_panel_so_the_workspace_still_empties
test_a_panel_pane_is_never_the_task_pane
test_session_start_opens_the_fleet_panel
test_a_failed_fleet_panel_does_not_stop_session_start
