#!/usr/bin/env bash
# tests/fm-magibook-pyspark.test.sh - behavior tests for the executable
# magibook-pyspark initialization and bounded-query templates.
#
# These tests import the templates and drive their public callable behavior
# through faked Spark operations and fake MagiBook CLI subprocesses.
# They assert observable state, lifecycle transitions, task identity, process
# bounds, returned aggregates, and concrete refusal diagnostics.
# They never inspect or parse implementation source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required to drive the template)"; exit 0; }

TEMPLATE="$ROOT/.agents/skills/magibook-pyspark/templates/ensure_spark.py"
[ -f "$TEMPLATE" ] || fail "ensure_spark.py template missing"

TMP_ROOT=$(fm_test_tmproot fm-magibook-pyspark)
DRIVER="$TMP_ROOT/driver.py"

cat >"$DRIVER" <<'PY'
import importlib.util
import sys


spec = importlib.util.spec_from_file_location("ensure_spark", sys.argv[1])
es = importlib.util.module_from_spec(spec)
spec.loader.exec_module(es)

FULL = {
    "spark.app.name": "test-app",
    "spark.master": "yarn",
    "spark.hadoop.yarn.cluster.name": "test-cluster",
    "spark.yarn.queue": "test-queue",
    "spark.dynamicAllocation.enabled": "true",
    "spark.shuffle.service.enabled": "true",
    "spark.dynamicAllocation.maxExecutors": "10",
    "spark.ui.showConsoleProgress": "false",
}


class FakeOps:
    """Record builds and probes without importing PySpark."""

    def __init__(
        self,
        ctx=None,
        stopped=False,
        app_id="app-live",
        probe_exc=None,
        id_exc=None,
        build_id="app-built",
        build_probe_exc=None,
    ):
        self._ctx = ctx
        self._stopped = stopped
        self._app_id = app_id
        self._probe_exc = probe_exc
        self._id_exc = id_exc
        self._build_id = build_id
        self._build_probe_exc = build_probe_exc
        self.builds = 0
        self.probes = 0
        self.built_conf = None

    def active_context(self):
        return self._ctx

    def is_stopped(self, context):
        return self._stopped

    def application_id(self, context):
        if self._id_exc:
            raise self._id_exc
        return self._app_id

    def probe(self, context):
        self.probes += 1
        if self._probe_exc:
            raise self._probe_exc

    def build(self, conf):
        self.builds += 1
        self.built_conf = conf
        self._ctx = object()
        self._stopped = False
        self._app_id = self._build_id
        self._id_exc = None
        self._probe_exc = self._build_probe_exc
        return self._ctx


results = []


def check(name, condition):
    results.append((name, bool(condition)))


# Live contexts are proven by an action and reused without a build.
ops = FakeOps(ctx=object(), app_id="app-live")
status = es.ensure_spark(FULL, ops=ops)
check("live_reused", status["state"] == es.LIVE and status["action"] == "reused")
check("live_application_id", status["applicationId"] == "app-live")
check("live_probed", ops.probes == 1)
check("live_not_built", ops.builds == 0)

# Absence builds once, probes the returned context, then reports live.
ops = FakeOps(ctx=None, build_id="app-fresh")
status = es.ensure_spark(FULL, ops=ops)
check("absent_initialized", status["action"] == "initialized")
check("absent_application_id", status["applicationId"] == "app-fresh")
check("absent_one_build", ops.builds == 1)
check("new_context_probed", ops.probes == 1)

# A stopped context follows the same single-build path.
ops = FakeOps(ctx=object(), stopped=True, build_id="app-restarted")
status = es.ensure_spark(FULL, ops=ops)
check("stopped_initialized", status["action"] == "initialized")
check("stopped_one_build", ops.builds == 1)
check("stopped_replacement_probed", ops.probes == 1)

