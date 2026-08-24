#!/usr/bin/env python3
"""Idempotent Spark liveness check plus single initialization for a MagiBook Cell.

Paste this whole file into a persistent MagiBook `python` Cell.
When a Cell runs it top to bottom the ``__main__`` block executes, resolves the
Spark configuration from the placeholders below, checks whether a usable Spark
session already exists in this kernel, and initializes exactly once only when
one does not.
The reusable logic lives in module-level functions so a test harness can import
this file and drive the same behavior with a faked Spark interface, without ever
starting a real SparkContext.

Contract this template enforces:

- Liveness is proven by a minimal Spark ACTION, never by the presence of
  ``SparkContext._active_spark_context`` alone.
- A probe failure is classified, not swallowed: authentication, authorization,
  scheduler, network, and query failures stay distinguishable from genuine
  absence, and anything unrecognized is treated as ambiguous rather than absent.
- Ambiguous ownership or health stops safely with a concrete diagnostic; it
  never stops an unknown application and never launches a second context.
- Caller configuration is preserved verbatim; the home fills the placeholders
  from the captain-preference owner and this template never silently rewrites a
  validated default.

Fill every ``<...>`` placeholder before running.
Do not paste credentials, user identifiers, Book IDs, task IDs, dates, or table
names into this Cell.
"""

from __future__ import annotations

import json
import time

# --- Configuration placeholders --------------------------------------------
#
# These are the reusable knobs the home fills from the captain-preference owner.
# The private, environment-specific values (SG YARN cluster, authorized queue,
# max executors) stay as placeholders here so this shared template carries no
# home-specific identifiers.
# The safe, non-private defaults below ship as concrete values and remain
# overridable through the CONFIG_OVERRIDES dict without being rewritten here.

BASE_SPARK_DEFAULTS = {
    # Safe, non-private validated defaults. Override, never silently changed.
    "spark.dynamicAllocation.enabled": "true",
    "spark.shuffle.service.enabled": "true",
    "spark.ui.showConsoleProgress": "false",
}

PLACEHOLDER_SPARK_SETTINGS = {
    # Filled per home from the captain-preference owner (see the skill).
    "spark.app.name": "<APP_NAME>",
    "spark.master": "<SPARK_MASTER>",
    "spark.hadoop.yarn.cluster.name": "<SG_YARN_CLUSTER>",
    "spark.yarn.queue": "<AUTHORIZED_QUEUE>",
    "spark.dynamicAllocation.maxExecutors": "<MAX_EXECUTORS>",
}

# Any additional Spark settings the home needs, preserved verbatim.
# Example: {"spark.yarn.priority": "10"}.
CONFIG_OVERRIDES: dict = {}

# --- State model ------------------------------------------------------------

ABSENT = "absent"  # no usable context; safe to initialize exactly once
LIVE = "live"  # context present and a minimal action succeeded; reuse it
INITIALIZING = "initializing"  # context is still coming up; poll, never rebuild
AMBIGUOUS = "ambiguous"  # ownership or health unclear; stop safely, never guess

_DETAIL_MAX = 500


class AmbiguousSparkStateError(RuntimeError):
    """Raised when Spark state is ambiguous and acting would be a guess."""


class UnfilledPlaceholderError(ValueError):
    """Raised when a required configuration placeholder was left unfilled."""


def _is_placeholder(value) -> bool:
    return isinstance(value, str) and value.startswith("<") and value.endswith(">")


def _truncate(text: str) -> str:
    text = str(text)
    if len(text) <= _DETAIL_MAX:
        return text
    return text[: _DETAIL_MAX - 3] + "..."


