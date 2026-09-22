#!/usr/bin/env bash
# Behavior tests for the verified OpenHands SDK crewmate/scout adapter.
#
# The facts pinned here are the ones a driver or SDK change could silently
# break and the ones a wrong guess would make dangerous:
#   1. The openhands worker is the firstmate-owned driver
#      bin/fm-openhands-worker.py under an OpenHS venv interpreter, so
#      neither a process name nor an argv[0] can name it: detection rides the
#      FM_OPENHANDS_HARNESS marker plus args-level driver-filename evidence,
#      and the marker alone is never evidence (the omp precedence contract).
#   2. The args anchor is the full driver filename, so an unrelated python
#      process merely carrying the openhands fragment never reads as this
#      harness. Driver ancestry is args-strength only (the live process name
#      is the interpreter's), so a retained foreign marker outranks it by the
#      marker-names-its-harness rule - which is exactly why the spawn clears
#      every foreign marker at the launch boundary, and why the marker-plus-
#      ancestry pair is what identifies a launched worker.
#   3. Control mechanics are the driver's own contract: C-c once cancels the
#      in-flight run, no clear key, the cancellation ack is the run-log
#      close, /exit stops the worker, and a secondmate launch is refused
#      because the headless driver has no primary supervision surface.
#   4. Busy state is the run-log fold: an unmatched run_started is busy, a
#      trailing run_terminal (completed OR cancelled) is idle, and a
#      missing, empty, or malformed log is unknown, never idle.
#   5. The delivery row is the literal `[fm-openhands] working` and is
#      harness-scoped: idle and cancelled rows never acknowledge, and no
#      other harness borrows it.
#   6. The spawn refuses loudly before pane creation when the venv
#      interpreter, the SDK import, or the credential profile is missing,
#      truncates a predecessor's run log at launch, and never passes an
#      effort flag (record-and-omit).
#   7. The driver itself honors its own contract end to end through
#      --selftest: run pairs, turn-end touch, stdin steering, /exit, and the
#      SIGINT cancel path, all with real processes and no SDK.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_OPENHANDS_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
DRIVER="$ROOT/bin/fm-openhands-worker.py"
TMP_ROOT=$(fm_test_tmproot fm-openhands-harness)

# The spawn drives the real preflight under this base PATH. node is carried
# when the invoking environment has it, the kimi/agy fixture shape, but no
# openhands surface needs it.
NODE_BIN=$(command -v node 2>/dev/null || true)
BASE_PATH=${FM_TEST_BASE_PATH:-${NODE_BIN:+$(dirname "$NODE_BIN"):}/usr/bin:/bin:/usr/sbin:/sbin}
REAL_PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)

fake_ps() {  # <dir> <comm> <args>
  local fakebin=$1
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\n' '${FAKE_PS_COMM:?}'; exit 0 ;;
  *"args="*) printf '%s\n' '${FAKE_PS_ARGS:?}'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_openhands_ancestry_detects_the_driver_process() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-driver")
  FAKE_PS_COMM=python3.12 \
    FAKE_PS_ARGS='/home/someone/.config/openhands/venv/bin/python /repo/bin/fm-openhands-worker.py --run-log /st/x.openhands-run brief' \
    fake_ps "$fakebin"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "a driver-named python ancestry must be detected, got '$out'"
  out=$(FM_OPENHANDS_HARNESS=openhands PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "the launch marker plus driver ancestry must be detected, got '$out'"
  verdict=$(PATH="$fakebin:$PATH" "$HARNESS" ancestry)
  [ "$verdict" = "args openhands" ] \
    || fail "the driver ancestry verdict must be args-strength, got '$verdict'"
  pass "fm-harness.sh: ancestry detects the driver process at args strength"
}

test_openhands_marker_alone_is_not_evidence() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-nomatch")
  FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c echo hi' fake_ps "$fakebin"
  out=$(FM_OPENHANDS_HARNESS=openhands PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != openhands ] \
    || fail "the marker with no driver ancestry must not claim openhands, got '$out'"
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != openhands ] \
    || fail "an inherited AGENT=1 must never claim the openhands identity, got '$out'"
  pass "fm-harness.sh: the FM_OPENHANDS_HARNESS marker is precedence only"
}

