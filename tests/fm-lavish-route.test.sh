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
case "${1-}" in
  -w) printf 'WIN::%s\n' "$2" ;;
  -u)
    path=$2
    drive=${path%%:*}
    rest=${path#?:}
    rest=${rest//\\//}
    printf '/mnt/%s%s\n' "${drive,,}" "$rest"
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
: "${FM_LAVISH_TEST_LOG:?}"
printf '<call>\n' >> "$FM_LAVISH_TEST_LOG"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$FM_LAVISH_TEST_LOG"; done
case ":${WSLENV:-}:" in
  *:FM_LAVISH_WINDOWS_ARGV_JSON:*) ;;
  *) unset FM_LAVISH_WINDOWS_ARGV_JSON ;;
esac
if [ -n "${FM_LAVISH_WINDOWS_ARGV_JSON:-}" ]; then
  printf '<structured-argv>\n' >> "$FM_LAVISH_TEST_LOG"
  perl -MJSON::PP -e '
    my $args = decode_json($ARGV[0]);
    print "<$_>\n" for @$args;
  ' "$FM_LAVISH_WINDOWS_ARGV_JSON" >> "$FM_LAVISH_TEST_LOG"
fi
if [ "${FM_LAVISH_TEST_OUTPUT:-0}" = 1 ]; then
  action=${6-}
  artifact=${7-}
  case "$action" in
    open)
      printf 'session:\n  file: "%s"\n  url: "http://127.0.0.1:4388/session/test"\n  status: active\n' "$artifact"
      printf 'next_step: "Run `lavish-axi poll %s` now."\n' "$artifact"
      ;;
    poll)
      printf 'session:\n  file: "%s"\n  status: feedback\n' "$artifact"
      printf 'prompts[2]:\n  - text: "Captain quoted `lavish-axi poll C:\\\\Users\\\\private.html` in feedback"\n'
      printf '  - target:\n'
      printf '%s\n' '      scenePath: "C:\\Users\\Captain\\.lavish-axi\\whiteboards\\review #1.excalidraw"'
      printf '    attachments[1]{path}:\n'
      printf '%s\n' '      "C:\\Users\\Captain\\.lavish-axi\\attachments\\marked #1.png"'
      printf 'next_step: "Run `lavish-axi poll %s --agent-reply answer` again."\n' "$artifact"
      ;;
  esac
fi
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
  assert_line_count "$log" '<structured-argv>' 2 "dash-prefixed lifecycle argv did not cross the PowerShell boundary structurally"
  ! grep -Fq 'linux-cli-was-called' "$log" \
    || fail "WSL silently started the competing Linux Lavish CLI"
  pass "WSL open and poll preserve artifact identity on one Windows runtime route"
}

test_wsl_output_keeps_followup_on_router_and_exposes_feedback_paths() {
  local dir fakebin artifact real log out
  dir="$TMP_ROOT/windows-output"
  mkdir -p "$dir/reviews with spaces"
  artifact="$dir/reviews with spaces/review #1.html"
  printf '<h1>review</h1>\n' > "$artifact"
  real=$(realpath "$artifact")
  fakebin=$(make_windows_stubs "$dir")
  log="$dir/calls.log"
  : > "$log"

  out=$(FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    FM_LAVISH_TEST_OUTPUT=1 PATH="$fakebin:$BASE_PATH" \
    "$ROUTER" open "$artifact") \
    || fail "the WSL open output route failed"
  printf '%s\n' "$out" | grep -F "WSL artifact \\\"$real\\\"" >/dev/null \
    || fail "open output did not identify the original WSL artifact safely"
  ! printf '%s\n' "$out" | grep -F 'WIN::' >/dev/null \
    || fail "open output exposed the Windows artifact path"
  ! printf '%s\n' "$out" | grep -F '`lavish-axi poll' >/dev/null \
    || fail "open output could start a competing Linux Lavish session"

  out=$(FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    FM_LAVISH_TEST_OUTPUT=1 PATH="$fakebin:$BASE_PATH" \
    "$ROUTER" poll "$artifact") \
    || fail "the WSL poll output route failed"
  printf '%s\n' "$out" | grep -F '/mnt/c/Users/Captain/.lavish-axi/whiteboards/review #1.excalidraw' >/dev/null \
    || fail "poll output did not expose the whiteboard scene through a WSL path"
  printf '%s\n' "$out" | grep -F '/mnt/c/Users/Captain/.lavish-axi/attachments/marked #1.png' >/dev/null \
    || fail "poll output did not expose the image attachment through a WSL path"
  printf '%s\n' "$out" | grep -F "WSL artifact \\\"$real\\\"" >/dev/null \
    || fail "poll output did not identify the original WSL artifact safely"
  printf '%s\n' "$out" | grep -F "Captain quoted \`lavish-axi poll C:\\\\Users\\\\private.html\` in feedback" >/dev/null \
    || fail "poll output rewrote arbitrary captain feedback"
  ! printf '%s\n' "$out" | grep -F 'next_step: "Run `lavish-axi' >/dev/null \
    || fail "poll output could start a competing Linux Lavish session"
  pass "WSL output keeps follow-up routed and converts feedback paths"
}

