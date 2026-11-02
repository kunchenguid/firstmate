#!/usr/bin/env bash
# tests/fm-backend-hc.test.sh - fake-hc-CLI unit tests for the herdr-core
# session-provider adapter (bin/backends/hc.sh) and its dispatcher arms in
# bin/fm-backend.sh. tests/fm-backend-hc-smoke.test.sh drives a real isolated
# hc core; this suite pins selection, identity, keys, liveness, and close
# behavior with a stub so it runs everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-tests)

# The stub answers `get` from <dir>/<address>.json (exit from <address>.exit,
# 3 = not_found when no file exists), `ls` from <dir>/ls.json, `run` with
# <dir>/run.json, and removes <address>.json on `rm` unless <dir>/rm-sticks
# exists. Every call is logged with its HC_SESSION and HC_SOCKET.
make_hc_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
{
  printf 'HC_SESSION=%s HC_SOCKET=%s' "${HC_SESSION:-}" "${HC_SOCKET:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
cmd=${1:-}
last=""
for a in "$@"; do last=$a; done
case "$cmd" in
  --version) printf 'hc %s\n' "${FAKE_HC_VERSION:-0.1.14}" ;;
  server) printf '{"live":0}\n' ;;
  connect)
    IFS= read -r _req || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":%s}}\n' "${FAKE_HC_GENERATION:-1}"
    ;;
  ls) cat "$D/ls.json" 2>/dev/null || printf '{"terminals":[]}\n' ;;
  run) cat "$D/run.json" ;;
  get)
    [ -f "$D/$last.exit" ] && exit "$(cat "$D/$last.exit")"
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  rm) [ -e "$D/rm-sticks" ] || rm -f "$D/$last.json"; printf '{}\n' ;;
  read) printf 'screen of %s\n' "$last" ;;
  send)
    if [ -f "$D/send.exit" ]; then
      printf '{"error":{"kind":"%s"}}\n' "$(cat "$D/send.kind" 2>/dev/null || echo blocked)" >&2
      exit "$(cat "$D/send.exit")"
    fi
    cat "$D/send.json" 2>/dev/null || printf '{"started":true,"wait":{"status":"working"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/hc"
  printf '%s\n' "$fb"
}

# Each case runs in its own shell with a fresh stub directory and home.
setup_case() {  # <name> -> sets D, FB, HOMEDIR
  D="$TMP_ROOT/$1"
  mkdir -p "$D"
  FB=$(make_hc_fakebin "$D")
  HOMEDIR="$D/home"
  mkdir -p "$HOMEDIR"
}

# hc_shell <script>: run <script> in bash with the adapter sourced against the
# stub. FM_HC_BIN pins the stub so an inherited FM_HC_BIN or an installed
# herdr-core never wins; CASE_HC_BIN overrides it for binary-resolution cases.
# HOMETAG is exported so the script can build matching labels.
hc_shell() {  # <script>
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN=${CASE_HC_BIN:-$FB/hc} \
    FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    HC_SESSION=fmtest bash -c '
      . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
      fm_backend_source hc || { echo "source failed" >&2; exit 90; }
      HOMETAG=$(fm_backend_hometag)
      '"$1"
}

# terminal_json <address> <state> <task-label> <home> <fg-name> <fg-argv0>
write_terminal() {
  jq -n --arg a "$2" --arg s "$3" --arg t "$4" --arg h "$5" --arg n "$6" --arg v "$7" '
    {address: $a, state: $s, labels: {"firstmate.task": $t, "firstmate.home": $h},
     cwd: "/start", foreground: (if $n == "" then null else {name: $n, argv: [$v], cwd: "/live", pid: 1} end)}' \
    > "$1/$2.json"
}

hometag_of() {
  FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

# expect_refused <cmd...>: the command must exit nonzero.
expect_refused() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a refusal from: ${*: -1}"
}

FM_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_hc_is_spawn_capable_and_never_autodetected() {
  local out
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_validate_spawn hc && echo spawn-ok
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID TERM_PROGRAM REX_BLOCK __CFBundleIdentifier
    HC_TERMINAL_ID=t7 HC_SESSION=x fm_backend_detect >/dev/null && echo detected || echo not-detected
    fm_backend_required_tools hc' 2>&1)
  assert_contains "$out" spawn-ok "hc must be spawn-capable"
  assert_contains "$out" not-detected "an inherited HC_TERMINAL_ID must not select hc"
  assert_contains "$out" "hc jq treehouse" "hc needs hc, jq and treehouse"
  pass "hc: explicit-only, spawn-capable, with its tool set"
}

