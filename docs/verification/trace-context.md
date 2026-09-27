# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-08-03.
Shell: GNU bash 3.2.57 (macOS).
Comparison base: `main` at `976d97f`.


The suite touches no real harness or live fleet.
`tests/fm-session-start.test.sh` additionally proves only a lock-owning session start writes the effective state and a lock-refused read-only start leaves it unchanged.


```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
ALL TESTS PASSED
```

Run all three trace-context suites from the repo root; each prints one `ok - ...` per assertion.
A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running fleet.
