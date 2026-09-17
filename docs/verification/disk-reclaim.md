# Disk reclaim verification

This page records the September 16–17, 2026 measurement and recovery that produced the current disk-reclaim rules.
The maintained operating procedure is [disk reclaim during live fleet builds](../disk-reclaim.md).

## Incident boundary

The Data volume initially had 19 GiB free after an earlier full-disk event.
An earlier manual deletion of `~/.cache/polygate` briefly raised free space by about 24 GiB, but live builds regenerated the cache.
During the observation window, free space repeatedly fell despite reclaim, and one supervising shell had already reached `ENOSPC`.

The working target was 60 GiB free.
That is a short working margin, not an overnight guarantee.

## Reclaim evidence

The following simulator runtimes had zero devices immediately before deletion and were absent from `xcrun simctl runtime list` afterward:

| Runtime | UUID | Reported size |
|---|---|---:|
| iOS 18.0 | `7972864F-6EF3-46F2-85A6-24DF769164F8` | 7.8 GiB |
| iOS 18.1 | `431D15A9-7E38-4DBE-A84D-9873C9F6479A` | 8.0 GiB |
| iOS 18.3.1 | `6A3900FA-93C4-4E2A-9E6C-BECCB4ED3AE2` | 8.1 GiB |
| watchOS 11.2 | `1D5F26D6-DA39-4A79-A9C4-E4AB1510B8E8` | 4.2 GiB |

The first Toolbox pass removed these superseded versions after `info.json` identified the current version and the process table showed zero users:

| Removed version | Current version | Size |
|---|---|---:|
| `orcha/3.3.6` | `3.3.61` | 1.7 GiB |
| `agentspaces/1.1.8929.0` | `1.1.9406.0` | 1.5 GiB |
| `brazil-graph/1.0.200971.0` | `1.0.200977.0` | 1.1 GiB |
| `kiro-cli/2.22.1-nightly.3-nightly` | `2.22.1-nightly.4-nightly` | 1.0 GiB |
| `storecli/1.6.1252.stable` | `1.6.1253.stable` | 1.0 GiB |
| `barium/1.0.1138.0` | `1.0.1139.0` | 715 MiB |

A second Toolbox pass removed 13 additional non-running superseded versions totaling 2.22 GiB.
The largest were `octo/1.0.65.0` at 708 MiB and `cradle-mcp/1.0.166.0` at 520 MiB.
Running superseded Brazil CLI, Kiro Crew, Builder MCP, Claude, Codex, and AIM versions were deliberately left.

The final reclaim removed 14 process-unreferenced Brazil package-cache versions totaling 19.55 GiB:

| Removed package-cache version | Size |
|---|---:|
| `MusicPlaybackExperienceKMM-1.0.5947.0` | 2.31 GiB |
| `MusicPlaybackExperienceKMM-1.0.6169.0` | 2.31 GiB |
| `RewindKMMUmbrella-1.0.72.0` | 1.60 GiB |
| `RewindKMMUmbrella-1.0.86.0` | 1.60 GiB |
| `RewindKMMUmbrella-1.0.92.0` | 1.60 GiB |
| `AndroidNDK-r27.5389.0` | 3.42 GiB |
| `AlcatrazCocoaPodsUmbrella-1.2.1736.0` | 1.82 GiB |
| `WeblabExternalIOSTargets-0.1.16740.0` | 1.39 GiB |
| `GoLang-1.x.583935.0` | 1.28 GiB |
| `AndroidSDKPlatform-36.1018.0` | 536 MiB |
| `AndroidSDKBuildTools-36.1.0.931.0` | 484 MiB |
| `MusicPlatformKMMBuild-2.0.20.1657.0` | 246 MiB |
| `MusicPlatformKMMBuild-2.3.21.3.0` | 256 MiB |
| `PeruFastlane-1.0.1798.0` | 742 MiB |

The first attempt to remove that set refused to start because an `xcodebuild` was active.
The successful attempt ran only after the compiler window was idle, and a process snapshot showed no command referencing any selected package path.
The Brazil package cache was already confirmed to be re-downloadable, so cache misses can restore any version a later build still needs.

The reclaim removed six old, process-unreferenced Bazel output bases totaling 9.44 GiB in the first pass and five more totaling 2.37 GiB in the second pass.
Each base had a `DO_NOT_BUILD_HERE` marker, no active server or compiler, and an old modification time.
Each removal used `chmod -R u+w` before an explicit single-path `rm`.

Recent output bases were deliberately left even when they had no active client.
One 4.0 GiB base had been touched about five hours earlier, and one 2.7 GiB base had been touched about 38 hours earlier.
Both fell inside the one-to-two-day retention rule.

## Shared repository-cache failure and repair

The first Bazel pass also removed approximately 4.5 GiB at `_bazel_marsjohn/cache`.
That was not safe.
The deleted `repos/v1` subtree held shared repository contents used by `external/*` symlinks in every output base.

Two active lanes later failed on files inside `rules_swift+` and GRDB because their symlinks still existed while the shared targets did not.
The delayed failure made the deletion initially appear successful.

The repair restored `rules_swift+` and `rules_swift_package_manager++swift_deps+swiftpkg_grdb.swift` with targeted `bazel fetch --repo=... --force` calls through the surviving PolyGate mirror.
It then removed only verified dangling `external/*` symlinks: 257 in one affected output base and 236 in the other.
No resolving external symlink was removed.

A real iOS simulator build of `//iosApp/Packages/RewindCommon:RewindData` reached Swift compilation, linked `libRewindData.a`, and reported `Build completed successfully`.
The command later exited nonzero only because Build Event Protocol upload to the legacy PolyGate endpoint returned HTTP 404.
Both blocked lane owners were notified that the missing-external repair was complete and could retry.

## Regrowth measurements

The first two complete samples were 499 seconds apart:

| Path | 22:38 PDT | 22:46 PDT | Change |
|---|---:|---:|---:|
| `~/brazil-pkg-cache` | 46,471,088 KiB | 46,471,096 KiB | 8 KiB |
| `~/Library/Caches/bazel` | 40,269,704 KiB | 40,537,640 KiB | 267,936 KiB |
| `~/.toolbox/tools` | 31,268,360 KiB | 23,864,872 KiB | reclaim, not growth |
| Available space | 45,040,100 KiB | 58,695,124 KiB | reclaim, not growth |

Bazel grew by about 31.5 MiB per minute during that interval.
The Brazil package cache was effectively flat.

At 22:46 PDT, PolyGate occupied 2,125,148 KiB.
At 23:37 PDT, its three active worktree caches occupied 4,630,424 KiB, 4,209,240 KiB, and 2,157,516 KiB, for about 10.5 GiB total.
That is approximately 170 MiB per minute, or 10 GiB per hour, of aggregate PolyGate growth.

Over the same approximately 51-minute interval, available space fell from about 56 GiB to about 37 GiB before the next reclaim.
The aggregate observed consumption was therefore about 22 GiB per hour, including PolyGate, Bazel output growth, and other active build outputs.

At that observed burst rate, a 60 GiB margin lasts roughly 2.7 hours.
An eight-hour unattended run would require approximately 180 GiB of headroom if the same activity continued.
The current disk cannot safely host the observed fleet overnight without reducing concurrent heavy builds, adding capacity, or introducing a real size bound for PolyGate's intermediate artifacts.

## Latest headroom

At 07:45 PDT on September 17, `df -h /System/Volumes/Data` reported 61 GiB free and 93% capacity used.
The exact available count was 64,389,428 KiB.
Deletion stopped at that point because the 60 GiB working target had been reached.