test_openhands_rejects_unrelated_python_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-unrelated")
  FAKE_PS_COMM=python3.12 FAKE_PS_ARGS='python3 -m openhands.server serve' fake_ps "$fakebin"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != openhands ] \
    || fail "an openhands-fragment command without the driver filename must not read as this harness, got '$out'"
  FAKE_PS_COMM=python3.12 FAKE_PS_ARGS='python3 /opt/tools/openhands-report.py --serve' fake_ps "$fakebin"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != openhands ] \
    || fail "an unrelated python script carrying the fragment must not read as this harness, got '$out'"
  pass "fm-harness.sh: the args anchor is the full driver filename, never the fragment"
}

test_openhands_claims_no_inherited_launcher_marker() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  FAKE_PS_COMM=python3.12 \
    FAKE_PS_ARGS='/venv/bin/python /repo/bin/fm-openhands-worker.py --run-log /st/x.openhands-run' \
    fake_ps "$fakebin"
  out=$(CLAUDECODE=1 FM_OPENHANDS_HARNESS=openhands PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "the launch marker with driver ancestry must outrank an inherited CLAUDECODE, got '$out'"
  # Driver ancestry is args-strength only, so a RETAINED foreign marker wins
  # by the marker-names-its-harness rule. That is the design, not a bug: it is
  # exactly why the spawn clears every foreign marker at the launch boundary,
  # and why the cleared launch boundary is the contract a real worker runs on.
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = claude ] \
    || fail "a retained CLAUDECODE must keep outranking args-only ancestry, got '$out'"
  out=$(env -u CLAUDECODE PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "with the launch boundary's cleared markers the driver ancestry must identify openhands, got '$out'"
  out=$(AGENT=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = openhands ] \
    || fail "an inherited AGENT=1 must not stop the driver ancestry identifying openhands, got '$out'"
  pass "fm-harness.sh: the launch boundary's cleared markers are what make driver ancestry decide"
}

test_openhands_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported openhands || fail "openhands must be a supported control harness"
  [ "$(fm_control_harness_family openhands)" = openhands ] || fail "openhands must map to its own family"
  fm_control_harness_supports_kind openhands scout || fail "openhands must run scouts"
  fm_control_harness_supports_kind openhands ship || fail "openhands must run ships"
  fm_control_harness_supports_kind openhands secondmate \
    && fail "openhands must refuse secondmates" || true
  [ "$(fm_control_interrupt_key openhands)" = C-c ] || fail "openhands must interrupt on C-c"
  [ "$(fm_control_interrupt_repeat openhands)" = 1 ] || fail "openhands must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key openhands)" ] || fail "openhands must need no clear key"
  [ "$(fm_control_interrupt_ack_source openhands)" = openhands-run-log ] \
    || fail "openhands must ack its interrupt against the run-log close"
  [ "$(fm_control_exit_command openhands)" = /exit ] || fail "openhands must exit on /exit"
  local wiring
  wiring=$(fm_control_harness_wiring_paths openhands /wt /st taskid)
  [ "$wiring" = "/st/taskid.openhands-run" ] \
    || fail "openhands wiring must retire exactly the run log, got '$wiring'"
  pass "fm-control-lib: openhands mechanics are C-c once, run-log ack, and /exit"
}

test_openhands_busy_fold_trusts_both_halves() {
  local log
  log="$TMP_ROOT/fold-openhands-run"
  printf '%s\n' '{"ts":"2026-09-19T00:00:00+00:00","event":"run_started","run":1}' > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = busy ] || fail "an unmatched run_started must fold busy"
  printf '%s\n' \
    '{"ts":"2026-09-19T00:00:00+00:00","event":"run_started","run":1}' \
    '{"ts":"2026-09-19T00:00:01+00:00","event":"run_terminal","run":1,"terminal":"completed"}' > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = settled ] || fail "a completed pair must fold settled"
  printf '%s\n' \
    '{"ts":"2026-09-19T00:00:00+00:00","event":"run_started","run":1}' \
    '{"ts":"2026-09-19T00:00:01+00:00","event":"run_terminal","run":1,"terminal":"cancelled"}' > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = settled ] \
    || fail "a cancelled close must fold settled, the interrupt's own ack"
  printf '%s\n' \
    '{"ts":"2026-09-19T00:00:00+00:00","event":"run_started","run":1}' \
    '{"ts":"2026-09-19T00:00:01+00:00","event":"run_terminal","run":1,"terminal":"completed"}' \
    '{"ts":"2026-09-19T00:00:02+00:00","event":"run_started","run":2}' > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = busy ] || fail "a second open run must fold busy"
  : > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = none ] || fail "an empty log must fold none"
  printf '%s\n' 'not json at all' > "$log"
  [ "$(fm_busy_openhands_run_state "$log")" = unknown ] || fail "a malformed log must fold unknown, never idle"
  fm_busy_openhands_run_state "$TMP_ROOT/does-not-exist-openhands-run" \
    && fail "a missing log must fail the fold rather than claim a verdict" || true
  pass "fm-busy-lib: the run-log fold trusts open and close, and nothing else"
}

