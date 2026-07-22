#!/usr/bin/env bash
# Behavior tests for the same-home primary launcher: strict parsing, opaque argv,
# fixed home/cwd/session routing, compatible attach, lock refusal, and races.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-launch)
LAUNCH="$ROOT/bin/fm-primary-launch.sh"
USER_NAME=$(id -un)

cleanup_tmux() {
  local marker socket
  while IFS= read -r marker; do
    socket=$(cat "$marker")
    tmux -L "$socket" kill-server 2>/dev/null || true
  done < <(find "$TMP_ROOT" -name socket-name -type f 2>/dev/null)
  fm_test_cleanup
}
trap cleanup_tmux EXIT

make_case() {
  local name=$1 dir home fakebin socket harness
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  fakebin="$dir/fakebin"
  socket="fm-primary-${name//[^a-zA-Z0-9]/}-$$"
  mkdir -p "$home/bin" "$home/state" "$fakebin"
  cp "$LAUNCH" "$home/bin/fm-primary-launch.sh"
  cp "$ROOT/bin/fm-lock.sh" "$home/bin/fm-lock.sh"
  chmod +x "$home/bin/"*.sh
  cat > "$home/bin/pi" <<'JS'
setInterval(() => {}, 300000)
JS
  printf '%s\n' "$socket" > "$dir/socket-name"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'daemon status') printf '%s\n' 'daemon running'; exit 0 ;;
  'daemon start') exit 0 ;;
esac
exit 2
SH
  chmod +x "$fakebin/no-mistakes"
  for harness in codex pi grok claude opencode; do
    cat > "$fakebin/$harness" <<'SH'
#!/usr/bin/env bash
set -u
harness=$(basename "$0")
{
  printf 'harness=%s\n' "$harness"
  printf 'user=%s\n' "$(id -un)"
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'home=%s\n' "${FM_HOME:-}"
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    printf 'argv[%s]=<%s>\n' "$i" "$arg"
    i=$((i + 1))
  done
} > "${FM_PRIMARY_TEST_LOG:?}"
printf '%s\n' "$$" > "${FM_HOME:?}/state/.lock"
exec -a "$harness" sleep 300
SH
    chmod +x "$fakebin/$harness"
  done
  printf '%s|%s|%s|%s\n' "$dir" "$home" "$fakebin" "$socket"
}

run_launch() {
  local home=$1 fakebin=$2 socket=$3 log=$4
  shift 4
  FM_PRIMARY_LAUNCH_TESTING=1 \
    FM_PRIMARY_ROOT_OVERRIDE="$home" \
    FM_PRIMARY_HOME_OVERRIDE="$home" \
    FM_PRIMARY_USER_OVERRIDE="$USER_NAME" \
    FM_PRIMARY_TMUX_SOCKET="$socket" \
    FM_PRIMARY_NO_ATTACH=1 \
    FM_PRIMARY_TEST_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$home/bin/fm-primary-launch.sh" "$@"
}

wait_for_file() {
  local file=$1
  local -i attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ -f "$file" ] && return 0
    attempt=$((attempt + 1))
    sleep 0.02
  done
  return 1
}

kill_case() {
  tmux -L "$1" kill-server 2>/dev/null || true
}

