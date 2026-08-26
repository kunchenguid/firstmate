#!/usr/bin/env python3
"""Lean idempotent Spark liveness check and single initialization Cell.

Paste this file into a persistent MagiBook Python Cell.
Fill every placeholder from the captain-preference owner before running it.
The public functions accept a small injected Spark interface so behavior can be
tested without importing PySpark or starting a real SparkContext.
"""

from __future__ import annotations

import json

SPARK_SETTINGS = {
    "spark.app.name": "<APP_NAME>",
    "spark.master": "yarn",
    "spark.hadoop.yarn.cluster.name": "<SG_YARN_CLUSTER>",
    "spark.yarn.queue": "<AUTHORIZED_QUEUE>",
    "spark.dynamicAllocation.enabled": "<DYNAMIC_ALLOCATION_ENABLED>",
    "spark.shuffle.service.enabled": "<SHUFFLE_SERVICE_ENABLED>",
    "spark.dynamicAllocation.maxExecutors": "<MAX_EXECUTORS>",
    "spark.ui.showConsoleProgress": "<CONSOLE_PROGRESS_ENABLED>",
}

# Add validated settings here or pass them to ensure_spark().
ADDITIONAL_SPARK_SETTINGS = {}

ABSENT = "absent"
LIVE = "live"
INITIALIZING = "initializing"
AMBIGUOUS = "ambiguous"

_DETAIL_MAX = 500


class AmbiguousSparkStateError(RuntimeError):
    """Raised when ownership or liveness is unsafe to guess."""


class UnfilledPlaceholderError(ValueError):
    """Raised before a partially configured session reaches YARN."""


def _truncate(value):
    text = str(value)
    if len(text) <= _DETAIL_MAX:
        return text
    return text[: _DETAIL_MAX - 3] + "..."


def _is_placeholder(value):
    return isinstance(value, str) and value.startswith("<") and value.endswith(">")


def resolve_config(overrides=None):
    """Return the caller's full configuration without rewriting its values."""
    conf = dict(SPARK_SETTINGS)
    conf.update(ADDITIONAL_SPARK_SETTINGS)
    if overrides:
        conf.update(overrides)
    unfilled = sorted(key for key, value in conf.items() if _is_placeholder(value))
    if unfilled:
        raise UnfilledPlaceholderError(
            "unfilled Spark configuration placeholders: " + ", ".join(unfilled)
        )
    return conf


def classify_spark_error(exc):
    """Classify only explicit stopped/startup evidence; keep other errors unsafe."""
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


def _failure(operation, exc, application_id=None):
    state = classify_spark_error(exc)
    detail = "{} failed with {}: {}".format(
        operation, type(exc).__name__, _truncate(exc)
    )
    return state, application_id, detail


def _assess_context(ops, context, expected_app_id=None):
    if context is None:
        return ABSENT, None, "no active SparkContext in this kernel"
    try:
        if ops.is_stopped(context):
            return ABSENT, None, "active SparkContext reports stopped"
    except Exception as exc:  # classify the exact Spark failure; never swallow it
        return _failure("SparkContext stopped check", exc)

    try:
        application_id = ops.application_id(context)
    except Exception as exc:  # classify the exact Spark failure; never swallow it
        return _failure("application id check", exc)
    if not application_id:
        return INITIALIZING, None, "application id not yet assigned"
    if expected_app_id is not None and application_id != expected_app_id:
        return (
            AMBIGUOUS,
            application_id,
            "active application {} does not match expected {}".format(
                application_id, expected_app_id
            ),
        )

    try:
        ops.probe(context)
    except Exception as exc:  # classify the exact Spark failure; never swallow it
        return _failure("minimal Spark action", exc, application_id)
    return LIVE, application_id, "minimal Spark action succeeded"


def assess_spark_state(ops, expected_app_id=None):
    """Return absent, live, initializing, or ambiguous for the active context."""
    try:
        context = ops.active_context()
    except Exception as exc:  # classify the exact Spark failure; never swallow it
        return _failure("active SparkContext lookup", exc)
    return _assess_context(ops, context, expected_app_id)


def _status(state, action, application_id, detail):
    return {
        "state": state,
        "action": action,
        "applicationId": application_id,
        "detail": _truncate(detail),
    }


def ensure_spark(overrides=None, *, ops, expected_app_id=None):
    """Reuse a proven live context or build and probe exactly one new context."""
    state, application_id, detail = assess_spark_state(ops, expected_app_id)
    if state == LIVE:
        return _status(LIVE, "reused", application_id, detail)
    if state == INITIALIZING:
        return _status(
            INITIALIZING,
            "waiting",
            application_id,
            "initialization is still in progress; poll its exact task: " + detail,
        )
    if state == AMBIGUOUS:
        raise AmbiguousSparkStateError(
            "refusing to act on ambiguous Spark state: " + _truncate(detail)
        )

    # ABSENT is the only state allowed to initialize, and this path builds once.
    new_context = ops.build(resolve_config(overrides))
    new_state, new_application_id, new_detail = _assess_context(ops, new_context)
    if new_state == LIVE:
        return _status(LIVE, "initialized", new_application_id, new_detail)
    if new_state == INITIALIZING:
        return _status(
            INITIALIZING,
            "initialized-waiting",
            new_application_id,
            "the single initialization is still starting; poll its exact task: "
            + new_detail,
        )
    raise AmbiguousSparkStateError(
        "single initialization did not produce a proven live context; "
        "refusing a duplicate build: "
        + _truncate(new_detail)
    )


class _RealSparkOps:
    """Small PySpark adapter imported lazily for copy-ready Cell execution."""

    def active_context(self):
        from pyspark import SparkContext

        return SparkContext._active_spark_context

    def is_stopped(self, context):
        if getattr(context, "_jsc", None) is None:
            return True
        return bool(context._jsc.sc().isStopped())

    def application_id(self, context):
        return context.applicationId

    def probe(self, context):
        context.parallelize([1], 1).count()

    def build(self, conf):
        import logging
        import os

        from pyspark import SparkConf
        from pyspark.sql import SparkSession

        spark_conf = SparkConf()
        spark_conf.setAppName(conf["spark.app.name"])
        spark_conf.setMaster(conf["spark.master"])
        for key, value in conf.items():
            if key not in ("spark.app.name", "spark.master"):
                spark_conf.set(key, value)

        logging.disable(logging.CRITICAL)
        devnull = os.open(os.devnull, os.O_WRONLY)
        stdout_fd = os.dup(1)
        stderr_fd = os.dup(2)
        try:
            os.dup2(devnull, 1)
            os.dup2(devnull, 2)
            session = (
                SparkSession.builder.config(conf=spark_conf)
                .enableHiveSupport()
                .getOrCreate()
            )
        finally:
            os.dup2(stdout_fd, 1)
            os.dup2(stderr_fd, 2)
            os.close(devnull)
            os.close(stdout_fd)
            os.close(stderr_fd)

        globals()["spark"] = session
        context = session.sparkContext
        context.setLogLevel("OFF")
        logging.getLogger("py4j").disabled = True
        log4j = session._jvm.org.apache.log4j
        log4j.LogManager.getRootLogger().setLevel(log4j.Level.OFF)
        return context


if __name__ == "__main__":
    result = ensure_spark(ADDITIONAL_SPARK_SETTINGS, ops=_RealSparkOps())
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
