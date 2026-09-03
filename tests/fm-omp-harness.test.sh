#!/usr/bin/env bash
# Hermetic contract tests for the provisional OMP-on-Herdr adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness) \
  || fail "could not allocate OMP harness fixture root"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
CASE_SEQ=0

make_herdr() { # <case-dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\037' "$@" >> "$FM_FAKE_HERDR_LOG"
printf '\n' >> "$FM_FAKE_HERDR_LOG"
cmd=${1:-}; sub=${2:-}; pane=${3:-}
agent_dead=${FM_FAKE_AGENT_DEAD:-$FM_FAKE_HERDR_CLOSED.agent-dead}
control_log=${FM_FAKE_CONTROL_LOG:-$FM_FAKE_HERDR_LOG.control}
case "$cmd $sub" in
  "status --json") printf '%s\n' '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}' ;;
  "session list") printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"%s"}]}\n' "$FM_FAKE_SOCKET" ;;
  "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' ;;
  "tab list") printf '%s\n' '{"result":{"tabs":[]}}' ;;
  "tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}' ;;
  "pane get")
    if [ -f "$FM_FAKE_HERDR_CLOSED" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t2","workspace_id":"w1","foreground_cwd":"%s"}}}\n' "$pane" "$FM_FAKE_PANE_PATH"
    ;;
  "pane run")
    printf '%s\n' "${4:-}" >> "$FM_FAKE_RUN_LOG"
    case "${FM_FAKE_OMP_FAIL:-}" in
      gotmp) case "${4:-}" in *'export GOTMPDIR='*) exit 1 ;; esac ;;
      trace) case "${4:-}" in *'export TRACEPARENT='*) exit 1 ;; esac ;;
    esac
    ;;
  "pane send-text")
    payload=${4:-}
    if [ "$payload" = /quit ]; then
      : > "$agent_dead"
      printf '%s\n' "$payload" >> "$control_log"
    else
      rm -f -- "$agent_dead"
      printf '%s' "$payload" > "$FM_FAKE_LAUNCH_LOG"
    fi
    [ "${FM_FAKE_OMP_FAIL:-}" != launch-text ] || exit 1
    [ "${FM_FAKE_OMP_FAIL:-}" != encoding ] || rm -f -- "$FM_FAKE_BRIEF"
    ;;
  "pane send-keys")
    printf '%s\n' "${4:-}" >> "$control_log"
    [ "${FM_FAKE_OMP_FAIL:-}" != enter ] || exit 1
    ;;
  "pane close")
    [ "${FM_FAKE_OMP_CLEANUP_FAIL:-0}" = 1 ] || : > "$FM_FAKE_HERDR_CLOSED"
    ;;
  "agent wait")
    if [ "${FM_TEST_PRECREATE_META_STAGE_SYMLINK:-0}" = 1 ]; then
      while [ ! -f "$FM_FAKE_STAGE_READY" ]; do /bin/sleep 0.01; done
    fi
    if [ "${FM_FAKE_OMP_FAIL:-}" = signal ]; then
      signal_pid=$(cat "$FM_FAKE_SIGNAL_PID_FILE") || exit 1
      case "$signal_pid" in ''|*[!0-9]*) exit 1 ;; esac
      kill -HUP "$signal_pid"
    fi
    [ "${FM_FAKE_OMP_FAIL:-}" != readiness ] || exit 1
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    ;;
  "agent get")
    if [ -f "$agent_dead" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      exit 1
    fi
    if [ "${FM_FAKE_RELAUNCH_PRECHECK:-0}" = 1 ]; then
      count=0
      [ ! -f "$FM_FAKE_AGENT_GET_COUNT" ] || count=$(cat "$FM_FAKE_AGENT_GET_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_AGENT_GET_COUNT"
      if [ "$count" -eq 1 ]; then
        printf '%s\n' '{"error":{"code":"agent_not_found"}}'
        exit 1
      fi
    fi
    printf '%s\n' '{"result":{"agent":{"agent":"omp","agent_status":"idle"}}}'
    ;;
  "agent prompt")
    [ "${FM_FAKE_OMP_FAIL:-}" != prompt ] || exit 1
    printf '%s' "${4:-}" > "$FM_FAKE_PROMPT_LOG"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

new_case() { # <name> [brief]
  local name=$1 brief=${2:-"OMP fixture brief"} case_dir home project wt fakebin id
  CASE_SEQ=$((CASE_SEQ + 1))
  case_dir="$TMP_ROOT/$name-$CASE_SEQ"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/wt"
  id="omp-$name-$CASE_SEQ-$$"
  fakebin=$(make_herdr "$case_dir/tools")
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" "$brief"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$project" "$wt" "fm/$id"
  : > "$case_dir/herdr.log"
  : > "$case_dir/run.log"
  : > "$case_dir/control.log"
  printf '%s\n' "$case_dir|$home|$project|$wt|$fakebin|$id"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR ID <<EOF
$1
EOF
}

register_task_tmp() { # <id>
  local raw="$FM_TEST_TMP_BASE/fm-$1" physical
  [ -d "$raw" ] || return 0
  physical=$(CDPATH='' cd -P -- "$raw" && pwd -P) || return 1
  if [ -e "$physical/.fm-test-fixture" ] || [ -L "$physical/.fm-test-fixture" ]; then
    fm_test_fixture_marker_matches "$physical" "$$" "$FM_TEST_OWNER_IDENTITY" \
      && grep -Fqx -- "$physical" "$FM_TEST_CLEANUP_REGISTRY"
  else
    fm_test_register_cleanup_dir "$physical"
  fi
}

run_spawn() { # [extra args]
  local rc=0 spawn_pid output signal_pid_file legacy_stage
  output="$CASE_DIR/spawn.out"
  signal_pid_file="$CASE_DIR/spawn.pid"
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_OMP_HERDR_EXPERIMENTAL="${FM_TEST_OMP_EXPERIMENTAL:-1}" \
    HERDR_ENV= HERDR_PANE_ID= HERDR_TAB_ID= HERDR_WORKSPACE_ID= HERDR_SOCKET_PATH= HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" FM_FAKE_HERDR_CLOSED="$CASE_DIR/closed" \
    FM_FAKE_RUN_LOG="$CASE_DIR/run.log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_PROMPT_LOG="$CASE_DIR/prompt.log" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_AGENT_GET_COUNT="$CASE_DIR/agent-get-count" \
    FM_FAKE_AGENT_DEAD="$CASE_DIR/agent-dead" FM_FAKE_CONTROL_LOG="$CASE_DIR/control.log" \
    FM_FAKE_SIGNAL_PID_FILE="$signal_pid_file" FM_FAKE_STAGE_READY="$CASE_DIR/stage-ready" \
    FM_TEST_PRECREATE_META_STAGE_SYMLINK="${FM_TEST_PRECREATE_META_STAGE_SYMLINK:-0}" \
    FM_FAKE_SOCKET="$CASE_DIR/herdr.sock" \
    FM_FAKE_BRIEF="$HOME_DIR/data/$ID/brief.md" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$ID" "$PROJECT_DIR" --scout "$@" > "$output" 2>&1 &
  spawn_pid=$!
  printf '%s\n' "$spawn_pid" > "$signal_pid_file"
  if [ "${FM_TEST_PRECREATE_META_STAGE_SYMLINK:-0}" = 1 ]; then
    legacy_stage="$HOME_DIR/state/.$ID.meta.omp-recovery.$spawn_pid"
    ln -s "$FM_TEST_META_STAGE_SENTINEL" "$legacy_stage" \
      || fail "could not precreate legacy OMP metadata staging symlink"
    : > "$CASE_DIR/stage-ready"
  fi
  wait "$spawn_pid" || rc=$?
  cat "$output"
  register_task_tmp "$ID" || fail "could not register $ID task temp for guarded cleanup"
  return "$rc"
}

run_control() { # <verb> [args]
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_OMP_HERDR_EXPERIMENTAL="${FM_TEST_OMP_EXPERIMENTAL:-1}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_LAUNCH_WAIT=0.05 HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" FM_FAKE_HERDR_CLOSED="$CASE_DIR/closed" \
    FM_FAKE_RUN_LOG="$CASE_DIR/run.log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_PROMPT_LOG="$CASE_DIR/prompt.log" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_AGENT_GET_COUNT="$CASE_DIR/agent-get-count" FM_FAKE_SOCKET="$CASE_DIR/herdr.sock" \
    FM_FAKE_AGENT_DEAD="$CASE_DIR/agent-dead" FM_FAKE_CONTROL_LOG="$CASE_DIR/control.log" \
    FM_FAKE_BRIEF="$HOME_DIR/data/$ID/brief.md" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$CONTROL" "$ID" "$@"
}

run_teardown() {
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_TEARDOWN_GUARD_DONE=1 HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" FM_FAKE_HERDR_CLOSED="$CASE_DIR/closed" \
    FM_FAKE_RUN_LOG="$CASE_DIR/run.log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_PROMPT_LOG="$CASE_DIR/prompt.log" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_AGENT_GET_COUNT="$CASE_DIR/agent-get-count" FM_FAKE_SOCKET="$CASE_DIR/herdr.sock" \
    FM_FAKE_AGENT_DEAD="$CASE_DIR/agent-dead" FM_FAKE_CONTROL_LOG="$CASE_DIR/control.log" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" "$TEARDOWN" "$ID" "$@"
}

test_personal_launch_is_fixed_and_prompt_is_argv_safe() {
  local record out rc expected prompt brief injected substitution
  injected="$TMP_ROOT/injected"
  substitution="$TMP_ROOT/substitution"
  brief="Review this safely: '; touch $injected
\$(touch $substitution)"
  record=$(new_case personal "$brief"); read_case "$record"
  rc=0; out=$(run_spawn --harness omp --profile personal --backend herdr) || rc=$?
  [ "$rc" -eq 0 ] || fail "personal OMP spawn: exit $rc
$out"
  assert_contains "$out" "spawned $ID harness=omp profile=personal kind=scout" "OMP success omitted its profile"
  expected="/bin/zsh -lic 'omp \"\$@\"' fm-omp"
  [ "$(cat "$CASE_DIR/launch.log")" = "$expected" ] || fail "personal OMP did not use the fixed Mist wrapper argv"
  prompt=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$ID/brief.md")
  [ "$(cat "$CASE_DIR/prompt.log")" = "$prompt" ] || fail "OMP prompt bytes changed across Herdr's argv boundary"
  assert_absent "$injected" "OMP prompt executed a quote injection"
  assert_absent "$substitution" "OMP prompt executed command substitution"
  assert_grep 'profile=personal' "$HOME_DIR/state/$ID.meta" "OMP metadata omitted profile"
  assert_grep $'agent\037wait\037w1:p2\037--until\037idle\037' "$CASE_DIR/herdr.log" "OMP readiness did not use Herdr agent wait"
  assert_grep $'agent\037prompt\037w1:p2\037' "$CASE_DIR/herdr.log" "OMP delivery did not use Herdr agent prompt"
  pass "personal OMP uses the fixed wrapper and an argv-safe native prompt"
}

test_sf_launch_uses_ompp_without_forwarded_profile() {
  local record out rc
  record=$(new_case sf); read_case "$record"
  rc=0; out=$(run_spawn --harness omp --profile sf --backend herdr) || rc=$?
  expect_code 0 "$rc" "sf OMP spawn"
  [ "$(cat "$CASE_DIR/launch.log")" = "/bin/zsh -lic 'ompp \"\$@\"' fm-omp" ] \
    || fail "sf OMP did not use the fixed ompp wrapper"
  assert_not_contains "$(cat "$CASE_DIR/launch.log")" "--profile" "OMP forwarded a profile into the wrapper"
  assert_contains "$out" "profile=sf" "sf OMP success omitted its profile"
  pass "sf OMP selects ompp without reproducing Mist configuration"
}

test_named_boundary_refuses_implicit_and_override_inputs() {
  local record out rc args label
  for label in gate no-profile no-backend wrong-backend bad-profile model effort config alias other-profile; do
    record=$(new_case "reject-$label"); read_case "$record"
    case "$label" in
      gate) args=(--harness omp --profile personal --backend herdr);;
      no-profile) args=(--harness omp --backend herdr);;
      no-backend) args=(--harness omp --profile personal);;
      wrong-backend) args=(--harness omp --profile personal --backend tmux);;
      bad-profile) args=(--harness omp --profile other --backend herdr);;
      model) args=(--harness omp --profile personal --backend herdr --model default);;
      effort) args=(--harness omp --profile personal --backend herdr --effort high);;
      config) args=(--harness omp --profile personal --backend herdr --config bad);;
      alias) args=(--harness omp --profile personal --backend herdr --alias bad);;
      other-profile) args=(--harness claude --profile personal --backend herdr);;
    esac
    rc=0
    if [ "$label" = gate ]; then
      out=$(FM_TEST_OMP_EXPERIMENTAL=0 run_spawn "${args[@]}") || rc=$?
    else
      out=$(run_spawn "${args[@]}") || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "$label input unexpectedly crossed the OMP boundary"
    [ ! -s "$CASE_DIR/herdr.log" ] || fail "$label refusal created a Herdr side effect"
    assert_absent "$HOME_DIR/state/$ID.meta" "$label refusal published metadata"
  done
  record=$(new_case reject-config-fallback); read_case "$record"
  printf 'omp\n' > "$HOME_DIR/config/crew-harness"
  rc=0; out=$(run_spawn --backend herdr) || rc=$?
  [ "$rc" -ne 0 ] || fail "configured OMP selection unexpectedly dispatched"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "configured OMP refusal touched Herdr"
  pass "named OMP requires explicit harness/profile/backend and rejects provider overrides"
}

