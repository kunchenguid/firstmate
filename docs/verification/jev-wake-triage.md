# Jev stale-escalation triage verification

Audience: maintainer verification.

This record supports the default-on Jev classifier owned by [`../configuration.md`](../configuration.md) ("Jev stale-escalation triage") and hooked from `bin/fm-watch.sh`'s at-threshold wedge path.
It records only facts that must be re-established when the typesafe.ai System One API or the watcher's stale-escalation probes change.
Incident chronology stays in the private task report.

## Portable behavior

`tests/fm-jev-wake-triage.test.sh` drives `bin/fm-jev-wake-triage.sh` with a fake `curl` that records argv, the request body, the header on file descriptor 3, and whether the secret reached its environment.
It proves an absent `TYPESAFE_API_KEY`, and a key present only in `.env`, print `action=unavailable`, stamp `jev_triage.unavailable` with the task class, exit 0, and never invoke `curl`.
It proves a `true_wedge` Choice returns `action=escalate`, a `pipeline_wait` or `healthy_idle` Choice returns `action=suppress`, and HTTP 500, transport failure, and a malformed answer fail-open to `action=unavailable`.
It proves the request uses `https://api.typesafe.ai/v1/systemone`, asks one Choice with `pipeline_wait`/`true_wedge`/`healthy_idle` and one Noul, and sends the key only as the bearer header.
It proves the first N calibration rows include the input summary and Jev answer, and that telemetry keeps counting after that cap.
Watcher cases replace the helper through `FM_JEV_WAKE_TRIAGE_BIN` and prove `pipeline_wait` suppresses without advancing the escalation counter, `true_wedge` and `action=unavailable` keep today's possible-wedge wake, and `config/jev-wake-triage=off` skips the helper entirely.
They also prove the `FM_JEV_WAKE_TRIAGE` override in both directions: `off` skips the helper with no config file present, and `on` re-enables the gate over a config file that says `off`.

```console
$ bash tests/fm-jev-wake-triage.test.sh | tail -1
# all fm-jev-wake-triage tests passed
```

A live run needs a vault-injected `TYPESAFE_API_KEY` and is not part of the suite.
