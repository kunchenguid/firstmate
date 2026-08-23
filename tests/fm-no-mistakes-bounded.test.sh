#!/usr/bin/env bash
# Behavior coverage for explicit-only bounded NoMistakes runs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-bounded)

make_case() {
  local name=$1 mode=${2:-no-mistakes} d
  d="$TMP_ROOT/$name"
  mkdir -p "$d/home/state" "$d/fakebin"
  fm_git_init_commit "$d/repo"
  printf 'agent: codex\nauto_fix:\n  review: 0\n' > "$d/repo/.no-mistakes.yaml"
  git -C "$d/repo" add .no-mistakes.yaml
  git -C "$d/repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm profile
  git -C "$d/repo" worktree add --quiet -b "fm/$name" "$d/wt"
  fm_write_meta "$d/home/state/task.meta" \
    "window=fake" "worktree=$d/wt" "project=$d/repo" "harness=codex" \
    "kind=ship" "mode=$mode" "yolo=off"
  cat > "$d/clock" <<'SH'
#!/usr/bin/env bash
n=$(head -1 "$CLOCK_VALUE")
if [ "$(wc -l < "$CLOCK_VALUE")" -gt 1 ]; then
  tail -n +2 "$CLOCK_VALUE" > "$CLOCK_VALUE.next"
  mv "$CLOCK_VALUE.next" "$CLOCK_VALUE"
fi
printf '%s\n' "$n"
printf 'clock %s\n' "$n" >> "$EVENT_LOG"
SH
  chmod +x "$d/clock"
  printf '1000\n' > "$d/clock.value"
  cat > "$d/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "$EVENT_LOG"
if [ "${FAKE_TIMEOUT_EXPIRE:-0}" = 1 ]; then exit 124; fi
[ "$1" = --foreground ] && shift
shift
exec "$@"
SH
  chmod +x "$d/fakebin/timeout"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'nm %s\n' "$*" >> "$EVENT_LOG"
case "$*" in
  "axi run"*)
    cat <<'OUT'
run:
  id: "run-1"
  branch: fm/test
  status: running
gate: review
findings[1]{id,severity,file,action,description}:
  r1,warning,a.sh,auto-fix,first review finding
OUT
    ;;
  "axi respond"*)
    cat <<'OUT'
run:
  id: "run-1"
  branch: fm/test
  status: running
gate: review
findings[1]{id,severity,file,action,description}:
  r2,error,b.sh,ask-user,remaining rereview finding
OUT
    ;;
  "axi status --run run-1"*|"axi status")
    if [ -f "$CASE_DIR/aborted" ]; then
      printf 'run:\n  id: "run-1"\n  status: cancelled\noutcome: cancelled\n'
    elif [ "${FAKE_STATUS_CHECKS_PASSED:-0}" = 1 ]; then
      printf 'run:\n  id: "run-1"\n  status: running\noutcome: checks-passed\n'
    else
      printf 'run:\n  id: "run-1"\n  status: running\ngate:\n  step: review\n  status: fix_review\nfindings[1]{id,severity,file,action,description}:\n  r2,error,b.sh,ask-user,remaining rereview finding\n'
    fi
    ;;
  "axi abort --run run-1")
    : > "$CASE_DIR/aborted"
    printf 'outcome: cancelled\n'
    ;;
  "axi sync --recover")
    printf 'branch_sync:\n  state: user_owned\n'
    ;;
  *) printf 'error: unexpected fake invocation\n'; exit 2 ;;
esac
SH
  chmod +x "$d/fakebin/no-mistakes"
  printf '%s\n' "$d"
}

