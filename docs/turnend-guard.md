# Turn-end guard

`bin/fm-turnend-guard.sh` is the callable Phase B backstop for the "no turn ends
blind" rule. It accepts an optional harness stop payload as JSON on stdin.

When the payload is the first stop attempt, the guard checks the current home. A
plain firstmate checkout is in scope when `git-dir` equals `git-common-dir`. A
secondmate home is also in scope when its local `.fm-secondmate-home` marker is
a regular file containing a safe id. That marker-aware exception matters because
a Treehouse-leased secondmate home is itself a linked worktree. Child crew and
scout worktrees remain out of scope: they are linked worktrees, their git-dir
differs from git-common-dir, and they do not carry the secondmate marker.
A declared task worker is never in scope, whatever root or state path it
inherited. [Worker isolation](worker-isolation.md) owns that declaration.

An in-scope home with no `state/*.meta` files is idle and exits silently. With
child work in flight, the guard allows the turn only when the watcher lock names
this home and `bin/fm-watch.sh`, its PID is alive and identity-matched, and
`.last-watcher-beat` is fresh. Otherwise it prints `TURN WOULD END BLIND -
SUPERVISION IS OFF` and exits 2 so a caller can re-arm supervision. A valid
single-document JSON object with a unique boolean root field
`stop_hook_active=true` is allowed, preventing a repeated stop-hook loop.
Malformed, duplicate-key,
multi-document, non-object, NUL-tainted, or invalid-UTF-8 input is treated as an
unproved first stop and follows the blind-turn guard path.

The script is intentionally not wired into `fm-spawn.sh`, PreToolUse, or any
harness hook in Phase B. This keeps the JT change backend-neutral and avoids
enabling Herdr/Pi-only paths. Hook wiring remains a separate decision after the
callable predicate has proven useful in the supported tmux flow.

Focused coverage: `tests/fm-turnend-guard.test.sh`.
