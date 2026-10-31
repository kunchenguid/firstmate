#!/usr/bin/env bash
# Sleep-aware extension deadline regression tests on the real invocation path.
#
# A host deadline that fires far past its bound because the machine was
# suspended - simulated with SIGSTOP/SIGCONT of the invocation tree - re-arms
# one bounded grace instead of killing a healthy invocation, the captured
# error records which bound fired and how far it overran, and a genuinely
# stalled invocation still dies at its bound with no grace. The suite drives
# only public commands, package executables, and the durable records those
# commands publish. It never asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST="$ROOT/bin/fm-extension.mjs"
TMP_ROOT_RAW=$(fm_test_tmproot fm-extension-sleep-deadlines)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
PACKAGES="$TMP_ROOT/packages"
HOMES="$TMP_ROOT/homes"
mkdir -p "$PACKAGES" "$HOMES"

BOUND_MS=3000
poll_pid=
inner_host_pid=
group_pid=

cleanup_sleep_deadlines() {
  # Resume before signalling: a frozen target must never outlive this trap.
  [ -z "$group_pid" ] || kill -CONT -"$group_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -CONT "$inner_host_pid" 2>/dev/null || true
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -TERM "$inner_host_pid" 2>/dev/null || true
  [ -z "$group_pid" ] || kill -TERM -"$group_pid" 2>/dev/null || true
  chmod -R u+w "$TMP_ROOT_RAW" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_sleep_deadlines EXIT
trap 'cleanup_sleep_deadlines; exit 130' INT
trap 'cleanup_sleep_deadlines; exit 143' TERM

PACKAGE="$PACKAGES/sleep-deadlines"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.sleep-deadlines",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-sleep"]}
  ],
  "required_consents": []
}
JSON
chmod 0644 "$PACKAGE/firstmate-extension.json"
cat > "$PACKAGE/entrypoint.py" <<'PY'
#!/usr/bin/env python3
import json, os, signal, sys, time

request = json.load(sys.stdin)
with open("firstmate-extension.json", encoding="utf-8") as source:
    manifest = json.load(source)
verb = sys.argv[1] if len(sys.argv) > 1 else ""