test_openhands_classify_reads_only_the_run_log() {
  local statedir id verdict
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  id=openhands-classify
  printf '%s\n' '{"event":"run_started","run":1}' > "$statedir/$id.openhands-run"
  verdict=$(fm_busy_classify tmux fake:win openhands "$id" "$statedir")
  [ "$verdict" = "busy openhands-run-log" ] \
    || fail "an open run must classify busy openhands-run-log, got '$verdict'"
  printf '%s\n' \
    '{"event":"run_started","run":1}' \
    '{"event":"run_terminal","run":1,"terminal":"completed"}' > "$statedir/$id.openhands-run"
  verdict=$(fm_busy_classify tmux fake:win openhands "$id" "$statedir")
  [ "$verdict" = "idle openhands-run-log" ] \
    || fail "a closed run must classify idle openhands-run-log, got '$verdict'"
  rm -f "$statedir/$id.openhands-run"
  verdict=$(fm_busy_classify tmux fake:win openhands "$id" "$statedir")
  [ "$verdict" = "unknown openhands-run-log" ] \
    || fail "no sidecar must classify unknown openhands-run-log, got '$verdict'"
  pass "fm-busy-lib: openhands classifies through its run log and nothing else"
}

test_openhands_busy_signatures_are_harness_scoped() {
  printf '[fm-openhands] working\n' | fm_busy_lines_match openhands \
    || fail "harness=openhands must match its own working row"
  printf '[fm-openhands] idle\n' | fm_busy_lines_match openhands \
    && fail "the idle row must never acknowledge a submit" || true
  printf '[fm-openhands] cancelled\n' | fm_busy_lines_match openhands \
    && fail "the cancelled row must never acknowledge a submit" || true
  printf 'the fm-openhands worker is working\n' | fm_busy_lines_match openhands \
    && fail "echoed output without the bracketed row must not acknowledge" || true
  printf '[fm-openhands] working\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow the openhands row" || true
  printf '[fm-openhands] working\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  printf '[fm-openhands] working\n' | fm_busy_lines_match '' \
    || fail "the harness-less union must acknowledge the openhands row"
  pass "fm-composer-lib: the openhands delivery row is scoped and never borrowed"
}

test_openhands_driver_honors_its_own_contract() {
  [ -n "$REAL_PYTHON" ] || fail "test needs a real python3 interpreter"
  local work="$TMP_ROOT/driver-contract" log turnend out rc
  mkdir -p "$work"
  log="$work/x.openhands-run"
  turnend="$work/x.turn-ended"
  rm -f "$turnend"
  out=$(printf '/exit\n' | "$REAL_PYTHON" "$DRIVER" --selftest --run-log "$log" --turn-end "$turnend" 'do the task' 2>&1)
  rc=$?
  expect_code 0 "$rc" "the selftest driver must exit 0 on /exit"
  assert_contains "$out" "[fm-openhands] working" "the driver never printed its working row"
  assert_contains "$out" "[fm-openhands] idle" "the driver never printed its idle row"
  [ "$(grep -c '"event": "run_started"' "$log")" -eq 1 ] \
    || fail "the brief run must append exactly one started record"
  [ "$(grep -c '"event": "run_terminal"' "$log")" -eq 1 ] \
    || fail "the brief run must append exactly one terminal record"
  [ -e "$turnend" ] || fail "the finished run never touched the turn-end marker"
  rm -f "$turnend"
  out=$(printf 'steer one\n/quit\n' | "$REAL_PYTHON" "$DRIVER" --selftest --run-log "$log" --turn-end "$turnend" 2>&1)
  rc=$?
  expect_code 0 "$rc" "the selftest driver must exit 0 on /quit with no brief"
  [ "$(grep -c '"event": "run_started"' "$log")" -eq 2 ] \
    || fail "a stdin steer must append its own started record"
  [ "$(grep -c '"event": "run_terminal"' "$log")" -eq 2 ] \
    || fail "a stdin steer must append its own terminal record"
  [ -e "$turnend" ] || fail "the steered run never touched the turn-end marker"
  [ "$(fm_busy_openhands_run_state "$log")" = settled ] \
    || fail "the steered log must fold settled after both runs close"
  pass "fm-openhands-worker.py: run pairs, turn-end, steering, and /exit all hold"
}