test_wsl_export_converts_output_path() {
  local dir fakebin artifact output real_output log
  dir="$TMP_ROOT/windows-export"
  mkdir -p "$dir/reviews with spaces"
  artifact="$dir/reviews with spaces/review #1.html"
  output="$dir/reviews with spaces/export #1.html"
  real_output=$(realpath -m "$output")
  printf '<h1>review</h1>\n' > "$artifact"
  fakebin=$(make_windows_stubs "$dir")
  log="$dir/calls.log"
  : > "$log"

  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" export "$artifact" --out "$output" \
    || fail "the WSL export route failed"

  assert_line_count "$log" '<--out>' 1 "export did not preserve the path-valued option through structured argv"
  assert_line_count "$log" "<WIN::$real_output>" 1 "export did not convert its output path for Windows"
  pass "WSL export writes to the requested converted output path"
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
    PATH="$fakebin:$BASE_PATH" "$ROUTER" stop --port 4390 \
    || fail "the WSL stop route failed"
  FM_LAVISH_RUNTIME_OVERRIDE=windows FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" setup \
    || fail "the tracked WSL setup route failed"

  for action in end export share stop setup; do
    assert_line_count "$log" "<$action>" 1 "the $action action did not use the Windows route exactly once"
  done
  assert_line_count "$log" '<call>' 5 "a lifecycle or setup action created a duplicate runtime invocation"
  assert_line_count "$log" '<--port>' 1 "the WSL stop route dropped its port option"
  assert_line_count "$log" '<4390>' 1 "the WSL stop route changed its port value"
  assert_line_count "$log" '<structured-argv>' 4 "a lifecycle argument list bypassed structured forwarding"
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
  FM_LAVISH_RUNTIME_OVERRIDE=native FM_LAVISH_TEST_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" "$ROUTER" stop --port 4390 \
    || fail "native stop with a published port argument failed"

  assert_line_count "$log" "<$artifact>" 2 "native artifact argv changed"
  assert_line_count "$log" '<poll>' 1 "native poll did not preserve the published subcommand"
  assert_line_count "$log" '<stop>' 1 "native stop did not preserve the published subcommand"
  assert_line_count "$log" '<--port>' 1 "native stop dropped its port option"
  assert_line_count "$log" '<4390>' 1 "native stop changed its port value"
  assert_line_count "$log" '<Native # title>' 1 "native argv containing spaces and # changed"
  ! grep -Fq '<open>' "$log" \
    || fail "native open gained a subcommand that lavish-axi does not use"
  pass "non-WSL open and poll remain native and argv-compatible"
}

test_wsl_lifecycle_uses_one_windows_route
test_wsl_output_keeps_followup_on_router_and_exposes_feedback_paths
test_wsl_export_converts_output_path
test_wsl_routes_every_lifecycle_action
test_wsl_missing_prerequisite_refuses_without_fallback
test_windows_runtime_failure_refuses_without_fallback
test_non_wsl_behavior_remains_native
