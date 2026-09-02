# Verification: model-routing benchmark isolation

Active empirical facts about which confinement mechanisms actually deny benchmark sibling access.
`docs/model-routing-benchmark.md` owns why the gates exist; `bin/fm-bench-gate.sh --help` owns their mechanics.

Refresh this record with:

```
bin/fm-test-run.sh tests/fm-bench-isolation-e2e.test.sh
```

That test provisions two real entrant clones with detached candidate commits, then runs all seven sibling-access probes inside the declared confinement.
Every probe runs against the sibling's root, against each of its four declared private stores, and against any object store its clone reaches through `objects/info/alternates`.
It refuses a pass that checked nothing: each denial requires a positive control proving the same probe reaches the target unconfined, so each declared private store must hold material the probe can read without the confinement.
The portable gate suite also proves that a benchmark launch resolves the cleared wrapper and its recorded private layout before delivery, while an ordinary task id remains unchanged and an unavailable wrapper refuses the benchmark launch.

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

The restore portion of `tests/fm-bench-gate.test.sh` executes each archived evaluator through its recorded argv and compares the SHA-256 of its output to the archived result hash.
It also proves that an absolute path, a parent traversal, a symlink escape, a changed manifest binding, and a changed evaluator result all refuse before cleanup can be authorised.

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
Each probe now measures the underlying capability by whatever means the environment offers - reading the object bytes directly when `git` is absent, reading `/proc/*/cmdline` rather than asking `ps` - and reports `PROBE INCONCLUSIVE` when it has no means at all.
The gate refuses on inconclusive, so a confinement whose image simply lacks a tool can no longer look like enforced isolation.

The process probe reads `/proc` one file at a time and emits one line per process, then excludes only its own PID.
An earlier revision concatenated every `cmdline` into a single line, so the self-exclusion deleted the entire table and an image without `ps` reported a denial while the whole host process table was readable.
Measured on Linux in `debian:stable-slim`, which ships no `ps`, with a sibling process running in the same PID namespace:

```
$ docker run --rm -v "$PWD/bin:/probe:ro" debian:stable-slim /probe/driver.sh
PROBE LEAKED saw another benchmark process in the process table
```

The same command against the concatenating revision reported `PROBE DENIED only this probe's own process is visible`.
`tests/fm-bench-gate.test.sh` covers this on any host with a `/proc` filesystem, first with a sibling process running and then without.

## What this does not establish

A cleared mechanism bounds what an entrant can reach from inside the confinement.
It says nothing about exposure that happened before the benchmark: a model that already saw a historical packet in earlier work is a provenance question, not an isolation one, and `provenance-check` owns it.
