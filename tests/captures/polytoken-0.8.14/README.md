# Polytoken TUI captures

These files are unchanged `tmux capture-pane -p -e` output of a real Polytoken 0.8.14 TUI, used as replay inputs by `../../fm-polytoken-harness.test.sh`.
They were captured on 2026-09-26 in a 100x30 tmux pane, in a disposable git repository, with the TUI started by `polytoken new --model 'codex/gpt-6-luna(low)'`.
Every frame except `license.ansi` has the terminal cursor on row 27 (0-based), the blank or first draft row between the composer's two rules.

| File | Observed state |
| --- | --- |
| `idle.ansi` | A completed turn (`Completed in 1.67s`) above an empty composer. |
| `draft.ansi` | Two unsubmitted draft rows typed with Alt+Enter between them. |
| `busy.ansi` | A running shell tool call with the `Running for 7.91s` turn row. |
| `cancelled.ansi` | The same turn after one Escape, showing `Canceled after 7.98s`. |
| `primed.ansi` | An idle agent after one Escape, whose status row reads `Press Esc again to rewind to a prompt.` |
| `rewind-picker.ansi` | The rewind picker a second Escape opened 0.5 seconds later. |
| `license.ansi` | The license-agreement gate a throwaway `XDG_DATA_HOME` with no recorded acceptance opened at launch. |

The status row alternates between its left and right halves when it does not fit the pane width, so frames differ there by design.
Passing replay assertions establish classification of these exact frames, not live behavior; `../../fm-polytoken-signals-live-e2e.test.sh` refreshes the live facts.
