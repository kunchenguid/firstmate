#!/usr/bin/env bash
# tests/fm-zai-windows-identity.test.sh - zai engine identity over Windows chains.
#
# zai (the herdr-fork primary engine, a node bundle running zai-cli) is
# identified only through process ancestry - it publishes no env marker - and
# on MSYS-style Windows hosts that ancestry must come from the hybrid
# /proc-then-CIM walk in bin/fm-windows-process-lib.sh. This suite pins, with
# no real Windows or real zai required:
#   - the shared matcher's zai verdicts in bin/fm-session-lock-lib.sh,
#   - the Windows ancestry twin's climb semantics (climb to the first harness
#     match, stop at the first non-harness ancestor, claude contiguous-run),
#   - pid liveness over the CIM enumeration,
#   - bin/fm-harness.sh and bin/fm-lock.sh end to end over a simulated
#     MSYS Windows host: a fake uname (MINGW) selects the Windows branch and
#     FM_WINDOWS_ANCESTRY_PS feeds a synthetic identity chain, so both real
#     enumeration halves stay out of the deterministic path.
#
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-zai-win) || exit 1

# Build a fakebin that makes every consumer believe it is on an MSYS Windows
# host and answers the chain enumeration from FM_FAKE_WIN_CHAIN (identity lines
# with literal \037 escapes and \n separators, innermost first).
make_windows_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/$1")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "MINGW64_NT-10.0-26200"
SH
  chmod +x "$fakebin/uname"
  cat > "$fakebin/fake-chain-ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *-Filter*)
    # Liveness mode: answer only for pids the synthetic chain knows, plus the
    # optional extra foreign holder a test registers.
    line=$(printf '%b' "${FM_FAKE_WIN_CHAIN:-}" | grep -F -- "$(printf '%s\037' "$FM_LOCK_WINPID")")
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      exit 0
    fi
    if [ -n "${FM_FAKE_FOREIGN_LINE:-}" ] && [ "$FM_LOCK_WINPID" = "${FM_FAKE_FOREIGN_PID:-}" ]; then
      printf '%s\n' "$FM_FAKE_FOREIGN_LINE"
      exit 0
    fi
    exit 1
    ;;
esac
printf '%b' "${FM_FAKE_WIN_CHAIN:-}"
SH
  chmod +x "$fakebin/fake-chain-ps"
  printf '%s\n' "$fakebin"
}

# Emit one synthetic identity line with real US separators.
chain_line() {  # <pid> <comm> <args>
  printf '%s\037%s\037%s\n' "$1" "$2" "$3"
}

ZAI_ARGS='node.exe C:/Users/dev/AppData/Roaming/npm/node_modules/zai-cli/dist/cli.js'

# --- the shared lock-lib matcher ---------------------------------------------

test_matcher_zai_node_bundle() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches "node.exe" "$ZAI_ARGS"
    printf '%s-%s' "$?" "$FM_HARNESS_IS_CLAUDE"
  ) || fail "matcher: sourcing the session-lock lib failed"
  assert_equals "0-0" "$out" "matcher: node.exe running zai-cli matches as zai, not claude"
}

test_matcher_zai_repo_checkout() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches "node.exe" "node.exe /home/dev/work/harness/zai/dist/cli.js"
    printf '%s' "$?"
  ) || fail "matcher: sourcing the session-lock lib failed"
  assert_equals "0" "$out" "matcher: node.exe running a zai repo checkout matches as zai"
}

test_matcher_plain_bash_never_zai() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches "bash.exe" 'bash.exe -c bin/fm-crew-state.sh tm-1'
    printf '%s' "$?"
  ) || fail "matcher: sourcing the session-lock lib failed"
  assert_equals "1" "$out" "matcher: an ordinary bash.exe child is not a harness"
}

test_matcher_herdr_wrapper_never_harness() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches "herdr.exe" '"C:/Program Files/Herdr/bin/herdr.exe" server'
    printf '%s' "$?"
  ) || fail "matcher: sourcing the session-lock lib failed"
  assert_equals "1" "$out" "matcher: the herdr wrapper is not the session engine"
}

# --- the Windows ancestry twin ------------------------------------------------

# The lib is sourced once per subshell; tests override fm_windows_ancestry_lines
# with a synthetic chain, so the real /proc and CIM halves stay out of the way.

