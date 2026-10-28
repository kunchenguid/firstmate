# MiniMax Code worker verification
Audience: maintainer verification.
Verified 2026-10-28 on macOS 27.0.1 arm64 with MiniMax Code `0.7.1` (npm `@minimax-ai/code`, running under Node 26.3.0), model `minimax/MiniMax-M3.1-Flash`, tmux 3.7c, and a named Herdr 0.9.5 lab session.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/mcode.md) owns operating facts; executable owners carry launch and state mechanics.
This verification covers crewmates and scouts on tmux and Herdr.
Primary, secondmate, ACP, headless `mcode exec`, mcode's own worktree and agent-team features, and quota-provider integration are outside this guarantee.

## Refresh commands

```sh
mcode --version
mcode --help
bin/fm-test-run.sh tests/fm-mcode-harness.test.sh
FM_MCODE_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-mcode-signals-live-e2e.test.sh
FM_MCODE_SIGNALS_LIVE=1 FM_MCODE_LIVE_BACKEND=herdr bin/fm-test-run.sh tests/fm-mcode-signals-live-e2e.test.sh
```

The credentialed guard runs the real `fm-spawn.sh` launch on a private tmux server, or in a named non-default Herdr lab session through `bin/fm-herdr-lab.sh`, with only worktree allocation stubbed.
Steering, interrupt, exit, and relaunch use the real `fm-send.sh` and `fm-control.sh`.
It uses the caller's own MiniMax sign-in and spends a few small prompts of the plan, and it needs the caller's global Full access, which it reads and never writes.
It fails rather than skips when the launch preflight refuses, and failures name the installed mcode version and backend.
Its sessions land in the caller's own mcode data directory.

## Live guard results

On 2026-10-28 both backends completed with exit 0:

```text
ok - mcode 0.7.1 [tmux]: spawn brief, Full access, model minimax/MiniMax-M3.1-Flash, identity, and title idle
ok - mcode 0.7.1 [tmux]: the worker commit carries no attribution
ok - mcode 0.7.1 [tmux]: real fm-send doorbell read and acknowledged
ok - mcode 0.7.1 [tmux]: one Escape cancels the turn, keeps the agent, and the title settles
ok - mcode 0.7.1 [tmux]: /quit exits and prints mcode --session <id>
ok - mcode 0.7.1 [tmux]: relaunch re-delivers the brief and the worker exits again
ok - mcode 0.7.1 [herdr]: spawn brief, Full access, model minimax/MiniMax-M3.1-Flash, identity, and title idle
ok - mcode 0.7.1 [herdr]: the worker commit carries no attribution
ok - mcode 0.7.1 [herdr]: real fm-send doorbell read and acknowledged
ok - mcode 0.7.1 [herdr]: one Escape cancels the turn, keeps the agent, and the title settles
ok - mcode 0.7.1 [herdr]: /quit exits and prints mcode --session <id>
ok - mcode 0.7.1 [herdr]: relaunch re-delivers the brief and the worker exits again
```

A brief that told the worker to read its inbox "later, when the doorbell arrives" made M3.1-Flash start a background poller and keep its turn open for minutes, so the guard's brief ends the turn explicitly.

## Observed vendor surfaces

`mcode --help` lists `-m, --model <provider/model>`, `--session [id]`, `-c, --continue`, `--tui-mode`, `--mode`, `--ptc`, and system-prompt options, and no permission, effort, trust, plugin, or hooks flag.
`mcode exec --help` lists `--permission <policy>` (`smart`, `full`, or `off`) and `--effort <level>` for headless runs only.
The TUI permission mode is the top-level `permissionMode` key of `$MINIMAX_DATA_DIR/config.yaml`, whose loader accepts `default`, `acceptEdits`, `bypassPermissions`, `auto`, and `off`, with `auto` when unset.
`/permission full` wrote `permissionMode: bypassPermissions` to `~/.minimax/config.yaml`, and Alt+M cycled the same key through `bypassPermissions`, `default`, and `auto` as it changed the status row's `Full access`, `Ask`, and `Auto`.
In `Auto`, a shell append to a file outside the workspace stopped on:

```text
◆ Approval required
Why · Needs confirmation: The exact user-requested command appends to a concrete file outside the current workspace root.
↑/↓ choose · Enter confirm · Esc deny · Ctrl+C stop
```