test_create_task_is_independent_labeled_and_refuses_duplicates() {
  local out tag
  setup_case create
  printf '{"address":"t9"}\n' > "$D/run.json"
  out=$(hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj')
  assert_equals "$out" t9 "create_task prints the new address"
  tag=$(hometag_of)
  out=$(grep $'\x1frun\x1f' "$D/log")
  for want in HC_SESSION=fmtest --no-parent --outlive-parent --no-notify $'--cwd\x1f/proj' \
    "firstmate.task=fm-a1" "firstmate.home=$tag" "herdr.space=fm-$tag" "herdr.tab=$tag-fm-a1"; do
    assert_contains "$out" "$want" "hc run must carry $want"
  done
  printf '{"terminals":[{"address":"t9"}]}\n' > "$D/ls.json"
  : > "$D/log"
  expect_refused hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj'
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "a live duplicate must not start a second terminal"
  pass "hc: create_task starts an independent labeled terminal and refuses a duplicate"
}

test_control_interrupt_delivers_the_harness_keys() {
  local tag out rc=0 id=hcint1
  setup_case interrupt
  tag=$(hometag_of)
  write_terminal "$D" t2 live "fm-$id" "$tag" 2.1.312 claude
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data"
  printf 'window=fmtest:t2\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\nbackend=hc\nhc_session=fmtest\nhc_terminal=t2\n' \
    "$id" "$D" "$D" > "$HOMEDIR/state/$id.meta"
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" FM_CONTROL_POLL=0.05 \
    "$FM_TEST_ROOT/bin/fm-control.sh" "$id" interrupt 2>&1) || rc=$?
  expect_code 0 "$rc" "interrupt on an hc task should succeed"$'\n'"$out"
  assert_contains "$(grep $'\x1fkeys\x1f' "$D/log")" $'keys\x1f--json\x1ft2\x1f--\x1fesc' "interrupt must press Escape on the recorded terminal"
  pass "hc: fm-control interrupt delivers the harness's interrupt key"
}

test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close() {
  local tag
  setup_case foreign
  tag=$(hometag_of)
  write_terminal "$D" t3 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t4 live fm-a1 other-home zsh /bin/zsh
  write_terminal "$D" t5 live "" "" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t3 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t4 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t5'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t4'
  assert_not_contains "$(cat "$D/log")" $'\x1fkeys\x1f' "no key may reach a foreign terminal"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "no foreign terminal may be closed"
  pass "hc: another task's, another home's, or an unlabeled terminal gets no input and no close"
}

test_invalid_session_never_reaches_hc() {
  setup_case session
  expect_refused hc_shell 'fm_backend_hc_cli "" ls'
  expect_refused hc_shell 'fm_backend_send_key hc :t2 Enter'
  assert_equals "$(cat "$D/log" 2>/dev/null)" "" "an empty or malformed session must not call hc"
  pass "hc: an empty session never falls through to the ambient core"
}

# hc 0.1.14 lets an exported HC_SOCKET win over HC_SESSION, so an inherited one
# would send every call to another core.
test_inherited_socket_never_overrides_the_session() {
  setup_case socket
  HC_SOCKET=/elsewhere/other.sock hc_shell 'fm_backend_hc_cli fmtest ls' >/dev/null
  assert_contains "$(cat "$D/log")" "HC_SESSION=fmtest HC_SOCKET="$'\x1f'"ls" "hc must run with HC_SOCKET unset"
  pass "hc: an inherited HC_SOCKET never overrides the session pin"
}

test_agent_state_classifies_foreground_and_absence() {
  local tag out
  setup_case state
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" 2.1.312 claude
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  write_terminal "$D" t3 finished fm-a1 "$tag" "" ""
  write_terminal "$D" t4 live fm-a1 "$tag" node node
  write_terminal "$D" t5 live fm-a1 "$tag" "" ""
  printf '1\n' > "$D/t6.exit"
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'for a in t1 t2 t3 t4 t5 t6 t7; do printf "%s=%s " $a "$(fm_backend_agent_state hc fmtest:$a)"; done')
  assert_equals "$out" "t1=alive t2=dead t3=missing t4=ambiguous t5=unreadable t6=unreadable t7=missing " \
    "agent_state over claude, shell, finished, other, no foreground, core error, not found"
  pass "hc: agent_state maps foreground, finished, not_found and core errors onto the shared vocabulary"
}

