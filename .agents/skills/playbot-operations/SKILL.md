---
name: playbot-operations
description: >-
  Agent-only operational reference for Playbot.
  Load before any Playbot dispatch, Playbot liaison or bridge work, or mother-clucker art generation.
  Owns thread and workspace routing, bridge mechanics, reliability limits, direct asset generation, and Seedance behavior.
user-invocable: false
metadata:
  internal: true
---

# Playbot operations

Load this skill before any Playbot dispatch, Playbot liaison or bridge work, or mother-clucker art generation.
This skill is the single owner of general Playbot mechanics.
Keep captain-private strategy, fleet delivery posture, and project-specific identifiers, branches, paths, briefs, and secrets in the local fleet reference.

## Liaison bridge and fresh-thread doctrine

The Playbot liaison bridge carries the brief and status through the target workspace's `.fm/` directory.
Playbot honors the bridge brief, appends sparse status, and leaves `.fm/` uncommitted by convention.
The directory is untracked but is not gitignored, so it appears in `git status` and a broad `git add -A` can commit the full bridge.
Any thread that commits must stage explicit project paths and leave `.fm/` uncommitted.

Use FRESH-THREADS-ONLY for dispatch.
Do not ask for a parked thread to be resumed.
Put pending decisions and continuity into the bridge and repository, then fire a fresh thread with a short pointer.
This is a findability doctrine, not a Playbot capability limit.
CDP can continue the thread currently open in the application, but that capability does not change the fresh-thread dispatch doctrine.

Every worktree has its own `.fm/`.
Untracked bridge files and generated assets do not follow a new worktree, and a brief in one workspace is invisible to a thread in another workspace.
Write the brief into the target workspace's `.fm/` or give the thread an absolute path.

## Threads and parallel workspaces

Always distinguish these two actions with exact language:

- Say `new thread in workspace <name>` when reusing an existing workspace.
- Say `new workspace from <branch>` when creating a new worktree and branch.

Never say only `new thread off <branch>`.
Default to a new thread in the existing workspace that already holds the on-disk artifacts and evidence the task needs.
Create a new workspace only when work must run in parallel with a live thread or genuinely needs a different branch base.

Playbot's `New workspace from <branch>` creates a Git worktree on a new branch.
Fork from the latest working branch rather than assuming the default branch contains the latest work.
Workspace creation requires its first prompt and has no separate empty-workspace step.
When the bridge cannot exist before creation, use a short bootstrap prompt telling the thread where the brief will appear, watch for the new worktree, and copy the bridge into that exact worktree as soon as it exists.
A fully self-contained creation prompt is suitable only when the thread needs no on-disk references.

Parallel workspaces fragment work across branches.
Downstream work that needs several branches requires one consolidation merge after all affected live threads are quiet.
Never merge into a branch while a live Playbot workspace is changing it.

Allow only one live thread in a workspace.
Two threads can claim output slots independently without overwriting them, but they interleave the shared status log, leave numbering gaps, duplicate generation spend, and can race on uncommitted files.
If a duplicate starts, stop the later thread.

## Parallel production and review gates

Generation threads commit nothing.
They place outputs in `.fm/` staging, and one serial lander in the designated main integration workspace integrates the approved results.
This prevents duplicate or overlapping commits and keeps branch reconciliation with one owner.

Put taste checkpoints before volume.
Approve the style frame and model identity before generating a full set.
For multi-shot visual work, approve one continuity master before fan-out.
Give each reference one role such as identity, geometry and blocking, materials and style, or shot intent.
Freeze immutable set, character, prop, and lighting facts in the master, derive shots from it, and validate the depicted story action before reusing an older asset.
Preserve rejected attempts as history instead of silently recycling them as current references.

## Thread reliability and quota

Long Playbot threads can die silently.
The sidebar can show a dead thread exactly like an idle thread, and a parked `needs-decision` thread also looks idle there.
Use the bridge status, MCP snapshot, or rollout transcript rather than the sidebar to distinguish those states.

Silent deaths clustered when three or four threads ran concurrently, while one- and two-thread stretches were reliable.
Keep concurrency to about two live threads until Playbot supplies stronger evidence.
If a death strands uncommitted changes, preserve them on a work-in-progress branch and continue from the tree in a fresh thread.
After compaction, a corrupt image reference can also kill a thread with a `400 invalid image_url` response.

Playbot quota exhaustion requires a vendor-side reset.
It is not repaired by restarting the thread or workspace.
Park the briefs with their state intact and do other work while waiting for the external reset.

## Bridge watcher behavior

Register a watcher for every parallel workspace because a watcher attached to the main workspace does not see another worktree's status log.
Also cover ad-hoc Playbot worktrees with a catch-all scanner or they can finish without producing a wake.
Resolve workspace codenames and branches from the repository's worktree inventory rather than guessing.

