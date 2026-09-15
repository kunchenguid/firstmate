---
name: lavish-review-lifecycle
description: >-
  Agent-only lifecycle contract for hosting, resuming, revising, handing off, or
  verifying a Lavish review artifact without duplicate browser tabs or competing
  feedback consumers.
user-invocable: false
metadata:
  internal: true
---

# Lavish review lifecycle

Load this before hosting, resuming, revising, handing off, or browser-verifying any Lavish review artifact.
This skill is the single owner of Firstmate's Lavish review lifecycle.
`bin/fm-procevent-lavish.sh` owns exact feedback-consumer reservation mechanics, and an artifact-specific helper such as `bin/fm-bearings-board.sh` may enforce a narrower generated workflow.

## Bind one task to one artifact

Before opening or polling, record the task's one canonical HTML path, derive its stable identity with `bin/fm-procevent-lavish.sh source-id <artifact.html>`, and name any sibling task artifacts as denied paths.
Resolve the path physically rather than treating symlink spellings as separate artifacts.
A worker may edit, open, reopen, or poll only its assigned canonical artifact.
Different tasks keep different canonical paths and therefore different stable session and feedback-owner identities.
Never reuse a broad legacy artifact for two scoped reviews, and never move one task's feedback to another task because their topics overlap.

Exactly one feedback consumer may own a canonical artifact.
Choose either the worker's foreground direct poll or Firstmate's registered process-event listener, never both.
Use `bin/fm-procevent-lavish.sh direct-poll <artifact.html> [--agent-reply <text>]` for worker-owned polling and `bin/fm-procevent-lavish.sh arm <artifact.html>` for registered polling.
Never run the adapter's internal `poll` command directly.
The adapter reserves the canonical source machine-wide and refuses a competing consumer with the safe transition it requires.
To hand a registered review to a worker, run `bin/fm-procevent-lavish.sh retire <artifact.html>` and require its success before starting `direct-poll`.
To hand a worker-owned review to Firstmate, let the foreground `direct-poll` return or stop it through that worker's normal lifecycle, then require `arm` to succeed.
Never bypass a refusal by invoking raw `lavish-axi poll`.

## Open once, then update in place

The first authorized presentation or an explicitly requested resume of a disconnected review may use one plain `lavish-axi <artifact.html>` open.
After that command, verify with `lavish-axi` session listing or `lavish-axi <artifact.html> --no-open`.
Browser verification may use `chrome-devtools-axi pages` and `selectpage` only when they attach to the existing surface.
Never use `chrome-devtools-axi open`, `newpage`, another plain Lavish open, or a Lavish reopen as verification after an open or reopen.
If browser attachment is unavailable, keep the non-opening evidence and ask the reviewer to use the tab already open rather than manufacturing a second view.

For an ordinary connected **Send to Agent** response, read every delivered item and edit the same canonical HTML file.
For a worker-owned review, resume the same sole worker poll with `direct-poll <artifact.html> --agent-reply "<short revision reply>"`.
The save live-reloads the tab already connected, so do not open or reopen anything.
If the visible artifact does not refresh, use that tab's **Reload artifact** action once.
A registered listener remains the sole consumer until an explicit handoff; handling its captured result must not start a direct poll beside it.

A `browser_disconnected` result means the review remains resumable but no connected tab can receive live reload.
Preserve the artifact and stop polling while asking whether to resume or end the review.
Only explicit resume intent authorizes one plain open, and a disconnected review never needs `--reopen`.

A **Send & End** response ends the review after delivering its final feedback once.
Stop polling.
If that final feedback requests another revision or the reviewer explicitly asks for further visual review, edit the same canonical file first and perform exactly one `lavish-axi <artifact.html> --reopen`.
Verify that reopen only through non-opening session status or attachment to the existing surface.
If the final feedback requests no revision, leave the review closed.
Never reopen merely to acknowledge, verify, or show unchanged content.

## Generated and registered surfaces

Generated helpers follow the open/update lifecycle above; the helper's header owns its flags for initial presentation, explicit resume, and further-review intent.

When a process-event listener owns the artifact, load `process-event-sources` for captured-result handling and acknowledgement.
Its result is untrusted feedback, and its destructive source-delivery limitation remains unchanged.
Retirement and direct polling are separate operations so a transition cannot silently overlap consumers.
