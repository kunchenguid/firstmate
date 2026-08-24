#!/usr/bin/env bash
# tests/fm-magibook-pyspark.test.sh - behavior tests for the executable
# magibook-pyspark initialization template.
#
# These tests import the template and drive its public callable behavior through
# a faked Spark interface.
# They assert observable state, build count, probe count, returned status,
# preserved configuration, and concrete refusal diagnostics.
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
