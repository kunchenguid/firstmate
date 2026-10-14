# Devin CLI

Worker lifecycle verified on 2026-09-21 and 2026-09-22 with Devin CLI 3000.11.1 (cc4e349ca55e), and primary integration verified on 2026-09-26 with 3000.11.3 (9c803229faa4).
The router owns the dispatch boundary: primary, crewmate, and scout are supported; secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/devin.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Native `UserPromptSubmit` opens, `Stop` closes normal completion, and `SessionEnd` closes shutdown through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit`, with the shared slash-command settle before Enter; prints `devin -r <session-id>`. |
| Interrupt | One Esc, then a second only after the running turn renders `esc again to interrupt` and at least 0.5 seconds later; no restored draft and no clear key. An idle agent gets one press and `cancel=not-running`, because a fast idle pair opens the `/revert` picker, where Enter reverts file changes. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Devin discovers Firstmate's user skills from `~/.agents/skills`, and `fm-send` types the slash form through its popup settle. |
| Resume | `devin -r <session-id>`; `--model` may switch the resumed session's model. |
| Model flag | `--model <model-id>`, including `swe-2-medium` and account-listed `fusion-<lead>-sidekick-swe-2-medium` ids. |
| Effort flag | None; effort is encoded in the model id, and Firstmate records the independent axis without passing it. |
| Model discovery | `devin models list`; authentication preflight is `devin auth status`. |
| Marker | None; anchored native `devin` ancestry identifies the adapter and outranks foreign inherited markers. |
| Trust dialogs | The launch skips workspace trust for this run; the spawn owner carries the exact flags. |
| Imported config | The worker config sets `read_config_from.claude` false, so no Claude Code hook, `CLAUDE.md` rule, `.claude/skills`, or Claude MCP entry is imported; `AGENTS.md` and `.agents/skills` still load. |
| Commit attribution | Unless the home sets `config/keep-ai-trailers` (`../../../../../docs/configuration.md` "Commit attribution"), the worker config sets `attribution` false, Devin's switch for its `Co-Authored-By` trailer and `Generated with Devin` line; with the flag, the user config's setting (default on) is kept. |

## Worker lifecycle limits

An armed double Esc renders `Canceled. What should Devin do?` and restores the empty composer but emits no `Stop` hook on this version.
The control plane therefore invalidates the interrupted incarnation to `unknown`, with `cancel=unconfirmed`; it never fabricates semantic idle from a delivered key.
A manual keyboard cancellation outside that control plane can leave the last busy record until the next normal completion or session exit.
An open revert picker is closed with one Esc, never Enter; the control plane does that after its own presses and refuses to type an exit command into it.
Tool responses are not used as main-turn completion signals.
Herdr identifies a Devin pane natively from its own screen-detection manifest, and interrupt and steering work there, but `exit` and therefore `relaunch` refuse on Herdr: its cursorless composer read answers `unknown` for Devin's frame.

`../../../../../bin/fm-spawn.sh` owns autonomy, trust, typed brief delivery, color preservation, and the omission of the Claude permission-mode mapping.
`../../../../../bin/fm-devin-config.sh` owns the private user-config snapshot and appended lifecycle hooks; the user and project configs remain vendor-owned.
The config snapshot can contain private settings and has mode 600.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified `❭` glyph, dim idle placeholder, active-turn composer, and interrupt hint.
The shared delivery path must preserve ANSI styling: placeholder-like text surviving a styled capture remains a draft and must not be overwritten.
The `../../../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send` on both SWE-2 and Fusion.
The shared slash-command settling path also handles `/quit` autocomplete.

## Primary integration

A Devin primary is supported when launched from the firstmate home under tmux or Herdr; a secondmate is not.
Tracked `.devin/config.json` sets `read_config_from.claude` false, so the repo's `.claude/settings.json` hooks cannot double-execute beside Devin's own registrations; `AGENTS.md` and `.agents/skills` still load.
Tracked `.devin/hooks.v1.json` registers `../../../../../bin/fm-sessionstart-devin.sh` on `SessionStart`, `../../../../../bin/fm-turnend-guard-devin.sh` on `Stop` with a 28800-second timeout, and the arm, cd, and delegation pre-tool guards on `PreToolUse`.
Devin awaits a `Stop` hook synchronously, so the park model holds the turn boundary open on one foreground watcher cycle and returns a wake as a single `{"decision":"block","reason":...}` continuation inside the same turn; queued captain input and Escape stand the park down rather than waiting out the park.
While parked, a typed-plus-Enter captain message is visibly queued and drains as its own turn only after the hook exits without a block, and Devin kills only the hook's own shell at timeout, orphaning its children.
[`../../../../../docs/supervision-protocols/devin.md`](../../../../../docs/supervision-protocols/devin.md) owns the supervision contract and [`../../../../../docs/turnend-guard.md`](../../../../../docs/turnend-guard.md) owns the loop bound and pane stand-down contract.
ACP, quota-provider integration, and native Fusion subagent accounting remain separate follow-ups.
