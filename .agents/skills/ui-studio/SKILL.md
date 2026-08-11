---
name: ui-studio
description: >-
  Fast local UI-iteration lane: one persistent branch (ui/studio), one long-lived agent,
  and Storybook hot-reloading fed by Vibe annotations.
  Use when the captain invokes /ui-studio start, /ui-studio land, or /ui-studio status,
  or when they ask to open, land, or check the UI studio for a project.
user-invocable: true
metadata:
  internal: true
---

<!-- Owner: firstmate shared tracked skills. Merge-path decision rationale lives in the "land" section below - do not duplicate it elsewhere. -->

# ui-studio

The UI studio is a fast lane for iterating on UI without routing through firstmate's
spawn/worktree/PR/Chromatic supervision loop.
It owns a persistent branch (`ui/studio`), a reused worktree in `state/`, and one
long-lived studio agent that watches Vibe annotations and applies changes live in Storybook.
Firstmate stays OUT of the edit loop - no watcher, no turn-end guard, no task meta.

## Ownership exception

This skill is the sole owner of the `ui/studio` branch and the
`state/ui-studio/<project>/` worktree for the named project.
Creating or maintaining that worktree necessarily adds metadata to the project clone
under `projects/<project>/.git/worktrees/`.
This narrow write is an explicitly approved exception to hard rule 1, scoped to the
`ui/studio` branch only.
It does not authorize any other write to the project clone or to `projects/`.

## Subcommands

All three subcommands drive `bin/fm-ui-studio.sh` for deterministic infrastructure work,
then handle the agent-lifecycle or captain-communication steps that require LLM judgment.

Default project is `alc-dashboard-app` when no project arg is given.

### `/ui-studio start [<project>]`

1. Resolve the project clone under `$PROJECTS/<project>` using the
   `$FM_HOME/data/projects.md` registry.
   If the clone is absent, stop and tell the captain.

2. Run `bin/fm-ui-studio.sh start <project>` (pass `FM_HOME`, `FM_ROOT_OVERRIDE`, and
   any `*_OVERRIDE` vars already in the environment so path resolution is consistent).
   The script exits non-zero on any infrastructure error and prints a plain-English
   error; relay it to the captain and stop.
   On success it prints `KEY=VALUE` lines:

   ```
   worktree=<path>
   storybook_pid=<n>
   storybook_url=<url>
   storybook_log=<path>
   storybook_status=starting|running
   vibe_status=up|down|unavailable
   studio_state=fresh|reused
   ```

3. If `storybook_status=starting`, tell the captain the server is warming up and to
   watch its log at the printed `storybook_log` path.

4. **Launch the studio agent pane** (firstmate does this step, not the script):

   a. Read the crew harness: `bin/fm-harness.sh crew`.
   b. If the harness is `claude` and `$HERDR_ENV = 1`, use the Herdr CLI to open a
      new tab in this firstmate session's home workspace, with the worktree as its CWD,
      and label it `ui-studio/<project>`:
      ```
      herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
        --cwd <worktree> --label "ui-studio/<project>" --no-focus
      ```
      Parse the returned `tab_id` and `pane_id`.
      Record the pane ID in `state/ui-studio/<project>.pane` (one line, no newline context).
      Then send the agent command and initial prompt:
      ```
      herdr pane send-text <pane_id> "claude"
      herdr pane send-keys <pane_id> enter
      ```
      Wait about 10 seconds for Claude to start, then send the initial prompt via
      `herdr pane send-text <pane_id> "<prompt>"` and `herdr pane send-keys <pane_id> enter`.
   c. For other harnesses or non-Herdr sessions, print the worktree path and the
      harness command and tell the captain to open a terminal there manually.
      The studio agent prompt is in the next step.

