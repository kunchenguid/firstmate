#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER=${FM_BOUNDED_IO_HELPER:-"$ROOT/bin/fm_bounded_io.py"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2)" ;;
  esac
}

test_output_limit_terminates_noisy_process() {
  output="$TMP/output-limit"
  if python3 "$HELPER" run --timeout 5 --max-output-bytes 1024 -- \
    python3 -c 'import sys; sys.stdout.write("x" * 4096)' >"$output" 2>&1; then
    fail "noisy process crossed the aggregate output ceiling"
  fi
  value=$(cat "$output")
  assert_contains "$value" "1024-byte aggregate output limit" \
    "output-limit failure was not loud"
  [ "$(wc -c < "$output" | tr -d '[:space:]')" -lt 2048 ] \
    || fail "output-limit diagnostic was itself unbounded"
}

test_final_wait_keeps_original_deadline() {
  started=$(python3 -c 'import time; print(time.monotonic())')
  output="$TMP/final-wait"
  if python3 "$HELPER" run --timeout 0.25 --max-output-bytes 1024 -- \
    python3 -c 'import os,time; os.close(1); os.close(2); time.sleep(1.5)' \
    >"$output" 2>&1; then
    fail "closed output pipes escaped the command deadline"
  fi
  elapsed=$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$started")
  python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 1.25 else 1)' "$elapsed" \
    || fail "final wait exceeded the original deadline: ${elapsed}s"
  assert_contains "$(cat "$output")" "timed out after 0.25 seconds" \
    "final-wait timeout was not loud"
}

test_success_reaps_residual_process_group() {
  pid_file="$TMP/residual-pid"
  python3 "$HELPER" run --timeout 2 --max-output-bytes 1024 -- \
    python3 -c 'import subprocess,sys; child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(3)"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(child.pid)' \
    >"$pid_file"
  child_pid=$(cat "$pid_file")
  case "$child_pid" in ''|*[!0-9]*) fail "residual child PID was malformed" ;; esac
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "successful leader left residual process $child_pid alive"
  fi
}

test_tracked_detached_descendant_is_cleaned() {
  pid_file="$TMP/detached-pid"
  python3 "$HELPER" run --timeout 2 --max-output-bytes 1024 -- \
    python3 -c 'import subprocess,sys; child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,close_fds=True); print(child.pid)' \
    >"$pid_file"
  child_pid=$(cat "$pid_file")
  case "$child_pid" in ''|*[!0-9]*) fail "detached child PID was malformed" ;; esac
  if kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    fail "tracked detached descendant escaped ownership cleanup as $child_pid"
  fi
}

test_batch_deadline_remains_absolute() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
budget = module.DeadlineBudget(0.05, 1)
deadline = budget.bounded_deadline(1, "review command")
time.sleep(0.06)
started = time.monotonic()
try:
    module.run_bounded(
        [sys.executable, "-c", "raise SystemExit(0)"],
        timeout_seconds=1,
        absolute_deadline=deadline,
        maximum_output_bytes=1024,
    )
except module.BoundedTimeout as error:
    assert "expired before start" in str(error), str(error)
else:
    raise AssertionError("expired batch deadline was restarted by the command")
assert time.monotonic() - started < 0.25
PY
}

test_selector_failure_precedes_spawn() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
spawned = []


def selector_failure():
    raise RuntimeError("selector unavailable")


def unexpected_spawn(*_args, **_kwargs):
    spawned.append(True)
    raise AssertionError("child spawned before selector setup completed")


module.selectors.DefaultSelector = selector_failure
module.subprocess.Popen = unexpected_spawn
try:
    module.run_bounded(
        [sys.executable, "-c", "raise SystemExit(0)"],
        timeout_seconds=1,
        maximum_output_bytes=1024,
    )
except RuntimeError as error:
    assert str(error) == "selector unavailable", str(error)
else:
    raise AssertionError("selector failure was accepted")
assert not spawned
PY
}

test_input_validation_precedes_spawn() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
spawned = []


def unexpected_spawn(*_args, **_kwargs):
    spawned.append(True)
    raise AssertionError("supervisor spawned before input validation completed")


module.subprocess.Popen = unexpected_spawn
try:
    module.run_bounded(
        [sys.executable, "-c", "raise SystemExit(0)"],
        timeout_seconds=1,
        maximum_output_bytes=1024,
        input_bytes=object(),
    )
except module.BoundedIOError as error:
    assert "input must be bytes" in str(error), str(error)
