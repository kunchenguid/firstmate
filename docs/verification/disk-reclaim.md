# Disk reclaim verification

This page records the September 16–17, 2026 measurement and recovery that produced the current disk-reclaim rules.
The maintained operating procedure is [disk reclaim during live fleet builds](../disk-reclaim.md).

## Incident boundary

The Data volume initially had 19 GiB free after an earlier full-disk event.
An earlier manual deletion of the remote build-cache daemon's local cache briefly raised free space by about 24 GiB, but live builds regenerated the cache.
During the observation window, free space repeatedly fell despite reclaim, and one supervising shell had already reached `ENOSPC`.

The working target was 60 GiB free.
That is a short working margin, not an overnight guarantee.

## Reclaim evidence

The following simulator runtimes had zero devices immediately before deletion and were absent from `xcrun simctl runtime list` afterward:

| Runtime | Reported size |
|---|---:|
| iOS 18.0 | 7.8 GiB |
| iOS 18.1 | 8.0 GiB |
| iOS 18.3.1 | 8.1 GiB |
| watchOS 11.2 | 4.2 GiB |

The first tool-manager pass removed six superseded tool versions after each tool's `info.json` identified a newer current version and the process table showed zero users:

| Removed version | Size |
|---|---:|
| An agent-orchestration tool version | 1.7 GiB |
| An agent-workspace tool version | 1.5 GiB |
| A dependency-graph tool version | 1.1 GiB |
| A nightly agent CLI version | 1.0 GiB |
| A package-store CLI version | 1.0 GiB |
| A build-support tool version | 715 MiB |

A second tool-manager pass removed 13 additional non-running superseded versions totaling 2.22 GiB.
The largest were one tool version at 708 MiB and one MCP server version at 520 MiB.
Running superseded versions of the build tool CLI, agent gateway, MCP servers, agent CLIs, and the agent-plugin manager were deliberately left.

The final reclaim removed 14 process-unreferenced versions from the internal build tool's package cache, totaling 19.55 GiB:

| Removed package-cache version | Size |
|---|---:|
| A KMM playback package version | 2.31 GiB |
| A second version of the same KMM playback package | 2.31 GiB |
| Three versions of a KMM umbrella package | 1.60 GiB each |
| An Android NDK version | 3.42 GiB |
| A CocoaPods umbrella package version | 1.82 GiB |
| An iOS experiment-targets package version | 1.39 GiB |
| A Go toolchain version | 1.28 GiB |
| An Android SDK platform version | 536 MiB |
| An Android SDK build-tools version | 484 MiB |
| Two versions of a KMM build-plugin package | 246 MiB and 256 MiB |
| A Fastlane package version | 742 MiB |

The first attempt to remove that set refused to start because an `xcodebuild` was active.
The successful attempt ran only after the compiler window was idle, and a process snapshot showed no command referencing any selected package path.
The internal build tool's package cache was already confirmed to be re-downloadable, so cache misses can restore any version a later build still needs.

The reclaim removed six old, process-unreferenced Bazel output bases totaling 9.44 GiB in the first pass and five more totaling 2.37 GiB in the second pass.
Each base had a `DO_NOT_BUILD_HERE` marker, no active server or compiler, and an old modification time.
Each removal used `chmod -R u+w` before an explicit single-path `rm`.

Recent output bases were deliberately left even when they had no active client.
One 4.0 GiB base had been touched about five hours earlier, and one 2.7 GiB base had been touched about 38 hours earlier.
Both fell inside the one-to-two-day retention rule.

## Shared repository-cache failure and repair

The first Bazel pass also removed approximately 4.5 GiB at `_bazel_<user>/cache`.
That was not safe.
The deleted `repos/v1` subtree held shared repository contents used by `external/*` symlinks in every output base.

Two active lanes later failed on files inside `rules_swift+` and GRDB because their symlinks still existed while the shared targets did not.
The delayed failure made the deletion initially appear successful.

The repair restored `rules_swift+` and `rules_swift_package_manager++swift_deps+swiftpkg_grdb.swift` with targeted `bazel fetch --repo=... --force` calls through the surviving remote build-cache mirror.
It then removed only verified dangling `external/*` symlinks: 257 in one affected output base and 236 in the other.
No resolving external symlink was removed.

A real iOS simulator build of an app library target reached Swift compilation, linked the target's static library, and reported `Build completed successfully`.
The command later exited nonzero only because Build Event Protocol upload to a legacy remote build-cache endpoint returned HTTP 404.

## Regrowth measurements

The first two complete samples were 499 seconds apart:

| Path | 22:38 PDT | 22:46 PDT | Change |
|---|---:|---:|---:|
| Build tool package cache | 46,471,088 KiB | 46,471,096 KiB | 8 KiB |
| `~/Library/Caches/bazel` | 40,269,704 KiB | 40,537,640 KiB | 267,936 KiB |
| Tool-manager versions | 31,268,360 KiB | 23,864,872 KiB | reclaim, not growth |
| Available space | 45,040,100 KiB | 58,695,124 KiB | reclaim, not growth |

Bazel grew by about 31.5 MiB per minute during that interval.
The internal build tool's package cache was effectively flat.

At 22:46 PDT, the remote build-cache daemon's local cache occupied 2,125,148 KiB.
At 23:37 PDT, its three active worktree caches occupied 4,630,424 KiB, 4,209,240 KiB, and 2,157,516 KiB, for about 10.5 GiB total.
That is approximately 170 MiB per minute, or 10 GiB per hour, of aggregate remote build-cache growth.

Over the same approximately 51-minute interval, available space fell from about 56 GiB to about 37 GiB before the next reclaim.
The aggregate observed consumption was therefore about 22 GiB per hour, including the remote build-cache daemon, Bazel output growth, and other active build outputs.

At that observed burst rate, a 60 GiB margin lasts roughly 2.7 hours.
An eight-hour unattended run would require approximately 180 GiB of headroom if the same activity continued.
The current disk cannot safely host the observed fleet overnight without reducing concurrent heavy builds, adding capacity, or introducing a real size bound for the remote build-cache daemon's intermediate artifacts.

## Latest headroom

At 07:45 PDT on September 17, `df -h /System/Volumes/Data` reported 61 GiB free and 93% capacity used.
The exact available count was 64,389,428 KiB.
Deletion stopped at that point because the 60 GiB working target had been reached.
