# Render deploy verification

This documents `bin/fm-deploy-check.sh` and its wiring into the merge path.
It exists because a merge is not shipped until its deploy reaches Live.

## The failure it prevents

mattmccarthy.dev served a July-1 build for 5 days across 10 consecutive silently-failed deploys (`data/learnings.md`, "Render - deploys can fail silently for days").
A Render service keeps serving its last good build when a new deploy fails, so nothing looks broken from the outside.
Firstmate's merge poll only watched the PR, so a merged-but-never-deployed change read as shipped.
This verification closes that gap by watching the deploy, not just the merge.

## What runs, and when

When the merge poll (`state/<id>.check.sh`, written by `bin/fm-pr-check.sh`) detects the PR merged, it reads the merge commit and the task's project.
If the project maps to a Render service, it calls `bin/fm-deploy-check.sh --arm <id> <project> <merge-sha>`, which rewrites `state/<id>.check.sh` to probe the deploy and records `deploy_service=`/`deploy_sha=`/`deploy_armed_at=` into the meta.
The watcher then polls that probe on its normal check cadence: it stays silent while the deploy is pending and wakes firstmate exactly once, with `deploy live:`, `deploy FAILED:`, or (if no deploy for the sha appears within the bounded deadline) `deploy verification TIMED OUT:`.
That single wake is durable: after emitting it the probe disarms by removing its own `state/<id>.check.sh`, so a held-teardown failure never re-wakes firstmate every check interval.
Removing the file mid-run is safe because the watcher captures and durably enqueues the emitted line before the next sweep.
On failure the probe writes the recent service boot log to `state/<id>.deploy-log` and names it in the wake line.
The bounded deadline (`FM_DEPLOY_VERIFY_DEADLINE`, default 1800s, measured from `deploy_armed_at`) exists so a deploy that is never created - autodeploy off, or superseded before creation - cannot hold teardown open forever.
A project with no mapped service keeps the plain `merged` wake, unchanged.
This transition fires for every merge path, because both a captain merge on GitHub and a `bin/fm-pr-merge.sh` self-merge are observed by the same merge poll.

## Read-only

The helper only lists deploys and reads logs.
It never triggers a deploy, restarts, or changes service state.
Read-only Render checks are standing-authorized (`data/learnings.md`, "Render - CLI authorized, service map").

## Service resolution

`bin/fm-deploy-check.sh` resolves its `<service|project>` argument in this order:

1. A literal `srv-...` service id is used as-is.
2. A `<project> <srv-id>` entry in `config/render-services.map` (local, gitignored; `$FM_RENDER_SERVICES_MAP` overrides the path). This is the override path.
3. Otherwise `render services -o json` is queried and matched by name (`.service.name`), because ids drift and the live list is the cheap source of truth.

Resolution never guesses; an unmapped, unmatched project exits non-zero.

## Deploy classification

A single commit can have several deploys (for example an `api`-triggered redeploy alongside a `new_commit` one), so the probe examines every deploy whose `commit.id` starts with the target sha.

| Bucket | Render status | Meaning |
| --- | --- | --- |
| success (Live) | `live`, `inactive` | The commit built and served; `inactive` just means a newer deploy has since replaced it. |
| failed | `build_failed`, `update_failed`, `pre_deploy_failed` | Newest deploy for the sha failed and none reached a served state; a hard captain-facing blocker. |
| pending | `created`, `queued`, `build_in_progress`, `update_in_progress`, `pre_deploy_in_progress`, or no deploy for the sha yet | Keep polling. |
| other | `canceled`, `deactivated`, anything else | Surfaced, never silently reported Live, but not a hard failure. |

`canceled` is deliberately not a failure: Render cancels a queued or in-progress deploy when a newer deploy supersedes it, so two merges landing close together on the same service would otherwise make the first task falsely report `deploy FAILED (canceled)` even though the newer live deploy contains the first merge's content.
An `other`/`canceled` sha that never resolves is terminated by the bounded deadline's timed-out wake, not by a false failure.
If any deploy for the sha reached a served state, the commit is Live even when an earlier deploy of the same commit failed.

## Modes

- `fm-deploy-check.sh <service|project> <sha>` - blocking poll until Live (exit 0), failed (exit 3, prints boot log), or timeout (exit 2). For manual/direct use.
- `fm-deploy-check.sh --once <service|project> <sha>` - single probe for the watcher check contract: one line iff terminal (Live, failed, or timed out), silent otherwise, always exit 0. On the wired path it reads `FM_DEPLOY_ARMED_AT` (deadline reference) and `FM_DEPLOY_DISARM_PATH` (its own check.sh, removed after a terminal wake so it fires once).
- `fm-deploy-check.sh --resolve <project>` - print the resolved service id.
- `fm-deploy-check.sh --arm <id> <service|project> <sha>` - resolve once, record meta (including `deploy_armed_at=`), write the deploy probe check.sh wired with the arm time and disarm path.

Cadence, timeout, and deadline are env-overridable: `FM_DEPLOY_POLL_INTERVAL` (default 15s), `FM_DEPLOY_TIMEOUT` (default 900s, the blocking poll's bound), `FM_DEPLOY_VERIFY_DEADLINE` (default 1800s, the wired watcher path's bound before a timed-out wake), `FM_DEPLOY_LOG_LINES` (default 50), `FM_RENDER_BIN` (default `render`), `FM_RENDER_SERVICES_TIMEOUT` (default 10s, the hard bound on the `render services` resolution fallback so a hanging CLI can never starve the merge poll's fallback wake inside the watcher's check budget).

## Evidence

2026-07-11, Render CLI v2.5.0, logged in as captain, on macOS (Darwin 25.4.0).

`render deploys list srv-xxxx... -o json --confirm` (service id redacted; the real ids live only in the local gitignored `config/render-services.map`) returned an array of deploys, each with `.commit.id`, `.status` (lowercase, e.g. `live`, `update_failed`, `inactive`), `.id` (`dep-...`), and `.createdAt`.
The mtmccarthy history showed the exact silent-failure shape: commit `c40669d3...` had both a `live` deploy (trigger `api`) and an `update_failed` deploy (trigger `new_commit`), and the surrounding history was a wall of `Update Failed`.

`render services -o json --confirm` returned an array where each element wraps one resource under a type key (`service`, `postgres`, `project`, `environment`); web-service name and id live under `.service.name` / `.service.id`.
Verified at runtime that both `astroai` and `mtmccarthy` resolved to their live `srv-xxxx... (redacted)` ids by name.

Helper behavior verified against that live data (read-only, service id redacted):

```
$ fm-deploy-check.sh --once srv-xxxx... c40669d37b624e2d2cfae12b89902217ba849d8b
deploy live: c40669d3... on srv-xxxx...

$ FM_DEPLOY_LOG_OUT=/tmp/log fm-deploy-check.sh --once srv-xxxx... 5e2a4271103aac22b099d2ebb2695c3885afa3d6
deploy FAILED: 5e2a4271... on srv-xxxx... (update_failed, dep-d92tq5favr4c73bhkjmg) - boot log: /tmp/log

$ fm-deploy-check.sh --once srv-xxxx... deadbeefdeadbeef
$   # (silent: no deploy for that sha)
```

`render logs -r <service> -o text --limit <n> --direction backward --confirm` supplies the boot log; it is best-effort and never fatal to the check.