else:
    raise AssertionError("non-buffer input was accepted")
assert not spawned
PY
}

test_identity_bound_signaling_avoids_reused_pids() {
  python3 - "$HELPER" <<'PY'
import errno
import importlib.util
import signal
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
identity = (321, 17)
sent = []
closed = []
unsafe = []
module.os.pidfd_open = lambda process_id: 44
module.signal.pidfd_send_signal = (
    lambda descriptor, signal_number: sent.append((descriptor, signal_number))
)
module._linux_process_identity = lambda process_id: identity
module.os.close = lambda descriptor: closed.append(descriptor)
module.os.kill = lambda process_id, signal_number: unsafe.append(
    (process_id, signal_number)
)
module._linux_signal_owned_process(321, identity, signal.SIGTERM)
assert sent == [(44, signal.SIGTERM)], sent
assert closed == [44], closed
assert not unsafe, unsafe
sent.clear()
module._linux_process_identity = lambda process_id: (321, 18)
module._linux_signal_owned_process(321, identity, signal.SIGKILL)
assert not sent, sent
assert closed == [44, 44], closed
token = object()
darwin_sent = []
module._darwin_process_audit_token = lambda process_id: token
module._darwin_process_identity = lambda process_id: identity
module._darwin_signal_audit_token = (
    lambda observed, signal_number: darwin_sent.append(
        (observed, signal_number)
    ) or 0
)
module._darwin_signal_owned_process(321, identity, signal.SIGTERM)
assert darwin_sent == [(token, signal.SIGTERM)], darwin_sent
module._darwin_signal_audit_token = lambda _token, _signal_number: errno.ESRCH
module._darwin_signal_owned_process(321, identity, signal.SIGKILL)
assert not unsafe, unsafe
PY
}

test_process_census_enforces_item_and_time_bounds() {
  python3 - "$HELPER" <<'PY'
import errno
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
budget = module._ProcessCensusBudget(
    time.monotonic() + 1,
    maximum_items=2,
    maximum_argument_bytes=8,
)
module._linux_children = lambda process_id, census: [101, 102, 103]
try:
    module._linux_owned_processes(budget)
except OSError as error:
    assert error.errno == errno.EOVERFLOW, error
else:
    raise AssertionError("process census item limit was not enforced")
budget = module._ProcessCensusBudget(
    time.monotonic() + 1,
    maximum_items=8,
    maximum_argument_bytes=8,
)
budget.consume_argument_bytes(8)
try:
    budget.consume_argument_bytes(1)
except OSError as error:
    assert error.errno == errno.EOVERFLOW, error
else:
    raise AssertionError("process argument census limit was not enforced")
ticks = iter((0.0, 1.0))
module.time.monotonic = lambda: next(ticks)
budget = module._ProcessCensusBudget(0.75, maximum_items=8)
module._linux_children = lambda process_id, census: [101]
module._linux_process_identity = lambda process_id, census=None: (process_id, 1)
try:
    module._linux_owned_processes(budget)
except OSError as error:
    assert error.errno == errno.ETIMEDOUT, error
else:
    raise AssertionError("process census deadline was not enforced during traversal")
PY
}

test_linux_child_inventory_streams_with_bounds() {
  python3 - "$HELPER" <<'PY'
import errno
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
closed = []
reads = []


def install_chunks(values):
    chunks = iter(values)
    module.os.open = lambda *_args: 55
    module.os.close = lambda descriptor: closed.append(descriptor)

    def read_chunk(descriptor, maximum):
        reads.append((descriptor, maximum))
        return next(chunks)

    module.os.read = read_chunk


install_chunks((b"12 3", b"4\n", b""))
budget = module._ProcessCensusBudget(time.monotonic() + 1, maximum_items=3)
assert module._linux_children(999, budget) == [12, 34]
assert closed == [55], closed
closed.clear()
reads.clear()
install_chunks((b"1 2 ", b"3 ", b"4 ", b"5 ", b""))
budget = module._ProcessCensusBudget(time.monotonic() + 1, maximum_items=3)
try:
    module._linux_children(999, budget)
except OSError as error:
    assert error.errno == errno.EOVERFLOW, error
else:
    raise AssertionError("streamed child inventory crossed its item limit")
assert len(reads) == 3, reads
assert closed == [55], closed
PY
}