test_raw_omp_roots_remain_unverified_escape_hatches() {
  local root record out rc
  for root in omp ompp; do
    record=$(new_case "raw-$root"); read_case "$record"
    rc=0; out=$(run_spawn --harness "$root --operator-escape" --backend herdr) || rc=$?
    expect_code 0 "$rc" "raw $root spawn"
    assert_grep 'harness=raw-omp' "$HOME_DIR/state/$ID.meta" "raw $root was allowed to claim the named adapter"
    assert_no_grep 'profile=' "$HOME_DIR/state/$ID.meta" "raw $root received a verified profile"
  done
  pass "direct raw omp and ompp roots are labeled raw-omp"
}

test_postpublication_failures_cleanup_or_retain_recovery() {
  local phase phases record out rc meta sidecar sentinel spawn_pid
  phases=${FM_OMP_RECOVERY_PHASE:-"gotmp launch-text enter readiness encoding prompt signal"}
  for phase in $phases; do
    record=$(new_case "failure-$phase"); read_case "$record"
    rc=0; out=$(FM_FAKE_OMP_FAIL="$phase" run_spawn --harness omp --profile personal --backend herdr) || rc=$?
    [ "$rc" -ne 0 ] || fail "$phase failure unexpectedly succeeded"
    assert_present "$CASE_DIR/closed" "$phase failure did not remove the exact Herdr endpoint
$out"
    assert_absent "$HOME_DIR/state/$ID.meta" "$phase failure left fresh metadata after proven endpoint cleanup"
    assert_absent "$HOME_DIR/state/$ID.cleanup-recovery" "$phase proven cleanup left a recovery sidecar"
    spawn_pid=$(cat "$CASE_DIR/spawn.pid")
    ! kill -0 "$spawn_pid" 2>/dev/null || fail "$phase failure leaked its spawn process"
    [ -z "$(find "$HOME_DIR/state" \( -name ".$ID.meta.omp-recovery.*" -o -name ".$ID.cleanup-recovery.*" \) -print -quit)" ] \
      || fail "$phase failure leaked an OMP metadata staging file"
  done

  record=$(new_case cleanup-unconfirmed); read_case "$record"
  rc=0; out=$(FM_FAKE_OMP_FAIL=readiness FM_FAKE_OMP_CLEANUP_FAIL=1 run_spawn --harness omp --profile sf --backend herdr) || rc=$?
  [ "$rc" -ne 0 ] || fail "unconfirmed cleanup unexpectedly succeeded"
  meta="$HOME_DIR/state/$ID.meta"; sidecar="$HOME_DIR/state/$ID.cleanup-recovery"
  assert_present "$meta" "unconfirmed cleanup lost endpoint metadata"
  assert_present "$sidecar" "unconfirmed cleanup did not publish private recovery"
  [ "$(stat -f %Lp "$sidecar" 2>/dev/null || stat -c %a "$sidecar")" = 600 ] || fail "recovery sidecar is not mode 0600"
  assert_grep 'cleanup_recovery=omp-delivery' "$sidecar" "recovery sidecar kind is not closed"
  assert_grep 'delivery_cleanup=unconfirmed' "$sidecar" "recovery sidecar overstated cleanup"
  assert_grep 'profile=sf' "$sidecar" "recovery sidecar lost profile"

  record=$(new_case meta-stage-symlink); read_case "$record"
  sentinel="$CASE_DIR/outside"
  printf 'outside\n' > "$sentinel"
  rc=0
  out=$(FM_FAKE_OMP_FAIL=readiness FM_FAKE_OMP_CLEANUP_FAIL=1 \
    FM_TEST_PRECREATE_META_STAGE_SYMLINK=1 FM_TEST_META_STAGE_SENTINEL="$sentinel" \
    run_spawn --harness omp --profile personal --backend herdr) || rc=$?
  [ "$rc" -ne 0 ] || fail "metadata-stage symlink failure unexpectedly succeeded"
  [ "$(cat "$sentinel")" = outside ] \
    || fail "OMP metadata annotation followed a precreated staging symlink"
  assert_present "$HOME_DIR/state/$ID.cleanup-recovery" \
    "secure metadata staging failure lost authoritative sidecar recovery"
  rm -f -- "$HOME_DIR/state/.$ID.meta.omp-recovery.$(cat "$CASE_DIR/spawn.pid")"
  [ -z "$(find "$HOME_DIR/state" \( -name ".$ID.meta.omp-recovery.*" -o -name ".$ID.cleanup-recovery.*" \) -print -quit)" ] \
    || fail "OMP recovery left a metadata staging artifact"
  pass "every injected delivery failure cleans up or retains closed recovery"
}