test_openhands_driver_cancels_its_run_on_sigint() {
  [ -n "$REAL_PYTHON" ] || fail "test needs a real python3 interpreter"
  local work="$TMP_ROOT/driver-interrupt" log turnend pid
  mkdir -p "$work"
  log="$work/x.openhands-run"
  turnend="$work/x.turn-ended"
  rm -f "$turnend"
  # Job control for the launch only: without it a background child inherits
  # SIGINT ignored and Python then leaves it ignored, so the interrupt under
  # test would never arrive. With it the child carries the default
  # disposition the real pane has.
  set -m
  "$REAL_PYTHON" "$DRIVER" --selftest --selftest-hold 30 --run-log "$log" --turn-end "$turnend" 'long task' \
    > "$work/out.log" 2>&1 &
  pid=$!
  set +m
  # Wait for the started record so the interrupt lands mid-run, not pre-start.
  local waited=
  for _ in $(seq 1 100); do
    grep -q '"event": "run_started"' "$log" 2>/dev/null && { waited=1; break; }
    sleep 0.05
  done
  [ -n "$waited" ] || { kill -9 "$pid" 2>/dev/null || true; fail "the held run never wrote its started record"; }
  kill -INT "$pid"
  wait "$pid"
  rc=$?
  [ "$rc" -eq 130 ] || fail "an interrupted driver must exit 130, got $rc"
  assert_grep '"terminal": "cancelled"' "$log" "the interrupted run never closed its pair as cancelled"
  [ -e "$turnend" ] || fail "the cancelled run never touched the turn-end marker"
  [ "$(fm_busy_openhands_run_state "$log")" = settled ] \
    || fail "a cancelled close must fold settled so the interrupt cannot wedge busy"
  pass "fm-openhands-worker.py: SIGINT closes the run pair as cancelled and exits 130"
}

# --- spawn fixtures ---------------------------------------------------------

make_openhands_fakebin() {
  local fakebin=$1
  fakebin=$(fm_fakebin "$fakebin")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
  capture-pane) printf '[fm-openhands] working\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # The fake venv interpreter: passes the SDK import probe, and any other
  # invocation would be the pane launch, which must never execute here.
  cat > "$fakebin/openhands-venv-python" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-c import openhands.sdk, openhands.tools"*)
    [ -z "${FM_FAKE_OPENHANDS_IMPORT_FAIL:-}" ] && exit 0
    echo "ModuleNotFoundError: No module named 'openhands'" >&2
    exit 1
    ;;
esac
echo "fake openhands python must never execute a launch" >&2
exit 9
SH
  chmod +x "$fakebin/openhands-venv-python"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_openhands_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_openhands_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise OpenHands dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'openhands\n' > "$home/config/crew-harness"
  umask 077
  cat > "$home/config/openhands-llm.env" <<'EOF'
LLM_MODEL=fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash
LLM_API_KEY=fm-fake-key
EOF
  umask 022
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_openhands_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_openhands_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_OPENHANDS_PY="$fakebin/openhands-venv-python" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness openhands --mode no-mistakes --yolo off "$@" 2>&1
}