test_darwin_descendant_refresh_prunes_stale_entries() {
  python3 - "$HELPER" <<'PY'
import errno
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
command_identity = (10, 1)
live_identity = (11, 1)
stale_identity = (12, 1)
known = {
    10: command_identity,
    11: live_identity,
    12: stale_identity,
}
table = {
    10: (1, 10, 501, command_identity),
    11: (1, 11, 501, live_identity),
}
module._darwin_process_table = lambda budget: table
budget = module._ProcessCensusBudget(time.monotonic() + 1, maximum_items=4)
module._darwin_refresh_descendants(10, known, budget)
assert known == {10: command_identity, 11: live_identity}, known
visited = []
module._darwin_process_table = lambda budget: visited.append(True) or table
oversized = {10: command_identity, 11: live_identity, 12: stale_identity}
budget = module._ProcessCensusBudget(time.monotonic() + 1, maximum_items=2)
try:
    module._darwin_refresh_descendants(10, oversized, budget)
except OSError as error:
    assert error.errno == errno.EOVERFLOW, error
else:
    raise AssertionError("oversized retained descendant inventory was traversed")
assert not visited, visited
PY
}

test_partial_input_writes_do_not_copy_remainder() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original_write = module.os.write
observed = []


def partial_write(descriptor, value):
    observed.append(isinstance(value, memoryview))
    if isinstance(value, memoryview):
        value = value[: min(3, len(value))]
    return original_write(descriptor, value)


module.os.write = partial_write
result = module.run_bounded(
    [sys.executable, "-c", "import sys; print(len(sys.stdin.buffer.read()))"],
    timeout_seconds=2,
    maximum_output_bytes=1024,
    input_bytes=b"x" * 64,
)
assert result.returncode == 0, result.returncode
assert result.stdout == b"64\n", result.stdout
assert observed and all(observed), observed
PY
}

test_json_artifact_is_bounded_and_regular() {
  artifact="$TMP/verdict.json"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"padding":"x"*4096}))' "$artifact"
  output="$TMP/artifact-output"
  if python3 "$HELPER" json --max-bytes 1024 "$artifact" >"$output" 2>&1; then
    fail "oversized structured artifact bypassed its byte ceiling"
  fi
  assert_contains "$(cat "$output")" "exceeds 1024 bytes" \
    "oversized artifact failure was not loud"
  ln -s "$artifact" "$TMP/verdict-link.json"
  if python3 "$HELPER" json --max-bytes 8192 "$TMP/verdict-link.json" \
    >"$output" 2>&1; then
    fail "symlinked structured artifact was accepted"
  fi
  assert_contains "$(cat "$output")" "not a regular file" \
    "symlinked artifact failure was not loud"
}

test_concurrent_artifact_replacements_are_rejected() {
  artifact="$TMP/concurrent-verdict.json"
  python3 - "$HELPER" "$artifact" <<'PY'
import importlib.util
import os
from pathlib import Path
import signal
import sys
import threading

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
artifact = Path(sys.argv[2])


def exercise_replacement(replace, expected_message):
    original_open = module.os.open
    replacement_started = threading.Event()
    replacement_done = threading.Event()
    replacement_errors = []

    def replace_after_stat():
        replacement_started.wait()
        try:
            replace()
        except BaseException as error:
            replacement_errors.append(error)
        finally:
            replacement_done.set()

    def coordinated_open(path, flags, *args, **kwargs):
        replacement_started.set()
        if not replacement_done.wait(1):
            raise AssertionError("concurrent artifact replacement did not finish")
        if replacement_errors:
            raise replacement_errors[0]
        return original_open(path, flags, *args, **kwargs)

    def alarm_handler(_signum, _frame):
        raise AssertionError("concurrent FIFO replacement blocked during open")

    replacer = threading.Thread(target=replace_after_stat)
    replacer.start()
    module.os.open = coordinated_open
    signal.signal(signal.SIGALRM, alarm_handler)
    signal.setitimer(signal.ITIMER_REAL, 1.5)
    try:
        try:
            module.read_bounded_json(artifact, maximum_bytes=1024)
        except module.BoundedIOError as error:
            assert expected_message in str(error), str(error)
        else:
            raise AssertionError("concurrent artifact replacement was accepted")
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        module.os.open = original_open
        replacer.join()


artifact.write_text('{"original":true}', encoding="utf-8")


def replace_with_fifo():
    artifact.unlink()
    os.mkfifo(artifact)


exercise_replacement(replace_with_fifo, "descriptor is not a regular file")
artifact.unlink()
artifact.write_text('{"original":true}', encoding="utf-8")
replacement = artifact.with_name("replacement-verdict.json")
replacement.write_text('{"replacement":true}', encoding="utf-8")
exercise_replacement(
    lambda: os.replace(replacement, artifact),
    "identity changed while opening",
)
PY
}

