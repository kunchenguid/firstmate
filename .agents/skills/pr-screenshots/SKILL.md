---
name: pr-screenshots
description: Agent-only playbook for embedding UI screenshots in a ship PR via GitHub release assets. Use before dispatching a UI ship task on a PR-producing project, to add the screenshot-capture step to the brief by hand, and after that PR opens, to embed the crewmate's data/<id>/screenshots.md into the PR body. Relevant only for UI ship work.
user-invocable: false
metadata:
  internal: true
---

# pr-screenshots

Firstmate's standard for UI ship work is that the PR demonstrates the change with screenshots, so a reviewer sees the result without checking out the branch.
This skill owns when and how firstmate applies that standard.
`bin/fm-pr-screenshots.sh` (its header comment and `--help`) owns the mechanics, and `docs/pr-screenshots.md` owns the mechanism narrative and the empirical inline-rendering record.

The feature is deliberately isolated so it never collides with an upstream change: the helper, this skill, `docs/pr-screenshots.md`, and the colocated `tests/fm-pr-screenshots.test.sh` are the whole feature.
Nothing about it lives inline in upstream-owned core files beyond this skill's one-line trigger in `AGENTS.md` section 13.

## When it applies

A ship task whose change is visible in the UI, on a `direct-PR` or `no-mistakes` project: both produce a PR to embed images into.
`local-only` projects have no PR, so this skill never applies to them, and non-UI work never applies either.

## At dispatch: add the capture step to the brief by hand

`bin/fm-brief.sh` deliberately does not inject this step, so add it yourself when you dispatch a UI ship task on a PR-producing mode.
After scaffolding the brief, append a `# UI screenshots` section to `data/<id>/brief.md` before spawning, using the same absolute firstmate-home paths that brief already uses for its status file.

Shared wording for both PR modes, with `<firstmate-home>` and `<id>` filled in:

```
# UI screenshots
If this task changes the UI, capture the key states of your change with the project's own browser tooling (Playwright or chrome-devtools-axi) and save the images under <firstmate-home>/data/<id>/screenshots/ (a sanctioned path outside your worktree, like the status file).
Then run <firstmate-home>/bin/fm-pr-screenshots.sh --namespace fm/<id> <firstmate-home>/data/<id>/screenshots/* from your worktree and <delivery line>.
This applies only to UI changes; skip it entirely for non-UI work.
```

Fill `<delivery line>` from the project mode:

- `direct-PR`: `include its printed markdown in your gh-axi pr create --body-file so the images render in the PR body`.
- `no-mistakes`: `save its printed markdown to <firstmate-home>/data/<id>/screenshots.md; firstmate embeds that block into the pull request after the pipeline opens it`.

Keep it proportionate: the section is conditional on the change touching the UI, so a task that turns out to be non-UI simply skips it.

## After the PR opens: embed (no-mistakes only)

For a `no-mistakes` UI PR the crewmate leaves the markdown at `data/<id>/screenshots.md` and never touches the PR body, because a PR-body edit is a project write that firstmate owns.
Once the PR is open, embed it yourself as part of normal PR handling:

```
bin/fm-pr-screenshots.sh embed <full GitHub PR URL> data/<id>/screenshots.md
```

The block carries a `<!-- fm-pr-screenshots -->` marker, so `embed` is idempotent and a re-run is a safe no-op.
If `data/<id>/screenshots.md` is absent, the change had no UI to capture, so skip the embed.
A `direct-PR` crewmate has already folded the markdown into its own PR body, so firstmate never runs `embed` for that mode.