# Existing unhealthy contexts preserve their concrete cause and refuse a build.
for label, message in [
    ("authentication", "Kerberos authentication failed for principal"),
    ("authorization", "Permission denied on the authorized queue"),
    ("scheduler", "TaskScheduler lost executor while probing"),
    ("network", "Connection reset by peer to shuffle service"),
    ("query", "AnalysisException: table or view not found"),
]:
    ops = FakeOps(ctx=object(), probe_exc=RuntimeError(message))
    diagnostic = ""
    try:
        es.ensure_spark(FULL, ops=ops)
    except es.AmbiguousSparkStateError as exc:
        diagnostic = str(exc)
    check(f"ambiguous_{label}_refused", message in diagnostic)
    check(f"ambiguous_{label}_no_build", ops.builds == 0)

# Ownership mismatch is ambiguous before a query probe or build.
ops = FakeOps(ctx=object(), app_id="app-other")
refused = False
try:
    es.ensure_spark(FULL, ops=ops, expected_app_id="app-expected")
except es.AmbiguousSparkStateError:
    refused = True
check("application_mismatch_refused", refused and ops.builds == 0)

# Startup evidence waits for the exact task and never initializes again.
ops = FakeOps(
    ctx=object(),
    id_exc=RuntimeError("Application has not yet been assigned an id"),
)
status = es.ensure_spark(FULL, ops=ops)
check("initializing_id_waits", status["state"] == es.INITIALIZING)
check("initializing_id_no_build", ops.builds == 0)

ops = FakeOps(
    ctx=object(),
    probe_exc=RuntimeError("Initial job has not accepted any resources"),
)
status = es.ensure_spark(FULL, ops=ops)
check("initializing_probe_waits", status["action"] == "waiting")
check("initializing_probe_no_build", ops.builds == 0)

# Explicit dead-gateway evidence is absence and permits one probed replacement.
ops = FakeOps(
    ctx=object(),
    id_exc=RuntimeError("Java gateway process exited before sending its port"),
    build_id="app-after-gateway",
)
status = es.ensure_spark(FULL, ops=ops)
check("dead_gateway_rebuilt_once", ops.builds == 1)
check("dead_gateway_replacement_probed", ops.probes == 1)
check("dead_gateway_live", status["applicationId"] == "app-after-gateway")

# Unrecognized application-id failures stay ambiguous.
ops = FakeOps(
    ctx=object(),
    id_exc=RuntimeError("py4j network error while fetching the application id"),
)
refused = False
try:
    es.ensure_spark(FULL, ops=ops)
except es.AmbiguousSparkStateError:
    refused = True
check("unrecognized_id_refused", refused and ops.builds == 0)

# The absent build path cannot claim live when its mandatory probe is unhealthy.
message = "Kerberos authentication failed during the new-session probe"
ops = FakeOps(ctx=None, build_probe_exc=RuntimeError(message))
diagnostic = ""
try:
    es.ensure_spark(FULL, ops=ops)
except es.AmbiguousSparkStateError as exc:
    diagnostic = str(exc)
check("new_unhealthy_refused", message in diagnostic)
check("new_unhealthy_one_build", ops.builds == 1)
check("new_unhealthy_probed", ops.probes == 1)

# A newly built context that is still scheduling reports waiting, never live.
ops = FakeOps(
    ctx=None,
    build_probe_exc=RuntimeError("Initial job has not accepted any resources"),
)
status = es.ensure_spark(FULL, ops=ops)
check("new_initializing_waits", status["state"] == es.INITIALIZING)
check("new_initializing_action", status["action"] == "initialized-waiting")
check("new_initializing_one_build", ops.builds == 1)

# Caller values and additional settings pass through unchanged.
conf = es.resolve_config(
    {
        **FULL,
        "spark.dynamicAllocation.maxExecutors": "25",
        "spark.yarn.priority": "10",
    }
)
check("override_preserved", conf["spark.dynamicAllocation.maxExecutors"] == "25")
check("additional_preserved", conf["spark.yarn.priority"] == "10")

ops = FakeOps(ctx=None)
es.ensure_spark({**FULL, "spark.yarn.priority": "10"}, ops=ops)
check("build_configuration_preserved", ops.built_conf["spark.yarn.priority"] == "10")

placeholder_guarded = False
try:
    es.resolve_config()
except es.UnfilledPlaceholderError:
    placeholder_guarded = True
