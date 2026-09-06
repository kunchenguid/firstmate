# agy (Antigravity CLI)

Verified on 2026-09-03 with Antigravity CLI 1.1.24, which self-updated to 1.1.25 mid-investigation.
Describe agy by behavior rather than by version: it updates itself without being asked, and the hooks facility this adapter depends on is absent from `--help` and has changed recently in its own changelog.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy` on `PATH`. |
| Launch | `agy --dangerously-skip-permissions [--model M] [--effort E] -i "<prompt>"`. `-i` starts an interactive session seeded with the prompt; `-p` runs one turn and exits. |
| Flag order | Go-style flags: `-i` and `-p` consume the NEXT argument, so the prompt must be last and every other flag must precede it. `agy -p --dangerously-skip-permissions "..."` takes the flag as its prompt and reports the real prompt ignored. |
| Models | `agy models` lists current ids; the Gemini family encodes an effort tier in the id itself (`gemini-3.8-flash-high`), and `--model` and `--effort` may both be passed. |
| Effort | `--effort low\|medium\|high`; agy names that set in its own refusal. `xhigh` and `max` are omitted rather than rejected at launch. |
| Busy state | No semantic source and deliberately unarmed; classifies `unknown missing`. Supervision rides the turn-end wake below. |
| Exit command | `/exit` (aliased `quit`). Two `Ctrl+D` presses also exit, the first showing `press ctrl+d again to exit`. |
| Interrupt | Single Escape. Renders `⎿ Interrupted · What should Antigravity CLI do instead?` and leaves the composer EMPTY, so no clear key is needed. |
| Resume | `agy --conversation=<id>`, printed on exit. Restores real model context, NOT the workspace: the banner shows the launching cwd, so resume must run from the original worktree. |
| Environment marker | `ANTIGRAVITY_CONVERSATION_ID`, exported to every tool subprocess, whose value equals the `conversationId` in the Stop payload. |
| Composer | Bare `>` prompt inside horizontal rules; no bordered box. `>` is a shell-prompt glyph outside a bordered container, so the composer verdict is always `unknown` - typed-submit confirmation therefore works on tmux (whose submit core resolves it through the busy footer) and reports unconfirmed on EVERY other backend including herdr, whose footer rescue is gated on `pending` - a narrower scope than cursor, which reads `pending` and is rescued on herdr. The brief rides the launch command, not `fm-send`. |
| Status bar | `? for shortcuts` when it will accept a prompt; `esc to cancel` when it will not. |

## Detection ordering

agy does NOT clear an inherited `CLAUDECODE`.
`CLAUDECODE=1 agy -p` and having the agent print its own environment returned both `CLAUDECODE=1` and `ANTIGRAVITY_CONVERSATION_ID`, so an agy worker launched from a claude primary carries both markers and whichever is tested first wins.
`../../../bin/fm-harness.sh` therefore tests `ANTIGRAVITY_CONVERSATION_ID` BEFORE `CLAUDECODE`, exactly as it does for cursor, and `../../../bin/fm-spawn.sh` also clears the foreign markers at the launch boundary.

## Workspace trust is the spawn-blocking hazard

`--dangerously-skip-permissions` governs TOOL permissions only and does NOT suppress the workspace-trust dialog.
Launching with that flag into a folder agy has never seen still renders `Do you trust the contents of this project?`, so every fresh task worktree hits it.
The dialog draws NO status-bar text, so a pane parked on it is indistinguishable from idle by any rendered signal - no spinner, no `esc to cancel`.
`../../../bin/fm-agy-trust.sh` therefore registers the worktree in `trustedWorkspaces` in `$HOME/.gemini/antigravity-cli/settings.json` before launch, and refuses rather than degrades.
Teardown withdraws the same entry with `--remove`, which runs no scope test because removal can only withdraw trust, and writes nothing when the path is already absent.
Its scope test is structural: only a linked git worktree of the named project is accepted, and a primary checkout, a foreign project's worktree, a worktree subdirectory, a plain directory, the home directory, and the settings directory are each refused.
Trust is not inherited by a nested repository - `/tmp/claude-1000` trusted did not cover the git repo at `/tmp/claude-1000/agylab` - so each task worktree needs its own entry.

## Crew turn-end hook

agy is outside the primary turn-end guard scope; it is a crewmate/scout adapter only and `../../../bin/fm-spawn.sh` refuses a `--secondmate` launch on it, because there is no agy primary supervision protocol.

`../../../bin/fm-agy-turnend-hook.sh` owns one `firstmate-turn-end` key in `$HOME/.gemini/config/hooks.json`, one silent always-zero hook script, and one private token registry under `$HOME/.gemini/antigravity-cli/fm-turn-end.d/`.
Every operator hook in that file is preserved.
Each agy worker worktree receives a gitignored `.fm-agy-turnend` pointer, and the global hook touches `state/<id>.turn-ended` only when the Stop payload's `workspacePaths`, the pointer, and the registry entry all agree.
Workspace-local `<worktree>/.agents/hooks.json` also loads, but only in interactive mode: print mode logs `loaded 0 named hooks from 0 hooks.json file(s)` for the same file.

**A Stop event is not on its own a finished turn.**
agy moves a shell command that outruns its own wait into the background, yields the composer, and fires Stop with `fullyIdle` false while that command still runs; a second Stop with `fullyIdle` true follows once it finishes and the agent reports it.
The installed hook fires only on `fullyIdle` true, and any future busy-state writer must apply the same gate.

## Where the turn-end signal is silent

Two paths end a turn with NO Stop event, so a worker on either goes idle and quiet and the watcher's staleness check is the only backstop.
Do not read a silent pane as a healthy one.

- **A DECLINED tool call.** Choosing `4. No` at a permission prompt returns the pane to idle with `⎿ User declined the tool call` and fires nothing.
  Reproduced twice, with a same-session plain turn firing Stop normally as a positive control.
  Launching with `--dangerously-skip-permissions` is what keeps a crewmate off this path.
- **An Escape interrupt.** Cancelling a turn fires nothing.
  Firstmate initiates its own interrupts, so it already knows, but a captain interrupting a pane by hand leaves no wake.

Stop correctly does NOT fire while parked at a permission prompt, which is the safe direction: there is no false "done".

`terminationReason` values beyond `NO_TOOL_CALL` are UNVERIFIED.
The payload documents `model_stop`, `max_steps_exceeded` and `error`, but every observation here returned `NO_TOOL_CALL`; forcing an error, a step-limit, and a context-limit stop would settle whether Stop fires on those paths at all.

## Rendered states

`? for shortcuts` means idle.
`esc to cancel` means busy, parked at a tool-permission prompt, or holding an open slash-command menu - the status bar alone does not separate them, so look for `Requesting permission for:` / `Do you want to proceed?` in the body.
A trailing `· N task(s) · /tasks` on an otherwise idle bar means background work is still running.
`../../../bin/fm-composer-lib.sh` matches `esc to cancel` as a DELIVERY guard only; `../../../bin/fm-busy-lib.sh` owns why it is never a recorded worker state and what a semantic `PreInvocation`/`Stop` pair would take.
