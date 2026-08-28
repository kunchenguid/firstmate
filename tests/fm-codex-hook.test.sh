#!/usr/bin/env bash
# Behavior tests for the tracked Codex hook transport, including cmd.exe's
# native Windows parsing path when that host is available.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-hook)
FIXTURE="$TMP_ROOT/firstmate root with spaces"
SCAN_LOG="$TMP_ROOT/ancestry-scans"
mkdir -p "$FIXTURE/bin" "$FIXTURE/.codex"
: > "$FIXTURE/AGENTS.md"
cp "$ROOT/.codex/hooks.json" "$FIXTURE/.codex/hooks.json"
cp "$ROOT/bin/fm-codex-hook.sh" "$FIXTURE/bin/fm-codex-hook.sh"
cp "$ROOT/bin/fm-codex-hook.cmd" "$FIXTURE/bin/fm-codex-hook.cmd"
chmod +x "$FIXTURE/bin/fm-codex-hook.sh"
cat > "$FIXTURE/bin/fm-session-lock-lib.sh" <<'SH'
fm_harness_ancestry_pid() {
  printf 'scan\n' >> "$FM_TEST_SCAN_LOG"
  printf '610\n'
}
SH
export FM_TEST_SCAN_LOG="$SCAN_LOG"

for target in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-turnend-guard.sh; do
  cat > "$FIXTURE/bin/$target" <<'SH'
#!/usr/bin/env bash
printf 'target=%s\n' "$(basename "$0")"
printf 'session_pid=%s\n' "${FM_SESSION_HARNESS_PID:-}"
cat
SH
  chmod +x "$FIXTURE/bin/$target"
done

exercise_hook() {  # <jq-path> <command-field> <expected-target>
  local query=$1 field=$2 expected=$3 command payload out status=0
  command=$(jq -r "$query.$field // empty" "$FIXTURE/.codex/hooks.json")
  [ -n "$command" ] || fail "$field is missing for $expected"
  payload=$(jq -cn --arg expected "$expected" '{hook_event_name:"fixture",expected:$expected}')
  if [ "$field" = commandWindows ]; then
    out=$(printf '%s' "$payload" | (cd "$FIXTURE" && env -u FM_SESSION_HARNESS_PID MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /s /c "$command") 2>&1) || status=$?
  else
    out=$(printf '%s' "$payload" | (cd "$FIXTURE" && env -u FM_SESSION_HARNESS_PID bash -c "$command") 2>&1) || status=$?
  fi
  [ "$status" -eq 0 ] || fail "$field transport for $expected exited $status: $out"
  assert_contains "$out" "target=$expected" "$field did not dispatch to $expected"
  assert_contains "$out" "$payload" "$field did not preserve stdin for $expected"
  case "$expected" in
    fm-sessionstart-run.sh) assert_contains "$out" "session_pid=610" "$field did not export SessionStart ownership" ;;
    *)
      case "$out" in
        *session_pid=610*) fail "$field resolved SessionStart ownership for $expected" ;;
      esac
      ;;
  esac
}

exercise_all() {  # <command-field>
  local field=$1
  exercise_hook '.hooks.SessionStart[0].hooks[0]' "$field" fm-sessionstart-run.sh
  exercise_hook '.hooks.PreToolUse[0].hooks[0]' "$field" fm-arm-pretool-check.sh
  exercise_hook '.hooks.PreToolUse[0].hooks[1]' "$field" fm-cd-pretool-check.sh
  exercise_hook '.hooks.Stop[0].hooks[0]' "$field" fm-turnend-guard.sh
}

rm -f "$SCAN_LOG"
exercise_all command
[ "$(wc -l < "$SCAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "POSIX lifecycle hooks performed more than the SessionStart ancestry scan"
pass "Codex hook transport: POSIX commands dispatch all tracked hooks with stdin intact"

test_login_profile_dependency() {
  local home no_login_bin login_bin jq_path command payload out status=0
  home="$TMP_ROOT/profile-home"
  no_login_bin="$TMP_ROOT/no-login-bin"
  login_bin="$TMP_ROOT/login-bin"
  jq_path=$(command -v jq) || fail "jq is required to prepare the login-profile regression"
  mkdir -p "$home" "$no_login_bin" "$login_bin"
  cat > "$no_login_bin/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$no_login_bin/jq"
  ln -s "$jq_path" "$login_bin/jq"
  if PATH="$no_login_bin:$PATH" "$no_login_bin/jq" --version >/dev/null 2>&1; then
    fail "profile-free fixture unexpectedly has a working jq"
  fi
  printf 'OSTYPE=linux-gnu\nPATH=%q:%q:$PATH\nexport PATH\n' "$login_bin" "$no_login_bin" > "$home/.bash_profile"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$FIXTURE/.codex/hooks.json")
  payload=$(jq -cn '{hook_event_name:"fixture",expected:"profile-jq"}')
  out=$(printf '%s' "$payload" | (
    cd "$FIXTURE" && env -u FM_SESSION_HARNESS_PID HOME="$home" PATH="$no_login_bin:$PATH" bash -c "$command"
  ) 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "login-profile hook transport exited $status: $out"
  assert_contains "$out" "target=fm-turnend-guard.sh" "login profile did not provide jq to the dispatcher"
  assert_contains "$out" "$payload" "login-profile hook transport did not preserve stdin"
  pass "Codex hook transport: POSIX login profile supplies dispatcher dependencies"
}

test_login_profile_dependency

if command -v cmd.exe >/dev/null 2>&1; then
  rm -f "$SCAN_LOG"
  exercise_all commandWindows
  [ "$(wc -l < "$SCAN_LOG" | tr -d ' ')" = 1 ] \
    || fail "native Windows lifecycle hooks performed more than the SessionStart ancestry scan"
  pass "Codex hook transport: native Windows commands survive cmd.exe and preserve stdin"
else
  pass "Codex hook transport: native Windows command path skipped (cmd.exe unavailable)"
fi
