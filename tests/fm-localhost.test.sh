#!/usr/bin/env bash
# Behavior coverage for the cross-kernel localhost owner. The suite drives the
# public inspect/recover/verify interface through fake Windows kernel probes and
# real Git repositories; it never calls internal Python functions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity localhost-tests localhost-tests@example.invalid

HELPER="$ROOT/bin/fm-localhost.py"
TMP_ROOT=$(fm_test_tmproot fm-localhost-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
joined=$*
case "$joined" in
  *Stop-Process*)
    [ "${FM_WINDOWS_STOP_FAIL:-0}" != 1 ] || exit 1
    printf 'stop\n' >> "${FM_STOP_LOG:?}"
    : > "${FM_KILLED_MARKER:?}"
    if [ -n "${FM_MUTATE_EXPECTED_AFTER_STOP:-}" ]; then
      printf 'concurrent edit\n' >> "$FM_MUTATE_EXPECTED_AFTER_STOP"
    fi
    printf 'terminated\n'
    ;;
  *HttpClient*)
    printf 'route\n' >> "${FM_ROUTE_LOG:?}"
    : > "${FM_ROUTE_DONE_MARKER:?}"
    if [ -n "${FM_MUTATE_EXPECTED_DURING_ROUTE:-}" ] && [ ! -f "${FM_ROUTE_MUTATION_MARKER:?}" ]; then
      printf 'concurrent route edit\n' >> "$FM_MUTATE_EXPECTED_DURING_ROUTE"
      : > "$FM_ROUTE_MUTATION_MARKER"
    fi
    cat "${FM_WIN_ROUTE_JSON:?}"
    ;;
  *Get-NetTCPConnection*)
    [ "${FM_WINDOWS_INSPECTION_FAIL:-0}" != 1 ] || exit 1
    [ ! -f "${FM_KILLED_MARKER:?}" ] || [ "${FM_POST_STOP_WINDOWS_FAIL:-0}" != 1 ] || exit 1
    if [ -n "${FM_MUTATE_WSL_BRANCH_ON_INSPECT:-}" ] && [ ! -f "${FM_BRANCH_MUTATION_MARKER:?}" ]; then
      git -C "$FM_MUTATE_WSL_BRANCH_ON_INSPECT" switch -q -c feature
      : > "$FM_BRANCH_MUTATION_MARKER"
    fi
    if [ -f "${FM_ROUTE_DONE_MARKER:?}" ] && [ -n "${FM_WIN_POST_ROUTE_JSON:-}" ]; then
      cat "$FM_WIN_POST_ROUTE_JSON"
      exit 0
    fi
    if [ -f "${FM_KILLED_MARKER:?}" ] || [ "${FM_WIN_ALWAYS_RELAY:-0}" = 1 ]; then
      cat "${FM_WIN_RELAY_JSON:?}"
      exit 0
    fi
    count=0
    [ ! -f "${FM_INSPECT_COUNT:?}" ] || count=$(cat "$FM_INSPECT_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_INSPECT_COUNT"
    if [ "$count" -ge 4 ] && [ -n "${FM_WIN_FOURTH_JSON:-}" ]; then
      if [ -n "${FM_FOURTH_TASK_FILE:-}" ]; then
        printf 'project=%s\n' "${FM_FOURTH_TASK_PROJECT:?}" > "$FM_FOURTH_TASK_FILE"
      fi
      cat "$FM_WIN_FOURTH_JSON"
    elif [ "$count" -ge 3 ] && [ -n "${FM_WIN_THIRD_JSON:-}" ]; then
      if [ -n "${FM_THIRD_TASK_FILE:-}" ]; then
        printf 'project=%s\n' "${FM_THIRD_TASK_PROJECT:?}" > "$FM_THIRD_TASK_FILE"
      fi
      cat "$FM_WIN_THIRD_JSON"
    elif [ "$count" -ge 2 ] && [ -n "${FM_WIN_SECOND_JSON:-}" ]; then
      cat "$FM_WIN_SECOND_JSON"
    else
      cat "${FM_WIN_INITIAL_JSON:?}"
    fi
    ;;
  *) exit 2 ;;
esac
SH

cat > "$FAKEBIN/ss" <<'SH'
#!/usr/bin/env bash
set -u
show=0
case "${FM_WSL_MODE:-none}" in
  always) show=1 ;;
  after-launch) [ -f "${FM_LAUNCH_MARKER:?}" ] && show=1 ;;
