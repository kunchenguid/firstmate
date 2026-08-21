#!/usr/bin/env python3
"""The worker provider every admitted behavior test gets unless it names another.

bin/fm-worker-lifecycle.py resolves FM_WORKER_PROVIDER_COMMAND with a DEFAULT of
the real Azure adapter:

    provider_command = os.environ.get(
        "FM_WORKER_PROVIDER_COMMAND", "python3 {}".format(shlex.quote(str(AZURE_PROVIDER))))

That default is right for an operator and catastrophic for a test.  A unit that
omits the variable on purpose - to prove the lifecycle refuses a request - gets
the real adapter, and if the ambient environment also carries the operator's
FM_AZURE_* identity the request is not refused at all: it is served, and a real
billable VM appears that no controller record tracks.  That is not hypothetical.
It happened on 2026-08-20 (vm-fm7c799d-wkr-01, task tag `cloud-noenv-c7`, a
fixture id from tests/fm-spawn-cloud.test.sh).

So tests/run.sh binds THIS adapter as the suite-wide default.  It speaks the
provider protocol only far enough to refuse, loudly, on the first request, and it
records the reach so tests/run.sh can fail the suite over it.  A test that
genuinely drives a provider sets FM_WORKER_PROVIDER_COMMAND to its own fixture,
which wins because it is set on the test's own command line.

Fail closed, never fall through: an unset provider is a wiring mistake, and the
expensive direction is the one that silently works.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    payload = sys.stdin.read()
    try:
        request = json.loads(payload) if payload.strip() else {}
    except ValueError:
        request = {}
    action = request.get("action") or request.get("op") or "unknown"
    task = request.get("task") or request.get("id") or "unknown"
    test_script = os.environ.get("FM_TEST_CURRENT_TEST", "unknown-test")
    name = os.path.basename(test_script)

    log = os.environ.get("FM_TEST_CLOUD_REACH_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(
                "FM_CLOUD_REACH test={} via=provider action={} task={}\n".format(
                    name, action, task
                )
            )

    message = (
        "test admission refused: {} reached a worker provider without naming one. "
        "FM_WORKER_PROVIDER_COMMAND was not set by the test, so the lifecycle would "
        "otherwise have resolved the REAL Azure adapter (action={} task={}). Set "
        "FM_WORKER_PROVIDER_COMMAND to this test's fixture provider.".format(
            name, action, task
        )
    )
    print(message, file=sys.stderr)
    # Speak the protocol's failure shape too, so a caller that parses stdout gets
    # a refusal rather than a decode error it might treat as a transient.
    print(json.dumps({"ok": False, "error": message}))
    return 97


if __name__ == "__main__":
    raise SystemExit(main())