The original bridge watcher was edge-triggered and advanced its cursor after each new status line.
Its silent-end fallback handled only `working:` and `resolved:`, so a final `needs-decision:` line fired once and could then remain parked forever without another event.
The corrected watcher gives `needs-decision:` its own branch and re-wakes at most hourly with an explicit `IDLE ON CAPTAIN GATE` signal.
Publish or change a private watcher only through `bin/fm-check-register.sh`, which owns trusted custom-check registration.
Audit watcher clones for the same missing branch whenever one copy of this defect is found.
When a behavioral rule keeps failing, first verify that the runtime emits a signal capable of triggering it.

The MCP `app_get_thread_snapshot` result exposes `status`, `needsApproval`, `needsInput`, `error`, and `isLive`.
Prefer that level signal over reconstructing thread state only from an edge-triggered log when the scoped MCP connection is available.

## Local control surfaces

Playbot exposes an unauthenticated loopback MCP server on a random port recorded for the project, and its health endpoint returns `ok`.
It also exposes a separate Electron Chrome DevTools Protocol endpoint while the application window is open.
Enumerate both local surfaces before concluding that Playbot cannot perform an operation.

The MCP surface can list workspaces, threads, and models, read a thread, return a thread snapshot, and generate assets directly.
The `execute_engine_code` and `execute_browser_script` tools appear only on a project-scoped connection.
The scope must use Playbot's real project root identifier.
An invented root identifier can connect and list tools normally while every project operation fails with `No project is in scope for this connection`.

MCP does not start or answer a thread.
The CLI launch path can create one thread when Playbot is fully stopped and the launch cold-boots the application.
A second CLI fire while that application instance is running can exit successfully with no output and create nothing.
Treat one launch per cold boot as a CLI handoff limitation, not as a limit on MCP generation or the whole Playbot application.
The separate `--playbot-cli` handoff is also known to silently no-op and must not be accepted on exit status alone.

CDP can type into the TipTap composer with `Input.insertText` and click the `Send message` button.
Assigning `innerText` does not update ProseMirror state.
That path continues whichever thread is already open, exactly as a human message does.
It can also answer a pending approval dialog.
Fresh-thread creation through CDP is not established until automation opens a new chat first, so do not present it as verified.
The CDP port and DOM selectors are version-sensitive and can disappear or change in any Playbot release.
The application needs a project window open, though the window may be minimized.

Verify a CDP send in the rollout transcript rather than by expecting a new thread row.
A successful continuation leaves thread count unchanged and grows the existing rollout.
The real desktop database holds workspace-thread state, while the harness state database holds thread rollout paths.
Do not infer product behavior from an empty legacy database path.
The desktop database also stores a plaintext authentication token, so treat the file as secret, scope readers to the required thread tables, and never log or transmit its credential fields.
The execution model and reasoning level remain persisted per-chat GUI settings and are not settable through these programmatic paths.
Playbot deep links reject query strings and fragments, so they cannot carry a prompt.

## Direct asset generation

Use the MCP `generate_assets` operation for images, sound effects, music, video, and 3D assets without starting a Playbot thread.
The generation path works in batches, and `wait_for_asset_generation` blocks until it returns each asset's saved path and completion state.
Target `.fm/` staging so generated files remain untracked until the serial lander accepts them.
Direct generation does not require a cold boot or human transport.
Image requests require the `transparent` field, which should be false for film frames.
The `specificSize` field caps at 1536, so use `aspectRatio` for formats such as 16:9.

The generators expose no seed parameter.
Repeating an otherwise identical request at a higher resolution creates a new take rather than an upscaled copy.
Approve the shot design at a cheaper resolution, but do not assume the exact approved take will survive a later master-resolution request.

For a surgical image edit, use one reference image with `fal-ai/nano-banana-pro` and describe the requested visual change precisely.
Supplying a second reference can blend the images instead of transplanting only the named feature.
Inspect the donor feature directly rather than describing it from memory.

## Seedance

Seedance 2.0 is available in the Playbot editor under `Assets > Video` and through direct asset generation as `bytedance/seedance-2.0/image-to-video`.
It is image-to-video, not text-to-video.
Author each shot twice, with the still first and the motion pass second.
Supply a starting still and describe only how that frame should move.
Keep character, environment, and style facts in the still because repeating them in the motion prompt invites drift.

The direct generator accepts a starting frame and an optional ending frame.
It supports roughly 4 to 15 seconds, resolutions through 4K, and an audio-generation toggle.
Set the aspect ratio explicitly rather than leaving it on Auto.
Use a cheaper resolution to test the shot design and 4K for a master request, subject to the no-seed new-take limitation above.
Keep generated audio off when dialogue or sound will be produced in post.
Seed source references into the project's asset surface so the generation remains reproducible.
An approved on-model character asset can also serve as the starting frame.
