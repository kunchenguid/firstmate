# Files known to need the `--external-sources` lint fallback

`bin/fm-lint.sh` always lints with ShellCheck's `--external-sources`, which recursively analyzes every file a script sources.
When a file hits its per-file timeout or memory ceiling, `fm-lint.sh` retries that one file once without `--external-sources` before reporting a failure (`docs/configuration.md` "Per-file lint bounds"; `bin/fm-lint.sh`'s `fm_lint_run_one_file` owns the exact mechanism).
This file tracks which tracked files are currently known to need that fallback and why, so a newly pathological file shows up as a diff to this list in review instead of blending into routine lint output.

Measured 2026-09-06 against ShellCheck 0.11.0 with full (non-`--fast`) analysis, on the then-default 1 GiB ceiling.
A file's own body has no lint defect in any of these cases; the cost is entirely `--external-sources` following the sourced-file graph.
Dropping `--external-sources` on its own is not enough to finish clean, though: it also makes ShellCheck SC1091 every `. "$SCRIPT_DIR/..."` line (it can no longer follow them, `# shellcheck source=` directives notwithstanding) and SC2329 any function a sourced file calls back into (a test's mock override of a production function, the common shape here). Neither is a defect in the file's own body, so the fallback excludes both codes (`bin/fm-lint.sh`'s `fm_lint_run_one_file`); a genuine SC2034/etc. finding in the file's own body still fails it.

## Never stabilized (still growing past 4 GiB / 180s in isolation)

| File | Reason |
|---|---|
| `bin/fm-teardown.sh` | Sources a large number of `fm-*-lib.sh` helpers; one of the two files named in the 2026-09-05 incident report. Fallback (no `--external-sources`) measured clean at ~550 MB / ~6s. |
| `bin/fm-watch.sh` | Same cross-sourcing pattern as `fm-teardown.sh`. |
| `tests/fm-daemon.test.sh` | Sources the daemon's own large dependency graph for its test setup. |
| `tests/fm-pending-reply.test.sh` | Sources the pending-reply library plus its own transitive dependencies. |

## Finished, but well past a 1 GiB ceiling (measured peak, `--external-sources`, isolated)

| File | Peak |
|---|---|
| `bin/fm-backlog-handoff.sh` | ~3.9 GiB |
| `bin/fm-send.sh` | ~3.9 GiB |
| `bin/fm-spawn.sh` | ~3.5 GiB |
| `tests/fm-remote-reply.test.sh` | ~3.4 GiB |
| `bin/fm-procevent-remote-reply.sh` | ~3.0 GiB |
| `bin/fm-backend-herdr.test.sh` (`tests/`) | ~2.7 GiB |
| `tests/fm-afk-launch.test.sh` | ~2.7 GiB |
| `bin/fm-remote-secondmate-control.sh` | ~2.5 GiB |
| `bin/fm-secondmate-restart.sh` | ~2.5 GiB |
| `tests/fm-send-remote-delivery.test.sh` | ~2.5 GiB |
| `bin/fm-secondmate-report.sh` | ~2.4 GiB |
| `bin/fm-supervise-daemon.sh` | ~2.4 GiB |
| `bin/fm-pending-reply-lib.sh` | ~2.0 GiB |
| `tests/fm-extension-binding.test.sh` | ~2.0 GiB |
| `bin/fm-bootstrap.sh` | ~1.75 GiB |
| `bin/fm-promote.sh` | ~1.75 GiB |
| `bin/fm-session-start.sh` | ~1.3 GiB |
| `tests/fm-idle-compact-live-e2e.test.sh` | ~1.3 GiB |
| `bin/fm-public-followup.sh` | ~1.2 GiB |
| `tests/fm-public-followup.test.sh` | ~1.2 GiB |
| `tests/fm-idle-compact-herdr-live-e2e.test.sh` | ~1.13 GiB |
| `tests/fm-idle-compact.test.sh` | ~1.1 GiB |
| `tests/fm-secondmate-reconcile.test.sh` | ~1.04 GiB |

`FM_LINT_FILE_MEM_KB`'s default (a 6 GiB target, capped by host memory divided across concurrent shards) clears every file in the second table with headroom on a normal-size host; the fallback exists for the first table, and for any host small enough to derive a ceiling below a given file's real peak.
Fixing why the first table's files make ShellCheck's extended dataflow analysis never converge is separate follow-up work, not part of the per-file bound itself.
