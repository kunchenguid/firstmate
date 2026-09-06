# Grok Build

The xAI `grok` TUI is Claude-Code-compatible.
Verified initially on 2026-06-29 with 0.2.73, slash submission on 2026-07-03 with 0.2.82, effort on 2026-07-13 with 0.2.99, and exit on 2026-07-19 with 0.2.103.
Launch shape: `grok --always-approve "$(cat <brief>)"`.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The last rendered-tail fallback, isolated to Grok pending a semantic source: the mid-turn footer row carrying `Shift+Tab:mode` and then `Esc:cancel` (measured on 1.0.13; both keys are required on one row rather than the bare token, with intervening segments such as `· always-approve` tolerated because their footer position is unmeasured) or the older `Ctrl+c:cancel`, both absent from the idle bar (`Shift+Tab:mode │ Ctrl+x:shortcuts` on 1.0.13), never the locale-fragile braille spinner. |
| Exit | `/exit` prints `Resume this session with: grok --resume <session-id>`; fallback is `Ctrl+Q` twice within 1000ms, `Ctrl+D` quits in VS Code-family terminals, and `Ctrl+C` interrupts. |
| Interrupt | Single `Ctrl+C`; Escape only focuses scrollback. A single-trial Escape on 1.0.13 cancelled an active tool turn (`docs/verification/grok-queued-enter.md`), contradicting the Escape half; that one trial is not a verification, so keep `Ctrl+C` until a dedicated repeat interrupt verification runs. |
| Skill | `/<skill>`, for example `/no-mistakes`, with end-to-end user-skill discovery, invocation, and real `no-mistakes axi run` evidence; the popup may consume Enter and fill an argument placeholder, requiring a real second Enter. |
| Autonomy | `--always-approve`, footer `· always-approve`, verified unattended; `--permission-mode bypassPermissions` is stronger equivalent. |
| Marker | `GROK_AGENT=1` on child or tool processes in 0.2.73 and no `CLAUDECODE`; a 1.0.0 hook instead had `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` without `GROK_AGENT`, so ancestry guarantees identity. |
| Resume | `grok --resume <session-id>`, or `grok -c` / `--continue` for cwd latest; `--fork-session` creates a new id. |
| Model | `--model <model>`; discover current account models with `grok models`. |
| Effort | `--reasoning-effort <low\|medium\|high>`, alias `--effort`; version 0.2.99 rejects `xhigh` and `max` with `use one of: high, medium, low`; `references/common/model-and-effort.md` owns fallback and unsupported-value handling. |

Reliable Grok rules must account for hook markers as well as the child fast path.
`../../../docs/turnend-guard.md` under "Harness integrations" owns the marker contract.

## Submission and startup

Slash autocomplete can turn the first Enter into selection plus an argument hint, including `/no-mistakes`'s optional task argument or `/compact compaction instructions`, without submission.
The shared classifier keeps that text pending, and retry sends the second Enter on both verified backends; Herdr may also prove a turn through native state.

On 2026-07-03 two Grok 0.2.82 Herdr workers left `/no-mistakes` typed for minutes while send returned success.
Old Herdr logic treated any pane delta as submission, including popup closure and placeholder fill.
Tmux and Herdr now route captures through `../../../bin/fm-composer-lib.sh`, which classifies real text on every proven content row.
`../../../docs/herdr-backend.md` owns the boundary and `../../../tests/fm-backend-herdr.test.sh` covers it.

The "Run Grok Build in a project directory?" picker appears only outside a project, such as home, Desktop, Downloads, or `/tmp`.
The spawn starts in the isolated git root, so Grok trusts it and needs no key.
For unavoidable non-project launch, `[hints] project_picker_disabled = true` in `~/.grok/config.toml` suppresses the picker.

## Composer

Fresh placeholder `Type a message...` uses dark 24-bit TRUECOLOR, not SGR-2.
`fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` drops dim or faint and truecolor below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128.
On Grok 0.2.93, real input `38;2;224;222;244` measured about 225 luminance, while borders and placeholder ranged from `38;2;50;47;70` through `38;2;110;106;134`, about 51-110, and were dropped.
The truecolor rule assumes the fleet's dark theme; SGR-2 is theme-independent.
Coverage is `../../../tests/fm-composer-ghost.test.sh` and `../../../tests/fm-backend-herdr.test.sh`.

Tmux `#{cursor_y}` may point at the pristine composer's bottom border.
The shared classifier locates the full box and all content rows, so border cursor and multi-row composers require no adapter offsets.

## Worker turn-end hook

Grok fires `Stop` each turn.
Project hooks require folder trust in `~/.grok/trusted_folders.toml`, which Firstmate does not edit; global `~/.grok/hooks/` is always trusted.
The spawn installs guarded global `fm-turn-end.json` and `fm-turn-end.sh`.
They act only when workspace `.fm-grok-turnend` matches the registry under `~/.grok/hooks/fm-turn-end.d/`, then touch the task's `state/<id>.turn-ended` through always-set `GROK_WORKSPACE_ROOT`, which equals the worktree.
This stays outside the worktree, needs no trust grant, and writes only Firstmate files.
`../../../bin/fm-teardown.sh` removes the gitignored pointer before pooling.
Secondmates skip it because idle is healthy and ordinary stale-pane detection does not apply.

## Primary integration

Verified on 2026-07-28 with 0.2.112 and genuine pre-native 0.2.73.
`.grok/hooks/fm-primary-turnend-guard.json` invokes `../../../bin/fm-turnend-guard-grok.sh`.
The exact running Stop payload selects same-process continuation on 0.2.112; 0.2.73 omits that capability and needs one guarded `grok --resume`.
`../../../docs/turnend-guard.md` owns adaptive and malformed-input behavior.

Grok also loads Claude project settings, so Claude entries for Grok-covered events stand down under `GROK_AGENT` or `GROK_HOOK_EVENT`; that owner records the exact set and why `GROK_SESSION_ID` is excluded.
Project-local hooks require launch-time `--trust`; without it the guard steps aside and `../../../bin/fm-guard.sh` is the next-command alarm.
Watcher supervision remains tracked background notification around `../../../bin/fm-watch-arm.sh`, not Pi-style extension ownership.
PreToolUse blocks directly, but every `$VAR` in a hook command needs inline `:-default` or Grok refuses the hook.