check("unfilled_placeholders_refused", placeholder_guarded)

failed = [name for name, ok in results if not ok]
for name, ok in results:
    print(("ok" if ok else "FAIL") + " - " + name)
if failed:
    print("FAILURES: " + ", ".join(failed))
    sys.exit(1)
print("ALL_TEMPLATE_CHECKS_PASSED")
PY

out=$(python3 "$DRIVER" "$TEMPLATE" 2>&1) || {
  printf '%s\n' "$out"
  fail "template behavior checks failed"
}
assert_contains "$out" "ALL_TEMPLATE_CHECKS_PASSED" "template driver did not report all checks passed"

pass "magibook-pyspark template: live reuse, one probed initialization, waiting, ambiguous refusal, config preservation"

PARALLEL_TEMPLATE="$ROOT/.agents/skills/magibook-pyspark/templates/parallel_queries.py"
[ -f "$PARALLEL_TEMPLATE" ] || fail "parallel_queries.py template missing"

PARALLEL_DRIVER="$TMP_ROOT/parallel_driver.py"

cat >"$PARALLEL_DRIVER" <<'PY'
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


spec = importlib.util.spec_from_file_location("parallel_queries", sys.argv[1])
pq = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pq
spec.loader.exec_module(pq)

root = Path(sys.argv[2])
root.mkdir()
fake_cli = root / "fake-magibook"
fake_cli.write_text(
    r'''#!/usr/bin/env python3
import json
import fcntl
import os
from pathlib import Path
import sys


state_path = Path(os.environ["FAKE_MAGIBOOK_STATE"])
lock_handle = Path(str(state_path) + ".lock").open("a+", encoding="utf-8")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
state = json.loads(state_path.read_text(encoding="utf-8"))
args = sys.argv[1:]
if args[:1] == ["--region"]:
    args = args[2:]


def save():
    state_path.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")


def emit(payload):
    save()
    print(json.dumps(payload, sort_keys=True))
    raise SystemExit(0)


event = {"args": args}
state.setdefault("events", []).append(event)

if args[:2] == ["cell", "view"]:
    cell_id = str(args[2])
    if "--output" in args:
        emit(
            {
                "id": cell_id,
                "output": [
                    {
                        "type": "text/plain",
                        "content": "MAGIBOOK_QUERY_STATUS "
                        + json.dumps(
                            {
                                "applicationId": state["applicationId"],
                                "queryKey": "query-" + cell_id,
                            },
                            sort_keys=True,
                        ),
                    }
                ],
                "is_truncated": False,
            }
        )
    emit({"id": cell_id, "cell_type": "python", "content": state["cells"].get(cell_id, "")})

if args[:2] == ["cell", "edit"]:
    cell_id = str(args[2])
    old_path = Path(args[args.index("--old-file") + 1])
    new_path = Path(args[args.index("--new-file") + 1])
    old_value = old_path.read_text(encoding="utf-8")
    if old_value != state["cells"].get(cell_id, ""):
        print("old content mismatch", file=sys.stderr)
        save()
        raise SystemExit(1)
    state["cells"][cell_id] = new_path.read_text(encoding="utf-8")
    emit({"cell_id": cell_id, "updated": True})

if args[:2] == ["cell", "run"]:
    cell_id = str(args[3])
    if state["scenario"] == "submit-error":
        save()
        print("rejected SENSITIVE_PAYLOAD_42", file=sys.stderr)
        raise SystemExit(1)
    task_id = "task-" + cell_id
    state.setdefault("submissions", []).append({"cellId": cell_id, "taskId": task_id})
    state.setdefault("taskCells", {})[task_id] = cell_id
    emit({"batch_task_id": task_id})

if args[:2] == ["cell", "task-status"]:
    task_id = str(args[2])
    cell_id = state["taskCells"][task_id]
    polls = state.setdefault("polls", {})
    count = int(polls.get(task_id, 0))
    polls[task_id] = count + 1
    scenario = state["scenario"]
    if scenario == "cancelled":
        statuses = ["cancelled"]
    elif scenario == "mixed" and cell_id == "2":
        statuses = ["failed"]
    elif scenario == "first-fails" and cell_id == "1":
        statuses = ["failed"]
    elif scenario == "serialized" and cell_id == "1":
        statuses = ["running", "running", "success"]
    elif scenario == "serialized":
        statuses = ["queued", "queued", "running", "success"]
    elif scenario == "interrupted":
        statuses = ["running"]
    else:
        statuses = ["running", "success"]
    status_value = statuses[min(count, len(statuses) - 1)]
    event["returnedStatus"] = status_value
    emit({"status": status_value})

print("unexpected fake command", args, file=sys.stderr)
save()
raise SystemExit(1)
''',
    encoding="utf-8",
)
fake_cli.chmod(fake_cli.stat().st_mode | stat.S_IXUSR)