test_windows_twin_stops_at_engine() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_host_is_windows() { return 0; }
    fm_windows_ancestry_lines() {
      chain_line 501 bash.exe 'bash.exe -c ls'
      chain_line 502 node.exe "$ZAI_ARGS"
      chain_line 503 herdr.exe 'herdr.exe server'
    }
    fm_harness_ancestry_pids_windows
  ) || fail "windows twin: the walk found no harness"
  assert_equals "502" "$out" "windows twin: the innermost zai-cli node hop is the whole ancestry"
}

test_windows_twin_claude_contiguous_run() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_host_is_windows() { return 0; }
    fm_windows_ancestry_lines() {
      chain_line 601 bash.exe 'bash.exe -c hook'
      chain_line 602 claude 'claude bg-pty-host'
      chain_line 603 claude 'claude'
      chain_line 604 pwsh.exe 'pwsh.exe -NoExit'
    }
    fm_harness_ancestry_pids_windows
  ) || fail "windows twin: the claude walk found no harness"
  assert_equals "602
603" "$out" "windows twin: a claude run reports its contiguous chain, stopping at pwsh"
}

test_windows_twin_no_harness_is_empty() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_host_is_windows() { return 0; }
    fm_windows_ancestry_lines() {
      chain_line 701 bash.exe 'bash.exe -c ls'
      chain_line 702 pwsh.exe 'pwsh.exe -NoExit'
    }
    fm_harness_ancestry_pids_windows
    printf '%s' "$?"
  ) || fail "windows twin: consuming an empty verdict failed"
  assert_equals "1" "$out" "windows twin: a chain without a harness returns nothing"
}

test_windows_pid_alive_verdicts() {
  local out
  out=$(
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_host_is_windows() { return 0; }
    fm_windows_process_line() {
      case $1 in
        802) chain_line 802 node.exe "$ZAI_ARGS" ;;
        803) chain_line 803 bash.exe 'bash.exe -c ls' ;;
        *) return 1 ;;
      esac
    }
    fm_harness_pid_alive 802 && printf 'engine=alive '
    fm_harness_pid_alive 803 || printf 'shell=not-harness '
    fm_harness_pid_alive 804 || printf 'dead=not-alive'
  ) || fail "pid liveness: sourcing the session-lock lib failed"
  assert_equals "engine=alive shell=not-harness dead=not-alive" "$out" \
    "pid liveness: alive engine true, plain shell and dead pid false"
}

# --- end to end over a simulated MSYS Windows host ---------------------------

test_fm_harness_prints_zai() {
  local fakebin out
  fakebin=$(make_windows_fakebin harness-e2e)
  FM_FAKE_WIN_CHAIN="$(chain_line 901 bash.exe 'bash.exe -c run')\\n$(chain_line 902 node.exe "$ZAI_ARGS")\\n$(chain_line 903 herdr.exe 'herdr.exe server')\\n" \
    FM_WINDOWS_ANCESTRY_PS="$fakebin/fake-chain-ps" \
    FM_ROOT_OVERRIDE="$TMP_ROOT/e2e-home" PATH="$fakebin:$PATH" \
    bash "$ROOT/bin/fm-harness.sh" > "$TMP_ROOT/harness.out" 2>&1
  out=$(cat "$TMP_ROOT/harness.out")
  assert_equals "zai" "$out" "fm-harness.sh: simulated Windows chain resolves zai"
}

test_fm_harness_unknown_without_engine() {
  local fakebin out
  fakebin=$(make_windows_fakebin harness-e2e-none)
  FM_FAKE_WIN_CHAIN="$(chain_line 911 bash.exe 'bash.exe -c run')\\n$(chain_line 912 herdr.exe 'herdr.exe server')\\n" \
    FM_WINDOWS_ANCESTRY_PS="$fakebin/fake-chain-ps" \
    FM_ROOT_OVERRIDE="$TMP_ROOT/e2e-home-none" PATH="$fakebin:$PATH" \
    bash "$ROOT/bin/fm-harness.sh" > "$TMP_ROOT/harness-none.out" 2>&1
  out=$(cat "$TMP_ROOT/harness-none.out")
  assert_equals "unknown" "$out" "fm-harness.sh: a chain without an engine stays unknown"
}

