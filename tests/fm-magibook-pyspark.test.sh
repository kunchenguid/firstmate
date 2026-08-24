#!/usr/bin/env bash
# tests/fm-magibook-pyspark.test.sh - behavior tests for the magibook-pyspark
# skill's executable Cell templates (.agents/skills/magibook-pyspark/templates/).
#
# These drive the public callable behavior of the init and query templates
# through a FAKED Spark ops interface: no real cluster, no pyspark import. They
# assert observable outcomes - live reuse without building, exactly one build
# when absent, a waiting status (never a second build) while initializing, and a
# hard refusal on ambiguous/unhealthy state - plus config preservation and the
# query template's spark.sql-only, no-build contract.
#
# They never grep or parse the template source for strings; every assertion runs
# the imported functions and checks their return values or side effects.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required to drive the templates)"; exit 0; }

TEMPLATES="$ROOT/.agents/skills/magibook-pyspark/templates"
[ -f "$TEMPLATES/ensure_spark.py" ] || fail "ensure_spark.py template missing"
[ -f "$TEMPLATES/query_cell.py" ] || fail "query_cell.py template missing"

TMP_ROOT=$(fm_test_tmproot fm-magibook-pyspark)
DRIVER="$TMP_ROOT/driver.py"

cat >"$DRIVER" <<'PY'
import importlib.util
import sys