esac
[ "${FM_WSL_INSPECTION_FAIL:-0}" != 1 ] || exit 1
[ ! -f "${FM_KILLED_MARKER:?}" ] || [ "${FM_POST_STOP_WSL_FAIL:-0}" != 1 ] || exit 1
if [ "$show" -eq 1 ]; then
  printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:* users:(("node",pid=%s,fd=20))\n' \
    "${FM_TEST_PORT:?}" "${FM_WSL_PID:?}"
  if [ -n "${FM_WSL_SECOND_PID:-}" ]; then
    printf 'LISTEN 0 4096 [::]:%s [::]:* users:(("node",pid=%s,fd=21))\n' \
      "${FM_TEST_PORT:?}" "$FM_WSL_SECOND_PID"
  fi
fi
SH

cat > "$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "${FM_NPM_LOG:?}"
: > "${FM_LAUNCH_MARKER:?}"
if [ "${FM_NPM_STAY_ALIVE:-0}" = 1 ]; then
  trap 'exit 0' TERM INT
  while :; do sleep 1; done
fi
SH

chmod +x "$FAKEBIN/powershell.exe" "$FAKEBIN/ss" "$FAKEBIN/npm"

write_listener_json() {
  local path=$1 port=$2 address=$3 pid=$4 process=$5 executable=$6 command=$7 creation=${8:-creation-$4}
  python3 - "$path" "$port" "$address" "$pid" "$process" "$executable" "$command" "$creation" <<'PY'
import json, sys
path, port, address, pid, process, executable, command, creation = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump([{"address": address, "port": int(port), "pid": int(pid),
                "creation": creation,
                "process": process, "executable": executable or None,
                "command": command or None}], handle)
PY
}

append_listener_json() {
  local path=$1 port=$2 address=$3 pid=$4 process=$5 executable=$6 command=$7 creation=${8:-creation-$4}
  python3 - "$path" "$port" "$address" "$pid" "$process" "$executable" "$command" "$creation" <<'PY'
import json, sys
path, port, address, pid, process, executable, command, creation = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    rows = json.load(handle)
rows.append({"address": address, "port": int(port), "pid": int(pid),
             "creation": creation,
             "process": process, "executable": executable or None,
             "command": command or None})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(rows, handle)
PY
}

