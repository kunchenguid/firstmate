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
It also proves that a wrapper which returns probe denials but is not the trusted launch-capable confinement wrapper cannot clear `isolation-verify`.

## Per-mechanism results

Recorded 2026-09-02 on Darwin 27.0.0.

| Mechanism | Storage and filesystem | Process table | Environment | Verdict |
|---|---|---|---|---|
| `container` (Docker 29.7.2, `debian:stable-slim`) | denied | denied | denied | Clears `isolation-verify` |
| `bwrap` | not measured here (absent on this host) | expected denied via `--unshare-pid` | denied | Unverified; measure before relying on it |
| `sandbox-exec` (macOS) | not measured because its profile aborted before command execution | not measured | not measured | Removed; the wrapper rejects this mechanism |
| `none` | leaks | leaks | leaks | Present only so the probe set can be proven non-vacuous |

Exact output of the container run:

```
$ bin/fm-test-run.sh tests/fm-bench-isolation-e2e.test.sh
ok - enforced isolation (container) denies file, worktree, object, unreachable-object,
     sealed-material, process, and environment access
ok - the same confinement still lets an entrant work in its own private clone
```

The restore portion of `tests/fm-bench-gate.test.sh` restores every sample in turn, releases each restore workspace after validation, and retains only the selected replay tree before loading a confinement or executing archived code.
Before restoring, it proves that structured track, role, candidate, and packet identities exactly cover the planned scored-output set, that sample roots and nested entries contain no symlink or special-file escape, and that distinct role-specific artifacts populate all eight evidence groups.
It confines differential execution to the first sample in stable lexical order, which bounds execution cost and records the exercised sample in the cleanup receipt without bounding declaration validation.
It executes only a content-addressed evaluator from the capture-and-scoring evidence group and compares its genuine restored-tree output hash to the archive.
The gate-owned pure-data mutators cover JSON values, TypeScript, JavaScript, CSS and HTML text tokens, and pixels in non-interlaced 8-bit PNG inputs.
JSON and source genuine copies retain their archived bytes, while both PNG copies use the same deterministic equal-length gate encoding and the recorded PNG result hash covers that prepared genuine copy.
PNG decompression is capped at a 128 MiB raster before allocation, and a stream or declared dimension outside that bound is a named refusal.
Each complete run root is created in stable path order, receives matching ownership, permissions, access times, and modification times, and is compared path by path for directory order, settable metadata, byte length, and bytes before either copy executes.
Every gate-owned mutation preserves byte length with no scored-path exemption, so a declaration that cannot change at equal width is refused before execution.
The resulting perturbed copy may differ only through the declared value, token, or filtered pixel byte and must produce a different successful evaluator output.
At least one scored input per evaluator must prove dependence, while another input may remain explicitly unproven per input in both output and receipt.
The portable declaration fixtures refuse an invalid declared perturbation, and the execution fixtures prove that a valid structured mutation reaches a strict parser while a parser rejection is reported as inconclusive rather than as evidence of an input-invariant evaluator.
The genuine and perturbed executions receive independent opaque roots through the preflight-proven confinement wrapper, with networking disabled and no archive, repository, operator home, or wider user filesystem bind.
It also proves that a role, metadata difference, PNG encoding difference, formatting difference, or old perturbation marker cannot manufacture a dependence result, and that an oversized PNG, an over-broad symlink perturbation, an absolute path, a parent traversal, a symlink escape, an empty or escaping scored-input declaration, an invalid declared perturbation, an unlisted evidence file including nested `manifest.json`, an arbitrary command, an evaluator that ignores declared perturbable content, an unaddressed evaluator, a missing declaration on an unexecuted sample, a changed manifest binding, a missing git dependency after a successful drill, a changed evaluator result, and an archive changed concurrently during replay all refuse before cleanup can be authorised.
On a host without `bwrap` or a usable preloaded container image, the portable archive and static restore-declaration checks still run, including malformed and unselected-sample declarations and missing bundles, while cases that need evaluator execution or a gate-written receipt stay gated and a valid drill refuses before executing archived code.
The portable freeze fixtures require every planned packet and corresponding ground truth plus non-empty scoring and judge-prompt stores, and promotion fixtures refuse non-finite entrant or baseline composites before ranking or veto arithmetic.

The removed `sandbox-exec` profile was measured on this host with the following command; it exited 134 with `Abort trap: 6` before the evaluator wrote its sentinel.

```
$ tmpdir=$(mktemp -d); printf '#!/bin/sh\nprintf "ran\\n" > "$1/sentinel"\n' > "$tmpdir/ev.sh"; chmod +x "$tmpdir/ev.sh"; bin/fm-bench-confine.sh --mechanism sandbox-exec --allow "$tmpdir" -- "$tmpdir/ev.sh" "$tmpdir"
Abort trap: 6
$ echo $?
134
```

The current wrapper makes that unusable mechanism explicit:

```
$ bin/fm-bench-confine.sh --mechanism sandbox-exec --allow "$PWD" -- /bin/true
error: unknown mechanism sandbox-exec
$ echo $?
2
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
