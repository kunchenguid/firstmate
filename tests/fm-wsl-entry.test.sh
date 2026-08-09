#!/usr/bin/env bash
# Behavior tests for the repository-root Windows batch launcher and its
# deterministic WSL-side entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENTRY="$ROOT/bin/fm-wsl-entry.sh"
BATCH="$ROOT/firstmate.bat"
ATTRIBUTES="$ROOT/.gitattributes"
TMP_ROOT=$(fm_test_tmproot fm-wsl-entry)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P) || fail "could not resolve the test temp root"

make_entry_fixture() {  # <root>
  local fixture=$1
  mkdir -p "$fixture/bin"
  cp "$ENTRY" "$fixture/bin/fm-wsl-entry.sh"
  chmod +x "$fixture/bin/fm-wsl-entry.sh"
}

make_fake_launcher() {  # <root>
  cat > "$1/bin/fm-launch.sh" <<'SH'
#!/usr/bin/env bash
printf 'cwd=[%s]\n' "$PWD"
i=0
for arg in "$@"; do
  i=$((i + 1))
  printf 'arg%d=[%s]\n' "$i" "$arg"
done
exit "${FM_FAKE_LAUNCH_EXIT:-0}"
SH
  chmod +x "$1/bin/fm-launch.sh"
}

test_wsl_entry_preserves_root_arguments_and_status() {
  local fixture="$TMP_ROOT/Firstmate repo with spaces" out status=0
  make_entry_fixture "$fixture"
  make_fake_launcher "$fixture"

  out=$(cd / && FM_FAKE_LAUNCH_EXIT=23 "$fixture/bin/fm-wsl-entry.sh" \
    --print-menu "value with spaces" "" 2>&1) || status=$?

  expect_code 23 "$status" "WSL entry launcher status"
  assert_contains "$out" "cwd=[$fixture]" \
    "the WSL entry must launch from the repository it belongs to"
  assert_contains "$out" "arg1=[--print-menu]" \
    "the first launcher argument must pass through"
  assert_contains "$out" "arg2=[value with spaces]" \
    "an argument containing spaces must remain one argument"
  assert_contains "$out" "arg3=[]" \
    "an empty launcher argument must remain present"
  pass "fm-wsl-entry: repository paths with spaces, arguments, and exit status pass through unchanged"
}

test_wsl_entry_missing_launcher_is_actionable() {
  local fixture="$TMP_ROOT/missing launcher" out status=0
  make_entry_fixture "$fixture"

  out=$("$fixture/bin/fm-wsl-entry.sh" 2>&1) || status=$?

  expect_code 1 "$status" "missing launcher status"
  assert_contains "$out" "$fixture/bin/fm-launch.sh" \
    "the refusal must name the missing launcher"
  assert_contains "$out" "Update this Firstmate copy" \
    "the refusal must tell the operator how to repair the copy"
  pass "fm-wsl-entry: a missing fleet launcher refuses with an actionable repair"
}

to_windows_path() {  # <path>
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -aw "$1"
  elif command -v wslpath >/dev/null 2>&1; then
    wslpath -aw "$1"
  else
    return 1
  fi
}

test_batch_constructs_one_deterministic_wsl_command() {
  local case_root="$TMP_ROOT/batch case" batch_root="$TMP_ROOT/batch case/Firstmate root with spaces"
  local fake="$case_root/fake-wsl.cmd" runner="$case_root/run-test.cmd" log="$case_root/wsl-args.log"
  local fake_win runner_win log_win batch_root_win out status=0

  if ! command -v cmd.exe >/dev/null 2>&1; then
    pass "firstmate.bat: native command construction is covered on the Windows CI lane"
    return 0
  fi

  mkdir -p "$batch_root/bin"
  cp "$BATCH" "$batch_root/firstmate.bat"
  : > "$batch_root/bin/fm-wsl-entry.sh"

  fake_win=$(to_windows_path "$fake") || fail "could not map the fake WSL command to Windows"
  runner_win=$(to_windows_path "$runner") || fail "could not map the batch test runner to Windows"
  log_win=$(to_windows_path "$log") || fail "could not map the batch log to Windows"
  batch_root_win=$(to_windows_path "$batch_root") || fail "could not map the batch fixture to Windows"

  printf '%s\r\n' \
    '@echo off' \
    '> "%FIRSTMATE_WSL_TEST_LOG%" echo arg1=[%~1]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg2=[%~2]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg3=[%~3]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg4=[%~4]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg5=[%~5]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg6=[%~6]' \
    '>> "%FIRSTMATE_WSL_TEST_LOG%" echo arg7=[%~7]' \
    'exit /b %FIRSTMATE_FAKE_EXIT%' > "$fake"

  printf '%s\r\n' \
    '@echo off' \
    "set \"FIRSTMATE_WSL_EXE=$fake_win\"" \
    "set \"FIRSTMATE_WSL_TEST_LOG=$log_win\"" \
    'set "FIRSTMATE_FAKE_EXIT=37"' \
    'set "FIRSTMATE_NO_PAUSE=1"' \
    "call \"$batch_root_win\\firstmate.bat\" --print-menu \"two words\"" \
    'exit /b %ERRORLEVEL%' > "$runner"

  out=$(MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "$runner_win" 2>&1) || status=$?

  expect_code 37 "$status" "Windows batch bridge status"
  assert_grep 'arg1=[--cd]' "$log" "the batch bridge must set WSL's working directory"
  assert_grep "arg2=[$batch_root_win\\.]" "$log" \
    "the quoted Windows repository path must remain one argument"
  assert_grep 'arg3=[--exec]' "$log" "the batch bridge must bypass the distribution login shell"
  assert_grep 'arg4=[/bin/bash]' "$log" "the batch bridge must select bash explicitly"
  assert_grep 'arg5=[./bin/fm-wsl-entry.sh]' "$log" \
    "the batch bridge must enter through the tracked WSL helper"
  assert_grep 'arg6=[--print-menu]' "$log" "the first forwarded argument must be unchanged"
  assert_grep 'arg7=[two words]' "$log" "a forwarded argument with spaces must stay intact"
  assert_contains "$out" "Exit status: 37" \
    "a failed WSL command must report its propagated status"
  assert_contains "$out" "wsl --install" \
    "a failed WSL command must print an actionable WSL repair"
  pass "firstmate.bat: one explicit WSL command preserves a spaced root, arguments, and exit status"
}

test_checkout_pins_bridge_line_endings() {
  local attrs

  assert_present "$ATTRIBUTES" \
    "the repository must ship .gitattributes so every checkout normalizes the bridge"

  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    pass "bridge line endings: checkout normalization is covered from a git checkout"
    return 0
  fi

  attrs=$(git -C "$ROOT" check-attr eol -- firstmate.bat bin/fm-wsl-entry.sh 2>&1) \
    || fail "could not read the checkout attributes for the bridge"

  assert_contains "$attrs" "firstmate.bat: eol: crlf" \
    "cmd.exe terminates lines with CRLF, so checkouts must deliver firstmate.bat as CRLF"
  assert_contains "$attrs" "bin/fm-wsl-entry.sh: eol: lf" \
    "bash rejects CR-terminated scripts, so checkouts must deliver the WSL entry as LF"
  pass "bridge line endings: checkouts deliver a CRLF batch launcher and an LF WSL entry"
}

test_wsl_entry_preserves_root_arguments_and_status
test_wsl_entry_missing_launcher_is_actionable
test_batch_constructs_one_deterministic_wsl_command
test_checkout_pins_bridge_line_endings