test_openhands_launch_carries_the_driver_model_and_wiring() {
  local id rec out rc launch meta
  id="openhands-launch-z1-$$"
  rec=$(make_openhands_spawn_case launch "$id")
  read_openhands_spawn_record "$rec"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash)
  rc=$?
  expect_code 0 "$rc" "openhands spawn with a valid model should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/openhands-venv-python" "openhands launch did not pin the resolved venv interpreter"
  assert_contains "$launch" "fm-openhands-worker.py" "openhands launch did not run the firstmate-owned driver"
  assert_contains "$launch" "FM_OPENHANDS_HARNESS=openhands" "openhands launch did not set its detection marker"
  assert_contains "$launch" "--llm-env" "openhands launch did not carry its credential profile flag"
  assert_contains "$launch" "$HOME_DIR/config/openhands-llm.env" "openhands launch did not pin the active home's profile path"
  assert_contains "$launch" "--run-log" "openhands launch did not carry its run-log flag"
  assert_contains "$launch" "$HOME_DIR/state/$id.openhands-run" "openhands launch did not pin the per-task run log"
  assert_contains "$launch" "--turn-end" "openhands launch did not carry its turn-end flag"
  assert_contains "$launch" "--model 'fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash'" \
    "openhands launch did not carry the requested model"
  assert_contains "$launch" "env -u CLAUDECODE" "openhands launch did not clear the inherited launcher marker"
  assert_contains "$launch" "env -u CURSOR_AGENT" "openhands launch did not clear the cursor markers"
  assert_not_contains "$launch" "__OPENHANDSPY__" "openhands launch left its interpreter placeholder unsubstituted"
  assert_not_contains "$launch" "__OPENHANDSDRIVER__" "openhands launch left its driver placeholder unsubstituted"
  assert_not_contains "$launch" "__OPENHANDSENV__" "openhands launch left its env placeholder unsubstituted"
  assert_not_contains "$launch" "__OPENHANDSLOG__" "openhands launch left its log placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "openhands launch left its brief placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=openhands' "$meta" "openhands meta did not record its harness"
  assert_grep 'model=fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash' "$meta" "openhands meta did not record its model"
  [ -e "$HOME_DIR/state/$id.openhands-run" ] \
    || fail "openhands spawn did not truncate the run log into existence"
  [ -s "$HOME_DIR/state/$id.openhands-run" ] \
    && fail "the truncated run log must start empty" || true
  pass "fm-spawn: openhands launch carries driver, model, wiring, and cleared markers"
}

test_openhands_default_model_comes_from_the_profile() {
  local id rec out rc launch
  id="openhands-defaultmodel-z2-$$"
  rec=$(make_openhands_spawn_case defaultmodel "$id")
  read_openhands_spawn_record "$rec"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "openhands spawn without a model should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--model" "the launch must omit the model flag so the driver reads the profile default"
  assert_grep 'model=default' "$HOME_DIR/state/$id.meta" "meta must record the default model axis"
  pass "fm-spawn: an omitted model stays out of the launch and rides the profile"
}

test_openhands_effort_is_recorded_but_omitted() {
  local id rec out rc launch
  id="openhands-effort-z3-$$"
  rec=$(make_openhands_spawn_case effort "$id")
  read_openhands_spawn_record "$rec"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash --effort low)
  rc=$?
  expect_code 0 "$rc" "openhands spawn with an unsupported effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" "openhands launch passed a known-bad effort value"
  assert_grep 'effort=low' "$HOME_DIR/state/$id.meta" "openhands meta did not retain the unsupported effort axis"
  pass "fm-spawn: openhands omits effort from the launch but records it in task metadata"
}