make_case() {
  local dir="$TMP_ROOT/$1" seed="$TMP_ROOT/$1/seed"
  mkdir -p "$dir" "$seed"
  git -C "$seed" init -q -b main
  cat > "$seed/package.json" <<'JSON'
{"scripts":{"dev":"astro dev"}}
JSON
  printf 'node_modules/\n' > "$seed/.gitignore"
  printf 'canonical\n' > "$seed/page.txt"
  git -C "$seed" add package.json .gitignore page.txt
  git -C "$seed" commit -qm canonical
  git clone -q --bare "$seed" "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main

  mkdir -p "$dir/mount/c/repos"
  git clone -q "$dir/origin.git" "$dir/mount/c/repos/stale checkout"
  git clone -q "$dir/origin.git" "$dir/expected"
  mkdir -p "$dir/mount/c/repos/stale checkout/node_modules/astro"
  mkdir -p "$dir/expected/node_modules/astro"
  : > "$dir/mount/c/repos/stale checkout/node_modules/astro/astro.js"
  : > "$dir/expected/node_modules/astro/astro.js"
  printf 'stale local edit\n' >> "$dir/mount/c/repos/stale checkout/page.txt"

  mkdir -p "$dir/state" "$dir/proc/9200"
  printf 'node\n' > "$dir/proc/9200/comm"
  printf 'node\0%s\0dev\0--port\0%s\0' \
    "$dir/expected/node_modules/astro/astro.js" 43123 > "$dir/proc/9200/cmdline"
  ln -s "$dir/expected" "$dir/proc/9200/cwd"
  printf '{"status":200,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","length":4}\n' > "$dir/wsl-route.json"
  cp "$dir/wsl-route.json" "$dir/win-route.json"
  : > "$dir/stop.log"

  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev --token super-secret-value --header "X-Api-Key: header-secret" --json {"token":"json-secret"} --vm-id {1f662e3a-0323-4e37-a59f-304f0161cf55}'
  write_listener_json "$dir/win-relay.json" 43123 0.0.0.0 5100 wslrelay.exe \
    'C:\Windows\System32\wslrelay.exe' ''
  git -C "$dir/expected" rev-parse HEAD > "$dir/expected.sha"
  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1 mode=$2 out=$3
  shift 3
  rm -f "$dir/inspect-count" "$dir/killed" "$dir/launched" "$dir/npm.log"
  rm -f "$dir/route.log" "$dir/route-done"
  : > "$dir/stop.log"
  env \
    PATH="$FAKEBIN:$PATH" \
    WSL_DISTRO_NAME=TestDistro \
    FM_LOCALHOST_TESTING=1 \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_LOCALHOST_WINDOWS_MOUNT_ROOT="$dir/mount" \
    FM_LOCALHOST_PROC_ROOT="$dir/proc" \
    FM_LOCALHOST_TEST_WSL_ROUTE_JSON="$dir/wsl-route.json" \
    FM_LOCALHOST_START_TIMEOUT=1 \
    FM_TEST_PORT=43123 \
    FM_WSL_PID=9200 \
    FM_WSL_SECOND_PID="${FM_WSL_SECOND_PID:-}" \
    FM_LOCALHOST_TEST_LOCK_ATTEMPTS="${FM_LOCALHOST_TEST_LOCK_ATTEMPTS:-50}" \
    FM_MUTATE_WSL_BRANCH_ON_INSPECT="${FM_MUTATE_WSL_BRANCH_ON_INSPECT:-}" \
    FM_BRANCH_MUTATION_MARKER="$dir/branch-mutated" \
    FM_INSPECT_COUNT="$dir/inspect-count" \
    FM_WIN_INITIAL_JSON="$dir/win-initial.json" \
    FM_WIN_RELAY_JSON="$dir/win-relay.json" \
    FM_WIN_ROUTE_JSON="$dir/win-route.json" \
    FM_ROUTE_LOG="$dir/route.log" \
    FM_ROUTE_DONE_MARKER="$dir/route-done" \
    FM_KILLED_MARKER="$dir/killed" \
    FM_STOP_LOG="$dir/stop.log" \
    FM_LAUNCH_MARKER="$dir/launched" \
    FM_NPM_LOG="$dir/npm.log" \
    FM_NPM_STAY_ALIVE="${FM_NPM_STAY_ALIVE:-0}" \
    FM_WIN_THIRD_JSON="${FM_WIN_THIRD_JSON:-}" \
    FM_WIN_FOURTH_JSON="${FM_WIN_FOURTH_JSON:-}" \
    FM_THIRD_TASK_FILE="${FM_THIRD_TASK_FILE:-}" \
    FM_THIRD_TASK_PROJECT="${FM_THIRD_TASK_PROJECT:-}" \
    FM_FOURTH_TASK_FILE="${FM_FOURTH_TASK_FILE:-}" \
    FM_FOURTH_TASK_PROJECT="${FM_FOURTH_TASK_PROJECT:-}" \
    FM_WIN_POST_ROUTE_JSON="${FM_WIN_POST_ROUTE_JSON:-}" \
    FM_MUTATE_EXPECTED_AFTER_STOP="${FM_MUTATE_EXPECTED_AFTER_STOP:-}" \
    FM_MUTATE_EXPECTED_DURING_ROUTE="${FM_MUTATE_EXPECTED_DURING_ROUTE:-}" \
    FM_ROUTE_MUTATION_MARKER="$dir/route-mutated" \
    FM_POST_STOP_WINDOWS_FAIL="${FM_POST_STOP_WINDOWS_FAIL:-0}" \
    FM_POST_STOP_WSL_FAIL="${FM_POST_STOP_WSL_FAIL:-0}" \
    "$@" \
    "$HELPER" "$mode" "$dir/expected" 43123 "$(cat "$dir/expected.sha")" > "$out" 2>&1
}

test_listener_parsing_path_conversion_source_and_redaction() {
  local dir out
  dir=$(make_case inspect)
  out="$dir/out"
  FM_WSL_MODE=none run_case "$dir" inspect "$out" || fail "inspect should complete: $(cat "$out")"
  assert_grep 'owner_kernel=windows' "$out" "inspect omitted the Windows owner"
  assert_grep "checkout=$dir/mount/c/repos/stale checkout" "$out" "Windows drive path did not resolve to its checkout"
  assert_grep 'dirty=dirty' "$out" "inspect did not classify the stale source as dirty"
  assert_contains "$(cat "$out")" "checkout_windows=\\\\wsl.localhost\TestDistro\\" "WSL checkout did not convert to its Windows UNC path"
  assert_grep 'classification=native-windows-node-astro-dev' "$out" "Astro development server was not classified"
  assert_grep '--token <redacted>' "$out" "sensitive command flag was not redacted"
  assert_no_grep 'super-secret-value' "$out" "raw command secret reached output"
  assert_grep 'X-Api-Key: <redacted>' "$out" "header credential was not redacted"
  assert_no_grep 'header-secret' "$out" "header credential reached output"
  assert_no_grep 'json-secret' "$out" "JSON credential reached output"
  assert_no_grep '1f662e3a-0323-4e37-a59f-304f0161cf55' "$out" "raw local process identifier reached output"

  local unc_command
  unc_command="node.exe \"\\\\wsl.localhost\\TestDistro${dir//\//\\}\\mount\\c\\repos\\stale checkout\\node_modules\\astro\\astro.js\" dev"
  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 node.exe 'C:\Program Files\nodejs\node.exe' "$unc_command"
  FM_WSL_MODE=none run_case "$dir" inspect "$out" || fail "UNC inspect should complete: $(cat "$out")"
  assert_grep "checkout=$dir/mount/c/repos/stale checkout" "$out" "WSL UNC path did not resolve to its checkout"
  pass "localhost inspect parses listeners, converts Windows/WSL paths, classifies Git source, and redacts commands"
}

