---
name: upstream-integrate
description: Selectively integrate upstream firstmate commits into a local fork through an interactive captain dialogue and a spawned crewmate. Use when the captain invokes /upstream-integrate, asks "what's new in upstream", "what did the author add", or otherwise wants to review and selectively pull upstream commits into a fork where /updatefirstmate's fast-forward skips (diverged local branch). Fetches upstream, presents the new commits, captures the captain's selection, then dispatches a worker to cherry-pick each chosen commit, resolve conflicts toward local intent, run lint and tests, and land a local commit per change. Never auto-merges, never pushes; the captain selects each integration and the captain's explicit word gates any push.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# upstream-integrate

Selectively integrate upstream firstmate commits into a local fork.

For fork-with-local-customizations workflows where `/updatefirstmate`'s fast-forward path skips because the local branch has diverged.
This skill is the interactive, captain-driven alternative: inspect upstream, choose, dispatch a worker to cherry-pick the chosen commits, and land them as local commits with a clear prefix.
It never auto-merges and never pushes; the captain selects each integration.

`/updatefirstmate` is unaffected and remains the fast-forward-only path for when the local branch has not diverged.
`bin/fm-upstream-check.sh` is the read-only inspection half; this skill is the interactive plus worker-dispatch half.

## When to load

Load when the captain invokes `/upstream-integrate`, asks what is new in upstream, asks what the author added, or otherwise wants to review and selectively integrate upstream firstmate commits into a local fork.
Do not load for an ordinary fast-forward update; that is `/updatefirstmate`.

## Procedure

1. **Inspect upstream without merging.**
   ```sh
   bin/fm-upstream-check.sh
   ```
   It fetches the upstream remote and prints each new upstream commit (short sha, subject, author, date, changed files) not yet in the local branch, oldest first.
   No merge, no working-tree change.
   When it prints `up to date`, report that and stop.

2. **Present the summary to the captain.**
   For a short list, plain chat is fine: one line per commit with sha, subject, and the file list.
   For a longer or denser list, use `lavish-axi` with one card per commit so the captain can mark which to integrate; each card shows the subject, the changed files, and a one-line lead drawn from the commit body if present.

3. **Capture the captain's selection.**
   The captain either marks commits in the lavish surface or names them directly ("take X, Y, Z").
   Resolve each selection to a concrete sha before dispatch, and confirm the final list back to the captain in one line.

4. **Dispatch a worker to integrate the selection.**
   Register firstmate itself as the project if it is not already registered, spawn a ship worker in an isolated firstmate worktree, and brief it to:
   - cherry-pick each selected upstream sha in upstream order (oldest first),
   - resolve conflicts toward local intent, preserving the fork's customizations,
   - run `bin/fm-lint.sh` and the relevant `tests/*.test.sh` entries,
   - land one local commit per logical change with prefix `upstream-integrate:`,
   - never push.

   If the task touches firstmate's shared tracked material, the brief explicitly requires `firstmate-coding-guidelines` before editing.

5. **Supervise and report in plain outcomes.**
   Relay what landed, what conflicted and how the worker resolved it, and what was skipped.
   Push to the captain's origin only on the captain's explicit word, using the configured merge authority.

## Safety

- **Never auto-merge.** The captain chooses each integration.
- **Never push without the captain's explicit word.** Local commits land first; push is a separate gated decision.
- **The worker operates in an isolated worktree**, never the primary checkout.
- **Local customizations are preserved.** Conflicts are resolved toward local intent, not the upstream version.
- **`/updatefirstmate` and `bin/fm-ff-lib.sh` are untouched.** This skill adds a parallel path; it does not modify the fast-forward machinery.
