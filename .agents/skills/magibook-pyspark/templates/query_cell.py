#!/usr/bin/env python3
"""Query Cell template: obtain the ensured Spark session and run business logic.

Paste this whole file into a persistent MagiBook `python` Cell that runs AFTER
the initialization Cell built from ``ensure_spark.py``.
This Cell never builds a SparkContext of its own: it obtains the session the
init Cell ensured, verifies that session is still usable through the same
minimal-action liveness check, and only then runs its ``spark.sql`` business
logic.
The reusable logic lives in ``run_query`` so a test harness can import this file
and drive it with a faked session, without a real cluster.

Contract this template enforces:

- All query work goes through ``spark.sql(\"\"\"SELECT ...\"\"\")`` on the ensured
  session. It never uses Dorado, TQS, or any direct SQL submission path.
- It re-verifies session usability with the shared ``ensure_spark`` liveness
  check before querying, so a dead or ambiguous kernel is refused with a concrete
  diagnostic instead of a misleading query error.
- It returns and prints a bounded, machine-readable status carrying the
  application id, so a later Cell can confirm it reused the same session.

Fill the ``SELECT ...`` body with your business logic before running.
Do not paste credentials, user identifiers, Book IDs, task IDs, dates, or table
names anywhere this template does not already require them; keep task-specific
literals in the query body you author for the run, not in the reusable frame.
"""

from __future__ import annotations

import json

# The init Cell defined these in this kernel's globals. Import-for-tests keeps a
# standalone import working; inside a MagiBook kernel the names already exist.
try:  # pragma: no cover - exercised only inside a live MagiBook kernel
    assess_spark_state  # type: ignore[used-before-def]  # noqa: F821
    AmbiguousSparkStateError  # type: ignore[used-before-def]  # noqa: F821
    LIVE  # type: ignore[used-before-def]  # noqa: F821
    _RealSparkOps  # type: ignore[used-before-def]  # noqa: F821
except NameError:  # pragma: no cover - import path for tooling and tests
    from ensure_spark import (  # noqa: F401
        LIVE,
        AmbiguousSparkStateError,
        _RealSparkOps,
        assess_spark_state,
    )


_PREVIEW_MAX = 50


def get_ensured_session(get_session, *, ops, expected_app_id=None):
    """Return a session proven live, refusing a dead or ambiguous kernel.

    ``get_session`` returns the session object the init Cell ensured.
    ``ops`` is the same injected Spark-ops interface ``ensure_spark`` uses; the
    liveness re-check runs its minimal action rather than trusting object
    presence.
    This never builds a context: it re-assesses state and refuses anything that
    is not live, so a missing init Cell surfaces as a concrete error here instead
    of this Cell silently starting a second SparkContext.
    Raises ``AmbiguousSparkStateError`` when health is unclear, and
    ``RuntimeError`` when the session is absent, still initializing, or otherwise
    not live.
    """
    state, app_id, detail = assess_spark_state(ops, expected_app_id=expected_app_id)
    if state == "ambiguous":
        raise AmbiguousSparkStateError(
            "refusing to query on ambiguous Spark state: " + detail
        )
    if state != LIVE:
        raise RuntimeError(
            "ensured Spark session is not live before query "
            "(state={}, run the init Cell first): {}".format(state, detail)
        )
    session = get_session()
    if session is None:
        raise RuntimeError("no ensured Spark session available in this kernel")
    return session, app_id


def run_query(sql_text, get_session, *, ops, expected_app_id=None, row_reader=None):
    """Run ``sql_text`` on the ensured session and return a bounded status.

    Only ``spark.sql`` is used to submit the query, never a direct submission
    path.
    ``row_reader`` maps the resulting DataFrame to a bounded Python structure;
    it defaults to collecting rows as dicts. Keep results bounded in the query
    itself (aggregate or ``LIMIT``) so the Cell output stays small.
    """
    session, app_id = get_ensured_session(
        get_session, ops=ops, expected_app_id=expected_app_id
    )
    dataframe = session.sql(sql_text)
    if row_reader is None:
        rows = [row.asDict() for row in dataframe.collect()]
        preview = rows[:_PREVIEW_MAX]
    else:
        preview = row_reader(dataframe)
    return {
        "applicationId": app_id,
        "status": "OK",
        "rowsPreview": preview,
    }


if __name__ == "__main__":
    # Business logic goes here. Replace the SELECT body; keep the frame as-is.
    QUERY = """
        SELECT ...
    """

    def _get_session():
        return globals().get("spark")

    result = run_query(QUERY, _get_session, ops=_RealSparkOps())
    print(json.dumps(result, ensure_ascii=False))