test_fm_lock_acquires_engine_pid() {
  local fakebin home out
  fakebin=$(make_windows_fakebin lock-e2e)
  home=$TMP_ROOT/lock-home
  mkdir -p "$home/state"
  FM_FAKE_WIN_CHAIN="$(chain_line 921 bash.exe 'bash.exe -c run')\\n$(chain_line 922 node.exe "$ZAI_ARGS")\\n$(chain_line 923 herdr.exe 'herdr.exe server')\\n" \
    FM_WINDOWS_ANCESTRY_PS="$fakebin/fake-chain-ps" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    PATH="$fakebin:$PATH" \
    bash "$ROOT/bin/fm-lock.sh" > "$TMP_ROOT/lock.out" 2>&1
  out=$(cat "$TMP_ROOT/lock.out")
  assert_contains "$out" "lock acquired: harness pid 922" \
    "fm-lock.sh: the simulated zai engine pid holds the session lock"
  assert_equals "922" "$(cat "$home/state/.lock")" "fm-lock.sh: the lock file records the engine pid"
}

test_fm_lock_refuses_foreign_holder() {
  local fakebin home out
  fakebin=$(make_windows_fakebin lock-e2e-foreign)
  home=$TMP_ROOT/lock-home-foreign
  mkdir -p "$home/state"
  printf '932\n' > "$home/state/.lock"
  # A live foreign harness (932) holds the lock; this session's engine is 933.
  FM_FAKE_WIN_CHAIN="$(chain_line 931 bash.exe 'bash.exe -c run')\\n$(chain_line 933 node.exe "$ZAI_ARGS")\\n" \
    FM_FAKE_FOREIGN_PID=932 FM_FAKE_FOREIGN_LINE="$(chain_line 932 node.exe "$ZAI_ARGS")" \
    FM_WINDOWS_ANCESTRY_PS="$fakebin/fake-chain-ps" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    PATH="$fakebin:$PATH" \
    bash "$ROOT/bin/fm-lock.sh" > "$TMP_ROOT/lock-foreign.out" 2>&1
  out=$(cat "$TMP_ROOT/lock-foreign.out")
  assert_contains "$out" "another live firstmate session holds the lock" \
    "fm-lock.sh: a live foreign holder keeps this session read-only"

  # The same stale pid with the foreign engine gone releases the lock to us.
  FM_FAKE_WIN_CHAIN="$(chain_line 941 bash.exe 'bash.exe -c run')\\n$(chain_line 942 node.exe "$ZAI_ARGS")\\n" \
    FM_WINDOWS_ANCESTRY_PS="$fakebin/fake-chain-ps" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    PATH="$fakebin:$PATH" \
    bash "$ROOT/bin/fm-lock.sh" > "$TMP_ROOT/lock-takeover.out" 2>&1
  out=$(cat "$TMP_ROOT/lock-takeover.out")
  assert_contains "$out" "lock acquired: harness pid 942" \
    "fm-lock.sh: a stale lock is taken over by the live session"
}

test_matcher_zai_node_bundle && pass "matcher: node.exe running the zai-cli bundle matches as zai, not claude"
test_matcher_zai_repo_checkout && pass "matcher: node.exe running a zai repo checkout matches as zai"
test_matcher_plain_bash_never_zai && pass "matcher: an ordinary bash.exe child is never a harness"
test_matcher_herdr_wrapper_never_harness && pass "matcher: the herdr wrapper is not the session engine"
test_windows_twin_stops_at_engine && pass "windows twin: the walk reports the innermost zai-cli node hop only"
test_windows_twin_claude_contiguous_run && pass "windows twin: a claude run reports its contiguous chain"
test_windows_twin_no_harness_is_empty && pass "windows twin: a chain without a harness returns nothing"
test_windows_pid_alive_verdicts && pass "pid liveness: alive engine true, plain shell and dead pid false"
test_fm_harness_prints_zai && pass "fm-harness.sh: simulated Windows chain resolves zai"
test_fm_harness_unknown_without_engine && pass "fm-harness.sh: a chain without an engine stays unknown"
test_fm_lock_acquires_engine_pid && pass "fm-lock.sh: the simulated zai engine pid holds the session lock"
test_fm_lock_refuses_foreign_holder && pass "fm-lock.sh: a live foreign holder blocks; a stale one is taken over"