test_failed_relaunch_keeps_transaction_bound_recovery() {
  local record out rc meta helper
  record=$(new_case relaunch); read_case "$record"
  meta="$HOME_DIR/state/$ID.meta"
  fm_write_meta "$meta" \
    'window=fmtest:w1:p2' "endpoint_task_id=$ID" "worktree=$WT_DIR" "project=$PROJECT_DIR" \
    'harness=omp' 'profile=personal' 'kind=scout' 'tasktmp=' 'model=default' 'effort=default' \
    'spawn_gen=prior' 'backend=herdr' 'herdr_session=fmtest' 'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2'
  helper="$CASE_DIR/control-parent"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
shift
mkdir "$FM_STATE_OVERRIDE/.control-$id.lock"
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.control-$id.lock/pid"
"$@"
rc=$?
: # Prevent Bash from exec-replacing the control parent with fm-spawn.
exit "$rc"
SH
  chmod +x "$helper"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_OMP_HERDR_EXPERIMENTAL=1 FM_CONTROL_RELAUNCH_TX=tx-relaunch \
    FM_FAKE_OMP_FAIL=readiness FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_RELAUNCH_PRECHECK=1 FM_FAKE_AGENT_GET_COUNT="$CASE_DIR/agent-get-count" \
    FM_FAKE_HERDR_CLOSED="$CASE_DIR/closed" FM_FAKE_RUN_LOG="$CASE_DIR/run.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PROMPT_LOG="$CASE_DIR/prompt.log" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_BRIEF="$HOME_DIR/data/$ID/brief.md" \
    FM_FAKE_SOCKET="$CASE_DIR/herdr.sock" \
    HERDR_ENV= HERDR_PANE_ID= HERDR_TAB_ID= HERDR_WORKSPACE_ID= HERDR_SOCKET_PATH= \
    HERDR_SESSION=fmtest PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$helper" "$ID" "$SPAWN" "$ID" --relaunch --harness omp --profile personal 2>&1) || rc=$?
  register_task_tmp "$ID" || fail "could not register relaunch task temp"
  [ "$rc" -ne 0 ] || fail "failed OMP relaunch unexpectedly succeeded"
  assert_present "$meta" "failed relaunch removed its replacement metadata"
  assert_grep 'control_relaunch_tx=tx-relaunch' "$meta" "failed relaunch lost its transaction binding