test_native_stale_windows_shadow_recovers_to_verified_pair() {
  local dir out
  dir=$(make_case recover)
  out="$dir/out"
  FM_WSL_MODE=after-launch run_case "$dir" recover "$out" || fail "eligible recovery failed: $(cat "$out")"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "recovery did not issue exactly one termination"
  assert_grep 'recovered-and-verified' "$out" "recovery did not verify the final pair"
  assert_grep 'terminated-exact-pid:4100' "$out" "recovery did not report the exact PID"
  assert_grep 'run dev -- --host 0.0.0.0 --port 43123' "$dir/npm.log" "recovery used an unexpected launcher"
  local evidence
  evidence=$(find "$dir/state/localhost-evidence" -type f -name '*.evidence' -print -quit)
  [ -n "$evidence" ] || fail "recovery did not write private evidence"
  [ "$(stat -c %a "$evidence")" = 600 ] || fail "private evidence mode is not 0600"
  pass "stale native Windows Astro shadow recovers by exact PID to wslrelay plus clean WSL and matching routes"
}

test_healthy_relay_and_clean_wsl_verify() {
  local dir out
  dir=$(make_case healthy)
  out="$dir/out"
  FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" verify "$out" || fail "healthy pair did not verify: $(cat "$out")"
  assert_grep $'verification\tverdict=pass' "$out" "healthy verification did not pass"
  [ ! -s "$dir/stop.log" ] || fail "verify attempted termination"
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" recover "$out"; then
    fail "wslrelay owner was accepted as a recovery target"
  fi
  assert_grep 'refuse:wslrelay-is-never-terminated' "$out" "wslrelay recovery refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "wslrelay refusal still called termination"
  pass "healthy wslrelay plus clean WSL server passes with matching browser-like route fingerprints"
}

test_relay_identity_requires_canonical_executable() {
  local dir out
  dir=$(make_case relay-identity)
  out="$dir/out"
  write_listener_json "$dir/win-relay.json" 43123 0.0.0.0 5100 wslrelay.exe '' ''
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" verify "$out"; then
    fail "relay with missing executable identity passed verification"
  fi
  assert_grep 'reason=windows-owner-is-not-wslrelay' "$out" "missing relay executable identity did not refuse"
  [ ! -s "$dir/route.log" ] || fail "missing relay executable identity reached route verification"

  write_listener_json "$dir/win-relay.json" 43123 0.0.0.0 5100 wslrelay.exe \
    'C:\Users\x\wslrelay.exe' ''
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" verify "$out"; then
    fail "relay outside the trusted Windows system path passed verification"
  fi
  assert_grep 'reason=windows-owner-is-not-wslrelay' "$out" "untrusted relay path did not refuse"
  [ ! -s "$dir/route.log" ] || fail "untrusted relay path reached route verification"
  pass "relay verification requires the trusted canonical Windows system identity"
}

test_same_owner_multiple_bindings_verify() {
  local dir out
  dir=$(make_case multiple-bindings)
  out="$dir/out"
  append_listener_json "$dir/win-relay.json" 43123 :: 5100 wslrelay.exe \
    'C:\Windows\System32\wslrelay.exe' ''
  FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" verify "$out" || fail "same-owner multiple bindings did not verify: $(cat "$out")"
  assert_grep $'verification\tverdict=pass' "$out" "same-owner multiple bindings did not pass"
  pass "same-owner multiple listener bindings remain a verified relay pair"
}

test_same_owner_multiple_bindings_recover() {
  local dir out
  dir=$(make_case multiple-bindings-recover)
  out="$dir/out"
  append_listener_json "$dir/win-initial.json" 43123 :: 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev --token super-secret-value --header "X-Api-Key: header-secret" --json {"token":"json-secret"} --vm-id {1f662e3a-0323-4e37-a59f-304f0161cf55}'
  FM_WSL_MODE=after-launch run_case "$dir" recover "$out" || fail "same-owner multiple stale bindings did not recover: $(cat "$out")"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "same-owner multiple bindings did not issue one exact termination"
  assert_grep 'recovered-and-verified' "$out" "same-owner multiple stale bindings did not verify"
  pass "same-owner multiple stale Windows bindings recover by one exact PID"
}

test_active_task_refuses_without_termination() {
  local dir out
  dir=$(make_case active-task)
  out="$dir/out"
  printf 'window=fm-live\nworktree=%s\nproject=%s\n' \
    "$dir/mount/c/repos/stale checkout" "$dir/mount/c/repos/stale checkout" > "$dir/state/live.meta"
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "active task checkout was terminated"
  fi
  assert_grep 'refuse:active-firstmate-task-associated' "$out" "active task refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "active task refusal still called termination"
  pass "active Firstmate task ownership refuses recovery without termination"
}