TEMPLATES = sys.argv[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{TEMPLATES}/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules[name] = module
    return module


es = load("ensure_spark")
qc = load("query_cell")

FULL = {
    "spark.app.name": "test-app",
    "spark.master": "yarn",
    "spark.hadoop.yarn.cluster.name": "virtual-test",
    "spark.yarn.queue": "root.test_queue",
    "spark.dynamicAllocation.maxExecutors": "5000",
}


class Row:
    def __init__(self, d):
        self._d = d

    def asDict(self):
        return self._d


class FakeDataFrame:
    def __init__(self, rows):
        self._rows = rows

    def collect(self):
        return [Row(r) for r in self._rows]


class FakeSession:
    def __init__(self, rows):
        self._rows = rows
        self.sql_calls = []

    def sql(self, text):
        self.sql_calls.append(text)
        return FakeDataFrame(self._rows)


class FakeOps:
    """Fully injected Spark ops. Records build() calls; never touches pyspark."""

    def __init__(self, ctx=None, stopped=False, app_id="app-live",
                 probe_exc=None, id_exc=None, build_id="app-built"):
        self._ctx = ctx
        self._stopped = stopped
        self._app_id = app_id
        self._probe_exc = probe_exc
        self._id_exc = id_exc
        self._build_id = build_id
        self.builds = 0
        self.built_conf = None

    def active_context(self):
        return self._ctx

    def is_stopped(self, ctx):
        return self._stopped

    def application_id(self, ctx):
        if self._id_exc:
            raise self._id_exc
        return self._app_id

    def probe(self, ctx):
        if self._probe_exc:
            raise self._probe_exc

    def build(self, conf):
        self.builds += 1
        self.built_conf = conf
        return self._build_id


results = []


def check(name, cond):
    results.append((name, bool(cond)))


# 1. Live: reuse, never build.
ops = FakeOps(ctx=object(), app_id="app-live")
status = es.ensure_spark(FULL, ops=ops)
check("live_reused", status["action"] == "reused" and status["state"] == es.LIVE)
check("live_app_id", status["applicationId"] == "app-live")
check("live_no_build", ops.builds == 0)

# 2. Absent: build exactly once.
ops = FakeOps(ctx=None, build_id="app-fresh")
status = es.ensure_spark(FULL, ops=ops)
check("absent_initialized", status["action"] == "initialized")
check("absent_one_build", ops.builds == 1)
check("absent_app_id", status["applicationId"] == "app-fresh")

# 2b. Stopped context is also absent -> single build.
ops = FakeOps(ctx=object(), stopped=True, build_id="app-restart")
status = es.ensure_spark(FULL, ops=ops)
check("stopped_initialized", status["action"] == "initialized" and ops.builds == 1)

# 3. Ambiguous probe failures refuse; never build, never stop unknown app.
for label, exc in [
    ("auth", RuntimeError("Kerberos authentication failed for principal")),
    ("authz", RuntimeError("Permission denied: user not allowed on queue")),
    ("scheduler", RuntimeError("TaskSchedulerImpl lost executor 7")),
    ("network", RuntimeError("Connection reset by peer to shuffle service")),
    ("query", RuntimeError("AnalysisException: Table or view not found")),
]:
    ops = FakeOps(ctx=object(), probe_exc=exc)
    refused = False
    try:
        es.ensure_spark(FULL, ops=ops)
    except es.AmbiguousSparkStateError:
        refused = True
    check(f"ambiguous_{label}_refused", refused)
    check(f"ambiguous_{label}_no_build", ops.builds == 0)

# 3b. Mismatched application id is ambiguous, not silent reuse.
ops = FakeOps(ctx=object(), app_id="app-other")
refused = False
try:
    es.ensure_spark(FULL, ops=ops, expected_app_id="app-expected")
except es.AmbiguousSparkStateError:
    refused = True
check("mismatch_refused", refused and ops.builds == 0)

# 4. Initializing: id-not-yet-assigned and startup probe -> waiting, no build.
ops = FakeOps(ctx=object(), id_exc=RuntimeError("application id not assigned yet"))
status = es.ensure_spark(FULL, ops=ops, initializing_max_attempts=0)
check("init_id_waiting", status["state"] == es.INITIALIZING and status["action"] == "waiting")
check("init_id_no_build", ops.builds == 0)

ops = FakeOps(ctx=object(), probe_exc=RuntimeError("Initial job has not accepted any resources"))
status = es.ensure_spark(FULL, ops=ops, initializing_max_attempts=0)
check("init_probe_waiting", status["state"] == es.INITIALIZING and ops.builds == 0)

# 4b. Initializing then live is polled, not duplicated.
class FlakyOps(FakeOps):
    def __init__(self):
        super().__init__(ctx=object(), app_id="app-slow")
        self._probe_calls = 0

    def probe(self, ctx):
        self._probe_calls += 1
        if self._probe_calls == 1:
            raise RuntimeError("Initial job has not accepted any resources")


slept = []
ops = FlakyOps()
status = es.ensure_spark(
    FULL, ops=ops, initializing_max_attempts=3,
    initializing_sleep_seconds=0.0, sleep=lambda s: slept.append(s),
)
check("poll_then_live", status["state"] == es.LIVE and status["action"] == "reused")
check("poll_no_build", ops.builds == 0)
check("poll_waited", len(slept) == 1)

# 5. Config preservation: caller overrides win verbatim; unfilled placeholder is a hard error.
conf = es.resolve_config({**FULL, "spark.dynamicAllocation.maxExecutors": "7000",
                          "spark.yarn.priority": "10"})
check("override_wins", conf["spark.dynamicAllocation.maxExecutors"] == "7000")
check("extra_preserved", conf["spark.yarn.priority"] == "10")
check("default_preserved", conf["spark.ui.showConsoleProgress"] == "false")

placeholder_guarded = False
try:
    es.resolve_config()
except es.UnfilledPlaceholderError:
    placeholder_guarded = True
check("placeholder_guard", placeholder_guarded)

# The build path must pass the exact resolved config through to ops.build.
ops = FakeOps(ctx=None)
es.ensure_spark({**FULL, "spark.yarn.priority": "10"}, ops=ops)
check("build_gets_priority", ops.built_conf.get("spark.yarn.priority") == "10")
check("build_gets_queue", ops.built_conf.get("spark.yarn.queue") == "root.test_queue")

# 6. Query template: spark.sql only, reuses live session, never builds.
ops = FakeOps(ctx=object(), app_id="app-query")
session = FakeSession([{"n": 7}])
result = qc.run_query("SELECT count(*) AS n FROM range(10)", lambda: session,
                      ops=ops, expected_app_id="app-query")
check("query_ok", result["status"] == "OK" and result["applicationId"] == "app-query")
check("query_used_spark_sql", session.sql_calls == ["SELECT count(*) AS n FROM range(10)"])
check("query_no_build", ops.builds == 0)
check("query_rows", result["rowsPreview"] == [{"n": 7}])

# 6b. Query refuses a dead kernel and never builds a second context.
ops = FakeOps(ctx=None)
session = FakeSession([{"n": 7}])
refused = False
try:
    qc.run_query("SELECT 1", lambda: session, ops=ops)
except RuntimeError:
    refused = True
check("query_dead_refused", refused and ops.builds == 0 and session.sql_calls == [])

# 6c. Query refuses ambiguous health with the ambiguous error, no sql submitted.
ops = FakeOps(ctx=object(), probe_exc=RuntimeError("Permission denied on queue"))
session = FakeSession([{"n": 7}])
refused = False
try:
    qc.run_query("SELECT 1", lambda: session, ops=ops)
except qc.AmbiguousSparkStateError:
    refused = True
check("query_ambiguous_refused", refused and session.sql_calls == [])

failed = [name for name, ok in results if not ok]
for name, ok in results:
    print(("ok" if ok else "FAIL") + " - " + name)
if failed:
    print("FAILURES: " + ", ".join(failed))
    sys.exit(1)
print("ALL_TEMPLATE_CHECKS_PASSED")
PY

out=$(python3 "$DRIVER" "$TEMPLATES" 2>&1) || {
  printf '%s\n' "$out"
  fail "template behavior checks failed"
}
assert_contains "$out" "ALL_TEMPLATE_CHECKS_PASSED" "template driver did not report all checks passed"

pass "magibook-pyspark templates: live reuse, single init, poll-not-duplicate, ambiguous refusal, config preservation, spark.sql-only query"