test_json_decoded_strings_are_bounded() {
  artifact="$TMP/strings.json"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"padding":"x"*512}))' "$artifact"
  output="$TMP/structure-output"
  if python3 "$HELPER" json --max-bytes 2048 --max-string-bytes 128 "$artifact" \
    >"$output" 2>&1; then
    fail "decoded strings bypassed their aggregate ceiling"
  fi
  assert_contains "$(cat "$output")" "decoded string limit" \
    "decoded-string failure was not loud"
}

test_hostile_json_failures_are_normalized() {
  python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
root = Path(sys.argv[2])
artifacts = {
    "deep.json": ("[" * 1500 + "0" + "]" * 1500).encode(),
    "integer.json": b"1" * 5000,
    "nan.json": b"NaN",
    "infinity.json": b"Infinity",
    "negative-infinity.json": b"-Infinity",
    "surrogate.json": b'"\\ud800"',
}
for name, value in artifacts.items():
    path = root / name
    path.write_bytes(value)
    try:
        module.read_bounded_json(path, maximum_bytes=8192)
    except module.BoundedIOError as error:
        assert "JSON" in str(error), str(error)
    else:
        raise AssertionError(f"hostile JSON escaped normalization: {name}")
recursive = root / "recursive.json"
recursive.write_bytes(b"[]")
original_loads = module.json.loads
module.json.loads = lambda _value, **_kwargs: float("nan")
try:
    module.read_bounded_json(recursive, maximum_bytes=8192)
except module.BoundedIOError as error:
    assert "non-finite" in str(error), str(error)
else:
    raise AssertionError("non-finite parsed float escaped structural validation")
module.json.loads = lambda _value, **_kwargs: (_ for _ in ()).throw(
    RecursionError("nested")
)
try:
    module.read_bounded_json(recursive, maximum_bytes=8192)
except module.BoundedIOError as error:
    assert "malformed" in str(error), str(error)
else:
    raise AssertionError("JSON recursion failure escaped normalization")
finally:
    module.json.loads = original_loads
PY
}

test_batch_item_count_is_bounded() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
budget = module.DeadlineBudget(1, 2)
budget.consume_items([1, 2], "review items")
try:
    budget.consume_item("review items")
except module.BoundedIOError as error:
    assert "2-item limit" in str(error)
else:
    raise AssertionError("batch item ceiling was not enforced")
PY
}

run_case() {
  case "$1" in
    output-limit) test_output_limit_terminates_noisy_process ;;
    final-wait) test_final_wait_keeps_original_deadline ;;
    residual-group) test_success_reaps_residual_process_group ;;
    detached-tree) test_tracked_detached_descendant_is_cleaned ;;
    batch-deadline) test_batch_deadline_remains_absolute ;;
    selector-order) test_selector_failure_precedes_spawn ;;
    spawn-guard) test_input_validation_precedes_spawn ;;
    identity-signal) test_identity_bound_signaling_avoids_reused_pids ;;
    census-bounds) test_process_census_enforces_item_and_time_bounds ;;
    linux-census-stream) test_linux_child_inventory_streams_with_bounds ;;
    darwin-census-prune) test_darwin_descendant_refresh_prunes_stale_entries ;;
    partial-input) test_partial_input_writes_do_not_copy_remainder ;;
    artifact) test_json_artifact_is_bounded_and_regular ;;
    artifact-open-race) test_concurrent_artifact_replacements_are_rejected ;;
    decoded-strings) test_json_decoded_strings_are_bounded ;;
    hostile-json) test_hostile_json_failures_are_normalized ;;
    batch-items) test_batch_item_count_is_bounded ;;
    *) fail "unknown bounded-I/O test case: $1" ;;
  esac
}

if [ "$#" -gt 0 ]; then
  run_case "$1"
else
  for case_name in output-limit final-wait residual-group detached-tree \
    batch-deadline selector-order spawn-guard identity-signal census-bounds \
    linux-census-stream darwin-census-prune partial-input artifact \
    artifact-open-race decoded-strings hostile-json batch-items; do
    run_case "$case_name"
  done
fi

echo "fm-bounded-io tests passed"