class RecordingPopen:
    def __init__(self):
        self.calls = []
        self.lifecycle = []

    def __call__(self, argv, **kwargs):
        self.calls.append(
            {
                "argv": argv,
                "shell": kwargs.get("shell"),
            }
        )
        self.lifecycle.append(("start", argv))
        return RecordingProcess(subprocess.Popen(argv, **kwargs), argv, self.lifecycle)


class RecordingProcess:
    def __init__(self, process, argv, lifecycle):
        self._process = process
        self._argv = argv
        self._lifecycle = lifecycle
        self.stdout = process.stdout
        self.stderr = process.stderr
        self.pid = process.pid

    def poll(self):
        return self._process.poll()

    def terminate(self):
        return self._process.terminate()

    def kill(self):
        return self._process.kill()

    def wait(self, timeout=None):
        self._lifecycle.append(("wait", self._argv))
        return self._process.wait(timeout=timeout)

    @property
    def returncode(self):
        return self._process.returncode


class InterruptingSleep:
    def __init__(self):
        self.calls = 0

    def __call__(self, _seconds):
        self.calls += 1
        if self.calls == 1:
            raise KeyboardInterrupt()


class AdvancingClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        self.value += 1.0
        return self.value


results = []


def check(name, condition):
    results.append((name, bool(condition)))


def write_fake_state(path, scenario):
    path.write_text(
        json.dumps(
            {
                "scenario": scenario,
                "applicationId": "app-live",
                "cells": {},
                "events": [],
                "submissions": [],
                "taskCells": {},
                "polls": {},
            }
        ),
        encoding="utf-8",
    )


def build_cli(fake_state, recorder):
    environment = dict(os.environ)
    environment["FAKE_MAGIBOOK_STATE"] = str(fake_state)
    return pq.MagiBookCLI(
        "sg",
        executable=str(fake_cli),
        command_timeout=5,
        max_output_bytes=8192,
        sensitive_values=("SENSITIVE_PAYLOAD_42",),
        popen_factory=recorder,
        env=environment,
    )


def run_case(name, scenario, queries, max_parallel, **overrides):
    case_root = root / name
    case_root.mkdir()
    fake_state = case_root / "fake-state.json"
    registry = case_root / "registry.json"
    write_fake_state(fake_state, scenario)
    recorder = RecordingPopen()
    cli = build_cli(fake_state, recorder)
    aggregate = pq.run_parallel_queries(
        queries,
        initialization={"state": "live", "applicationId": "app-live"},
        cli=cli,
        book_uuid="book-test",
        state_path=registry,
        max_parallel=max_parallel,
        query_timeout=overrides.pop("query_timeout", 5),
        overall_timeout=overrides.pop("overall_timeout", 10),
        poll_interval=overrides.pop("poll_interval", 0.001),
        capability_probe_seconds=overrides.pop("capability_probe_seconds", 0),
        **overrides,
    )
    return aggregate, json.loads(fake_state.read_text(encoding="utf-8")), recorder, registry


def queries(count, *, sensitive=False):
    values = []
    for number in range(1, count + 1):
        literal = "SENSITIVE_PAYLOAD_42" if sensitive and number == 1 else str(number)
        values.append(
            pq.QuerySpec(
                key="query-{}".format(number),
                cell_id=str(number),
                sql="SELECT {!r} AS value".format(literal),
            )
        )
    return values


