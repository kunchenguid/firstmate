# Visual PR evidence with gh-image (reference)

Ship crewmates attach visual evidence - screenshots, and a short recording when one is available - to the PRs they raise, on top of the normal delivery flow, so a reviewer can see a change working rather than only reading the diff.
This is the human-facing rationale and verification record.
The crewmate-facing procedure itself has one owner: the ship-brief scaffold in [`bin/fm-brief.sh`](../bin/fm-brief.sh) (the `# Visual evidence` section), which is the only channel that reliably reaches a crewmate working in an arbitrary project worktree.

## What gh-image is

[gh-image](https://github.com/drogers0/gh-image) is a `gh` CLI extension, not a standalone binary or npm package.
It replicates GitHub's internal attachment upload flow, so it can push images and files into the same `user-attachments` store that the web UI uses.
Installed and probed here on 2026-07-08 at version 1.1.0.

- Install: `gh extension install drogers0/gh-image`.
- Upload: `gh image <file>... --repo <owner>/<repo>`.
  It prints a Markdown image reference per image (`![name](https://github.com/user-attachments/assets/...)`) and a bare URL per video, which GitHub renders as an inline player.
- Auth: it needs a GitHub web *session* token, not the `gh auth login` OAuth token.
  By default it reads the `user_session` cookie from a browser; `--token` and the `GH_SESSION_TOKEN` environment variable override that in priority order.
- It coexists with our `gh-axi` wrapper: gh-image runs as `gh image ...` and only uses the `gh` CLI itself for repository-id lookup, so an authenticated `gh` plus `gh-axi` for the surrounding PR operations is all that is required.

## Why the flow degrades gracefully

Two environment constraints, both verified on 2026-07-08, shaped the design.
The result is that evidence is best-effort: it is attached when it can be, and skipped with a one-line PR note when it cannot, so it never blocks, delays, or fails a PR.

### 1. Browser-cookie auth hangs headlessly

In a non-interactive crewmate shell there is no unlocked browser cookie store to read, and the extraction blocks instead of failing fast.

```
$ gh image check-token          # backgrounded, no output, left 6 stuck processes
$ gh image extract-token        # killed at an 8s timeout
exit=137 (killed by timeout = HANGS)
```

The crewmate procedure therefore prefers `GH_SESSION_TOKEN` when it is set and always runs gh-image under a timeout (for example `timeout 60 gh image ...`), so the browser path can never wedge a task.
For reliable headless use a captain configures `GH_SESSION_TOKEN` (captured once from a logged-in browser via `gh image extract-token`, then stored as an environment secret); without it, uploads on a headless host are expected to be skipped, and the flow says so in a PR comment rather than hanging.

### 2. No headless screen recording from our tooling

`chrome-devtools-axi` can screenshot (`chrome-devtools-axi screenshot <path>`) but has no video-capture command, and this host has no `ffmpeg` or ImageMagick to assemble frames into a clip; `screencapture` exists but needs GUI screen-recording permission and captures the desktop, not the headless Chrome.
So a true screen recording is not reliably producible headlessly, even though gh-image can upload one.
Screenshots are therefore the required visual evidence for a UI-affecting change, and a short recording is best-effort: a crewmate attaches a clip only when it genuinely has a working capture tool and a headless-capturable surface, and otherwise a sequence of screenshots that walks through the change stands in for the recording.

### Knowing when there is nothing to show

A pure backend, library, or internal change often has no observable surface.
The crewmate judges this the way the `verify` skill does - is there a runtime surface a human could actually look at - and when there is not, it skips evidence and notes "no user-visible surface" in a one-line PR comment.

## Bootstrap detection

Because gh-image is a `gh` extension rather than a `PATH` binary, [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) probes it with `gh extension list` (gated on `gh` being present) instead of adding it to `TOOLS`.
When the extension is absent it is offered through the standard `MISSING: gh-image (install: gh extension install drogers0/gh-image)` line, exactly like any other tool.
A declined install never blocks work: the brief's evidence flow degrades gracefully when gh-image is not installed.