run_driver() {
  local d=$1; shift
  ( cd "$d/wt" && \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" FM_NM_MONOTONIC_BIN="$d/clock" \
    FM_NM_BOOT_ID=test-boot FM_NM_TIMEOUT_BIN="$d/fakebin/timeout" \
    CLOCK_VALUE="$d/clock.value" EVENT_LOG="$d/events" CASE_DIR="$d" \
    "$ROOT/bin/fm-no-mistakes.sh" "$@" )
}

test_manual_only_routing() {
  local d out rc=0
  d="$TMP_ROOT/routing"; mkdir -p "$d/home/data"
  out=$(FM_HOME="$d/home" "$ROOT/bin/fm-project-mode.sh" missing 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "missing project auto-selected something other than direct-PR: $out"
  printf '%s\n' '- legacy [no-mistakes] - old entry' > "$d/home/data/projects.md"
  out=$(FM_HOME="$d/home" "$ROOT/bin/fm-project-mode.sh" legacy 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "legacy no-mistakes registry entry remained automatic: $out"
  FM_HOME="$d/home" "$ROOT/bin/fm-brief.sh" ordinary missing >/dev/null
  assert_grep 'This project ships **direct-PR**' "$d/home/data/ordinary/brief.md" \
    "ordinary brief did not stay direct-PR"
  assert_no_grep 'fm-no-mistakes.sh run' "$d/home/data/ordinary/brief.md" \
    "ordinary brief paid the no-mistakes path"
  FM_HOME="$d/home" "$ROOT/bin/fm-brief.sh" explicit missing --no-mistakes >/dev/null
  assert_grep 'fm-no-mistakes.sh run explicit' "$d/home/data/explicit/brief.md" \
    "explicit brief did not select the bounded driver"
  FM_HOME="$d/home" "$ROOT/bin/fm-brief.sh" bad missing --scout --no-mistakes >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "scout must reject the no-mistakes override"
  pass "manual-only routing requires an explicit per-task override"
}

test_pre_invocation_clock_is_deadline_authority() {
  local d policy events
  d=$(make_case timing)
  printf '1000\n1250\n' > "$d/clock.value"
  run_driver "$d" run task --intent "test intent" >/dev/null
  policy="$d/home/state/task.no-mistakes"
  assert_grep 'started_ms=1000' "$policy" "policy did not persist the pre-invocation monotonic time"
  assert_grep 'deadline_ms=1201000' "$policy" "policy did not derive the 20-minute deadline from pre-invocation time"
  events=$(cat "$d/events")
  case "$events" in clock*timeout*"nm axi run"*) : ;; *) fail "clock was not captured immediately before bounded axi run" ;; esac
  assert_contains "$events" 'timeout --foreground 1199.750s no-mistakes axi run --intent test intent' \
    "first drive did not subtract pre-invocation startup overhead from the hard ceiling"
  pass "pre-invocation fake monotonic clock owns the 20-minute outer deadline"
}

test_timeout_aborts_confirms_recovers_and_preserves_head() {
  local d out rc=0 before after events
  d=$(make_case timeout)
  before=$(git -C "$d/wt" rev-parse HEAD)
  out=$(FAKE_TIMEOUT_EXPIRE=1 run_driver "$d" run task --intent "timeout intent" 2>&1) || rc=$?
  expect_code 75 "$rc" "deadline path must return the bounded-stop code"
  after=$(git -C "$d/wt" rev-parse HEAD)
  [ "$before" = "$after" ] || fail "deadline recovery changed the preserved branch head"
  assert_contains "$out" 'reason: "20-minute wall-clock ceiling reached"' "deadline reason missing"
  assert_contains "$out" "preserved_head: \"$before\"" "full preserved head missing"
  assert_contains "$out" 'outcome: cancelled' "structured terminal confirmation missing"
  events=$(cat "$d/events")
  assert_contains "$events" 'nm axi abort --run run-1' "deadline did not use supported exact-run abort"
  assert_contains "$events" 'nm axi status --run run-1' "deadline did not confirm exact-run status"
  assert_contains "$events" 'nm axi sync --recover' "deadline did not use supported custody recovery"
  assert_not_contains "$events" 'daemon' "deadline path operated the shared daemon"
  pass "deadline cancellation confirms terminal state, recovers custody, and preserves corrections"
}

test_checks_passed_monitor_is_still_cancelled_at_ceiling() {
  local d out rc=0 events
  d=$(make_case checks-passed-monitor)
  out=$(FAKE_TIMEOUT_EXPIRE=1 FAKE_STATUS_CHECKS_PASSED=1 run_driver "$d" run task --intent "monitor intent" 2>&1) || rc=$?
  expect_code 75 "$rc" "checks-passed monitor must still take the supported terminal path"
  events=$(cat "$d/events")
  assert_contains "$events" 'nm axi abort --run run-1' "checks-passed monitor was mistaken for a terminal run"
  assert_contains "$out" 'outcome: cancelled' "monitor cancellation was not confirmed"
  pass "checks-passed monitoring is nonterminal at the wall-clock ceiling"
}

test_one_review_cycle_and_remaining_findings() {
  local d out rc=0 events
  d=$(make_case cycle)
  run_driver "$d" run task --intent "cycle intent" >/dev/null
  out=$(run_driver "$d" respond task --action fix --findings r1 --step review 2>&1) || rc=$?
  expect_code 75 "$rc" "rereview findings must stop after one fix cycle"
  assert_contains "$out" 'remaining rereview finding' "cycle stop did not report remaining findings"
  assert_contains "$out" 'review cycle limit reached after one fix and rereview' "cycle stop reason missing"
  events=$(cat "$d/events")
  [ "$(printf '%s\n' "$events" | grep -c '^nm axi respond')" -eq 1 ] || fail "more than one review response was authorized"
  assert_contains "$events" 'nm axi abort --run run-1' "cycle limit did not use supported abort"
  pass "one review-fix-rereview cycle is the hard maximum"
}

test_auto_yes_is_refused_before_axi() {
  local d out rc=0
  d=$(make_case auto-yes)
  out=$(run_driver "$d" run task --intent x --yes 2>&1) || rc=$?
  expect_code 2 "$rc" "--yes must be refused"
  assert_contains "$out" '--yes is forbidden' "--yes refusal was not explicit"
  assert_absent "$d/events" "--yes still invoked the clock or AXI"
  pass "automatic gate resolution is refused before AXI starts"
}

test_submitted_head_cannot_enable_internal_review_loops() {
  local d out rc=0
  d=$(make_case unsafe-review-profile)
  printf 'agent: codex\nauto_fix:\n  review: 1\n' > "$d/wt/.no-mistakes.yaml"
  git -C "$d/wt" add .no-mistakes.yaml
  git -C "$d/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unsafe-profile
  out=$(run_driver "$d" run task --intent x 2>&1) || rc=$?
  expect_code 2 "$rc" "submitted review auto-fix override must be refused"
  assert_contains "$out" 'submitted HEAD must use canonical auto_fix.review: 0' \
    "unsafe submitted review profile refusal was not explicit"
  assert_absent "$d/events" "unsafe submitted review profile still launched AXI"
  pass "submitted HEAD cannot enable an internal review-fix loop"
}

test_exact_worker_binding_and_direct_pr_noninterference() {
  local d out rc=0
  d=$(make_case exact)
  out=$(cd "$d/repo" && PATH="$d/fakebin:$PATH" FM_HOME="$d/home" FM_NM_BOOT_ID=test \
    "$ROOT/bin/fm-no-mistakes.sh" run task --intent x 2>&1) || rc=$?
  expect_code 2 "$rc" "a general session outside the task worktree must be refused"
  assert_contains "$out" "recorded worktree" "worktree binding refusal was not explicit"
  assert_absent "$d/events" "refused general session still invoked no-mistakes"

  d=$(make_case ordinary direct-PR); rc=0
  out=$(run_driver "$d" run task --intent x 2>&1) || rc=$?
  expect_code 2 "$rc" "ordinary direct-PR task must reject the bounded pipeline"
  assert_contains "$out" 'not explicitly marked for no-mistakes' "direct-PR refusal was not explicit"
  assert_absent "$d/events" "ordinary direct-PR task started a process or poll"
  pass "only the exact owning worker can drive an explicitly marked run"
}

test_trusted_config_selects_codex_and_disables_review_autofix() {
  python3 - "$ROOT/.no-mistakes.yaml" <<'PY' || fail "trusted no-mistakes config does not select Codex with review auto-fix disabled"
import sys, yaml
config = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert config["agent"] == "codex"
assert config["auto_fix"]["review"] == 0
PY
  pass "trusted NoMistakes config selects Codex and leaves review cycles to the bounded driver"
}

test_manual_only_routing
test_pre_invocation_clock_is_deadline_authority
test_timeout_aborts_confirms_recovers_and_preserves_head
test_checks_passed_monitor_is_still_cancelled_at_ceiling
test_one_review_cycle_and_remaining_findings
test_auto_yes_is_refused_before_axi
test_submitted_head_cannot_enable_internal_review_loops
test_exact_worker_binding_and_direct_pr_noninterference
test_trusted_config_selects_codex_and_disables_review_autofix
