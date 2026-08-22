#!/usr/bin/env bash
# Portable public-interface regressions for Firstmate's Lavish runtime router.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-route)
ROUTER="$ROOT/bin/fm-lavish.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
export FM_LAVISH_TESTING=1

make_windows_stubs() { # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/wslpath" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = -w ] || exit 2
printf 'WIN::%s\n' "$2"
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
: "${FM_LAVISH_TEST_LOG:?}"
printf '<call>\n' >> "$FM_LAVISH_TEST_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$FM_LAVISH_TEST_LOG"; done
exit "${FM_LAVISH_TEST_POWERSHELL_EXIT:-0}"
SH
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'linux-cli-was-called\n' >> "${FM_LAVISH_TEST_LOG:?}"
exit 99
SH
  chmod +x "$fakebin/wslpath" "$fakebin/powershell.exe" "$fakebin/lavish-axi"
  printf '%s\n' "$fakebin"
}

assert_line_count() { # <file> <line> <expected> <message>
  local file=$1 line=$2 expected=$3 message=$4 actual
  actual=$(grep -Fxc "$line" "$file" 2>/dev/null || true)
  [ "$actual" -eq "$expected" ] || fail "$message (expected $expected, got $actual)"
}

test_wsl_lifecycle_uses_one_windows_route() {
  local dir fakebin artifact real expected bridge_line log
  dir="$TMP_ROOT/windows-route"
  mkdir -p "$dir/reviews with spaces/# section"
  artifact="$dir/reviews with spaces/# section/review #1.html"
  printf '<h1>review</h1>\n' > "$artifact"
  real=$(realpath "$artifact")
  fakebin=$(make_windows_stubs "$dir")
  log="$dir/calls.log"
  : > "$log"

  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" open "$artifact" --label 'A # choice' \
    || fail "the WSL open route failed"
  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" poll "$artifact" --agent-reply 'same # session' \
    || fail "the WSL poll route failed"

  bridge_line="<WIN::$ROOT/bin/fm-lavish-windows.ps1>"
  assert_line_count "$log" '<call>' 2 "open and poll did not each invoke exactly one runtime"
  assert_line_count "$log" "$bridge_line" 2 "open and poll did not use the same tracked Windows bridge"
  assert_line_count "$log" "<WIN::$real>" 2 "the exact canonical artifact identity was not preserved"
  assert_line_count "$log" '<open>' 1 "the Windows route did not receive one open action"
  assert_line_count "$log" '<poll>' 1 "the Windows route did not receive one poll action"
  assert_line_count "$log" '<A # choice>' 1 "an open argument containing spaces and # was split or changed"
  assert_line_count "$log" '<same # session>' 1 "a poll argument containing spaces and # was split or changed"
  ! grep -Fq 'linux-cli-was-called' "$log" \
    || fail "WSL silently started the competing Linux Lavish CLI"
  pass "WSL open and poll preserve artifact identity on one Windows runtime route"
}

test_wsl_routes_every_lifecycle_action() {
  local dir fakebin artifact log action
  dir="$TMP_ROOT/windows-actions"
  mkdir -p "$dir"
  artifact="$dir/artifact.html"
  printf '<h1>review</h1>\n' > "$artifact"
  fakebin=$(make_windows_stubs "$dir")
  log="$dir/calls.log"
  : > "$log"

  for action in end export share; do
    FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
      PATH="$fakebin:$BASE_PATH" "$ROUTER" "$action" "$artifact" \
      || fail "the WSL $action route failed"
  done
  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" stop \
    || fail "the WSL stop route failed"
  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" setup \
    || fail "the tracked WSL setup route failed"

  for action in end export share stop setup; do
    assert_line_count "$log" "<$action>" 1 "the $action action did not use the Windows route exactly once"
  done
  assert_line_count "$log" '<call>' 5 "a lifecycle or setup action created a duplicate runtime invocation"
  ! grep -Fq 'linux-cli-was-called' "$log" \
    || fail "a WSL lifecycle action fell back to Linux"
  pass "every supported WSL live-session lifecycle action stays on Windows"
}

