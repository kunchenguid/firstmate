# Disk reclaim during live fleet builds

Disk pressure can make worktree creation, build placement, and agent launches fail as if routing or capacity were broken.
Measure `df -h /System/Volumes/Data` before diagnosing those higher layers.

This guide separates reclaimable per-lane state from shared state that only looks disposable.
The dated measurements behind these rules live in [disk reclaim verification](verification/disk-reclaim.md).

## The Bazel cache boundary

`~/Library/Caches/bazel/_bazel_$USER/<hash>` is a per-worktree output base.
Its `DO_NOT_BUILD_HERE` file names the owning workspace.
An output base can be reclaimed only when the workspace has no active compiler or Bazel client, no Bazel server references that output base, and its age is outside the retention window.
Bazel output trees are read-only, so run `chmod -R u+w` on one verified output base before removing that same absolute path.

`~/Library/Caches/bazel/_bazel_$USER/cache/repos/v1` is different.
It is a shared repository-content cache, and every output base can contain `external/*` symlinks into it.
Do not manually remove it.
Removing it breaks already-resolved external repositories across worktrees at their next build, often as a missing file inside an external repository rather than as an obvious cache error.

Leave shared repository-content eviction to Bazel.
Bazel 9.2 exposes `--repo_contents_cache_gc_max_age` with a 14-day default and a five-minute idle GC delay.
It also exposes local disk-cache GC controls including `--experimental_disk_cache_gc_max_size`, but those controls do not bound a PolyGate remote cache or per-worktree output bases.

If the shared repository cache is removed accidentally, do not run `clean` or `expunge`.
For each affected output base, verify that an `external/*` entry is a symlink and that its target does not exist.
Remove only that dangling symlink, using one explicit absolute path per removal, so Bazel can fetch that repository again.
Never remove an external symlink whose target still resolves.
Prove recovery with a real build that reaches compilation.

## Pre-delete safety check

Record the current free space and candidate sizes:

```sh
df -h /System/Volumes/Data
du -sk ~/.cache/polygate ~/brazil-pkg-cache ~/Library/Caches/bazel ~/.toolbox/tools
```

Before every deletion, inspect for active `xcodebuild`, `swift-frontend`, `kotlinc`, Gradle, and Bazel client processes.
An idle Bazel server is not an active build, but it still proves that its output base is live state rather than an orphan.
Stop the reclaim attempt when a compiler or build client starts.

Use these target-specific checks:

- PolyGate: map each hash directory to its worktree through `polygated.toml`'s `build-dir`.
  Treat a cache as abandoned only when daemon liveness and stale lock evidence agree.
  Remove only `intermediate_artifacts`; preserve `polygated.toml` and logs.
- Bazel: read `DO_NOT_BUILD_HERE`, check the output base's modification time, and search process command lines for its exact `--output_base`.
  Keep anything touched within the chosen retention window.
- Toolbox: read `<tool>/info.json` for `CurrentVersion.Version`, then search the complete process table for the exact superseded version path.
  A running superseded version is protected even when a newer version is current.
- Simulator runtimes: delete only runtimes with zero devices.
  Runtime deletion is asynchronous, so re-run `xcrun simctl runtime list` before counting the space.
- Brazil package cache: entries are re-downloadable, but do not remove a package version referenced by any running process or while a compiler is active.

Use one explicit absolute target per `rm`.
Do not use globs or a multi-target recursive removal.

## Measure regrowth

Take two samples with timestamps and a known interval:

```sh
date '+%Y-%m-%d %H:%M:%S %z'
df -k /System/Volumes/Data
du -sk ~/.cache/polygate ~/brazil-pkg-cache ~/Library/Caches/bazel ~/.toolbox/tools
```

Attribute growth to a producing tool before choosing retention.
PolyGate writes each worktree's remote-cache artifacts below its hash directory.
Bazel writes per-worktree output bases and the shared repository cache.
Brazil's package cache and Toolbox versions may be large without being the active producer.

## Unattended operation

Prefer a producer-owned size cap or TTL over periodic deletion.
The inspected PolyGate command surface exposed archive and telemetry size limits but no limit for `intermediate_artifacts`.
The generated Brazil Bazel configuration used PolyGate through `--remote_cache`, so Bazel's local disk-cache size limit did not control the largest observed producer.

A periodic reclaim cannot safely guarantee headroom while every heavy lane remains live.
Its smallest safe specification is:

1. Sample free space and the four cache roots at a fixed interval.
2. Act only below the chosen free-space floor.
3. Remove confirmed-dead PolyGate `intermediate_artifacts`, process-unreferenced Bazel output bases older than the retention window, and non-running superseded Toolbox versions.
4. Stop as soon as the floor is restored.
5. Never touch a live PolyGate cache, an active output base, the shared Bazel repository cache, version-controlled worktree files, or a simulator runtime with devices.

Do not install such a timer without an explicit operator decision.
If live caches alone can consume the available margin during the unattended window, reduce concurrent heavy builds or add disk capacity instead.
