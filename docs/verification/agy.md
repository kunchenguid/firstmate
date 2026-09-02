# agy (Antigravity CLI) adapter verification

Active empirical record for the agy crewmate/scout adapter.
Refresh it with `tests/fm-agy-surface-live-e2e.test.sh` after every agy upgrade.

| Field | Value |
|---|---|
| Date | 2026-09-02 |
| Version | agy 1.1.24 (`agy --version`) |
| Platform | macOS arm64 |
| Backend | Herdr 0.8.2, protocol 20, isolated lab session (`bin/fm-herdr-lab.sh`) |
| Model | `gemini-3.7-flash-high` (agy's own default) |

Scope: crewmate and scout only.
agy was not verified as a primary or a secondmate and is refused for both.

## Refresh command

```
FM_AGY_SURFACE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-agy-surface-live-e2e.test.sh
```

Result on 1.1.24:

```
# agy 1.1.24 (/Users/<user>/.local/bin/agy)
ok - agy 1.1.24 rejects a positional prompt and still offers -i
ok - agy 1.1.24 still advertises effort low|medium|high and a model flag
ok - agy 1.1.24 lists models without opening a session
ok - agy 1.1.24's global customization root is where the turn-end installer writes
all fm-agy-surface-live-e2e checks passed against agy 1.1.24
```

The suite carries one further check that the run above did not enable: `FM_AGY_TURNEND_LIVE_E2E=1` with `FM_AGY_TURNEND_PAYLOAD` naming a Stop payload captured from a real turn asserts only that agy still emits the `fullyIdle` and `workspacePaths` keys the installed hook parses.
It spends no turn and says nothing about what those values mean; what a `fullyIdle` value does to a turn is owned by the portable regression below.

What the HOOK tolerates and what this GUARD demands are deliberately different, and conflating them once weakened this check.
The hook must treat an absent `fullyIdle` as not a turn end, because protojson omits default values; the guard must still demand the key's PRESENCE, because a vendor that drops it is exactly the drift that would silently end every turn-end signal, and every Stop measured here carries the key explicitly, including the interrupted turn.
The guard was briefly relaxed to accept absence and is restored here.

The portable regression is `tests/fm-agy-harness.test.sh`, which pins the same contracts with no harness installed and carries the captured Stop payloads below as fixtures.

## Turn end: the `fullyIdle` contract

This is the guarantee the adapter is built around.

agy pushes a long-running foreground command into the background after about ten seconds, ends the turn saying it will wait, then wakes itself and ends a second turn once the work lands.
A firstmate that read the first turn end as "worker finished" would close a ship task with its validation pipeline still running.

Measured with a 90-second script (45 iterations printing progress, ending in `VALIDATION_DONE`) and the instruction "Run ./slow.sh in the foreground. When it finishes tell me its exact last line."
Captured Stop payloads, one conversation:

```
04:00:09Z  fullyIdle=false  workspacePaths=["/private/tmp/fm-agyw.XKJYYk"]
04:01:30Z  fullyIdle=true   workspacePaths=["/private/tmp/fm-agyw.XKJYYk"]
```

The false event arrived **81 seconds early with its workspace already populated**, so a hook keyed on the workspace alone would have fired on it.
A separate run reproduced the same split with a 71-second gap.
Two further Stop shapes were observed, both correctly ignored by the gate:

```
03:58:35Z  fullyIdle=false  workspacePaths=[]   # blocked on the workspace-trust dialog
04:01:44Z  fullyIdle=false  workspacePaths=[..] # interrupt (Escape)
```

`protojson` omits default values, so a false `fullyIdle` may arrive as an absent key.
The gate tests `select(.fullyIdle == true)` and never jq's `//`, which treats `false` as null.

Mutation evidence: removing the gate from `bin/fm-spawn.sh` makes `tests/fm-agy-harness.test.sh` fail with `a fullyIdle=false Stop was treated as a turn end`, so the regression is not vacuous.

## Hook installation

agy's global customization root is `~/.gemini/config/`, loaded with no trust grant.
Its global hooks live in one shared `hooks.json` keyed by hook name, which is the operator's file, so firstmate installs a plugin instead:

```
~/.gemini/config/plugins/fm-turn-end/{plugin.json,hooks.json,fm-turn-end.sh}
```

Verified across two runs: the plugin's `Stop` hook fires, and `~/.gemini/config/config.json` is byte-identical before and after (`diff` reported no change), so plugin discovery does not rewrite operator configuration.
Hook payloads arrive as JSON on **stdin**; the hook's working directory is the directory containing `hooks.json`, never the workspace, so the worktree comes only from `workspacePaths`.
agy reads the hook's verdict from stdout and only the literal decision `continue` blocks the stop, so the hook prints `{}` first and always exits zero.
The payload is copied by a background reader while the hook polls the captured bytes for complete JSON, then the reader is stopped on completion or on a five-second WALL-CLOCK bound.
The bound is wall clock rather than a poll count on purpose: each poll forks `cat` and `jq`, so a counted loop stretches with host load, and a measured run of the counted form took 9.2s on an idle host against the 10s timeout the hook's own `hooks.json` entry sets.
The portable regression proves that a pretty-printed payload is preserved even when the writer keeps stdin open; that bounded-open-stdin form was not re-exercised against a live agy.

`PreInvocation` and `PostInvocation` fire once per model invocation, not once per turn: 10 of each across 2 turns.
That is why they cannot pair with `Stop` to form a turn-level busy source.

## Busy state

agy's rendered footer does not separate a waiting turn from a finished one.

| Phase | Footer |
|---|---|
| Tokens streaming | `esc to cancel` |
| Waiting on backgrounded work | `? for shortcuts` |
| Turn genuinely over | `? for shortcuts` |

The middle row is the finding: for the whole 90-second wait the footer read the same as idle.
A Grok-shaped regex arm would therefore have returned a false idle for minutes, so agy ships with no worker-state source and classifies `unknown agy-unverified`.
`esc to cancel` is registered only as a delivery (submit-acknowledgement) signature, and collides with no other adapter's.

## Lifecycle

| Action | Verified form | Observed postcondition |
|---|---|---|
| Interrupt | Single Escape | Turn cancelled; composer left EMPTY (`>` between two rules), so no clear key is needed |
| Exit | `/exit` plus Enter | Prints `Resume with -c (or command below): agy --conversation=<id>`; pane process returns to `zsh` |
| Resume | `agy --conversation=<id>` or `-c` | Form printed by agy itself |

Exit was verified from a stopped agent.
`bin/fm-control.sh` interrupts a busy agent before submitting the exit command, so the busy path is interrupt-then-exit rather than a bare exit.

## Detection

`ANTIGRAVITY_AGENT=1` is set on child/tool processes, alongside `ANTIGRAVITY_LS_VERSION=cli-1.1.24`, `ANTIGRAVITY_CONVERSATION_ID`, and `ANTIGRAVITY_PROJECT_ID`.
agy sets neither `CLAUDECODE` nor `GROK_AGENT`.
The marker is checked ahead of `CLAUDECODE` because agy is not known to clear an inherited one.

Process name, read directly from the kernel with no multiplexer involved:

```
$ ps -o comm= -p <agy pid>
agy
```

Herdr's `pane process-info` reported the same: `name: "agy"`, `argv0: "agy"`, for `agy --dangerously-skip-permissions -i <brief>`.
The name is matched anchored, never globbed, because ordinary words such as `magyar` and `stagy` contain the substring.

## Launch, model, and effort

`agy --dangerously-skip-permissions "<prompt>"` is refused with `Error: unexpected argument`; agy reads a prompt only from `-p/--print`, `-i/--prompt-interactive`, or stdin.
The supervised form is `agy --dangerously-skip-permissions -i "<brief>"`.
Autonomy shows as `accept-edits` in the footer and was verified unattended for file writes and shell commands.

`--effort` advertises `(low|medium|high)`.
The value is validated inside the TUI rather than at flag-parse time, so `--effort xhigh` reaches terminal setup before being refused; the adapter omits `xhigh` and `max` rather than passing them.
`agy models` answers without opening a session and listed `gemini-3.7-flash-{high,medium,low}`, `gemini-3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium`.

## Workspace trust

Outside `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, agy asks `Do you trust the contents of this project?` with `Yes, I trust this folder` preselected; one Enter resolves it.
`--dangerously-skip-permissions` does not suppress it.
A session blocked on this dialog still fires `Stop` hooks with `fullyIdle:false`, which is a second reason the dialog must be answered rather than waited out.

An unanswered dialog is a silent hang: agy never reads the brief, its only `Stop` is ignored by the `fullyIdle` gate, and the busy classifier stays at `unknown agy-unverified`.
`bin/fm-spawn.sh` therefore polls the pane after launch and sends one Enter once the dialog is proven on screen, and the poll ends on that Enter, so exactly one is ever delivered.
What counts as proof is both of the dialog's own strings: the question anywhere in the capture, AND `Yes, I trust this folder` on a line carrying only non-letters before and after the label, matched as `^[^A-Za-z]*Yes, I trust this folder[^A-Za-z]*$`.
What the captured pane showed, at one terminal width and in agy 1.1.24, was the affirmative row as a selection marker followed by the label and nothing after it, the alternative on the next row, and a navigate/confirm hint below.
That is point evidence from one width and one version, not a guarantee about how agy renders the row elsewhere; it has not been re-exercised against a live agy since.

State what that anchor does and no more, because agy renders the brief as the first message in the same pane and a brief about this adapter quotes the dialog.
It EXCLUDES the label when letters surround it, such as `  the row reads Yes, I trust this folder here`.
It does NOT exclude the label on a bullet, numbered, or quoted line. These three all match, because the leading dash, digit, or quote is non-letter text the character class absorbs:

```
- Yes, I trust this folder
1. Yes, I trust this folder
- "Yes, I trust this folder"
```

So a brief that lists the dialog's options as bullets while also quoting the question satisfies both regexes, and the poll then sends one Enter into a session that has already started its turn, costing one surplus turn of the operator's quota.
The anchor is kept at this shape anyway rather than tightened onto the selection marker, because pinning a TUI shape observed once is the larger risk.
The two failure modes are not symmetric: if a future row shape carries a trailing hint or a right-aligned status the anchor does not match, the dialog is simply not answered, the worker sits idle, and ordinary stuck-worker detection catches it with no work lost.
The match assumes only the plain-text capture both backends serve through `fm_backend_capture`, where tmux's `capture-pane -p` and herdr's default `pane read` carry no escape sequences; the ANSI form is a separate primitive neither this poll nor any other launch gate reads.

How often that dialog actually appears was measured here against fresh lab directories, which is not how the fleet allocates a worktree.
Treehouse pools and recycles worktrees for tmux, herdr, zellij, and cmux tasks, as [`docs/architecture.md`](../architecture.md) records; teardown returns each one to that pool, and `trustedWorkspaces` is keyed by path.
So the dialog is the ordinary case only for the FIRST agy task in a given path: that task answers it and agy records the path as trusted, and every later task or relaunch in the same slot finds it already trusted and sees no dialog at all.
Orca is the exception, because it creates a worktree per task instead of pooling, so its paths are new every time.

Answering the dialog is the whole launch step: no readiness is proven afterwards.
Readiness could only be inferred from the same capture, and a capture is recent output on both backends rather than a screen snapshot, so it guarantees neither that a row was drawn by this incarnation nor that a repaint appends instead of replacing what it drew before.
An earlier iteration of this adapter did gate the spawn on a footer match and was removed for that reason; agy now behaves like every adapter except Kimi, and a launch that never starts is caught by ordinary stuck-worker detection instead of by a launch gate that could hard-fail a healthy spawn.
The cost of that choice lands on exactly those already-trusted spawns, which is the steady state rather than an edge case: with no dialog to see, the poll runs its full deadline (`FM_AGY_TRUST_POLLS`, 120 polls at `FM_AGY_POLL_INTERVAL` 0.5s, so about 60s) before the spawn continues, because the dialog's absence and a slow start read identically.
That is a deliberate trade, not an oversight.
Sixty silent automatic seconds spending no model tokens is noise against tasks that run for hours.
A shorter window buys that time back only by risking a miss, and a missed dialog leaves the worker stuck in a modal until stuck-worker detection fires, measured on this date at over four minutes plus a manual intervention, and it would land precisely on the first spawn into each new pool slot.
The ceiling and the interval therefore stay as they are, and readiness is never inferred from a pane capture again.
Relaunch is untested (see boundaries below); it adopts a live pane that nothing clears, so a predecessor's dialog text still in the capture would draw one Enter into an already-started session, whose worst case is one empty submit.

Answering the dialog has one out-of-tree effect that firstmate does not undo: it adds the answered worktree to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, which is operator state that firstmate's Enter causes to change.
The entries accumulate one per worktree path that has ever hosted an agy task, and teardown deliberately leaves them, because pruning the operator's own trust store is riskier than leaving it - the operator also runs agy outside the fleet.
`docs/configuration.md` carries that disclosure for operators.

The Enter is covered by `tests/fm-agy-harness.test.sh` against a rendered pane; it was not re-exercised against a live agy in this session, so treat the dialog text above as the measured fact and the test as the portable regression's contract.

## Quota

`quota-axi` reads agy over `cli-rpc` (plan Google AI Pro) but only while the Antigravity application is running; with it stopped it reports `Antigravity/agy is not running`.
All four windows were marked `unresolved_windows`, so agy has no `spendPriority` and cannot enter a quota-balanced profile array.
Resolving that belongs to `quota-axi`, not this adapter.

## Boundaries not verified

- **tmux.** Nothing was exercised under tmux; the lab ran on Herdr and tmux was not installed on the verification host. The process name registered in `bin/backends/tmux.sh` is the kernel-level `ps` fact above, not a tmux observation.
- One conversation and one model. The Claude and GPT-OSS models inside agy were not tested.
- Husk recovery, relaunch, and durable steering-inbox delivery were not tested.
- Primary and secondmate roles were not verified and are refused.

## Out-of-tree writes during verification

Proving a global hook requires writing under the operator's `~/.gemini/config/`.
Every lab run confirmed `hooks.json` and `plugins/` were absent beforehand, wrote only firstmate-namespaced files, removed them on exit through an `EXIT` trap, and printed the resulting directory listing to prove the root was left as found.
The Herdr `default` session was recorded before provisioning and verified identical afterwards by the lab helper's tripwire.