test_active_wsl_task_refuses_recovery_and_verification() {
  local dir out
  dir=$(make_case active-wsl-task)
  out="$dir/out"
  printf 'window=fm-live\nworktree=%s\nproject=%s\n' \
    "$dir/expected" "$dir/expected" > "$dir/state/live.meta"
  if FM_WSL_MODE=always run_case "$dir" recover "$out"; then
    fail "active WSL task ownership allowed Windows termination"
  fi
  assert_grep 'refuse:active-firstmate-task-associated' "$out" "active WSL task did not refuse recovery"
  [ ! -s "$dir/stop.log" ] || fail "active WSL task refusal still called termination"
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 run_case "$dir" verify "$out"; then
    fail "active WSL task ownership passed verification"
  fi
  assert_grep 'reason=active-firstmate-task-associated' "$out" "active WSL task did not refuse verification"
  [ ! -s "$dir/route.log" ] || fail "active WSL task reached route verification"
  pass "active WSL task ownership refuses recovery and verification"
}

test_multiple_wsl_owners_refuse_before_termination() {
  local dir out
  dir=$(make_case multiple-wsl-owners)
  out="$dir/out"
  mkdir -p "$dir/proc/9300"
  printf 'node\n' > "$dir/proc/9300/comm"
  printf 'node\0%s\0dev\0--port\0%s\0' \
    "$dir/expected/node_modules/astro/astro.js" 43123 > "$dir/proc/9300/cmdline"
  ln -s "$dir/expected" "$dir/proc/9300/cwd"
  if FM_WSL_MODE=always FM_WSL_SECOND_PID=9300 run_case "$dir" recover "$out"; then
    fail "multiple WSL owners allowed Windows termination"
  fi
  assert_grep 'refuse:ambiguous-wsl-ownership' "$out" "multiple WSL owners did not refuse recovery"
  [ ! -s "$dir/stop.log" ] || fail "ambiguous WSL ownership still called termination"
  pass "multiple WSL owners refuse recovery before mutation"
}

test_wsl_listener_must_remain_on_default_branch() {
  local dir out
  dir=$(make_case wsl-feature-branch)
  out="$dir/out"
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 FM_MUTATE_WSL_BRANCH_ON_INSPECT="$dir/expected" \
    run_case "$dir" verify "$out"; then
    fail "feature-branch WSL listener passed current-main verification"
  fi
  assert_grep 'reason=wsl-listener-identity-mismatch' "$out" "feature-branch WSL listener did not refuse"
  [ ! -s "$dir/route.log" ] || fail "feature-branch WSL listener reached route verification"
  pass "WSL listener verification requires the default branch"
}

test_production_like_wsl_and_launcher_refuse() {
  local dir out
  dir=$(make_case production-like)
  out="$dir/out"
  printf 'node\0%s\0dev\0--mode\0production\0' \
    "$dir/expected/node_modules/astro/astro.js" > "$dir/proc/9200/cmdline"
  if FM_WSL_MODE=always run_case "$dir" recover "$out"; then
    fail "production-like WSL Astro command was accepted"
  fi
  assert_grep 'refuse:wsl-port-owned-by-unexpected-process' "$out" "production-like WSL command did not refuse"
  [ ! -s "$dir/stop.log" ] || fail "production-like WSL command still called termination"

  cat > "$dir/expected/package.json" <<'JSON'
{"scripts":{"dev":"astro dev --mode production"}}
JSON
  git -C "$dir/expected" add package.json
  git -C "$dir/expected" commit -qm production-like
  git -C "$dir/expected" rev-parse HEAD > "$dir/expected.sha"
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "production-like project launcher was accepted"
  fi
  assert_grep 'refuse:project dev launcher is not proven to be Astro dev' "$out" "production-like project launcher did not refuse"
  [ ! -s "$dir/stop.log" ] || fail "production-like project launcher still called termination"
  pass "production-like WSL owners and project launchers refuse recovery"
}

test_task_state_lock_wait_is_bounded() {
  local dir out holder
  dir=$(make_case task-state-lock-timeout)
  out="$dir/out"
  mkfifo "$dir/lock-input"
  bash "$ROOT/bin/fm-task-state-lock.sh" "$dir/state" 50 < "$dir/lock-input" > "$dir/lock-output" &
  holder=$!
  exec 9>"$dir/lock-input"
  while ! grep -qx locked "$dir/lock-output" 2>/dev/null; do
    kill -0 "$holder" 2>/dev/null || fail "task-state lock holder exited before acquiring the lock"
    sleep 0.05
  done
  if FM_WSL_MODE=none FM_LOCALHOST_TEST_LOCK_ATTEMPTS=2 run_case "$dir" recover "$out"; then
    fail "contended task-state lock was accepted"
  fi
  assert_grep 'refuse:firstmate-task-state-boundary-timeout' "$out" "lock timeout did not produce a safe refusal"
  [ ! -s "$dir/stop.log" ] || fail "lock timeout still called termination"
  exec 9>&-
  wait "$holder" || fail "task-state lock holder did not release cleanly"
  pass "task-state publication lock contention refuses within a fixed bound"
}

