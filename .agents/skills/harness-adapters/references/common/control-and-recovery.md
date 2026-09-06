# Control and recovery

Load this with the running or recorded tool reference for trust, skill invocation, interrupt, exit, resume, or recovery.

## Typed data and lifecycle control

The router owns lifecycle-only control and recorded-harness selection.
Conversation and harness-native skill invocation use `../../../bin/fm-send.sh`.
`../../../docs/agent-control.md` owns the data-plane split, and `../../../bin/fm-control-lib.sh` owns executable capabilities.
Tool-reference exit and interrupt values are empirical records, not keys to improvise; a new adapter remains uncontrollable until they land in that owner.
Let the control plane verify postconditions.

## Trust and skill submission

Inspect after spawn within the tool's readiness window.
Select only its documented trust choice from the active Firstmate home, binding `FM_HOME` unless already correct, then inspect again under the router-owned completion postcondition.
No observed dialog proves only that launch.

Each supported harness handles its folder-trust gate differently, and the tool reference owns the detail.
Claude gates a fresh worktree and cannot be answered by key, so the spawn pre-registers the path in Claude's own store.
Cursor suppresses its dialog with launch-time `--trust`, and Muse suppresses its own with `--yolo`.
Grok dodges its gate instead of granting trust, because its project picker appears only outside a project and the spawn starts in the isolated git root.
Pi gates the fresh-worktree case too, but unlike Claude its dialog is answered with Enter, and `references/harness/pi.md` owns that recipe and where the decision persists.
Codex shows a directory-trust dialog on the first run for a repository root.
A Claude secondmate is deliberately not pre-registered, because `../../../bin/fm-spawn.sh` runs its per-harness pre-launch setup only for non-secondmate kinds, so the registration is never invoked for one.
That kind guard is the whole exclusion, because a treehouse-leased secondmate home is itself a linked worktree that the scope test would accept, and only a plain-clone home would be refused as a primary checkout.
The consequence is that a claude secondmate whose home Claude has never trusted meets the workspace-trust dialog itself, and firstmate cannot answer it any more than it can for a crewmate.
This is rarely seen because a secondmate home is persistent and reused, so its trust decision is made once and survives, unlike a per-task worktree that is new every time.

Use the tool's exact skill form, or natural language only when no separate command is verified or the form remains uncertain.
A successful send or key return is not proof of submission; require the tool-specific postcondition.
Popup, queued-input, and readiness handling belongs to `../../../bin/fm-composer-lib.sh` and the selected backend.

## Interrupt and exit

Use the control plane so capabilities are checked first.
Interrupt preserves the agent and work; exit stops only the agent and preserves its endpoint, isolated copy, and uncommitted changes.
Cleanup and discard are not lifecycle verbs.
The tool reference records repeat, acknowledgement, and clearing behavior, while the executable owner sends or refuses the sequence.

## Resume and recovery

Native resume availability and form belong solely to the selected tool reference.
Use native resume only when both that reference and the recovery procedure call for it.
Deterministic relaunch instead trusts instructions on disk, not a private session.

`../stuck-crewmate-recovery/SKILL.md` owns worker recovery and `../secondmate-provisioning/SKILL.md` owns secondmate recovery; both preserve recorded work.
The router's recovery scenarios select the additional common references for replacement profiles and secondmates.