test_agent_state_reads_a_shell_wrappers_group() {
  local tag out wrapper
  setup_case wrapper
  tag=$(hometag_of)
  # A shell wrapper in its own process group, waiting on a harness child.
  set -m
  bash -c '(exec -a claude sleep 30); :' &
  wrapper=$!
  set +m
  write_terminal "$D" t9 live fm-a1 "$tag" bash bash
  jq --argjson p "$wrapper" '.foreground.pid = $p' "$D/t9.json" > "$D/t9.tmp" && mv "$D/t9.tmp" "$D/t9.json"
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -g "$wrapper" -f '^claude' >/dev/null && break; sleep 0.1; done
  out=$(hc_shell 'fm_backend_agent_state hc fmtest:t9')
  kill -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  assert_equals "$out" alive "a shell wrapper running a harness child is alive"
  pass "hc: agent_state reads a shell wrapper's process group before calling it dead"
}

test_kill_proves_the_terminal_is_gone() {
  local tag
  setup_case kill
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "closing a live own terminal must succeed"
  assert_contains "$(cat "$D/log")" $'\x1fkill\x1f--json\x1ft1' "kill must end the program"
  assert_contains "$(cat "$D/log")" $'\x1frm\x1f--json\x1ft1' "kill must remove the terminal"
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "an already-gone terminal is a silent success"
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  touch "$D/rm-sticks"
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t2'
  pass "hc: kill ends and removes the terminal and refuses when it survives"
}

test_kill_refuses_another_tasks_terminal() {
  local tag
  setup_case kill-label
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t1 "" fm-a1'
  [ -f "$D/t1.json" ] || fail "another task's terminal must stay alive"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "another task's terminal must not be closed"
  hc_shell 'fm_backend_kill hc fmtest:t2 "" fm-a1' || fail "closing the task's own labeled terminal must succeed"
  [ ! -f "$D/t2.json" ] || fail "the task's own terminal must be removed"
  pass "hc: teardown's expected label refuses another task's terminal and closes the matching one"
}

test_capture_and_current_path_read_the_recorded_terminal() {
  local tag out
  setup_case read
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  out=$(hc_shell 'fm_backend_capture hc fmtest:t1 40 fm-a1; fm_backend_visible_capture hc fmtest:t1 fm-a1; fm_backend_hc_current_path fmtest:t1 fm-a1')
  assert_contains "$out" "screen of t1" "capture reads the recorded terminal"
  assert_contains "$out" "/live" "current_path prefers the foreground cwd"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f40\x1ft1' "capture asks for the requested history"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f0\x1ft1' "visible capture reads the screen only"
  pass "hc: capture, visible capture, and current path read the recorded terminal"
}

test_endpoint_validation_binds_hc_meta() {
  local meta out
  setup_case meta
  meta="$D/a1.meta"
  printf 'window=fmtest:t4\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 && echo "$FM_BACKEND_VALIDATED_BACKEND $FM_BACKEND_VALIDATED_TARGET"')
  assert_equals "$out" "hc fmtest:t4" "a consistent hc record validates to its target"
  printf 'window=fmtest:t5\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  expect_refused bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 2>/dev/null'
  pass "hc: endpoint validation requires window to equal hc_session:hc_terminal"
}

test_container_ensure_gates_binary_version_and_generation() {
  local out
  setup_case gate
  out=$(hc_shell 'fm_backend_hc_container_ensure')
  assert_equals "$out" fmtest "container_ensure prints the session after every gate passes"
  : > "$D/log"
  FAKE_HC_VERSION=0.1.9 expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_VERSION=bogus expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_GENERATION=2 expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_GENERATION=1 hc_shell 'fm_backend_hc_container_ensure' >/dev/null \
    || fail "generation 1 must be accepted"
  assert_contains "$(cat "$D/log")" $'\x1fconnect\x1f' "container_ensure must run the hello handshake"
  pass "hc: container_ensure refuses a misnamed, old, or wrong-generation binary"
}