test_pid_or_command_change_refuses_on_immediate_reresolution() {
  local dir out
  dir=$(make_case reresolve)
  out="$dir/out"
  write_listener_json "$dir/win-second.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev --host 127.0.0.1'
  if FM_WSL_MODE=none FM_WIN_SECOND_JSON="$dir/win-second.json" run_case "$dir" recover "$out"; then
    fail "PID reuse/change was accepted"
  fi
  assert_grep 'refuse:pid-or-command-reresolution-changed' "$out" "PID change refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "PID change refusal still called termination"

  write_listener_json "$dir/win-second.json" 43123 127.0.0.1 4101 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev'
  if FM_WSL_MODE=none FM_WIN_SECOND_JSON="$dir/win-second.json" run_case "$dir" recover "$out"; then
    fail "changed PID was accepted"
  fi
  assert_grep 'refuse:pid-or-command-reresolution-changed' "$out" "changed PID refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "changed PID refusal still called termination"

  write_listener_json "$dir/win-second.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev' \
    creation-reused
  if FM_WSL_MODE=none FM_WIN_SECOND_JSON="$dir/win-second.json" run_case "$dir" recover "$out"; then
    fail "reused PID with a different creation identity was accepted"
  fi
  assert_grep 'refuse:pid-or-command-reresolution-changed' "$out" "creation identity change was not reported"
  [ ! -s "$dir/stop.log" ] || fail "creation identity change still called termination"
  pass "PID or command change between observations refuses exact-PID recovery"
}

test_verify_revalidates_expected_checkout() {
  local dir out
  dir=$(make_case verify-checkout-revalidation)
  out="$dir/out"
  if FM_WSL_MODE=always FM_WIN_ALWAYS_RELAY=1 FM_MUTATE_EXPECTED_DURING_ROUTE="$dir/expected/page.txt" \
    run_case "$dir" verify "$out"; then
    fail "verify accepted a checkout changed during route fingerprinting"
  fi
  assert_grep 'reason=expected-checkout-dirty' "$out" "verify did not report the changed expected checkout"
  pass "verify revalidates the expected checkout after route inspection"
}

test_worker_with_astro_words_refuses() {
  local dir out
  dir=$(make_case worker)
  out="$dir/out"
  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\worker.js" --name astro dev'
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "worker command containing Astro words was accepted"
  fi
  assert_grep 'refuse:windows-process-is-not-proven-node-astro-dev' "$out" "worker command did not refuse"
  [ ! -s "$dir/stop.log" ] || fail "worker command refusal still called termination"
  pass "node worker commands containing Astro words refuse exact-PID recovery"
}

test_unknown_and_unrelated_windows_processes_refuse() {
  local dir out unrelated
  dir=$(make_case unknown)
  out="$dir/out"
  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 python.exe 'C:\Python\python.exe' ''
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "unknown Windows command was accepted"
  fi
  assert_grep 'refuse:windows-process-is-not-proven-node-astro-dev' "$out" "unknown command refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "unknown command refusal still called termination"

  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" preview'
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "production-like Astro preview process was accepted"
  fi
  assert_grep 'refuse:windows-process-is-not-proven-node-astro-dev' "$out" "production-like refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "production-like refusal still called termination"

  unrelated="$dir/unrelated.git"
  git clone -q --bare "$dir/seed" "$unrelated"
  git -C "$dir/mount/c/repos/stale checkout" remote set-url origin "$unrelated"
  write_listener_json "$dir/win-initial.json" 43123 127.0.0.1 4100 node.exe \
    'C:\Program Files\nodejs\node.exe' \
    '"C:\Program Files\nodejs\node.exe" "C:\repos\stale checkout\node_modules\astro\astro.js" dev'
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "unrelated Windows repository was accepted"
  fi
  assert_grep 'refuse:windows-process-is-unrelated' "$out" "unrelated repository refusal was not reported"
  [ ! -s "$dir/stop.log" ] || fail "unrelated repository refusal still called termination"
  pass "unknown commands and unrelated Windows repositories refuse without termination"
}

