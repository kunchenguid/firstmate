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
The payload is read whole with a bounded `read -r -t 5 -d ''` rather than one line or a plain `cat`, so a multi-line payload survives and a runner that never closes stdin cannot park the hook until agy's 10s timeout kills it.
That bounded form was not re-exercised against a live agy; only the EOF path was, and it is byte-identical to what the lab ran.
Measured directly on this host (GNU bash 3.2.57, macOS arm64): on EOF the variable holds the complete payload, and on the 5s timeout bash 3.2 assigns nothing, so a runner holding stdin open loses that turn end rather than delivering a truncated one.

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
A session blocked on this dialog still fires `Stop` hooks with `fullyIdle:false`, which is a second reason the gate matters.

Every crewmate and scout runs in a fresh per-task worktree, so the dialog is the ordinary case rather than an edge one, and an unanswered one is a silent hang: agy never reads the brief, its only `Stop` is ignored by the `fullyIdle` gate, and the busy classifier stays at `unknown agy-unverified`.
`bin/fm-spawn.sh` therefore polls the pane after launch and sends one Enter once the dialog is proven on screen.
Readiness is then settled only by a positive match of one of agy's own footers, never by the dialog's absence: a pane read that fails or comes back empty clears the dialog text without proving that the Enter was ever consumed.
The read is the same 120-line capture every other launch gate uses, so a dialog anywhere in the window is answered rather than missed; both backends answer with recent output rather than a screen snapshot, and an answered dialog re-served in that output is bounded by the one-Enter latch instead of by narrowing the read.
Because that output can predate the launch - a relaunch adopts a live pane and nothing clears it - the evidence is bounded to this incarnation instead: the gate captures the pane immediately before the launch Enter and reasons only about rows drawn after the last baseline row that is neither dialog nor footer text, which in practice is the row the launch line was typed on.
That anchoring assumes the backend re-serves that row byte-identically in later captures, which was not measured; a backend that re-renders or re-wraps it, or that answers the baseline read empty, degrades the gate to the unanchored read rather than failing, and an empty baseline read means the backend is already failing in a way the gate's own polls report at the deadline.
An empty read is treated as no evidence yet, and the spawn fails loudly at the deadline naming what was never observed.
That gate is covered by `tests/fm-agy-harness.test.sh` against a rendered pane; the Enter itself was not re-exercised against a live agy in this session, so treat the dialog text above as the measured fact and the gate as the portable regression's contract.

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
