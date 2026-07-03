# Orca backend adapter specification

This document defines the proposed Orca runtime backend contract before an implementation PR.
It is intentionally small: enough for upstream review of the adapter boundary, metadata, safety rules, and smoke coverage before any Orca code is ported.

## Status: proposed

Orca is a proposed runtime session and worktree backend for firstmate.
It is distinct from the crewmate harness.
The harness is the agent process firstmate launches inside a task endpoint, such as `claude`, `codex`, `opencode`, `pi`, `grok`, or `cursor`.
The runtime backend owns the endpoint and worktree lifecycle underneath that harness.

The current verified backends are `tmux` and experimental `herdr`.
Adding Orca should follow the existing adapter layout by introducing `bin/backends/orca.sh` and registering `orca` in `bin/fm-backend.sh` only when the implementation and smoke tests land.
This spec does not add that registration.

## Backend shape

An Orca task is one Orca worktree plus one Orca terminal.
Unlike the `tmux` and `herdr` adapters, Orca is expected to provide both the session endpoint and the task worktree.
That makes `worktree=` a first-class adapter output, not a path discovered after running `treehouse get` inside an existing terminal.

The adapter should still preserve firstmate's normal invariant: each ship or scout task runs outside the project primary checkout in a disposable worktree, and teardown refuses to discard unlanded work.

## Metadata contract

An Orca-spawned task must write these metadata fields before the harness launch is submitted:

```text
backend=orca
window=<generic firstmate target alias for the Orca terminal>
terminal=<orca terminal id or selector>
orca_worktree_id=<orca worktree id>
worktree=<absolute path to the Orca-created git worktree>
```

`window=` is required until selector resolution, watcher routing, and teardown are explicitly migrated away from the generic firstmate target alias.
Current core call sites still resolve `fm-<id>` through metadata `window=`, watch the recorded `window=`, and kill the recorded `window=` during teardown.
For Orca, `terminal=` is the Orca-native stable operational endpoint, while `window=` is the compatibility alias those shared firstmate paths consume.
Readers should treat `backend=orca` as the authoritative signal that Orca adapter operations, not tmux fallback lookups, own capture, sends, interrupt, and teardown.

## Adapter operations

The Orca adapter should expose the same categories that `tmux` and `herdr` expose today, mapped to Orca's CLI:

| Operation | Expected behavior |
| --- | --- |
| create/spawn | Create an isolated Orca worktree for the project and an Orca terminal for `fm-<id>`, then write metadata before sending the harness launch command. |
| capture/read | Return bounded plain text from the terminal for `fm-peek.sh`, `fm-watch.sh`, and stale-pane diagnostics. |
| send text | Type literal text into the terminal without changing the task metadata. |
| send submit/enter | Submit the current composer, matching firstmate's existing "send text then Enter" behavior. |
| interrupt | Deliver the backend's interrupt equivalent, normally Ctrl-C, without tearing down the task. |
| teardown | Close the Orca terminal and release/remove the Orca worktree only after firstmate's landed-work checks permit cleanup. |

The implementation should keep the generic call sites backend-oriented rather than introducing Orca-specific branches in every consumer.
Where the current interface lacks a clean hook for an Orca primitive, extend the shared backend operation set first.

## Tool gating

Bootstrap should require the `orca` CLI only when the selected runtime backend is Orca.
Selecting `tmux` must not require Orca.
Selecting `herdr` must keep its own existing requirements.

Backend selection should follow the existing precedence model:

1. explicit per-spawn backend override,
2. `FM_BACKEND`,
3. local `config/backend`,
4. runtime auto-detection when supported,
5. default `tmux`.

Orca should not be auto-detected unless there is a reliable, verified Orca runtime marker for the firstmate process itself.
Absent that marker, Orca should be explicit-only.

## Safety constraints

Secondmate launch must not use Orca in the first implementation.
`fm-spawn.sh --secondmate` should continue to force or require a supported non-Orca backend until Orca secondmate semantics are separately designed.

The contribution flow must never push directly to `kunchenguid/firstmate`.
Upstream-bound branches should be based on `upstream/main`, pushed to a contributor fork, and opened as pull requests against `kunchenguid/firstmate:main`.

Teardown must remain fail-closed.
It may close an Orca terminal and remove an Orca worktree only after the existing landed-work checks say the task is safe to clean up, or after an explicit discard path has been approved.
Uncommitted changes are never landed.
Committed work that is not reachable from an accepted remote branch, merged PR head, or accepted local-only merge must keep the worktree alive.

The adapter must not depend on ambient Orca state in a way that can target the wrong terminal or worktree.
Use recorded IDs from metadata for destructive operations, and fail rather than guessing when an ID is missing or no longer resolves.

## Smoke contract for a future implementation

A future Orca implementation PR should include fake-CLI unit coverage and a real-CLI smoke test that skips cleanly when Orca is unavailable.
At minimum, the smoke contract should prove:

- bootstrap reports `orca` as required only when Orca is selected;
- spawn writes `backend=orca`, required `window=`, `terminal=`, `orca_worktree_id=`, and `worktree=` before submitting the harness launch;
- `fm-peek.sh` or the shared capture path reads bounded terminal output;
- `fm-send.sh` can send text, submit Enter, and interrupt through the backend adapter;
- teardown refuses dirty or unlanded work before any Orca terminal/worktree removal;
- teardown closes the recorded terminal and releases the recorded worktree after landed-work checks pass;
- `--secondmate` launch refuses or bypasses Orca according to the documented rule;
- no test or helper attempts a push to `upstream`.

This PR intentionally stops at the specification.
The implementation PR should port Orca into upstream's current `bin/backends/<name>.sh` adapter shape rather than copying an older monolithic backend switch.
