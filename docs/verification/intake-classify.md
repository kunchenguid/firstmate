# Typed intake classification verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-intake-classify.sh` contract owned by [`../configuration.md`](../configuration.md) "Typed intake classification".

## Live System One probe

Run 2026-09-20 with the real key supplied only through the effective `FM_HOME/.env`, model `jev-latest`, confidence floor 0.6, timeout 5 seconds, and a request asking for a bounded pager investigation.

The exact command was:

```console
$ FM_HOME=<home-with-key> bin/fm-intake-classify.sh request.md --project firstmate
```

The relevant output fields observed in that run were:

```text
  model: jev-1.13.0   latency_ms: 369   tokens: 614/83
  deliverable: scout   confidence: 0.99
  probabilities: answer_now=0.0 unclear=0.0 scout=1.0 ship=0.0
  intent_clear: false   noul: 0.04
  urgency: routine   score: 0.05   confidence: 0.93
```

The API accepted one request containing Choice, NOUL, and Score questions in parallel.
Choice returned `choice`, `confidence`, and `probabilities`.
NOUL returned a 0 through 1 `noul` value without a confidence field.
Score accepted an ordered criteria list and returned `score`, `confidence`, `legend`, and probabilities keyed by the criteria positions.
The observed `scout` answer and low implementation-authorization score are compatible because implementation authorization gates only `ship`.

## Offline regression

`tests/fm-intake-classify.test.sh` uses fake curl and failing local-command fixtures to prove the exact off gate, `.env` precedence, one bounded typed request, shell-trace and process-boundary secret containment, status composition, and non-blocking runtime setup and request-I/O failures.

```console
$ bash tests/fm-intake-classify.test.sh | tail -1
# all fm-intake-classify tests passed
```