def raw(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

if verb == "handshake":
    raw({
        "schema": "firstmate.extension-handshake-response.v1",
        "request_id": request["request_id"],
        "extension_id": manifest["id"],
        "extension_version": manifest["version"],
        "host_protocol": 1,
        "capability": "process-event-adapter",
        "capability_version": 1,
        "adapter_names": request["capability"]["adapter_names"],
    })
    sys.exit(0)
if verb != "invoke":
    sys.exit(8)
mode = request.get("input", {}).get("config_ref", "")
if mode == "good":
    raw({
        "schema": "firstmate.extension-response.v1",
        "request_id": request["request_id"],
        "ok": True,
        "result": {"status": "result", "output": "launch ready recovered\n"},
        "error": None,
    })
    sys.exit(0)
if mode.startswith("hold|"):
    _, marker, release = mode.split("|", 2)
    with open(marker, "w", encoding="utf-8") as output:
        output.write(f"{os.getpid()}\n")
    while not os.path.exists(release):
        time.sleep(0.01)
    raw({
        "schema": "firstmate.extension-response.v1",
        "request_id": request["request_id"],
        "ok": True,
        "result": {"status": "result", "output": "resumed inside the grace\n"},
        "error": None,
    })
    sys.exit(0)
if mode.startswith("stall|"):
    _, marker = mode.split("|", 1)
    with open(marker, "w", encoding="utf-8") as output:
        output.write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
sys.exit(6)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

wait_for_file() {
  local file=$1
  for _ in $(seq 1 200); do
    [ -s "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_pid_exit() { # <pid> <seconds>
  local pid=$1 limit=$(( $2 * 10 )) attempt
  for ((attempt = 0; attempt < limit; attempt++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

sleep_until() { # <target-epoch-seconds>
  while [ "$(date +%s)" -lt "$1" ]; do sleep 0.2; done
}

prepare_home() { # <home>
  local home=$1 resolution
  mkdir -p "$home"
  FM_HOME="$home" "$HOST" bind "$PACKAGE" --adapter ext-sleep \
    --trust-same-user-code --timeout-ms "$BOUND_MS" >/dev/null \
    || fail "cannot bind the sleep-deadlines fixture"
  resolution=$(FM_HOME="$home" "$HOST" resolve-process-event ext-sleep) \
    || fail "cannot resolve the sleep-deadlines fixture"
  IFS=$'\t' read -r r_schema r_id r_version r_cap r_package r_binding r_extra <<< "$resolution"
  [ "$r_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$r_extra" ] \
    || fail "resolution record is malformed: $resolution"
}

start_poll() { # <home> <config-ref> <tag>
  FM_HOME="$1" "$HOST" process-event ext-sleep source.poll \
    --source-id sleep-source --config-ref "$2" \
    --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" \
    --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP_ROOT/$3.out" 2> "$TMP_ROOT/$3.err" &
  poll_pid=$!
}

freeze_invocation() { # <entrypoint-marker-file>
  local entry_pid barrier_pid
  entry_pid=$(sed -n '1p' "$1")
  case "$entry_pid" in ''|*[!0-9]*) fail "invocation marker has no process identity: $1" ;; esac
  barrier_pid=$(ps -o pgid= -p "$entry_pid" | tr -d '[:space:]')
  case "$barrier_pid" in ''|*[!0-9]*) fail "cannot locate the invocation process group" ;; esac
  group_pid=$barrier_pid
  inner_host_pid=$(ps -o ppid= -p "$group_pid" | tr -d '[:space:]')
  case "$inner_host_pid" in ''|*[!0-9]*) fail "cannot locate the invocation host process" ;; esac
  # Freeze the host whose deadline timers run and the whole invocation group,
  # which is what a machine sleep does to an in-flight invocation.
  kill -STOP "$inner_host_pid"
  kill -STOP -"$group_pid"
}

resume_invocation() {
  [ -n "$group_pid" ] && kill -CONT -"$group_pid" 2>/dev/null || true
  [ -n "$inner_host_pid" ] && kill -CONT "$inner_host_pid" 2>/dev/null || true
}

release_invocation_targets() {
  group_pid=
  inner_host_pid=
}

test_genuine_stall_dies_at_bound() {
  local home="$HOMES/stall" marker="$TMP_ROOT/stall.marker" tag=stall
  local marker_epoch started elapsed rc=0 output
  prepare_home "$home"
  start_poll "$home" "stall|$marker" "$tag"
  wait_for_file "$marker" || fail "the stalled fixture never reached the adapter"
  marker_epoch=$(date +%s)
  started=$marker_epoch
  wait_for_pid_exit "$poll_pid" 10 || fail "a genuinely stalled invocation outlived its bound"
  wait "$poll_pid"; rc=$?
  poll_pid=
  elapsed=$(( $(date +%s) - started ))
  output=$(cat "$TMP_ROOT/$tag.out")
  [ "$rc" -eq 70 ] || fail "stalled invocation exited $rc instead of the captured host-error status: $(cat "$TMP_ROOT/$tag.err")"
  assert_contains "$output" '"code":"timeout"' "a genuine stall did not produce timeout evidence"
  assert_contains "$output" '"bound":"invoke"' "a timeout evidence did not name its bound"
  assert_not_contains "$output" "overrun_ms" "a stall at its bound claimed a suspension overrun"
  [ "$elapsed" -le 6 ] || fail "a genuinely stalled invocation waited through a bounded grace: ${elapsed}s"
  pass "a genuinely stalled invocation dies at its bound with no grace"
}

test_frozen_invocation_resumes_inside_grace() {
  local home="$HOMES/resume" marker="$TMP_ROOT/resume.marker"
  local release="$TMP_ROOT/resume.release" tag=resume
  local marker_epoch rc=0 output
  prepare_home "$home"
  start_poll "$home" "hold|$marker|$release" "$tag"
  wait_for_file "$marker" || fail "the frozen fixture never reached the adapter"
  marker_epoch=$(date +%s)
  freeze_invocation "$marker"
  # Stay frozen well past bound + suspension slack, then resume inside the
  # bounded grace the late deadline must grant.
  sleep_until $(( marker_epoch + 7 ))
  resume_invocation
  touch "$release"
  wait_for_pid_exit "$poll_pid" 10 || fail "a resumed invocation never completed inside the grace"
  wait "$poll_pid"; rc=$?
  poll_pid=
  output=$(cat "$TMP_ROOT/$tag.out")
  [ "$rc" -eq 0 ] || fail "an invocation frozen across its deadline and resumed inside the grace failed (rc=$rc): $(cat "$TMP_ROOT/$tag.err")"
  assert_contains "$output" "resumed inside the grace" "the resumed invocation's result was lost"
  release_invocation_targets
  pass "a frozen invocation that resumes inside the grace completes"
}

test_frozen_invocation_still_dies_at_bound() {
  local home="$HOMES/frozen-stall" marker="$TMP_ROOT/frozen-stall.marker" tag=frozen-stall
  local marker_epoch rc=0 output overrun
  prepare_home "$home"
  start_poll "$home" "stall|$marker" "$tag"
  wait_for_file "$marker" || fail "the frozen stall fixture never reached the adapter"
  marker_epoch=$(date +%s)
  freeze_invocation "$marker"
  sleep_until $(( marker_epoch + 7 ))
  resume_invocation
  # The invocation never resumes its work: after the suspension-detected
  # bounded grace it must still be killed at its bound.
  wait_for_pid_exit "$poll_pid" 10 || fail "a frozen invocation that never resumed was never killed"
  wait "$poll_pid"; rc=$?
  poll_pid=
  output=$(cat "$TMP_ROOT/$tag.out")
  [ "$rc" -eq 70 ] || fail "a never-resuming invocation exited $rc instead of the captured host-error status: $(cat "$TMP_ROOT/$tag.err")"
  assert_contains "$output" '"code":"timeout"' "a suspension-driven kill did not produce timeout evidence"
  assert_contains "$output" '"bound":"invoke"' "a suspension-driven kill did not name its bound"
  assert_contains "$output" '"overrun_ms":' "a suspension-driven kill did not record its overrun"
  overrun=$(node -e 'const fs=require("fs");const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String(value.overrun_ms))' "$TMP_ROOT/$tag.out") \
    || fail "timeout evidence is not JSON"
  case "$overrun" in ''|*[!0-9]*) fail "timeout evidence carried a non-numeric overrun: $overrun" ;; esac
  [ "$overrun" -gt 2000 ] || fail "the recorded overrun ${overrun}ms does not exceed the suspension slack"
  release_invocation_targets
  pass "a frozen invocation that never resumes still fails at its bound with bound and overrun recorded"
}

test_launch_ready_recovers_after_suspension() {
  local case_dir="$TMP_ROOT/launch-ready" home="$HOMES/launch-ready"
  local tag=launch-ready marker marker_epoch rc=0 output barrier_pid
  mkdir -p "$case_dir/code"
  cp -R "$ROOT/bin" "$case_dir/code/bin"
  mv "$case_dir/code/bin/fm-extension-launch-barrier.mjs" \
    "$case_dir/code/bin/fm-extension-launch-barrier.original.mjs"
  cat > "$case_dir/code/bin/fm-extension-launch-barrier.mjs" <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const markerPath = fileURLToPath(new URL("./launch-wrapper.marker", import.meta.url));
if (!existsSync(markerPath)) {
  writeFileSync(markerPath, `${process.pid}\n`);
  await new Promise((resolve) => setTimeout(resolve, 6000));
}
await import("./fm-extension-launch-barrier.original.mjs");
JS
  prepare_home "$home"
  # Drive the copied tree so the delayed barrier it spawns is its own; only
  # the host's launch-ready wait is frozen, as in a sleep across the launch.
  FM_HOME="$home" "$case_dir/code/bin/fm-extension.mjs" process-event ext-sleep source.poll \
    --source-id sleep-source --config-ref good \
    --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" \
    --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP_ROOT/$tag.out" 2> "$TMP_ROOT/$tag.err" &
  poll_pid=$!
  marker="$case_dir/code/bin/launch-wrapper.marker"
  wait_for_file "$marker" || fail "the delayed launch barrier never started"
  marker_epoch=$(date +%s)
  barrier_pid=$(sed -n '1p' "$marker")
  case "$barrier_pid" in ''|*[!0-9]*) fail "barrier wrapper did not publish its process identity" ;; esac
  group_pid=$barrier_pid
  inner_host_pid=$(ps -o ppid= -p "$barrier_pid" | tr -d '[:space:]')
  case "$inner_host_pid" in ''|*[!0-9]*) fail "cannot locate the launch host process" ;; esac
  kill -STOP "$inner_host_pid"
  sleep_until $(( marker_epoch + 9 ))
  kill -CONT "$inner_host_pid"
  wait_for_pid_exit "$poll_pid" 10 || fail "a launch interrupted by suspension never recovered inside the grace"
  wait "$poll_pid"; rc=$?
  poll_pid=
  output=$(cat "$TMP_ROOT/$tag.out")
  [ "$rc" -eq 0 ] || fail "a suspended launch that resumed inside the grace failed (rc=$rc): $(cat "$TMP_ROOT/$tag.err")"
  assert_contains "$output" "launch ready recovered" "the recovered launch's result was lost"
  release_invocation_targets
  pass "a launch-ready wait interrupted by suspension recovers inside the grace"
}

