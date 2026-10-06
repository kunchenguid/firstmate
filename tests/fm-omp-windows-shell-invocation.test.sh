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
SH
cat >"$project/bin/fm-arm-pretool-check.sh" <<SH
#!$real_bash
printf 'arm:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
SH
cat >"$project/bin/fm-turnend-guard.sh" <<SH
#!$real_bash
cat >/dev/null
printf 'turnend:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
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
# to the real bash so the fake helpers actually run.
shim="$TMP_ROOT/shim"
mkdir -p "$shim"
cat >"$shim/bash" <<SH
#!$real_bash
printf 'bash-invoked:%s\n' "\$*" >> "\$FM_WINDOWS_SHELL_LOG"
exec "$real_bash" "\$@"
SH
chmod +x "$shim/bash"

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

expect_log() {
  local log=$1 expected=$2 contents
  contents=$(cat "$log")
  case "$contents" in
    *"$expected"*) ;;
    *) fail "missing '$expected' in:\n$contents" ;;
  esac
}

run_driver() {
  local mode=$1 log=$2 path_prefix=${3:-}
  EXT="$project/.omp/extensions/fm-primary-turnend-guard.ts" \
  DRIVER_MODE="$mode" \
  PLATFORM_OVERRIDE="$platform_override" \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" \
  FM_WINDOWS_SHELL_LOG="$log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
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

pass "omp session-start, pre-tool, turn-end, and operational-input seams invoke Bash owners through bash on native Windows and degrade silently when bash cannot run"
