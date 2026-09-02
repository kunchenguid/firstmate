# Verification: model-routing benchmark isolation

Active empirical facts about which confinement mechanisms actually deny benchmark sibling access.
`docs/model-routing-benchmark.md` owns why the gates exist; `bin/fm-bench-gate.sh --help` owns their mechanics.

Refresh this record with:

```
bin/fm-test-run.sh tests/fm-bench-isolation-e2e.test.sh
```

That test provisions two real entrant clones with detached candidate commits, then runs all seven sibling-access probes inside the declared confinement.
It refuses a pass that checked nothing: each denial requires a positive control proving the same probe reaches the target unconfined.

## Per-mechanism results

Recorded 2026-09-02 on Darwin 27.0.0.

| Mechanism | Storage and filesystem | Process table | Environment | Verdict |
|---|---|---|---|---|
| `container` (Docker 29.7.2, `debian:stable-slim`) | denied | denied | denied | Clears `isolation-verify` |
| `bwrap` | not measured here (absent on this host) | expected denied via `--unshare-pid` | denied | Unverified; measure before relying on it |
| `sandbox-exec` (macOS) | filesystem only | not confined | denied | Cannot clear the gate on its own |
| `none` | leaks | leaks | leaks | Present only so the probe set can be proven non-vacuous |

Exact output of the container run:

```
$ bin/fm-test-run.sh tests/fm-bench-isolation-e2e.test.sh
ok - enforced isolation (container) denies file, worktree, object, unreachable-object,
     sealed-material, process, and environment access
ok - the same confinement still lets an entrant work in its own private clone
```

The same run under `--mechanism none` refuses with all seven probe classes reported `PROBE LEAKED`, which is what proves the probes are not vacuous.

## Why the probes do not depend on git or ps

`debian:stable-slim` ships neither `git` nor `ps`:

```
$ docker run --rm debian:stable-slim sh -c 'command -v git || echo MISSING'
MISSING
$ docker run --rm debian:stable-slim sh -c 'command -v ps || echo MISSING'
MISSING
```

An earlier probe revision treated a missing tool as a denial, so this image cleared the gate while enforcing nothing measurable on three probe classes.
Each probe now measures the underlying capability by whatever means the environment offers - reading the object bytes directly when `git` is absent, reading `/proc/*/cmdline` when `ps` is absent - and reports `PROBE INCONCLUSIVE` when it has no means at all.
The gate refuses on inconclusive, so a confinement whose image simply lacks a tool can no longer look like enforced isolation.

## What this does not establish

A cleared mechanism bounds what an entrant can reach from inside the confinement.
It says nothing about exposure that happened before the benchmark: a model that already saw a historical packet in earlier work is a provenance question, not an isolation one, and `provenance-check` owns it.
