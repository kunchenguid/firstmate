# GitHub Copilot CLI

Copilot is a spawned crewmate, scout, and persistent secondmate TUI adapter, and a hand-opened primary, on tmux and Herdr only.
Every other runtime backend is refused.
A real Herdr pane and a real tmux pane have each run it with Copilot CLI 1.0.105 on 2026-11-05, and as a primary with 1.0.109 on 2026-11-11.
Launch, interrupt, exit, relaunch, and teardown were exercised on both tmux and Herdr.
[Copilot verification](../../../../../docs/verification/copilot.md) owns dated vendor evidence and what the backends have not yet exercised.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `COPILOT_HOME=<state>/<id>.copilot-home copilot --allow-all --no-ask-user --no-auto-update --plugin-dir <state>/<id>.copilot-plugin [--model <id>] [--reasoning-effort <level>] -i "<typed launch envelope>"`; `-i` starts the interactive session and auto-submits the prompt. [`fm-spawn.sh`](../../../../../bin/fm-spawn.sh)'s header owns flags. |
| Autonomy | `--allow-all` grants every tool, path, and URL permission but still shows a folder-trust dialog in a fresh worktree, which holds the `-i` prompt unsent. The launch therefore relocates `COPILOT_HOME` onto `state/<id>.copilot-home`, whose seeded `config.json` lists exactly the worktree under `trustedFolders`. Nothing is prompted, no other directory is trusted, and the user's `~/.copilot` is not written and is read only for the login keys below, so its user-level hooks, plugins, skills, and MCP servers do not load. Trusting the worktree still loads its own project hooks, skills, and MCP servers, as does every other unattended route; no setting suppresses that. Login survives the relocation on a host whose credential lives in the OS keyring, which is keyed by account rather than by home; for a host that stores the token in `config.json`, the seeding copies only `authTokens`, `copilotTokens`, `loggedInUsers`, and `lastLoggedInUser` from the real `${COPILOT_HOME:-$HOME/.copilot}/config.json` into the task `config.json` (mode 600, tolerant of a missing or unparsable source). Firstmate maps no other permission mode. |
| Sign-in failure | A launch with no usable login parks on `Please use /login to sign in to use Copilot` (no token) or `Authentication token found but could not be validated.` (rejected token); the busy classifier reads either as `unknown launch-prompt`. |
| Questions | `--no-ask-user` removes the `ask_user` tool, so a worker that would have shown a `Copilot needs information` picker decides alone and reports through the status file as usual; without the flag the same prompt held the pane on an unanswerable choice. |
| Model and effort | `--model <id>` takes a catalog id such as `claude-sonnet-5.5`; an unknown id exits at launch with `Model "<id>" from --model flag is not available.` `--reasoning-effort low\|medium\|high\|xhigh\|max` passes through. |
| Busy and turn end | Plugin hooks written by [`fm-copilot-plugin.sh`](../../../../../bin/fm-copilot-plugin.sh): `userPromptSubmitted` opens a turn, `agentStop` and `sessionEnd` close it (subagent payloads carrying `parentAgentId` are ignored), written as the `copilot-hook` record in [`fm-busy-lib.sh`](../../../../../bin/fm-busy-lib.sh). A copilot task with no record classifies `unknown missing`. |
| Interrupt | Two Escape presses. On a running turn the first renders `esc again to interrupt` for only about half a second, and the control plane sends the second immediately after that proof (press gap 0.05 s); the turn prints `Operation cancelled by user`. `agentStop` does not fire, so the busy record stays until the next prompt, but the session transcript (`<COPILOT_HOME>/session-state/<sessionId>/events.jsonl`) gets an `abort` event within about 0.1 s: `fm-control` reads a new one in the task's own home as the cancel acknowledgement (`cancel=confirmed`), and the typed wake reads it to ring without waiting out its interrupt grace. On an idle agent with history the second press opens a `Rewind to a previous point` picker, which one more Escape closes without restoring. |
| Exit | `/exit`, one Enter; the pane prints a summary and `Resume copilot --resume=<session-id>`. |
| Identity | None published. The kernel process name is the thread name `MainThread`; only argv[0] `copilot` identifies it, matched by exact basename in [`fm-harness.sh`](../../../../../bin/fm-harness.sh) and [`fm-agent-process-lib.sh`](../../../../../bin/fm-agent-process-lib.sh). The spawn clears foreign markers such as `CLAUDECODE`. |
| Composer | Two shapes, each with one footer row below and unchanged while a turn runs: a `❯` row between two full-width `─` rules (a plain pty), and the block-glyph box a real Herdr pane draws (`╻▄▄▄…`, `┃` input rows, `╹▀▀▀…`; empty is a bare `┃`). Read only when the caller names the recorded harness `copilot`, by `_fm_composer_copilot_state` in [`fm-composer-lib.sh`](../../../../../bin/fm-composer-lib.sh); more than one row between the rules reads `pending`, and a picker or dialog reads `unknown`. |
| Herdr | Herdr's own `copilot` integration reports the pane identity and session, so the hooks here carry no Herdr reporting. |
| Skills | `/<skill>` for a project skill (discovered from the worktree's `.agents/skills`, `.github/skills`, or `.claude/skills`) and `/<plugin>:<skill>` for a plugin skill; the model runs it as a `skill(<name>)` tool call. `fm-send` types a leading `/` on the typed plane, and the popup settle it already applies sufficed. Skills a user configures in the real `~/.copilot` (`skillDirectories`, installed plugins) are not inherited by the per-task home. |

## Hook carrier

A plugin directory is the per-task hook channel because every other source is a user or project file (`~/.copilot/hooks`, `.github/hooks` in the worktree).
`--plugin-dir` loads the hooks once the directory is trusted.
The directory holds `plugin.json` and `hooks/hooks.json` and is retired by relaunch and removed whole by teardown.
A raw launch command carries no `--plugin-dir`, so nothing is armed for it.

## Limits

Early provider or build errors can leave the spawn-owned busy record open when `agentStop` does not run; inspect the visible pane and use the ordinary recovery procedure.
Typing while a turn runs queues the line (`Queued (1)`) rather than failing, so a draft is detectable but an in-flight steer is not refused.
A subagent fires its own `userPromptSubmitted` and `agentStop` with `parentAgentId` in the payload, so the plugin hooks skip any payload carrying it and only the main agent's events open and close the turn.
A hand-opened primary should launch with `copilot --no-auto-update` (or `COPILOT_AUTO_UPDATE=false`): Copilot applies a downloaded release at the next plain launch, `autoUpdate: false` alone does not stop that, and only `fm-spawn` and the primary's session-start digest warn when `copilot --version` is outside the verified range (launch it with `bin/fm-copilot-primary.sh`, which opens a tmux session when the terminal has no tmux or Herdr pane; [recipe](../../../../../docs/supervision-protocols/copilot.md)).
A hand-opened primary session gets the session-start digest and the pre-tool seatbelts from the tracked `.github/hooks/firstmate-primary.json` ([verification](../../../../../docs/verification/copilot.md#native-primary-hooks)); a worker on a Firstmate worktree loads that file too and both adapters stand down by primary scope.
The turn-end guard and the typed wake are verified on tmux and Herdr ([verification](../../../../../docs/verification/copilot.md#typed-wake)); `bin/fm-copilot-wake.sh` owns the wake.
As this home's own primary, Copilot's session lock, digest, seatbelts, turn-end guard, typed wake, double-Escape interrupt, and exit were exercised live on both backends ([verification](../../../../../docs/verification/copilot.md#copilot-as-this-homes-primary)).
`/afk` and `/quiet` on a Copilot primary run the away daemon, never the supervision host, which has no Copilot arm owner; the typed wake stands down while away mode runs.
`/compact` fires no new session-start hook and a model does not rerun session start unprompted, so `bin/fm-copilot-compact.sh` re-emits the digest on the first prompt or tool call after any compaction ([verification](../../../../../docs/verification/copilot.md#compaction-re-emit)).

A killed wake process (`kill -9`, the OOM killer) restarts at the next prompt, from the `userPromptSubmitted` hook while work needs supervision, and the turn-end guard blocks a stop once while it is down.
Unattended, the orphaned watcher calls `bin/fm-copilot-wake.sh revive` on every poll, which restarts the wake process once its lock pid is dead, work needs supervision, and the pane is idle with an empty composer; a busy turn or a half-written line is never restarted over.
A self-update re-reads `AGENTS.md`, and Copilot's `view` refuses a file of that size (about 50 KB) in one call with `File too large to read at once`; a model then tends to read only the first range and stop, so `bin/fm-sessionstart-copilot.sh` appends that chunked-read instruction to the digest it hands a Copilot primary (no other harness's digest carries it).
Read it in successive `view_range` calls up to the last line (`wc -l` gives the length), or page it through the shell in chunks under about 39 KB, because shell output over that size is also saved to a file instead of returned.
A hand-opened primary launches with `-i '<one line>'` so the session-start digest arrives without a human prompt ([owner](../../../../../docs/sessionstart-nudge.md#github-copilot-cli)).
The typed wake loop re-executes itself when a self-update replaces `bin/fm-copilot-wake.sh`, so a running primary does not keep pre-update wake code.

## Secondmate

A secondmate launches through `fm-spawn.sh --secondmate` with the same per-task `COPILOT_HOME`, plugin, and `-i` launch as a worker, except that its worktree is the secondmate home and `FM_HOME` names that home.
The home's own tracked `.github/hooks/firstmate-primary.json` then supplies the digest, the seatbelts, the turn-end guard, and the turn records for the typed wake, because the `.fm-secondmate-home` marker makes the home a primary scope; the per-task plugin keeps publishing the mate's busy turns to the parent's `state/<id>.busy-state`, which `fm-crew-state` and the active-turn gate read.
The mate starts its own wake with `bin/fm-copilot-wake.sh start` once work is under way, and the wake process stands down when the pane's agent exits.
`fm-send` steers, `fm-control` interrupt, exit and relaunch, and the liveness sweep's relaunch use the same mechanics as for a worker.
The shared cd guard stays inert in a secondmate home that is a linked worktree (`docs/cd-guard.md` owns that scope), and an interrupted turn leaves the parent's busy record open until the next prompt, as for a worker.
[Verification](../../../../../docs/verification/copilot.md#secondmate) records what a live mate on tmux and Herdr did.