5. **Initial studio agent prompt** - use this exact text (substituting the real project,
   URL, and path):

   ```
   You are the UI Studio agent for <project>.
   Your only job: watch the Vibe annotation API at http://127.0.0.1:3846/api/annotations,
   pick up new annotations, apply each change to the source file named in the annotation's
   source_file_path field (mapping values to the project's design tokens where applicable),
   verify the change looks right in Storybook at <storybook_url>, then mark the annotation
   resolved by calling DELETE /api/annotations/<id>.
   You work only on branch ui/studio in the worktree at <worktree>.
   You may commit changes to ui/studio.
   You must NEVER push, open PRs, or touch main.
   Firstmate lands batches with /ui-studio land.
   You also accept direct chat from the captain for one-off edits.
   Poll annotations every 30 seconds when idle.
   ```

6. Print a concise captain summary:
   - worktree path
   - Storybook URL
   - Vibe status (up or down)
   - how to iterate (annotate in the browser, changes apply automatically)
   - that `/ui-studio land` ships a batch when ready

### `/ui-studio land [<project>]`

1. Run `bin/fm-ui-studio.sh land <project>`.
   The script:
   - Fetches origin, counts commits ahead, exits 0 printing `studio_ahead=0` when
     nothing is pending (relay "nothing to land" to the captain and stop).
   - Rebases `ui/studio` onto `origin/main` and exits non-zero with a conflict report
     on rebase failure.
   - Runs `pnpm lint`, `pnpm test --run`, and `pnpm build-storybook` in the worktree,
     exiting non-zero with the failing command's output on any failure.
   - Pushes `ui/studio` to origin.
   - Creates a PR via `gh-axi pr create` and prints `pr_url=<url>` and `pr_number=<n>`.

2. Record the PR URL for the captain (full `https://...` link).

3. **Merge path** - `bin/fm-pr-merge.sh` requires an existing task-meta file
   (`state/<id>.meta`) and cannot be used here since the studio lane has no firstmate
   task ID.
   The chosen approach: monitor CI with `gh-axi pr checks <number>` and, once all
   checks pass, merge with `gh-axi pr merge <number> --squash --delete-branch`.
   Merge metadata recording (`pr=` in meta) is omitted; the studio lane opts out of
   the firstmate task lifecycle by design.
   Do not use `fm-pr-merge.sh` or `fm-pr-check.sh` for this lane.

4. After merge is confirmed:
   a. Refresh the project clone: `bin/fm-fleet-sync.sh <project>`.
   b. Reset the studio worktree for the next round:
      `bin/fm-ui-studio.sh start <project>` (it detects no un-landed commits and
      fast-forwards to `origin/main`).
   c. Touch `state/ui-studio/<project>.last-land` with the current timestamp.
   d. Tell the captain the batch landed with the full PR URL.

5. Relay any non-zero script exit to the captain with the exact error before stopping.

### `/ui-studio status [<project>]`

Run `bin/fm-ui-studio.sh status <project>` and relay the structured output to the
captain in plain language:

- whether Storybook is running (PID alive + port responding)
- whether the studio agent pane is alive (check `state/ui-studio/<project>.pane` then
  `herdr pane get <pane_id>` when on Herdr, or state the pane ID and note it cannot be
  verified without Herdr)
- how many commits `ui/studio` is ahead of `origin/main`
- how long since the last land (from `state/ui-studio/<project>.last-land`)

## Heartbeat land-nudge

On every heartbeat, firstmate MAY run `/ui-studio status` for any active studio and
nudge the captain to `/ui-studio land` when the branch is drifting - defined as more
than 10 commits ahead of `origin/main` or more than 24 hours since the last land.
This is a reminder only; firstmate never auto-merges the studio branch.

## Guardrails

- The studio agent is deliberately unsupervised: no `state/<id>.meta`, no watcher entry,
  no turn-end guard.
  Never register it as a firstmate task or add it to the backlog.
- The studio worktree lives at `state/ui-studio/<project>/`, not under `projects/`.
- Firstmate never pushes `ui/studio` or merges it - only the `/ui-studio land` path does.
- The studio agent must never push, open PRs, or touch `main`.
- v1 scope: `alc-dashboard-app` only.
  The project registry lookup generalizes the path resolution, but multi-project
  orchestration is deferred.
