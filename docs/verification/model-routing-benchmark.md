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
It also requires every in-root private store to be ignored by Git and absent from the candidate index before launch, preventing routine candidate commits from absorbing benchmark object, temp, home, or session material.
The portable gate suite also proves that a benchmark launch resolves the cleared wrapper and its recorded private layout before delivery, while an ordinary task id remains unchanged, an unavailable wrapper refuses the benchmark launch, and a remote route cannot bypass the local confinement proof.

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

The restore portion of `tests/fm-bench-gate.test.sh` executes only an executable evaluator listed in each sample's content-addressed capture-and-scoring evidence group, compares its genuine restored-tree output hash to the archived result hash, and requires a different successful output after perturbing the manifest's declared scored inputs.
The genuine and perturbed executions receive separate freshly materialised evidence and working directories, so evaluator state cannot manufacture the required difference.
It also proves that an absolute path, a parent traversal, a symlink escape, an empty or escaping scored-input declaration, an unlisted evidence file including nested `manifest.json`, an arbitrary command, an evaluator that ignores restored content, an unaddressed evaluator, a changed manifest binding, a changed evaluator result, and an archive mutation during the rerun all refuse before cleanup can be authorised.

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
Each probe now measures the underlying capability by whatever means the environment offers - reading object bytes directly when `git` is absent, reading `/proc/*/cmdline` rather than asking `ps`, and using shell builtins where no external utility is necessary - and reports `PROBE INCONCLUSIVE` when a required utility such as `find` is absent and no alternative can measure the access.
The gate refuses on inconclusive, so a confinement whose image simply lacks a tool can no longer look like enforced isolation.

The process probe reads `/proc` one file at a time and emits one line per process while reading its marker from private material instead of passing the marker through any gate-created argv.
An earlier revision concatenated every `cmdline` into a single line, so the self-exclusion deleted the entire table and an image without `ps` reported a denial while the whole host process table was readable.
Measured on Linux in `debian:stable-slim`, which ships no `ps`, with a sibling process running in the same PID namespace:

```
$ docker run --rm -v "$PWD/bin:/probe:ro" debian:stable-slim sh -c 'marker=fm-bench-marker-$$; printf "%s\n" "$marker" >/tmp/process-target; cp /bin/sleep "/tmp/$marker"; "/tmp/$marker" 30 & PROCESS_INSPECTION_MARKER_FILE=/tmp/process-target /probe/fm-bench-probe.sh process_inspection'
PROBE LEAKED saw another benchmark process in the process table
```

The same command against the concatenating revision reported `PROBE DENIED only this probe's own process is visible`.
`tests/fm-bench-gate.test.sh` holds a probe at its process-table read and confirms the marker is absent from every visible launch argv before proving both the no-sibling denial and genuine-sibling leak paths.

## What this does not establish

A cleared mechanism bounds what an entrant can reach from inside the confinement.
It says nothing about exposure that happened before the benchmark: a model that already saw a historical packet in earlier work is a provenance question, not an isolation one, and `provenance-check` owns it.