# The generated public Cell interface always reuses spark.sql and bounds display.
source = pq.render_query_cell(pq.QuerySpec("query-render", "1", "SELECT 1", 25))
check("render_uses_spark_sql", 'spark.sql("""SELECT 1""")' in source)
check("render_bounds_output", ".show(n=25, truncate=120)" in source)

# A live init proof is mandatory and no subprocess starts before it exists.
init_root = root / "init-guard"
init_root.mkdir()
init_state = init_root / "fake-state.json"
write_fake_state(init_state, "default")
init_recorder = RecordingPopen()
init_cli = build_cli(init_state, init_recorder)
guarded = False
try:
    pq.run_parallel_queries(
        queries(1),
        initialization={"state": "initializing", "applicationId": None},
        cli=init_cli,
        book_uuid="book-test",
        state_path=init_root / "registry.json",
    )
except pq.InitializationRequiredError:
    guarded = True
check("no_query_before_initialization", guarded and not init_recorder.calls)

# One registry has one local orchestrator owner at a time.
lock_root = root / "registry-lock"
lock_root.mkdir()
lock_state = lock_root / "fake-state.json"
lock_registry = lock_root / "registry.json"
write_fake_state(lock_state, "default")
lock_recorder = RecordingPopen()
lock_cli = build_cli(lock_state, lock_recorder)
lock_handle = Path(str(lock_registry) + ".lock").open("a+", encoding="utf-8")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
lock_refused = False
try:
    pq.run_parallel_queries(
        queries(1),
        initialization={"state": "live", "applicationId": "app-live"},
        cli=lock_cli,
        book_uuid="book-test",
        state_path=lock_registry,
    )
except pq.RegistryError:
    lock_refused = True
finally:
    lock_handle.close()
check("registry_lock_refuses_overlap", lock_refused and not lock_recorder.calls)

# Four independent tasks never exceed the explicit two-task bound.
aggregate, fake_state, recorder, _ = run_case(
    "bounded", "default", queries(4, sensitive=True), 2
)
check("bounded_all_success", aggregate["overallStatus"] == "success")
check("bounded_remote_tasks", aggregate["capability"]["maxObservedActiveTasks"] == 2)
check("bounded_concurrency_observed", aggregate["capability"]["mode"] == "concurrent-observed")
check("no_unmeasured_speedup_claim", aggregate["capability"]["speedupClaimed"] is False)
submit_lifecycle = [
    event
    for event in recorder.lifecycle
    if event[1][3:5] == ["cell", "run"]
]
check("bounded_children_started_before_wait",
    [event[0] for event in submit_lifecycle[:3]] == ["start", "start", "wait"]
)
check("every_submit_has_task", all(
    child["taskId"] for child in aggregate["children"] if child["purpose"] == "submit-query"
))
check("argv_arrays_and_no_shell", all(
    isinstance(call["argv"], list) and call["shell"] is False for call in recorder.calls
))
check("query_not_in_argv", all(
    "SENSITIVE_PAYLOAD_42" not in token
    for call in recorder.calls
    for token in call["argv"]
))
edit_paths = [
    Path(event["args"][event["args"].index("--new-file") + 1])
    for event in fake_state["events"]
    if event["args"][:2] == ["cell", "edit"]
]
check("protected_temp_material_cleaned", edit_paths and all(not path.exists() for path in edit_paths))

# Ordinary CLI failure summaries redact configured sensitive values.
aggregate, _, _, _ = run_case(
    "redaction", "submit-error", queries(1, sensitive=True), 1
)
error_summary = aggregate["queries"][0]["error"]["summary"]
check("sensitive_summary_redacted", error_summary == "rejected <redacted>")