test_wsl_missing_prerequisite_refuses_without_fallback() {
  local dir fakebin artifact out rc log
  dir="$TMP_ROOT/windows-missing"
  mkdir -p "$dir/fakebin"
  artifact="$dir/artifact.html"
  log="$dir/calls.log"
  printf '<h1>review</h1>\n' > "$artifact"
  cat > "$dir/fakebin/wslpath" <<'SH'
#!/usr/bin/env bash
printf 'WIN::%s\n' "$2"
SH
  cat > "$dir/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'linux-cli-was-called\n' >> "${FM_LAVISH_TEST_LOG:?}"
exit 99
SH
  chmod +x "$dir/fakebin/wslpath" "$dir/fakebin/lavish-axi"
  : > "$log"

  set +e
  out=$(FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$dir/fakebin:$BASE_PATH" "$ROUTER" open "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "WSL continued without powershell.exe"
  printf '%s\n' "$out" | grep -F 'powershell.exe is unavailable' >/dev/null \
    || fail "the missing Windows prerequisite was not actionable: $out"
  ! grep -Fq 'linux-cli-was-called' "$log" \
    || fail "a missing Windows prerequisite fell back to Linux"
  pass "a missing Windows prerequisite refuses instead of falling back to Linux"
}

test_windows_runtime_failure_refuses_without_fallback() {
  local dir fakebin artifact log rc
  dir="$TMP_ROOT/windows-doctor-failure"
  mkdir -p "$dir"
  artifact="$dir/artifact.html"
  printf '<h1>review</h1>\n' > "$artifact"
  fakebin=$(make_windows_stubs "$dir")
  log="$dir/calls.log"
  : > "$log"

  set +e
  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    FM_LAVISH_TEST_POWERSHELL_EXIT=7 PATH="$fakebin:$BASE_PATH" \
    "$ROUTER" doctor 0.1.46 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 7 ] || fail "the Windows doctor failure was not preserved"
  assert_line_count "$log" '<doctor>' 1 "doctor did not query the Windows runtime"
  assert_line_count "$log" '<0.1.46>' 1 "doctor did not preserve the required version"
  ! grep -Fq 'linux-cli-was-called' "$log" \
    || fail "a failed Windows runtime check fell back to Linux"
  pass "an unavailable Windows Lavish runtime is an actionable refusal"
}

test_non_wsl_behavior_remains_native() {
  local dir fakebin artifact log
  dir="$TMP_ROOT/native"
  mkdir -p "$dir/fakebin"
  artifact="$dir/native review #1.html"
  log="$dir/calls.log"
  printf '<h1>native</h1>\n' > "$artifact"
  cat > "$dir/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
: "${FM_LAVISH_TEST_LOG:?}"
printf '<call>\n' >> "$FM_LAVISH_TEST_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$FM_LAVISH_TEST_LOG"; done
SH
  chmod +x "$dir/fakebin/lavish-axi"
  fakebin="$dir/fakebin"
  : > "$log"

  FM_LAVISH_RUNTIME_OVERRIDE=native FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" open "$artifact" --title 'Native # title' \
    || fail "native open failed"
  FM_LAVISH_RUNTIME_OVERRIDE=native FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" poll "$artifact" \
    || fail "native poll failed"

  assert_line_count "$log" "<$artifact>" 2 "native artifact argv changed"
  assert_line_count "$log" '<poll>' 1 "native poll did not preserve the published subcommand"
  assert_line_count "$log" '<Native # title>' 1 "native argv containing spaces and # changed"
  ! grep -Fq '<open>' "$log" \
    || fail "native open gained a subcommand that lavish-axi does not use"
  pass "non-WSL open and poll remain native and argv-compatible"
}

test_wsl_lifecycle_uses_one_windows_route
test_wsl_routes_every_lifecycle_action
test_wsl_missing_prerequisite_refuses_without_fallback
test_windows_runtime_failure_refuses_without_fallback
test_non_wsl_behavior_remains_native