test_openhands_bad_model_string_refuses_before_pane_creation() {
  local id rec out rc
  id="openhands-badmodel-z4-$$"
  rec=$(make_openhands_spawn_case badmodel "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model 'bad model!') || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid openhands model string should refuse the spawn"
  assert_contains "$out" "not a valid litellm provider/model string" \
    "invalid model refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an invalid model created a launch command" || true
  pass "fm-spawn: an invalid model string refuses before pane creation"
}

test_openhands_missing_venv_refuses_before_pane_creation() {
  local id rec out rc
  id="openhands-novenv-z5-$$"
  rec=$(make_openhands_spawn_case novenv "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness openhands --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing openhands venv should refuse the spawn"
  assert_contains "$out" "no executable OpenHands venv python found" \
    "missing venv refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing venv created a launch command" || true
  pass "fm-spawn: a missing venv refuses before pane creation"
}

test_openhands_sdk_import_failure_refuses_before_pane_creation() {
  local id rec out rc
  id="openhands-noimport-z6-$$"
  rec=$(make_openhands_spawn_case noimport "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_OPENHANDS_IMPORT_FAIL=1 \
    run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an SDK import failure should refuse the spawn"
  assert_contains "$out" "cannot import the OpenHands SDK" \
    "import-failure refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an import failure created a launch command" || true
  pass "fm-spawn: an SDK import failure refuses before pane creation"
}

test_openhands_missing_llm_env_refuses_before_pane_creation() {
  local id rec out rc
  id="openhands-noprofile-z7-$$"
  rec=$(make_openhands_spawn_case noprofile "$id")
  read_openhands_spawn_record "$rec"
  rm -f "$HOME_DIR/config/openhands-llm.env"
  rc=0
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing credential profile should refuse the spawn"
  assert_contains "$out" "config/openhands-llm.env must exist" \
    "missing-profile refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing profile created a launch command" || true
  pass "fm-spawn: a missing credential profile refuses before pane creation"
}

test_openhands_incomplete_llm_env_refuses_before_pane_creation() {
  local id rec out rc
  id="openhands-emptykey-z8-$$"
  rec=$(make_openhands_spawn_case emptykey "$id")
  read_openhands_spawn_record "$rec"
  umask 077
  printf 'LLM_MODEL=fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash\nLLM_API_KEY=\n' \
    > "$HOME_DIR/config/openhands-llm.env"
  umask 022
  rc=0
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an empty API key should refuse the spawn"
  assert_contains "$out" "non-empty LLM_MODEL and LLM_API_KEY" \
    "empty-key refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an empty key created a launch command" || true
  pass "fm-spawn: an incomplete credential profile refuses before pane creation"
}

test_openhands_secondmate_is_refused() {
  local id rec out rc
  id="openhands-secondmate-z9-$$"
  rec=$(make_openhands_spawn_case secondmate-refuse "$id")
  read_openhands_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_OPENHANDS_PY="$FAKEBIN_DIR/openhands-venv-python" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate openhands 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an openhands secondmate spawn should be refused"
  assert_contains "$out" "openhands is a verified crewmate/scout adapter only" \
    "openhands secondmate refusal lacked its concrete reason"
  pass "fm-spawn: openhands cannot be launched as a secondmate"
}

test_openhands_spawn_truncates_a_predecessors_run_log() {
  local id rec out rc statedir
  id="openhands-truncate-z10-$$"
  rec=$(make_openhands_spawn_case truncate "$id")
  read_openhands_spawn_record "$rec"
  statedir="$HOME_DIR/state"
  printf '%s\n' '{"event":"run_started","run":1}' > "$statedir/$id.openhands-run"
  out=$(run_openhands_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "openhands relaunch over a stale open run should succeed"
  [ -s "$statedir/$id.openhands-run" ] \
    && fail "the spawn must truncate a predecessor's open run, not append to it" || true
  pass "fm-spawn: a relaunch never folds a predecessor's open run"
}

test_openhands_ancestry_detects_the_driver_process
test_openhands_marker_alone_is_not_evidence
test_openhands_rejects_unrelated_python_mentions
test_openhands_claims_no_inherited_launcher_marker
test_openhands_control_mechanics_are_the_verified_ones
test_openhands_busy_fold_trusts_both_halves
test_openhands_classify_reads_only_the_run_log
test_openhands_busy_signatures_are_harness_scoped
test_openhands_driver_honors_its_own_contract
test_openhands_driver_cancels_its_run_on_sigint
test_openhands_launch_carries_the_driver_model_and_wiring
test_openhands_default_model_comes_from_the_profile
test_openhands_effort_is_recorded_but_omitted
test_openhands_bad_model_string_refuses_before_pane_creation
test_openhands_missing_venv_refuses_before_pane_creation
test_openhands_sdk_import_failure_refuses_before_pane_creation
test_openhands_missing_llm_env_refuses_before_pane_creation
test_openhands_incomplete_llm_env_refuses_before_pane_creation
test_openhands_secondmate_is_refused
test_openhands_spawn_truncates_a_predecessors_run_log