# The capture gate must accept every overrun_ms the host can emit (the host
# validates JS safe integers, at most 16 digits) and reject beyond it, so a
# long suspension can never silently lose the host-error identity that keeps
# retries coalescing into one capture.
overrun_boundary_case() { # <tag> <overrun-ms> <expect-host-error: yes|no> <expected-result-count after two rounds>
  (
    set -u
    local case_root="$TMP_ROOT/overrun-$1" overrun=$2 expect_marker=$3 expect_count=$4
    local home source claim_root evidence inbox round_result_count
    local saved_home=${HOME:-} saved_xdg=${XDG_STATE_HOME:-}
    home="$case_root/home"
    source="boundary-$1"
    claim_root="$case_root/claims"
    mkdir -p "$case_root/user-home" "$case_root/code" "$home" "$claim_root"
    export HOME="$case_root/user-home" XDG_STATE_HOME="$case_root/xdg"
    export FM_PROCEVENT_CLAIM_ROOT="$claim_root"
    export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10
    # Copied tree whose fm-extension.mjs is a shim: a source.poll emits the
    # exact envelope under test and exits 70, every other host command runs
    # the real host, so the production capture pipeline validates the bytes.
    cp -R "$ROOT/bin" "$case_root/code/bin"
    cat > "$case_root/code/bin/fm-extension.mjs" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" process-event "*" source.poll "*)
    printf '%s\\n' "\${FM_SHIM_EVIDENCE:?FM_SHIM_EVIDENCE is required}"
    exit 70
    ;;
esac
exec $ROOT/bin/fm-extension.mjs "\$@"
SHIM
    chmod 0755 "$case_root/code/bin/fm-extension.mjs"
    FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-sleep \
      --trust-same-user-code --timeout-ms "$BOUND_MS" >/dev/null \
      || fail "cannot bind the overrun-boundary fixture"
    fm_test_track_procevent_home "$home" "$claim_root"
    FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" register-extension ext-sleep "$source" \
      --config-ref boundary >/dev/null || fail "cannot register $1 fixture"
    evidence=$(printf '{"schema":"firstmate.process-event-extension-error.v1","extension_id":"org.example.sleep-deadlines","operation":"source.poll","code":"timeout","bound":"invoke","overrun_ms":%s}' "$overrun")
    inbox="$home/state/procevent-inbox"
    for round in 1 2; do
      if [ "$round" -eq 1 ]; then
        FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" \
          "$case_root/code/bin/fm-procevent.sh" start "$source" > "$case_root/start.out" 2>&1 \
          || fail "$1 start failed: $(cat "$case_root/start.out")"
      else
        FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" \
          "$case_root/code/bin/fm-procevent.sh" reconcile > "$case_root/reconcile.out" 2>&1 \
          || fail "$1 reconcile failed: $(cat "$case_root/reconcile.out")"
        assert_contains "$(cat "$case_root/reconcile.out")" 'started=1' "$1 retry did not launch a recovery poll"
      fi
      settle_source "$home" "$claim_root" "$source" \
        || fail "$1 round $round runner did not settle"
      round_result_count=$(inbox_count "$inbox" "$source")
      # A gate-accepted envelope coalesces into the first capture; a rejected
      # envelope allocates a fresh result each round.
      if [ "$expect_marker" = yes ]; then
        [ "$round_result_count" -eq 1 ] \
          || fail "$1 round $round produced $round_result_count results, expected 1 coalesced capture"
      else
        [ "$round_result_count" -eq "$round" ] \
          || fail "$1 round $round produced $round_result_count results, expected $round"
      fi
    done
    [ "$(inbox_count "$inbox" "$source")" -eq "$expect_count" ] \
      || fail "$1 did not settle at $expect_count captures"
    if [ "$expect_marker" = yes ]; then
      [ "$(host_error_count "$inbox" "$source")" -eq 1 ] \
        || fail "an overrun at the capture gate cap lost its host-error identity"
      [ "$expect_count" -eq 1 ] \
        || fail "an overrun at the capture gate cap must coalesce retries into one capture"
    else
      [ "$(host_error_count "$inbox" "$source")" -eq 0 ] \
        || fail "an overrun beyond the capture gate cap was accepted as host-error identity"
      [ "$expect_count" -eq 2 ] \
        || fail "an overrun beyond the capture gate cap should not coalesce retries"
    fi
    export HOME="$saved_home"
    if [ -n "$saved_xdg" ]; then export XDG_STATE_HOME="$saved_xdg"; else unset XDG_STATE_HOME; fi
    unset FM_PROCEVENT_CLAIM_ROOT FM_PROCEVENT_LAUNCH_FLOOR_SECONDS FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS
  )
}