`MINIMAX_DATA_DIR=<empty dir> mcode exec ...` failed with `Sign in to MiniMax to use Agent features. Run \`mcode login\`, then retry.`, so a per-task data directory loses the sign-in.
mcode's packaged hooks reference names the user file `{{DATA_DIR}}/hooks.json`, which needs `"enabled": true`, and a project `.minimax/hooks.json` that runs only after the user switches it on per project in Settings; a project hooks file in a fresh directory did not fire.
`mcode -m minimax/MiniMax-Bogus-9` and `mcode exec --model minimax/MiniMax-Bogus-9` both ran on M3.1-Flash with no error.
The installed config lists `MiniMax-M3` and `MiniMax-M3.1-Flash` under `provider.minimax.models`, and M3.1-Flash advertises effort levels `default`, `low`, `medium`, `high`, `xhigh`, and `max` that only `/model` and `mcode exec --effort` select.
A multi-line positional prompt starting with U+2063 submitted at launch with no extra Enter, and the model reported the leading `e2 81 a3` bytes, so the typed launch envelope survives.
No trust or onboarding dialog rendered in a fresh git directory.
`ps -o comm=` reported `minimax-code` for the TUI while tmux `#{pane_current_command}` reported `node`.

The terminal title read through tmux `#{pane_title}` and Herdr's `terminal_title`:

```text
Ready | hookprobe (mvs_7422) | MCode
Working | hookprobe (mvs_7422) | MCode      (every second of a turn, including an 8 s shell tool call)
Done | Run sleep 8 && echo done | MCode
Stopped | Run sleep 8 && echo done | MCode (after one Escape)
```

The bundle's title map also names `Needs approval`, `Needs input`, `Needs login`, `Failed`, and `Error`.
The spinner row above the composer read `⠏ Loading · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop` before the first tool and `⠼ Running 27s · ...` during one, and the idle header read `Message · Enter send · Ctrl+J newline`.
The composer row is a bold `38;2;104;192;255` `›`, then the placeholder `Ask Mcode to do anything` or a next-message suggestion as a reverse-video first cell followed by `38;2;173;173;173` text, under a `Suggested next message · Tab accept` header for a suggestion.
Typed text is the default foreground, and a typed `/quit` is bold `38;2;104;192;255`, luminance about 172.9 against the placeholder's 173.
The tmux cursor sat on the composer row.
After Ctrl+U cleared a typed `/quit`, the slash popup row `→ quit (exit)  Exit Minimax Code` stayed drawn until the next redraw.

One Escape on a running turn printed `Interrupted after 27s` and left an idle composer.
A turn interrupted before it produced anything printed `Interrupted after 0s` and `Stopped · message restored to the Composer.` with the prompt back in the composer.
On an idle composer one Escape printed `Press Esc again to edit the latest message`; a second Escape 0.1, 0.2, 0.3, or 0.4 s later opened `Editing the selected message · Enter replace and regenerate · Esc cancel` with the previous prompt in the composer, while 0.5, 0.6, 1.0, 1.5, and 2.0 s gaps did not, and one more Escape closed it.
`/quit` printed:

```text
Continue this session with:
  mcode --session mvs_acd90236558e44a5a56845bb6ad2508f
Intelligence with everyone, bye~
```

and the process exited with status 0.

## Herdr lab session

In a named Herdr 0.9.5 lab session, `agent get` on an mcode pane answered `agent_not_found` until the pane was reported from outside it:

```text
pane report-agent <pane> --source firstmate:mcode --agent mcode --state unknown
agent get -> {"agent":"mcode","agent_status":"unknown","terminal_title":"Ready | hookprobe (mvs_35cd) | MCode", ...}
```

A report made while the pane's shell was still in the foreground was dropped once mcode started.
A report made after mcode started stayed through a 12 s shell tool call, with `terminal_title` moving from `Working | ...` to `Done | ...`, and `agent get` answered `agent_not_found` again after `/quit`.
A relaunched mcode in the same pane accepted a fresh report.
`fm_backend_herdr_pane_process_state` read `agent` for the live mcode pane.

## Coverage and limits

The portable regression drives anchored ancestry and liveness, worker-only resolution, the single-press interrupt with its Ctrl+U clear and edit-mode hazard, the captured placeholder, suggestion, draft, and slash-command composer shapes with and without the mcode identity, the lazy Herdr identity probe, the title and spinner-row busy signals driven apart, the launch preflight, and the scout launch, readiness gate, and refusals.
`tests/fm-backend-herdr.test.sh` pins the stateless `mcode` registration reading live over a `minimax-code` process and stale over a shell-only pane.
Not verified and therefore unsupported:
- Linux; the process title and colours were observed on macOS only.
- `mcode --continue` and `mcode --session <id>` resume, and end-to-end skill invocation through `fm-send`.
- A turn parked on `Needs input` or `Needs login`, which the busy read reports unknown.
- A light mcode theme, whose placeholder colour is unrecorded; its composer would read pending and steering would defer.
- Zellij, Orca, cmux, Paseo, rex, tern, and T3 Code, which `fm-spawn.sh` refuses for mcode.
- Any primary or secondmate supervision, so the adapter refuses both.
