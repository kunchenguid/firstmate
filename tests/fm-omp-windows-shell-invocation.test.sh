#!/usr/bin/env bash
# Native-Windows omp extension regression for invoking tracked Bash owners through bash.
# Runs on every platform: off Windows it overrides process.platform to win32 so the
# bash-routing path is exercised for real; platform-specific assertions branch instead
# of skipping.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-windows-shell-invocation)

if [ "$(node -p 'process.platform')" = win32 ]; then
  platform_override=""
else
  platform_override=win32
fi

project="$TMP_ROOT/project"
mkdir -p "$project/.omp/extensions" "$project/.pi/extensions/lib" "$project/bin" "$project/state"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$project/.omp/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$project/.pi/extensions/lib/"

# The fake helpers carry an absolute shebang: a /usr/bin/env shebang would
# resolve "bash" through the shim again and the kernel shebang recursion would
# run forever without the script body ever executing.
real_bash=$(command -v bash)
NODE=$(command -v node)

cat >"$project/bin/fm-sessionstart-run.sh" <<SH
#!$real_bash
printf 'sessionstart:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-cd-pretool-check.sh" <<SH
#!$real_bash
printf 'cd:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
case " \$FM_VERDICT2 " in
  *" fm-cd-pretool-check.sh "*) printf 'cd deny\n' >&2; exit 2 ;;
esac
SH
cat >"$project/bin/fm-arm-pretool-check.sh" <<SH
#!$real_bash
printf 'arm:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
case " \$FM_VERDICT2 " in
  *" fm-arm-pretool-check.sh "*) printf 'arm deny\n' >&2; exit 2 ;;
esac
SH
cat >"$project/bin/fm-turnend-guard.sh" <<SH
#!$real_bash
cat >/dev/null
printf 'turnend:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
case " \$FM_VERDICT2 " in
  *" fm-turnend-guard.sh "*) printf 'turnend deny\n' >&2; exit 2 ;;
esac
SH
cat >"$project/bin/fm-operational-input.sh" <<SH
#!$real_bash
printf 'operational:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
input=\$(cat)
if [ "\$1" = encode ]; then
  printf 'encoded:%s:%s\n' "\$2" "\$input"
else
  printf 'not-operational\n'
fi
SH
chmod +x "$project/bin/"*.sh

# The shim shadows bash on PATH and records every bash invocation with its
# argv, proving the extension routed the helper through bash, then hands off
# to the real bash so the fake helpers actually run. When a script is named in
# FM_WSL127_SCRIPTS the shim refuses its first invocation with bash's own
# "cannot resolve the script" 127, simulating a WSL-launcher PATH bash that
# rejects the MSYS path form; later invocations hand off normally.
shim="$TMP_ROOT/shim"
mkdir -p "$shim"
cat >"$shim/bash" <<SH
#!$real_bash
printf 'bash-invoked:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
script_base=\$(basename "\$1" 2>/dev/null || true)
case " \$FM_WSL127_SCRIPTS " in
  *" \$script_base "*)
    countfile="\$FM_WSL127_COUNTDIR/\$script_base"
    count=0
    [ -f "\$countfile" ] && count=\$(cat "\$countfile")
    count=\$((count + 1))
    printf '%s\n' "\$count" >"\$countfile"
    if [ "\$count" -eq 1 ]; then
      printf 'bash: %s: No such file or directory\n' "\$1" >&2
      exit 127
    fi
    ;;
esac
exec "$real_bash" "\$@"
SH
chmod +x "$shim/bash"