test_overrun_at_the_capture_gate_cap_keeps_host_error_identity() {
  # 9007199254740991 is Number.MAX_SAFE_INTEGER: the largest value the host
  # can emit, so the gate must accept it and keep retry dedupe working.
  overrun_boundary_case cap 9007199254740991 yes 1 || exit 1
  pass "an overrun at the capture gate cap keeps its host-error identity and retry coalescing"
}

test_overrun_beyond_the_capture_gate_cap_is_rejected() {
  # 17 digits cannot come from a host-validated safe integer; the gate must
  # reject the envelope instead of recording a host-error identity.
  overrun_boundary_case beyond 10000000000000000 no 2 || exit 1
  pass "an overrun beyond the capture gate cap is rejected without host-error identity"
}

settle_source() { # <home> <claim-root> <source>
  local runner_pid
  for _ in $(seq 1 600); do
    runner_pid=$(sed -n '2p' "$2/$3.claim" 2>/dev/null || true)
    if [ ! -e "$1/state/procevent/$3.runner" ] && [ -z "$runner_pid" ]; then return 0; fi
    sleep 0.05
  done
  return 1
}

inbox_count() { # <inbox-dir> <source>
  compgen -G "$1/$2"'.*.result' 2>/dev/null | wc -l | tr -d ' '
}

host_error_count() { # <inbox-dir> <source>
  compgen -G "$1/$2"'.*.host-error' 2>/dev/null | wc -l | tr -d ' '
}

fm_test_run \
  test_genuine_stall_dies_at_bound \
  test_frozen_invocation_resumes_inside_grace \
  test_frozen_invocation_still_dies_at_bound \
  test_launch_ready_recovers_after_suspension \
  test_overrun_at_the_capture_gate_cap_keeps_host_error_identity \
  test_overrun_beyond_the_capture_gate_cap_is_rejected