test_windows_inspection_failure_is_safe() {
  local dir out
  dir=$(make_case inspection-failure)
  out="$dir/out"
  if FM_WSL_MODE=none FM_WINDOWS_INSPECTION_FAIL=1 run_case "$dir" recover "$out"; then
    fail "Windows inspection failure was accepted"
  fi
  assert_grep 'refuse:windows-inspection-unavailable' "$out" "Windows inspection failure did not produce a safe refusal"
  [ ! -s "$dir/stop.log" ] || fail "inspection failure still called termination"
  pass "unavailable Windows inspection refuses recovery without mutation"
}

test_wsl_inspection_failure_is_safe() {
  local dir out
  dir=$(make_case wsl-inspection-failure)
  out="$dir/out"
  if FM_WSL_MODE=none FM_WSL_INSPECTION_FAIL=1 run_case "$dir" recover "$out"; then
    fail "WSL inspection failure was accepted"
  fi
  assert_grep 'refuse:wsl-inspection-unavailable' "$out" "WSL inspection failure did not produce a safe refusal"
  [ ! -s "$dir/stop.log" ] || fail "WSL inspection failure still called termination"
  pass "unavailable WSL inspection refuses recovery without mutation"
}

test_task_state_inspection_failure_is_safe() {
  local dir out
  dir=$(make_case task-state-inspection-failure)
  out="$dir/out"
  rmdir "$dir/state"
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "missing Firstmate task state was accepted"
  fi
  assert_grep 'refuse:firstmate-task-state-inspection-unavailable' "$out" "missing task state did not produce a safe refusal"
  [ ! -s "$dir/stop.log" ] || fail "missing task state still called termination"
  if FM_WSL_MODE=none run_case "$dir" inspect "$out"; then
    fail "inspect accepted missing Firstmate task state"
  fi
  assert_grep $'owner_kernel=firstmate\tstatus=unavailable' "$out" "inspect did not report missing task state"
  pass "unavailable Firstmate task-state inspection refuses recovery without termination"
}

test_verify_proves_pair_before_route_requests() {
  local dir out
  dir=$(make_case verify-order)
  out="$dir/out"
  if FM_WSL_MODE=none run_case "$dir" verify "$out"; then
    fail "unverified localhost route passed"
  fi
  [ ! -s "$dir/route.log" ] || fail "verify fingerprinted localhost before proving ownership"
  assert_grep 'reason=windows-owner-is-not-wslrelay' "$out" "verify did not report the unverified owner"
  pass "verify proves the listener pair before contacting localhost"
}

test_mutation_recheck_refuses_new_task() {
  local dir out
  dir=$(make_case mutation-task)
  out="$dir/out"
  if FM_WSL_MODE=none FM_WIN_THIRD_JSON="$dir/win-initial.json" \
    FM_THIRD_TASK_FILE="$dir/state/live.meta" FM_THIRD_TASK_PROJECT="$dir/mount/c/repos/stale checkout" \
    run_case "$dir" recover "$out"; then
    fail "active task appearing at mutation boundary was accepted"
  fi
  assert_grep 'refuse:pid-or-command-reresolution-changed' "$out" "mutation-boundary task was not refused"
  [ ! -s "$dir/stop.log" ] || fail "mutation-boundary task refusal still called termination"
  pass "fresh mutation-boundary source and task proof blocks termination"
}

test_termination_boundary_refuses_new_task() {
  local dir out
  dir=$(make_case termination-boundary-task)
  out="$dir/out"
  if FM_WSL_MODE=none FM_WIN_FOURTH_JSON="$dir/win-initial.json" \
    FM_FOURTH_TASK_FILE="$dir/state/live.meta" FM_FOURTH_TASK_PROJECT="$dir/mount/c/repos/stale checkout" \
    run_case "$dir" recover "$out"; then
    fail "active task appearing at termination boundary was accepted"
  fi
  assert_grep 'refuse:pid-or-command-reresolution-changed' "$out" "termination-boundary task was not refused"
  [ ! -s "$dir/stop.log" ] || fail "termination-boundary task refusal still called termination"
  pass "termination-boundary task proof blocks exact-PID termination"
}

test_post_stop_inspection_failure_blocks_restart() {
  local dir out
  dir=$(make_case post-stop-failure)
  out="$dir/out"
  if FM_WSL_MODE=after-launch FM_POST_STOP_WINDOWS_FAIL=1 run_case "$dir" recover "$out"; then
    fail "post-stop inspection failure was accepted"
  fi
  assert_grep 'failed:windows-inspection-unavailable' "$out" "post-stop inspection failure was not reported"
  [ ! -e "$dir/npm.log" ] || fail "post-stop inspection failure launched npm"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "post-stop inspection failure did not preserve exact termination"
  pass "post-stop inspection failure blocks any restart"
}