--- output ---
$out
--- meta ---
$(cat "$meta")"
  assert_grep 'control_relaunch_tx=tx-relaunch' "$HOME_DIR/state/$ID.cleanup-recovery" "failed relaunch recovery lost its transaction binding"
  assert_grep 'delivery_cleanup=confirmed' "$HOME_DIR/state/$ID.cleanup-recovery" "failed relaunch did not record proven endpoint cleanup"
  # The task temp is registered with this test process and intentionally left
  # to tests/lib.sh; this case exercises recovery records, not temp-root removal.
  sed -i.bak 's|^tasktmp=.*$|tasktmp=|' "$meta"
  rm -f -- "$meta.bak"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  out=$(run_teardown --force 2>&1) \
    || fail "manual-backlog failed-relaunch teardown did not retire recovery: $out"
  assert_contains "$out" "failed transaction-bound OMP relaunch has no automatic backlog transition" \
    "manual-backlog failed-relaunch teardown was mislabeled as a fresh delivery"
  assert_absent "$HOME_DIR/state/$ID.meta" \
    "manual-backlog failed-relaunch teardown retained task metadata"
  assert_absent "$HOME_DIR/state/$ID.cleanup-recovery" \
    "manual-backlog failed-relaunch teardown retained its recovery sidecar"
  [ -z "$(find "$HOME_DIR/state" -name "$ID.*" -print -quit)" ] \
    || fail "manual-backlog failed-relaunch teardown left partial task state"
  pass "failed relaunch retains transaction recovery and retires it without a backlog"
}

