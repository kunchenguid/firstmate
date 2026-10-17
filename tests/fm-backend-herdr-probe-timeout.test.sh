#!/usr/bin/env bash
# tests/fm-backend-herdr-probe-timeout.test.sh - proves every synchronous herdr
# CLI read in bin/backends/herdr.sh runs under a real process-level bound, and
# that a hung probe's process is gone once that bound fires. The property is the
# adapter's own timeout discipline, so it is pinned with a fake herdr that
# ignores TERM and never answers a read; no real herdr installation is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-probe-timeout)
HANG_PIDS="$TMP_ROOT/hang-pids"
: > "$HANG_PIDS"

# A herdr stub that answers the server-state liveness read so target_ready
# passes, records its own pid, and then never returns from a real read. It
# ignores TERM (with a self-deadline so a broken adapter cannot hang the suite
# forever), so only the runner's KILL escalation can reap it.
make_hanging_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" >> "$FM_HANG_PIDS"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"protocol":22},"server":{"running":true}}\n'
  exit 0
fi
trap '' TERM
deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$deadline" ]; do
  sleep 1
done
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# A fake whose server launch is a short, normal-lived command: it exits 0 after
# a delay LONGER than the bound under test, so a wrongly bounded server call
# would be killed (124) instead of completing.
make_server_launch_fakebin() {  # <dir> <sleep-seconds> -> echoes fakebin dir
  local dir=$1 nap=$2 fb="$1/fakebin-server"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
sleep $nap
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# reap_hung_fakes: best-effort cleanup so a failed assertion cannot leave a
# stray fixture behind; registered on EXIT alongside lib.sh's own cleanup.
reap_hung_fakes() {
  local pid
  [ -f "$HANG_PIDS" ] || return 0
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -KILL "$pid" 2>/dev/null || true
  done < "$HANG_PIDS"
}
trap 'reap_hung_fakes; fm_test_cleanup' EXIT

# every_fake_is_gone: true only when each recorded pid is gone (or a zombie the
# init reaper is about to collect), after a short bounded settle. A still-live
# process after the grace window is a leaked shell and fails the case.
every_fake_is_gone() {
  local attempt=0 pid state
  while [ "$attempt" -lt 30 ]; do
    local all_gone=1
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      if kill -0 "$pid" 2>/dev/null; then
        state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$state" in
          ''|Z*) ;;
          *) all_gone=0 ;;
        esac
      fi
    done < "$HANG_PIDS"
    [ "$all_gone" -eq 1 ] && return 0
    attempt=$((attempt + 1))
    sleep 0.2
  done
  return 1
}

run_adapter_snippet() {  # <fakebin> <bound-seconds> <snippet>
  local fb=$1 bound=$2 snippet=$3
  PATH="$fb:$PATH" FM_HANG_PIDS="$HANG_PIDS" FM_BACKEND_HERDR_CLI_TIMEOUT="$bound" \
    FM_HOME="$TMP_ROOT/ambient-home" \
    bash -c ". \"\$0/bin/backends/herdr.sh\"; $snippet" "$ROOT"
}

test_capture_probe_is_bounded_and_reaped() {
  local dir fb start elapsed out rc
  dir="$TMP_ROOT/capture"; mkdir -p "$dir"
  fb=$(make_hanging_herdr_fakebin "$dir")
  start=$SECONDS
  out=$(run_adapter_snippet "$fb" 1 'fm_backend_herdr_capture fmtest:w1:p2 40' 2>/dev/null)
  rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -ne 0 ] || fail "a hung capture read must fail rather than return success (out='$out')"
  [ "$elapsed" -lt 15 ] || fail "a hung capture read ignored the bound and ran ${elapsed}s"
  every_fake_is_gone || fail "a hung capture read leaked its herdr process past the bound: $(tr '\n' ' ' < "$HANG_PIDS")"
  pass "capture read: a TERM-ignoring hung herdr is bounded and its process is reaped"
}

test_composer_state_probe_is_bounded_and_reaped() {
  local dir fb start elapsed out
  dir="$TMP_ROOT/composer"; mkdir -p "$dir"
  fb=$(make_hanging_herdr_fakebin "$dir")
  start=$SECONDS
  out=$(run_adapter_snippet "$fb" 1 'fm_backend_herdr_composer_state fmtest:w1:p2' 2>/dev/null)
  elapsed=$((SECONDS - start))
  [ "$out" = unknown ] || fail "a hung composer probe must read unknown, got '$out'"
  [ "$elapsed" -lt 20 ] || fail "a hung composer probe ignored the bound and ran ${elapsed}s"
  every_fake_is_gone || fail "a hung composer probe leaked its herdr process past the bound: $(tr '\n' ' ' < "$HANG_PIDS")"
  pass "composer_state probe: a TERM-ignoring hung herdr is bounded and its process is reaped"
}

test_generic_cli_read_is_bounded_and_reaped() {
  local dir fb start elapsed rc
  dir="$TMP_ROOT/cli"; mkdir -p "$dir"
  fb=$(make_hanging_herdr_fakebin "$dir")
  start=$SECONDS
  run_adapter_snippet "$fb" 1 'fm_backend_herdr_cli fmtest pane read w1:p2 --source recent --lines 200' >/dev/null 2>&1
  rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -eq 124 ] || fail "a hung fm_backend_herdr_cli read must return 124 (the bound), got $rc"
  [ "$elapsed" -lt 10 ] || fail "a hung fm_backend_herdr_cli read ignored the bound and ran ${elapsed}s"
  every_fake_is_gone || fail "a hung cli read leaked its herdr process past the bound: $(tr '\n' ' ' < "$HANG_PIDS")"
  pass "fm_backend_herdr_cli: the shared read owner bounds and reaps a hung herdr"
}

test_server_launch_is_exempt_from_the_bound() {
  local dir fb rc
  dir="$TMP_ROOT/server"; mkdir -p "$dir"
  fb=$(make_server_launch_fakebin "$dir" 2)
  run_adapter_snippet "$fb" 1 'fm_backend_herdr_cli fmtest server' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the long-lived server launch must not be bounded (got rc=$rc; a 1s bound would kill it)"
  pass "fm_backend_herdr_cli: the long-lived server launch stays exempt from the bound"
}

test_capture_probe_is_bounded_and_reaped
test_composer_state_probe_is_bounded_and_reaped
test_generic_cli_read_is_bounded_and_reaped
test_server_launch_is_exempt_from_the_bound