assert_rejected() {
  local home=$1 fakebin=$2 socket=$3 expected=$4
  shift 4
  local out status
  out=$(run_launch "$home" "$fakebin" "$socket" /dev/null "$@" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "launcher accepted rejected arguments: $*"
  assert_contains "$out" "$expected" "launcher rejection was unclear for: $*"
}

test_parsing_rejections() {
  local rec dir home fakebin socket
  rec=$(make_case parsing)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  assert_rejected "$home" "$fakebin" "$socket" 'positional prompts' hello
  assert_rejected "$home" "$fakebin" "$socket" 'unknown option' --raw
  assert_rejected "$home" "$fakebin" "$socket" 'exactly one harness selector' --pi --codex
  assert_rejected "$home" "$fakebin" "$socket" 'requires a value' --pi --model
  assert_rejected "$home" "$fakebin" "$socket" 'explicit harness selector' --model foo
  assert_rejected "$home" "$fakebin" "$socket" 'must be one of' --pi --effort turbo
  assert_rejected "$home" "$fakebin" "$socket" 'does not support effort max' --codex --effort max
  assert_rejected "$home" "$fakebin" "$socket" 'supports effort low' --grok --effort xhigh
  assert_rejected "$home" "$fakebin" "$socket" 'not verified' --opencode --effort low
  pass "primary launcher rejects ambiguous and unsupported input"
}

test_harness_argv_and_invariants() {
  local harness rec dir home fakebin socket log out expected model
  # shellcheck disable=SC2016  # literal shell syntax is the hostile model fixture.
  model='vendor/model $(touch nope); "quoted" * ?'
  for harness in codex pi grok claude opencode; do
    rec=$(make_case "argv-$harness")
    IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
    log="$dir/argv.log"
    case "$harness" in
      opencode) out=$(run_launch "$home" "$fakebin" "$socket" "$log" "--$harness" --model "$model") ;;
      grok) out=$(run_launch "$home" "$fakebin" "$socket" "$log" "--$harness" --model "$model" --effort high) ;;
      *) out=$(run_launch "$home" "$fakebin" "$socket" "$log" "--$harness" --model "$model" --effort xhigh) ;;
    esac
    assert_contains "$out" "harness=$harness" "launcher did not publish selected harness"
    wait_for_file "$log" || fail "$harness fake harness did not run"
    assert_grep "harness=$harness" "$log" "$harness executable was not selected"
    assert_grep "user=$USER_NAME" "$log" "$harness changed the Linux user"
    assert_grep "cwd=$home" "$log" "$harness changed the repository root"
    assert_grep "home=$home" "$log" "$harness changed FM_HOME"
    assert_grep "<$model>" "$log" "$harness did not preserve model as one opaque argv element"
    assert_absent "$home/nope" "hostile model executed shell source"
    expected=$(tmux -L "$socket" show-options -qv -t firstmate @firstmate_home)
    [ "$expected" = "$home" ] || fail "$harness session home metadata diverged"
    expected=$(tmux -L "$socket" show-options -qv -t firstmate @firstmate_harness)
    [ "$expected" = "$harness" ] || fail "$harness session harness metadata missing"
    case "$harness" in
      codex)
        assert_grep '<--dangerously-bypass-approvals-and-sandbox>' "$log" "bare Codex autonomy posture was not preserved"
        assert_grep '<model_reasoning_effort="xhigh">' "$log" "Codex effort argv was wrong"
        ;;
      pi) assert_grep '<--thinking>' "$log" "Pi thinking flag missing" ;;
      grok)
        assert_grep '<--trust>' "$log" "Grok normal project trust flag missing"
        assert_grep '<--reasoning-effort>' "$log" "Grok reasoning effort flag missing"
        assert_grep '<Run bin/fm-session-start.sh exactly once before doing anything else.>' "$log" "Grok fixed startup instruction missing"
        ;;
      claude) assert_grep '<--effort>' "$log" "Claude effort flag missing" ;;
      opencode) assert_no_grep 'effort' "$log" "OpenCode received an effort flag" ;;
    esac
    kill_case "$socket"
  done
  pass "all primary selectors preserve identity and map only model and effort argv"
}

test_bare_and_matching_attach_divergent_refusal() {
  local rec dir home fakebin socket log out status
  rec=$(make_case attach)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  log="$dir/argv.log"
  out=$(run_launch "$home" "$fakebin" "$socket" "$log")
  assert_contains "$out" 'harness=codex' "bare launch was not Codex"
  wait_for_file "$log" || fail "bare Codex did not start"

  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/ignored.log" --codex)
  assert_contains "$out" 'attached:' "matching selector did not attach"
  [ ! -e "$dir/ignored.log" ] || fail "matching attach launched a second harness"

  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/divergent.log" --pi 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "divergent selector attached to Codex"
  assert_contains "$out" 'already running on Codex' "divergent refusal did not name the live harness"
  assert_contains "$out" 'no state was changed' "divergent refusal omitted mutation guarantee"
  [ ! -e "$dir/divergent.log" ] || fail "divergent selector launched Pi"
  kill_case "$socket"
  pass "bare and matching selectors attach while divergent selectors refuse"
}