test_control_lifecycle_and_profile_relaunch_contract() {
  local record out rc before after
  record=$(new_case control); read_case "$record"
  out=$(run_spawn --harness omp --profile personal --backend herdr) \
    || fail "control fixture OMP spawn failed: $out"
  before=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")

  out=$(run_control interrupt 2>&1) || fail "OMP interrupt failed: $out"
  assert_contains "$out" "interrupt-delivered $ID harness=omp backend=herdr verified=agent-alive cancel=unconfirmed" \
    "OMP interrupt overstated or lost its cancellation evidence"

  out=$(run_control exit 2>&1) || fail "OMP exit failed: $out"
  assert_contains "$out" "stopped $ID harness=omp backend=herdr endpoint=$before" \
    "OMP exit lost its structured endpoint result"

  out=$(run_control relaunch --note 'continue the fixture' 2>&1) \
    || fail "OMP profile-preserving relaunch failed: $out"
  after=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  [ "$after" = "$before" ] || fail "OMP relaunch moved to a different pane"
  assert_contains "$out" "relaunched $ID harness=omp profile=personal" \
    "OMP relaunch did not persist its profile"
  assert_grep 'profile=personal' "$HOME_DIR/state/$ID.meta" \
    "OMP relaunch metadata lost the persisted profile"

  out=$(run_control relaunch --profile sf --note 'switch fixture profile' 2>&1) \
    || fail "OMP profile-changing relaunch failed: $out"
  [ "$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")" = "$before" ] \
    || fail "OMP profile change moved to a different pane"
  assert_contains "$out" "relaunched $ID harness=omp profile=sf" \
    "OMP relaunch did not report its changed profile"
  assert_grep 'profile=sf' "$HOME_DIR/state/$ID.meta" \
    "OMP relaunch metadata did not persist the changed profile"
  case "$(cat "$CASE_DIR/launch.log")" in
    *"/bin/zsh -lic 'ompp \"\$@\"' fm-omp") ;;
    *) fail "OMP profile-changing relaunch did not select the sf wrapper: $(cat "$CASE_DIR/launch.log")" ;;
  esac

  record=$(new_case control-refusal); read_case "$record"
  run_spawn --harness omp --profile personal --backend herdr >/dev/null \
    || fail "OMP refusal fixture spawn failed"
  : > "$CASE_DIR/control.log"
  rc=0
  out=$(FM_TEST_OMP_EXPERIMENTAL=0 run_control relaunch --note refused 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "OMP relaunch crossed the disabled experimental gate"
  [ ! -s "$CASE_DIR/control.log" ] || fail "disabled OMP relaunch emitted lifecycle bytes"

  sed -i.bak 's/^model=default$/model=caller-model/' "$HOME_DIR/state/$ID.meta"
  rm -f "$HOME_DIR/state/$ID.meta.bak"
  rc=0
  out=$(run_control relaunch --note refused 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "OMP relaunch accepted non-canonical model metadata"
  [ ! -s "$CASE_DIR/control.log" ] || fail "non-canonical OMP relaunch emitted lifecycle bytes"
  pass "OMP control is truthful, same-pane, profile-stable, and refuses invalid relaunches before stop"
}

test_fresh_recovery_tears_down_without_a_scout_deliverable() {
  local record out rc=0
  record=$(new_case teardown-recovery); read_case "$record"
  out=$(FM_FAKE_OMP_FAIL=readiness FM_FAKE_OMP_CLEANUP_FAIL=1 \
    run_spawn --harness omp --profile personal --backend herdr) || rc=$?
  [ "$rc" -ne 0 ] || fail "fresh OMP recovery fixture unexpectedly launched"
  assert_present "$HOME_DIR/state/$ID.cleanup-recovery" \
    "fresh OMP recovery fixture lost its authoritative sidecar"
  # Leave the fixture-owned task temp to tests/lib.sh; teardown is being tested
  # for recovery authorization here, not for removal of that registered root.
  sed -i.bak 's|^tasktmp=.*$|tasktmp=|' "$HOME_DIR/state/$ID.meta"
  rm -f "$HOME_DIR/state/$ID.meta.bak"
  rm -f "$CASE_DIR/closed"
  out=$(run_teardown 2>&1) || fail "fresh OMP recovery teardown failed: $out"
  assert_absent "$HOME_DIR/state/$ID.meta" \
    "fresh OMP recovery teardown retained task metadata"
  assert_absent "$HOME_DIR/state/$ID.cleanup-recovery" \
    "fresh OMP recovery teardown retained its sidecar"
  pass "fresh OMP delivery recovery tears down without inventing a scout deliverable"
}

test_signal_after_backlog_commit_preserves_committed_omp() {
  local record out rc=0
  record=$(new_case commit-signal); read_case "$record"
  printf '# queued fixture\n' > "$HOME_DIR/data/backlog.md"
  printf 'queued\n' > "$CASE_DIR/backlog-state"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'tasks-axi 0.2.5\n' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  show)
    printf '  state: %s\n' "$(cat "$FM_FAKE_BACKLOG_STATE")"
    printf '%s\n' '  held: no' '  blocked: no'
    ;;
  start)
    printf 'in_flight\n' > "$FM_FAKE_BACKLOG_STATE"
    spawn_pid=$(cat "$FM_FAKE_SIGNAL_PID_FILE") || exit 1
    case "$spawn_pid" in ''|*[!0-9]*) exit 1 ;; esac
    kill -HUP "$spawn_pid"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"
  rc=0
  out=$(FM_FAKE_BACKLOG_STATE="$CASE_DIR/backlog-state" \
    run_spawn --harness omp --profile personal --backend herdr) || rc=$?
  [ "$rc" -eq 129 ] || fail "post-commit HUP exited $rc instead of 129: $out"
  assert_present "$HOME_DIR/state/$ID.meta" \
    "post-commit HUP rolled back committed OMP metadata"
  assert_absent "$HOME_DIR/state/$ID.cleanup-recovery" \
    "post-commit HUP fabricated failed-delivery recovery"
  assert_absent "$CASE_DIR/closed" \
    "post-commit HUP closed the committed OMP endpoint"
  [ "$(cat "$CASE_DIR/backlog-state")" = in_flight ] \
    || fail "post-commit HUP rolled back the committed backlog transition"
  pass "OMP delivery rollback is disarmed before deferred commit-window signals resume"
}