test_launcher_script_rejects_shell_metacharacters() {
  local dir out
  dir=$(make_case launcher-shell)
  out="$dir/out"
  cat > "$dir/expected/package.json" <<'JSON'
{"scripts":{"dev":"astro dev $(touch injected-file)"}}
JSON
  git -C "$dir/expected" add package.json
  git -C "$dir/expected" commit -qm malicious-launcher
  git -C "$dir/expected" rev-parse HEAD > "$dir/expected.sha"
  if FM_WSL_MODE=none run_case "$dir" recover "$out"; then
    fail "shell metacharacters in the launcher were accepted"
  fi
  assert_grep 'refuse:project dev launcher is not proven to be Astro dev' "$out" "launcher shell metacharacters did not refuse"
  assert_no_grep 'Traceback' "$out" "launcher refusal escaped as a traceback"
  [ ! -s "$dir/stop.log" ] || fail "launcher refusal still called termination"
  pass "Astro launcher scripts with shell metacharacters refuse recovery"
}

test_post_recovery_fingerprint_mismatch_fails() {
  local dir out
  dir=$(make_case route-mismatch)
  out="$dir/out"
  printf '{"status":200,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","length":4}\n' > "$dir/win-route.json"
  if FM_WSL_MODE=after-launch FM_NPM_STAY_ALIVE=1 run_case "$dir" recover "$out"; then
    fail "post-recovery route mismatch passed"
  fi
  assert_grep 'failed:post-recovery-verification' "$out" "post-recovery mismatch was not reported"
  assert_grep 'route-fingerprint-mismatch' "$out" "route mismatch reason was not reported"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "mismatch case did not preserve exact single-PID termination"
  local launcher_pid
  launcher_pid=$(sed -n 's/.*launcher_pid=\([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
  [ -n "$launcher_pid" ] || fail "failed recovery did not report the owned launcher PID"
  ! kill -0 "$launcher_pid" 2>/dev/null || fail "failed recovery left the owned launcher running"
  pass "post-recovery Windows/WSL route fingerprint mismatch fails verification"
}

test_post_route_pair_change_fails_verification() {
  local dir out
  dir=$(make_case post-route-pair-change)
  out="$dir/out"
  if FM_WSL_MODE=after-launch FM_NPM_STAY_ALIVE=1 FM_WIN_POST_ROUTE_JSON="$dir/win-initial.json" \
    run_case "$dir" recover "$out"; then
    fail "post-route listener-pair change passed verification"
  fi
  assert_grep 'failed:post-recovery-verification' "$out" "post-route listener-pair change was not reported"
  assert_grep 'windows-owner-is-not-wslrelay' "$out" "post-route listener-pair reason was not reported"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "post-route pair change did not preserve exact single-PID termination"
  pass "post-route listener-pair changes fail verification"
}

test_checkout_revalidation_blocks_dirty_restart() {
  local dir out
  dir=$(make_case checkout-revalidation)
  out="$dir/out"
  if FM_WSL_MODE=none FM_MUTATE_EXPECTED_AFTER_STOP="$dir/expected/page.txt" run_case "$dir" recover "$out"; then
    fail "dirty expected checkout was launched"
  fi
  assert_grep 'failed:expected-checkout-dirty' "$out" "dirty expected checkout was not refused before restart"
  [ ! -e "$dir/npm.log" ] || fail "dirty expected checkout still launched npm"
  [ "$(wc -l < "$dir/stop.log" | tr -d ' ')" = 1 ] || fail "checkout revalidation did not preserve exact single-PID termination"
  pass "dirty expected checkout refuses restart after exact-PID termination"
}

test_listener_parsing_path_conversion_source_and_redaction
test_native_stale_windows_shadow_recovers_to_verified_pair
test_healthy_relay_and_clean_wsl_verify
test_relay_identity_requires_canonical_executable
test_same_owner_multiple_bindings_verify
test_same_owner_multiple_bindings_recover
test_active_task_refuses_without_termination
test_active_wsl_task_refuses_recovery_and_verification
test_multiple_wsl_owners_refuse_before_termination
test_wsl_listener_must_remain_on_default_branch
test_production_like_wsl_and_launcher_refuse
test_task_state_lock_wait_is_bounded
test_pid_or_command_change_refuses_on_immediate_reresolution
test_verify_revalidates_expected_checkout
test_worker_with_astro_words_refuses
test_unknown_and_unrelated_windows_processes_refuse
test_windows_inspection_failure_is_safe
test_wsl_inspection_failure_is_safe
test_task_state_inspection_failure_is_safe
test_verify_proves_pair_before_route_requests
test_mutation_recheck_refuses_new_task
test_termination_boundary_refuses_new_task
test_post_stop_inspection_failure_blocks_restart
test_launcher_script_rejects_shell_metacharacters
test_post_recovery_fingerprint_mismatch_fails
test_post_route_pair_change_fails_verification
test_checkout_revalidation_blocks_dirty_restart