test_send_text_submit_confirms_through_send_wait() {
  local tag out log
  setup_case submit
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" empty "a started turn confirms the submit"
  log=$(grep $'\x1fsend\x1f' "$D/log")
  assert_contains "$log" $'--wait\x1f--timeout\x1f' "submit must confirm through send --wait"
  assert_contains "$log" $'\x1f--\x1fdeploy now' "the text must arrive after the -- delimiter"
  printf '9\n' > "$D/send.exit"
  printf 'blocked\n' > "$D/send.kind"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1' 2>&1)
  assert_contains "$out" unknown "a blocked terminal is unknown, never forced"
  assert_contains "$out" blocked "the refusal must name the blocked cause"
  printf '11\n' > "$D/send.exit"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" send-failed "a finished terminal is send-failed"
  printf '3\n' > "$D/send.exit"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" send-failed "a missing terminal is send-failed"
  rm -f "$D/send.exit" "$D/send.kind"
  printf '{"started":null,"wait":{"status":"idle","timed_out":true}}\n' > "$D/send.json"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" unknown "a silent program falls back to the composer screen, which cannot prove empty on a plain pane"
  pass "hc: send_text_submit proves the turn through send --wait and never forces a blocked terminal"
}

test_send_delimiters_and_binary_socket_pins() {
  local tag out
  setup_case pins
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  hc_shell 'fm_backend_hc_send_text_line fmtest:t1 "-rf / --force" fm-a1' \
    || fail "send_text_line must accept flag-looking text"
  assert_contains "$(cat "$D/log")" $'send\x1f--json\x1ft1\x1f--\x1f-rf / --force' \
    "flag-looking text must arrive after the -- delimiter"
  out=$(FM_HC_SOCKET=/tmp/pinned.sock hc_shell 'fm_backend_hc_cli fmtest ls'; cat "$D/log")
  assert_contains "$out" "HC_SOCKET=/tmp/pinned.sock" "FM_HC_SOCKET must pin the socket for the call"
  CASE_HC_BIN=/nonexistent/hc expect_refused hc_shell 'fm_backend_hc_cli fmtest ls'
  mkdir -p "$D/pinned"
  cp "$FB/hc" "$D/pinned/hc"
  out=$(CASE_HC_BIN="$D/pinned/hc" hc_shell 'fm_backend_hc_bin')
  assert_equals "$out" "$D/pinned/hc" "FM_HC_BIN must win over an hc on PATH"
  pass "hc: send text is -- delimited, and FM_HC_BIN/FM_HC_SOCKET pin the call"
}

test_required_tool_check_uses_the_adapter_resolver() {
  local out
  setup_case tools
  mkdir -p "$D/core-only" "$D/none"
  cp "$FB/hc" "$D/core-only/herdr-core"
  out=$(env -u FM_HC_BIN PATH="$D/core-only:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo core-only-ok' 2>&1)
  assert_contains "$out" core-only-ok "a herdr-core-only install must satisfy the hc tool check"
  out=$(FM_HC_BIN="$FB/hc" PATH="$D/none:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo pinned-ok' 2>&1)
  assert_contains "$out" pinned-ok "an FM_HC_BIN-only install must satisfy the hc tool check"
  out=$(FM_HC_BIN=/nonexistent/hc PATH="$FB:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo found || echo missing' 2>&1)
  assert_contains "$out" missing "an unusable FM_HC_BIN must report hc missing even with hc on PATH"
  pass "hc: the bootstrap tool check resolves hc exactly as the adapter does"
}

fm_test_run \
  test_hc_is_spawn_capable_and_never_autodetected \
  test_required_tool_check_uses_the_adapter_resolver \
  test_create_task_is_independent_labeled_and_refuses_duplicates \
  test_control_interrupt_delivers_the_harness_keys \
  test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close \
  test_invalid_session_never_reaches_hc \
  test_inherited_socket_never_overrides_the_session \
  test_agent_state_classifies_foreground_and_absence \
  test_agent_state_reads_a_shell_wrappers_group \
  test_kill_proves_the_terminal_is_gone \
  test_kill_refuses_another_tasks_terminal \
  test_capture_and_current_path_read_the_recorded_terminal \
  test_endpoint_validation_binds_hc_meta \
  test_container_ensure_gates_binary_version_and_generation \
  test_send_text_submit_confirms_through_send_wait \
  test_send_delimiters_and_binary_socket_pins