case "${FM_OMP_HARNESS_TEST_FOCUS:-all}" in
  launch)
    test_personal_launch_is_fixed_and_prompt_is_argv_safe
    test_sf_launch_uses_ompp_without_forwarded_profile
    ;;
  boundary) test_named_boundary_refuses_implicit_and_override_inputs ;;
  raw) test_raw_omp_roots_remain_unverified_escape_hatches ;;
  recovery) test_postpublication_failures_cleanup_or_retain_recovery ;;
  relaunch) test_failed_relaunch_keeps_transaction_bound_recovery ;;
  control) test_control_lifecycle_and_profile_relaunch_contract ;;
  teardown) test_fresh_recovery_tears_down_without_a_scout_deliverable ;;
  commit-signal) test_signal_after_backlog_commit_preserves_committed_omp ;;
  all)
    test_personal_launch_is_fixed_and_prompt_is_argv_safe
    test_sf_launch_uses_ompp_without_forwarded_profile
    test_named_boundary_refuses_implicit_and_override_inputs
    test_raw_omp_roots_remain_unverified_escape_hatches
    test_postpublication_failures_cleanup_or_retain_recovery
    test_failed_relaunch_keeps_transaction_bound_recovery
    test_control_lifecycle_and_profile_relaunch_contract
    test_fresh_recovery_tears_down_without_a_scout_deliverable
    test_signal_after_backlog_commit_preserves_committed_omp
    ;;
  *) fail "unknown FM_OMP_HARNESS_TEST_FOCUS" ;;
esac