test_live_and_stale_lock_behavior() {
  local rec dir home fakebin socket log out status holder
  rec=$(make_case locks)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  log="$dir/argv.log"
  bash -c 'exec -a codex sleep 300' & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(run_launch "$home" "$fakebin" "$socket" "$log" --codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "live same-home lock without tmux was ignored"
  assert_contains "$out" 'live' "live-lock refusal was unclear"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "launcher changed a live lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  printf '999999\n' > "$home/state/.lock"
  out=$(run_launch "$home" "$fakebin" "$socket" "$log" --pi)
  assert_contains "$out" 'harness=pi' "stale lock did not hand off to normal session start"
  wait_for_file "$log" || fail "Pi did not launch after stale lock"
  [ "$(cat "$home/state/.lock")" != 999999 ] || fail "Pi did not acquire the stale session lock"
  kill_case "$socket"
  pass "live locks refuse and stale locks remain for session-start authority"
}

test_concurrent_launch_serialization() {
  local rec dir home fakebin socket log1 log2 out1 out2 pid1 pid2 count
  rec=$(make_case race)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  log1="$dir/one.log"
  log2="$dir/two.log"
  run_launch "$home" "$fakebin" "$socket" "$log1" --pi >"$dir/out1" 2>&1 & pid1=$!
  run_launch "$home" "$fakebin" "$socket" "$log2" --pi >"$dir/out2" 2>&1 & pid2=$!
  wait "$pid1" || fail "first concurrent launch failed"
  wait "$pid2" || fail "second concurrent launch failed"
  out1=$(cat "$dir/out1")
  out2=$(cat "$dir/out2")
  assert_contains "$out1$out2" 'attached:' "one concurrent caller did not attach"
  count=0
  [ -f "$log1" ] && count=$((count + 1))
  [ -f "$log2" ] && count=$((count + 1))
  [ "$count" -eq 1 ] || fail "concurrent launches created $count harness processes"
  [ "$(tmux -L "$socket" list-sessions -F '#{session_name}' | grep -c '^firstmate$')" -eq 1 ] || fail "concurrent launch created multiple sessions"
  kill_case "$socket"
  pass "concurrent launch attempts serialize to one primary session"
}

test_lock_live_pid_query_is_read_only() {
  local rec dir home fakebin socket out status holder
  rec=$(make_case lock-query)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  rm -rf "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-lock.sh" live-pid 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "live-pid reported a missing lock as live"
  assert_absent "$home/state" "read-only live-pid query created state"

  mkdir -p "$home/state"
  bash -c 'exec -a codex sleep 300' & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-lock.sh" live-pid)
  [ "$out" = "$holder" ] || fail "live-pid did not return the holder PID"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  bash -c 'exec -a pi sleep 300' & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-lock.sh" live-pid)
  [ "$out" = "$holder" ] || fail "live-pid did not recognize a Pi holder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-lock live-pid recognizes supported harnesses without mutation"
}

test_tracked_scripts_are_executable() {
  [ -x "$ROOT/bin/fm-primary-launch.sh" ] || fail "primary launcher is not executable"
  [ -x "$ROOT/bin/fm-lock.sh" ] || fail "session lock helper is not executable"
  pass "tracked primary launcher and lock helper are executable"
}

test_node_hosted_pi_process_identity() {
  local rec dir home fakebin socket out pane_pid
  rec=$(make_case node-pi)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  tmux -L "$socket" new-session -d -s firstmate "exec node '$home/bin/pi' --model openai-codex/gpt-5.6-sol"
  tmux -L "$socket" set-option -q -t firstmate @firstmate_home "$home"
  tmux -L "$socket" set-option -q -t firstmate @firstmate_harness pi
  pane_pid=$(tmux -L "$socket" display-message -p -t firstmate:0.0 '#{pane_pid}')
  printf '%s\n' "$pane_pid" > "$home/state/.lock"
  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/unused.log" --pi)
  assert_contains "$out" 'harness=pi' "Node-hosted Pi with Codex model was misclassified"
  [ ! -e "$dir/unused.log" ] || fail "Node-hosted Pi attach launched another harness"
  kill_case "$socket"
  pass "Node-hosted Pi identity ignores model argument substrings"
}

test_existing_session_requires_positive_identity() {
  local rec dir home fakebin socket out status log pane_pid holder
  rec=$(make_case session-identity)
  IFS='|' read -r dir home fakebin socket <<EOF
$rec
EOF
  tmux -L "$socket" new-session -d -s firstmate 'sleep 300'
  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/untagged.log" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "untagged generic session was adopted"
  assert_contains "$out" 'not verified' "untagged session rejection was unclear"
  kill_case "$socket"

  log="$dir/codex.log"
  run_launch "$home" "$fakebin" "$socket" "$log" --codex >/dev/null
  wait_for_file "$log" || fail "Codex fixture did not start"
  tmux -L "$socket" respawn-pane -k -t firstmate:0.0 'exec -a pi sleep 300'
  pane_pid=$(tmux -L "$socket" display-message -p -t firstmate:0.0 '#{pane_pid}')
  printf '%s\n' "$pane_pid" > "$home/state/.lock"
  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/replaced.log" --codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "stale Codex metadata authorized a replacement Pi process"
  assert_contains "$out" 'already running on Pi' "replacement-process refusal did not use live harness identity"

  tmux -L "$socket" set-option -q -t firstmate @firstmate_harness pi
  bash -c 'exec -a codex sleep 300' & holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(run_launch "$home" "$fakebin" "$socket" "$dir/masked.log" --pi 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "tmux session masked a different live same-home lock"
  assert_contains "$out" 'does not own the authoritative live lock' "different-lock refusal was unclear"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  kill_case "$socket"
  pass "existing sessions require matching home, lock, metadata, and live process"
}

test_tracked_scripts_are_executable
test_parsing_rejections
test_harness_argv_and_invariants
test_bare_and_matching_attach_divergent_refusal
test_live_and_stale_lock_behavior
test_concurrent_launch_serialization
test_lock_live_pid_query_is_read_only
test_node_hosted_pi_process_identity
test_existing_session_requires_positive_identity