def resolve_config(overrides=None, *, allow_placeholders=False) -> dict:
    """Merge defaults, placeholders, and caller overrides into one Spark config.

    Caller overrides win and are preserved verbatim, so a home applying the
    captain's validated values never has them silently rewritten.
    A remaining ``<...>`` placeholder is a hard error unless ``allow_placeholders``
    is set, which keeps a half-filled config from reaching a real cluster.
    """
    conf = dict(BASE_SPARK_DEFAULTS)
    conf.update(PLACEHOLDER_SPARK_SETTINGS)
    if overrides:
        conf.update(overrides)
    if not allow_placeholders:
        unfilled = sorted(key for key, value in conf.items() if _is_placeholder(value))
        if unfilled:
            raise UnfilledPlaceholderError(
                "unfilled Spark configuration placeholders: " + ", ".join(unfilled)
            )
    return conf


def classify_spark_error(exc: BaseException) -> str:
    """Classify a probe-action failure without collapsing every error to absence.

    Returns one of ``ABSENT``, ``INITIALIZING``, or a not-absent verdict of
    ``AMBIGUOUS``.
    The default posture is deliberately conservative: only an unmistakable
    "the context or JVM bridge is gone" signal counts as absence, a distinct
    "still starting" signal counts as initializing, and every other failure
    (authentication, authorization, scheduler, network, query) stays a
    distinguishable non-absence failure so the caller refuses rather than
    silently starting a second context.
    """
    message = str(exc).lower()
    absent_markers = (
        "sparkcontext was shut down",
        "sparkcontext has been stopped",
        "attempted to use a stopped sparkcontext",
        "java gateway process exited",
        "gateway not started",
        "connection refused to the java gateway",
    )
    if any(marker in message for marker in absent_markers):
        return ABSENT
    if type(exc).__name__ == "Py4JError" and (
        "gateway" in message or "shut down" in message or "stopped" in message
    ):
        return ABSENT
    initializing_markers = (
        "initial job has not accepted any resources",
        "application has not yet been assigned",
        "spark context is still starting",
        "not yet ready",
    )
    if any(marker in message for marker in initializing_markers):
        return INITIALIZING
    return AMBIGUOUS


def assess_spark_state(ops, *, expected_app_id=None):
    """Classify the current Spark state through the injected ``ops`` interface.

    ``ops`` must provide ``active_context()``, ``is_stopped(ctx)``,
    ``application_id(ctx)``, and ``probe(ctx)``.
    ``probe`` performs a minimal Spark action and raises on any failure.
    Returns ``(state, application_id, detail)``.
    """
    ctx = ops.active_context()
    if ctx is None:
        return ABSENT, None, "no active SparkContext in this kernel"
    if ops.is_stopped(ctx):
        return ABSENT, None, "active SparkContext object reports stopped"

    try:
        app_id = ops.application_id(ctx)
    except Exception as exc:  # noqa: BLE001 - classify, never swallow
        verdict = classify_spark_error(exc)
        detail = "{}: {}".format(type(exc).__name__, _truncate(exc))
        if verdict == ABSENT:
            return ABSENT, None, "application id shows context gone: " + detail
        if verdict == INITIALIZING:
            return INITIALIZING, None, "application id not yet assigned: " + detail
        return AMBIGUOUS, None, "application id check failed, health unclear: " + detail
    if not app_id:
        return INITIALIZING, None, "application id not yet assigned"

    if expected_app_id is not None and app_id != expected_app_id:
        return (
            AMBIGUOUS,
            app_id,
            "active application {} does not match expected {}".format(
                app_id, expected_app_id
            ),
        )

    try:
        ops.probe(ctx)
    except BaseException as exc:  # noqa: BLE001 - classify, never swallow
        verdict = classify_spark_error(exc)
        detail = "{}: {}".format(type(exc).__name__, _truncate(exc))
        if verdict == ABSENT:
            return ABSENT, None, "probe shows context gone: " + detail
        if verdict == INITIALIZING:
            return INITIALIZING, app_id, "probe shows context still starting: " + detail
        return AMBIGUOUS, app_id, "probe failed, health unclear: " + detail

    return LIVE, app_id, "minimal Spark action succeeded"