# A second invocation attaches to the exact prior task and never submits again.
retry_root = root / "retry"
retry_root.mkdir()
retry_state = retry_root / "fake-state.json"
retry_registry = retry_root / "registry.json"
write_fake_state(retry_state, "default")
retry_recorder = RecordingPopen()
retry_cli = build_cli(retry_state, retry_recorder)
retry_query = queries(1)
retry_data = json.loads(retry_state.read_text(encoding="utf-8"))
retry_data["scenario"] = "interrupted"
retry_state.write_text(json.dumps(retry_data), encoding="utf-8")
first = pq.run_parallel_queries(
    retry_query,
    initialization={"state": "live", "applicationId": "app-live"},
    cli=retry_cli,
    book_uuid="book-test",
    state_path=retry_registry,
    max_parallel=1,
    query_timeout=5,
    overall_timeout=10,
    poll_interval=0.001,
    sleep=InterruptingSleep(),
)
retry_data = json.loads(retry_state.read_text(encoding="utf-8"))
retry_data["scenario"] = "default"
retry_state.write_text(json.dumps(retry_data), encoding="utf-8")
second = pq.run_parallel_queries(
    retry_query,
    initialization={"state": "live", "applicationId": "app-live"},
    cli=retry_cli,
    book_uuid="book-test",
    state_path=retry_registry,
    max_parallel=1,
    query_timeout=5,
    overall_timeout=10,
    poll_interval=0.001,
)
retry_data = json.loads(retry_state.read_text(encoding="utf-8"))
status_task_ids = [
    event["args"][2]
    for event in retry_data["events"]
    if event["args"][:2] == ["cell", "task-status"]
]
check("retry_one_submission", len(retry_data["submissions"]) == 1)
check("retry_started_from_pending", first["queries"][0]["status"] == "interrupted")
check("retry_reuses_exact_task", second["queries"][0]["reusedTask"] is True)
check("retry_polls_only_exact_task", set(status_task_ids) == {first["queries"][0]["taskId"]})

# A mixed terminal result is an aggregate failure, never a false success.
aggregate, _, _, _ = run_case("mixed", "mixed", queries(2), 2)
statuses = {item["status"] for item in aggregate["queries"]}
check("mixed_result_preserved", statuses == {"success", "failure"})
check("mixed_overall_failure", aggregate["overallStatus"] == "partial-failure")

# A peer failure with a still-pending query stops submissions and exits promptly.
aggregate, failed_state, _, _ = run_case(
    "peer-fail-pending", "first-fails", queries(2), 1, overall_timeout=2.0
)
check("peer_failure_recorded", aggregate["queries"][0]["status"] == "failure")
check("peer_failure_stops_submission", aggregate["queries"][1]["status"] == "not-submitted")
check(
    "peer_failure_reason_is_peer",
    aggregate["queries"][1].get("reason") == "peer-failure",
)
check(
    "peer_failure_exit_bounded",
    aggregate["elapsedSeconds"] < 2.0,
)
check("peer_failure_single_submission", len(failed_state["submissions"]) == 1)
check("peer_failure_overall", aggregate["overallStatus"] == "partial-failure")
check("peer_failure_no_remote_work", aggregate["remoteWorkRemaining"] == [])

# Remote cancellation is terminal and a local timeout leaves the exact task reported.
aggregate, _, _, _ = run_case("cancelled", "cancelled", queries(1), 1)
check("cancellation_preserved", aggregate["queries"][0]["status"] == "cancelled")
timeout_clock = AdvancingClock()
aggregate, _, _, _ = run_case(
    "timeout",
    "interrupted",
    queries(1),
    1,
    query_timeout=0.5,
    wall_clock=timeout_clock,
)
check("timeout_preserved", aggregate["queries"][0]["status"] == "timeout")
check("timeout_remote_work", aggregate["remoteWorkRemaining"][0]["taskId"] == "task-1")

# A child whose stdio reaches EOF before exit still waits only until the deadline.
class DetachedStdioProcess:
    """Local child that closes stdout and stderr while still running."""

    def __init__(self):
        out_read, out_write = os.pipe()
        err_read, err_write = os.pipe()
        self.stdout = os.fdopen(out_read, "rb", buffering=0)
        self.stderr = os.fdopen(err_read, "rb", buffering=0)
        os.close(out_write)
        os.close(err_write)
        self.pid = 4242
        self.exited = False
        self.terminated = False
        self.killed = False
        self.unbounded_wait_violations = 0

    def poll(self):
        return 0 if self.exited else None

    def terminate(self):
        self.terminated = True
        self.exited = True

    def kill(self):
        self.killed = True
        self.exited = True

    def wait(self, timeout=None):
        if self.exited:
            return 0
        if timeout is None:
            self.unbounded_wait_violations += 1
            raise RuntimeError("unbounded wait on a live local child")
        raise subprocess.TimeoutExpired(["detached-stdio-fake"], timeout)


