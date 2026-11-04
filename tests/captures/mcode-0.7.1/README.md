# MiniMax Code 0.7.1 pane captures

These files are the visible pane of the real MiniMax Code 0.7.1 TUI (`mcode`), one per composer and busy state that `../../fm-mcode-harness.test.sh` replays through the shared classifiers.
They were recorded on 2026-10-28 on macOS arm64 with tmux 3.7c in a 160x50 pane, from `mcode -m minimax/MiniMax-M3.1-Flash` launched in a scratch git directory with the captain's own sign-in and Full access.

## Capture provenance

Each capture is unchanged `tmux capture-pane -p -e` output, so the ANSI styling the ghost stripper reads is intact, with trailing blank rows dropped and the scratch directory replaced by `{WORKDIR}` in the status row.
No replay substitutes that token, because no classifier reads the status row's path.
The cursor row is tmux's `#{cursor_y}` at capture time; mcode keeps the terminal cursor on its composer row.

| File | Cursor row | State | What the pane shows |
| --- | --- | --- | --- |
| `idle.ansi` | 32 | Idle after a turn | `Message · Enter send` header, the `Ask Mcode to do anything` placeholder in 38;2;173;173;173 after a reverse-video cell |
| `busy.ansi` | 30 | A turn running an 8 s shell tool | `⠧ Running 6s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop` in the header slot, the placeholder in the composer |
| `typed-draft.ansi` | 32 | Unsubmitted text | `Prompt · Enter send` header, `typed draft text` in the default foreground |
| `typed-slash.ansi` | 45 | `/quit` typed, slash popup open | `Command · Enter run` header, a bold 38;2;104;192;255 `/quit`, and the popup row `→ quit (exit)  Exit Minimax Code` |
| `suggestion.ansi` | 46 | Idle with a next-message suggestion | `Suggested next message · Tab accept` header and the suggestion in the placeholder colour |

## Replay limits

The replays prove how `bin/fm-composer-lib.sh` and the mcode busy fallback read these exact panes, with and without the mcode identity.
The terminal title, the second busy signal, is not part of a pane capture; `../../../docs/verification/mcode.md` records it.
Whether the installed mcode still renders these panes is the live guard's question: `tests/fm-mcode-signals-live-e2e.test.sh`.