opshim="$TMP_ROOT/opshim"
mkdir -p "$opshim"
cat >"$opshim/bash" <<SH
#!$real_bash
printf 'op-bash:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
case "\$1" in
  /mnt/d/*)
    input=\$(cat)
    printf 'encoded:%s:%s\n' "\$3" "\$input"
    ;;
  *)
    printf 'bash: %s: No such file or directory\n' "\$1" >&2
    exit 127
    ;;
esac
SH
chmod +x "$opshim/bash"

cat >"$TMP_ROOT/driver.mjs" <<'JS'
import { pathToFileURL } from "node:url";

if (process.env.PLATFORM_OVERRIDE) {
  Object.defineProperty(process, "platform", { value: process.env.PLATFORM_OVERRIDE });
}

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?windows=${Date.now()}`);
extension.default(pi);
const ctx = { sessionManager: { getSessionId: () => "windows-test" } };

const results = {};
if (process.env.DRIVER_MODE === "full") {
  handlers.get("session_start")({ type: "session_start" }, ctx);
  const started = await handlers.get("before_agent_start")({}, ctx);
  results.beforeAgentStart = started ? "message" : "none";
}
const toolCall = await handlers.get("tool_call")({
  type: "tool_call",
  toolName: "bash",
  input: { command: "printf test" },
});
results.toolCall = toolCall && Object.keys(toolCall).length > 0 ? "blocked" : "allowed";
const sessionStop = await handlers.get("session_stop")({ stop_hook_active: false });
results.sessionStop = sessionStop === undefined ? "settled" : "continued";
console.log(`RESULTS:${JSON.stringify(results)}`);
JS

cat >"$TMP_ROOT/op-driver.mjs" <<'JS'
import { pathToFileURL } from "node:url";

if (process.env.PLATFORM_OVERRIDE) {
  Object.defineProperty(process, "platform", { value: process.env.PLATFORM_OVERRIDE });
}

const lib = await import(`${pathToFileURL(process.env.OPLIB).href}?op=${Date.now()}`);
console.log(`OPRESULT:${lib.encodeFirstmateOperationalInput("session-start", "hello digest")}`);
JS

expect_log() {
  local log=$1 expected=$2 contents
  contents=$(cat "$log")
  case "$contents" in
    *"$expected"*) ;;
    *) fail "missing '$expected' in:\n$contents" ;;
  esac
}

expect_count() {
  local log=$1 needle=$2 want=$3 got
  got=$(grep -c "$needle" "$log" || true)
  [ "$got" = "$want" ] || fail "expected $want lines matching '$needle' in $log, got $got:\n$(cat "$log")"
}

run_driver() {
  local mode=$1 log=$2 path_prefix=${3:-}
  EXT="$project/.omp/extensions/fm-primary-turnend-guard.ts" \
  DRIVER_MODE="$mode" \
  PLATFORM_OVERRIDE="$platform_override" \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" \
  FM_WINDOWS_SHELL_LOG="$log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
  FM_WSL127_SCRIPTS="${FM_WSL127_SCRIPTS-}" \
  FM_WSL127_COUNTDIR="${FM_WSL127_COUNTDIR-}" \
  FM_VERDICT2="${FM_VERDICT2-}" \
  PATH="${path_prefix}$shim:$PATH" \
    "$NODE" "$TMP_ROOT/driver.mjs"
}

log="$TMP_ROOT/full-calls"
out=$(run_driver full "$log" 2>&1)
status=$?
expect_code 0 "$status" "omp win32 bash-route driver"
expected='RESULTS:{"beforeAgentStart":"message","toolCall":"allowed","sessionStop":"settled"}'
[ "$out" = "$expected" ] || fail "unexpected driver results: $out (want $expected)"

# Every helper, including the session-start wrapper and the operational-input
# classifier, reached bash with the script as argv; the seatbelts stayed silent
# and the turn-end hook let the session settle.
expect_log "$log" "bash-invoked:$project/bin/fm-sessionstart-run.sh --source startup --pi-prerequisite"
expect_log "$log" "bash-invoked:$project/bin/fm-cd-pretool-check.sh --command printf test"
expect_log "$log" "bash-invoked:$project/bin/fm-arm-pretool-check.sh --command printf test"
expect_log "$log" "bash-invoked:$project/bin/fm-turnend-guard.sh"
expect_log "$log" "bash-invoked:$project/bin/fm-operational-input.sh kind"
expect_log "$log" "sessionstart:--source startup --pi-prerequisite"
expect_log "$log" "cd:--command printf test"
expect_log "$log" "arm:--command printf test"
expect_log "$log" "turnend:"
case "$(cat "$log")" in
  *\\*) fail "non-POSIX script path reached bash:\n$(cat "$log")" ;;
esac

# Native Windows only: address the extension through its native Windows-style
# path so the root-derived script paths carry drive letters and backslashes,
# and assert MSYS-POSIX conversion (/c/...) reached bash.
if [ -z "$platform_override" ] && command -v cygpath >/dev/null 2>&1; then
  win_project=$(cygpath -w "$project")
  posix_project=$(cygpath -u "$win_project")
  win_log="$TMP_ROOT/winpath-calls"
  EXT="$win_project\\.omp\\extensions\\fm-primary-turnend-guard.ts" \
  DRIVER_MODE=full \
  PLATFORM_OVERRIDE='' \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" \
  FM_WINDOWS_SHELL_LOG="$win_log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
  PATH="$shim:$PATH" \
    "$NODE" "$TMP_ROOT/driver.mjs" >/dev/null
  expect_log "$win_log" "bash-invoked:$posix_project/bin/fm-turnend-guard.sh"
  case "$(cat "$win_log")" in
    *"bash-invoked:$win_project"*) fail "native Windows path reached bash unconverted:\n$(cat "$win_log")" ;;
  esac
fi

# Degraded: bash cannot run at all (on win32 a bash.exe that is not a valid
# executable reproduces the synchronous EFTYPE throw; elsewhere an empty PATH
# entry reproduces the asynchronous spawn error). The pre-checks and the
# turn-end hook must still settle with code 0 instead of crashing the
# extension, which is the silent-degradation contract.
broken="$TMP_ROOT/broken"
mkdir -p "$broken"
if [ -z "$platform_override" ]; then
  printf 'not a valid executable\n' >"$broken/bash.exe"
fi
degraded_log="$TMP_ROOT/degraded-calls"
out=$(EXT="$project/.omp/extensions/fm-primary-turnend-guard.ts" \
  DRIVER_MODE=degraded \
  PLATFORM_OVERRIDE="$platform_override" \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" \
  FM_WINDOWS_SHELL_LOG="$degraded_log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
  PATH="$broken" \
    "$NODE" "$TMP_ROOT/driver.mjs" 2>&1)
status=$?
expect_code 0 "$status" "omp win32 degraded-bash driver"
expected='RESULTS:{"toolCall":"allowed","sessionStop":"settled"}'
[ "$out" = "$expected" ] || fail "unexpected degraded results: $out (want $expected)"
[ ! -e "$degraded_log" ] || fail "helpers ran without a working bash:\n$(cat "$degraded_log")"

# WSL-launcher bash: the shim refuses the first bash attempt of every
# extension-owned helper with bash's own 127, so the extension must retry once
# in the other path form and still reach the helper; off Windows both forms
# are the same POSIX path, so the retry visibly runs the helper there, while
# on native Windows the MSYS-first order keeps the retry observable only as a
# second bash invocation.
wsl_log="$TMP_ROOT/wsl127-calls"
wsl_countdir="$TMP_ROOT/wsl127-counts"
mkdir -p "$wsl_countdir"
FM_WSL127_SCRIPTS=" fm-sessionstart-run.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh fm-turnend-guard.sh fm-operational-input.sh "
FM_WSL127_COUNTDIR="$wsl_countdir"
out=$(run_driver full "$wsl_log" 2>&1)
status=$?
FM_WSL127_SCRIPTS=
expect_code 0 "$status" "omp win32 WSL-launcher retry driver"
expected='RESULTS:{"beforeAgentStart":"message","toolCall":"allowed","sessionStop":"settled"}'
[ "$out" = "$expected" ] || fail "unexpected WSL-launcher retry results: $out (want $expected)"
for script in fm-sessionstart-run.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh fm-turnend-guard.sh fm-operational-input.sh; do
  expect_count "$wsl_log" "bash-invoked:.*$script" 2
done
if [ -n "$platform_override" ]; then
  expect_log "$wsl_log" "sessionstart:--source startup --pi-prerequisite"
  expect_log "$wsl_log" "cd:--command printf test"
  expect_log "$wsl_log" "arm:--command printf test"
  expect_log "$wsl_log" "turnend:"
  expect_log "$wsl_log" "operational:kind"
fi

# The shared operational-input seam converts a native drive-letter script path
# to the MSYS form first and retries once in WSL mount form when that bash
# answers 127: the opshim refuses every form except /mnt/d/..., so a successful
# encode proves both the conversion and the retry engaged.
op_log="$TMP_ROOT/op-calls"
out=$(OPLIB="$project/.pi/extensions/lib/fm-operational-input.ts" \
  PLATFORM_OVERRIDE="$platform_override" \
  FM_OPERATIONAL_INPUT_SCRIPT='D:/fm/bin/fm-operational-input.sh' \
  FM_WINDOWS_SHELL_LOG="$op_log" \
  PATH="$opshim:$PATH" \
    "$NODE" "$TMP_ROOT/op-driver.mjs" 2>&1)
status=$?
expect_code 0 "$status" "win32 operational-input native-path retry driver"
[ "$out" = "OPRESULT:encoded:session-start:hello digest" ] ||
  fail "unexpected operational-input encode result: $out"
expect_count "$op_log" "op-bash:" 2
first_op_line=$(head -n 1 "$op_log")
[ "$first_op_line" = "op-bash:/d/fm/bin/fm-operational-input.sh encode session-start" ] ||
  fail "MSYS form was not attempted first:\n$(cat "$op_log")"
expect_log "$op_log" "op-bash:/mnt/d/fm/bin/fm-operational-input.sh encode session-start"

# A real helper verdict is never retried: with the arm seatbelt and the
# turn-end guard exiting 2, each must be invoked exactly once and the verdict
# must surface (tool blocked, session compelled to continue).
verdict_log="$TMP_ROOT/verdict2-calls"
FM_VERDICT2=" fm-arm-pretool-check.sh fm-turnend-guard.sh "
out=$(run_driver full "$verdict_log" 2>&1)
status=$?
FM_VERDICT2=
expect_code 0 "$status" "omp win32 verdict-2 no-retry driver"
expected='RESULTS:{"beforeAgentStart":"message","toolCall":"blocked","sessionStop":"continued"}'
[ "$out" = "$expected" ] || fail "unexpected verdict-2 results: $out (want $expected)"
expect_count "$verdict_log" "bash-invoked:.*fm-cd-pretool-check.sh" 1
expect_count "$verdict_log" "bash-invoked:.*fm-arm-pretool-check.sh" 1
expect_count "$verdict_log" "bash-invoked:.*fm-turnend-guard.sh" 1
expect_log "$verdict_log" "arm:--command printf test"
expect_log "$verdict_log" "turnend:"

pass "omp session-start, pre-tool, turn-end, and operational-input seams invoke Bash owners through bash on native Windows, retry once in the other path form when a WSL-launcher bash cannot resolve the script, never retry a real verdict, and degrade silently when bash cannot run"