detached_root = root / "detached-stdio"
detached_root.mkdir()
detached_state = detached_root / "fake-state.json"
write_fake_state(detached_state, "default")
detached_process = DetachedStdioProcess()
detached_cli = pq.MagiBookCLI(
    "sg",
    executable="unused-magibook",
    command_timeout=0.2,
    popen_factory=lambda argv, **kwargs: detached_process,
)
detached_error = None
try:
    detached_cli.invoke_json("view-cell", "query-detached", None, "cell", "view", "1")
except pq.CLICommandError as exc:
    detached_error = exc
check(
    "detached_stdio_bounded",
    detached_error is not None and detached_error.timed_out is True,
)
check(
    "detached_stdio_timeout_category",
    detached_error is not None and detached_error.category == "timeout",
)
check(
    "detached_stdio_not_remote_cancellation",
    detached_error is not None
    and "did not cancel remote work" in detached_error.summary,
)
check(
    "detached_stdio_child_stopped",
    detached_process.terminated
    and detached_process.unbounded_wait_violations == 0,
)
check(
    "detached_stdio_audit_recorded",
    detached_cli.children and detached_cli.children[0]["timedOut"] is True,
)

# Queued overlap downgrades only remaining work to sequential execution.
aggregate, serialized_state, _, _ = run_case(
    "serialized", "serialized", queries(4), 3
)
check("serialized_fallback", aggregate["capability"]["mode"] == "serialized-fallback")
events = serialized_state["events"]
fourth_submit = next(
    (
        index
        for index, event in enumerate(events)
        if event["args"][:2] == ["cell", "run"] and event["args"][3] == "4"
    ),
    -1,
)
second_terminal = max(
    (
        index
        for index, event in enumerate(events)
        if event["args"][:2] == ["cell", "task-status"]
        and event["args"][2] == "task-2"
        and event.get("returnedStatus") == "success"
    ),
    default=-1,
)
check("serialized_remaining_waited", fourth_submit > second_terminal)
check("serialized_all_success", aggregate["overallStatus"] == "success")

# Interruption reconciles known tasks and reports remote work without cancelling it.
interrupt_sleep = InterruptingSleep()
aggregate, interrupted_state, _, _ = run_case(
    "interrupted",
    "interrupted",
    queries(3),
    2,
    sleep=interrupt_sleep,
)
check("interruption_aggregate", aggregate["overallStatus"] == "interrupted")
check("interruption_remote_work", {
    item["taskId"] for item in aggregate["remoteWorkRemaining"]
} == {"task-1", "task-2"})
check("interruption_did_not_cancel", all(
    "cancel" not in event["args"] and "delete" not in event["args"]
    for event in interrupted_state["events"]
))
check("interruption_left_unsubmitted", aggregate["queries"][2]["status"] == "not-submitted")

failed = [name for name, ok in results if not ok]
for name, ok in results:
    print(("ok" if ok else "FAIL") + " - " + name)
if failed:
    print("FAILURES: " + ", ".join(failed))
    sys.exit(1)
print("ALL_PARALLEL_QUERY_CHECKS_PASSED")
PY

parallel_out=$(python3 "$PARALLEL_DRIVER" "$PARALLEL_TEMPLATE" "$TMP_ROOT/parallel" 2>&1) || {
  printf '%s\n' "$parallel_out"
  fail "parallel query template behavior checks failed"
}
assert_contains "$parallel_out" "ALL_PARALLEL_QUERY_CHECKS_PASSED" "parallel query driver did not report all checks passed"

pass "magibook-pyspark parallel template: bounded subprocesses, exact retries, fallback, terminal outcomes, interruption"