def ensure_spark(
    overrides=None,
    *,
    ops,
    expected_app_id=None,
    initializing_max_attempts=1,
    initializing_sleep_seconds=15.0,
    sleep=time.sleep,
):
    """Return a usable Spark session status, initializing at most once.

    Behavior by assessed state:

    - ``LIVE``: reuse the existing session; never build.
    - ``ABSENT``: build exactly once from the resolved configuration.
    - ``INITIALIZING``: never build; re-probe up to ``initializing_max_attempts``
      times, then report a waiting status so the caller polls the exact
      initialization task instead of duplicating it.
    - ``AMBIGUOUS``: raise ``AmbiguousSparkStateError`` with a concrete
      diagnostic; never stop the unknown application and never build alongside it.

    Returns a bounded, machine-readable status dict including the application id.
    """
    attempt = 0
    while True:
        state, app_id, detail = assess_spark_state(ops, expected_app_id=expected_app_id)

        if state == LIVE:
            return {
                "state": LIVE,
                "action": "reused",
                "applicationId": app_id,
                "detail": _truncate(detail),
            }

        if state == AMBIGUOUS:
            raise AmbiguousSparkStateError(
                "refusing to act on ambiguous Spark state: " + _truncate(detail)
            )

        if state == INITIALIZING:
            if attempt < initializing_max_attempts:
                attempt += 1
                sleep(initializing_sleep_seconds)
                continue
            return {
                "state": INITIALIZING,
                "action": "waiting",
                "applicationId": app_id,
                "detail": _truncate(
                    "initialization still in progress; poll the init task, "
                    "do not resubmit: " + detail
                ),
            }

        # ABSENT: initialize exactly once for this run.
        conf = resolve_config(overrides)
        new_app_id = ops.build(conf)
        return {
            "state": LIVE,
            "action": "initialized",
            "applicationId": new_app_id,
            "detail": "initialized a single SparkContext for this run",
        }


class _RealSparkOps:
    """Default ops backed by pyspark, imported lazily so tests need no cluster."""

    def active_context(self):
        from pyspark import SparkContext

        return SparkContext._active_spark_context

    def is_stopped(self, ctx) -> bool:
        # Structural signal: a stopped context has released its Java gateway.
        return getattr(ctx, "_jsc", None) is None

    def application_id(self, ctx) -> str:
        return ctx.applicationId

    def _session(self, ctx):
        from pyspark.sql import SparkSession

        session = getattr(SparkSession, "_instantiatedSession", None)
        if session is not None:
            return session
        # Fall back to a session bound to the already-live context; getOrCreate
        # here reuses the active context and never starts a second one.
        return SparkSession.builder.getOrCreate()

    def probe(self, ctx) -> None:
        # Minimal distributed ACTION: forces the scheduler and executors so a
        # dead cluster cannot pass as live. Raises on any failure.
        self._session(ctx).sql("SELECT 1").collect()

    def build(self, conf: dict) -> str:
        import os

        from pyspark import SparkConf
        from pyspark.sql import SparkSession

        spark_conf = SparkConf()
        app_name = conf.get("spark.app.name")
        master = conf.get("spark.master")
        if app_name:
            spark_conf.setAppName(app_name)
        if master:
            spark_conf.setMaster(master)
        for key, value in conf.items():
            if key in ("spark.app.name", "spark.master"):
                continue
            spark_conf.set(key, value)

        # getOrCreate() emits JVM/gateway startup noise on stdout/stderr; mute it
        # only for the build window, then restore the descriptors.
        devnull = os.open(os.devnull, os.O_WRONLY)
        saved_out = os.dup(1)
        saved_err = os.dup(2)
        try:
            os.dup2(devnull, 1)
            os.dup2(devnull, 2)
            session = (
                SparkSession.builder.config(conf=spark_conf)
                .enableHiveSupport()
                .getOrCreate()
            )
        finally:
            os.dup2(saved_out, 1)
            os.dup2(saved_err, 2)
            os.close(devnull)
            os.close(saved_out)
            os.close(saved_err)

        globals()["spark"] = session
        return session.sparkContext.applicationId


if __name__ == "__main__":
    status = ensure_spark(CONFIG_OVERRIDES, ops=_RealSparkOps())
    print(json.dumps(status, ensure_ascii=False))
