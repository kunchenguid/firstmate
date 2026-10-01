# Herdr scrolled-back pane captures

These files own the recorded pane reads that the scrolled-back cases in `../../fm-backend-herdr.test.sh` replay.
They were captured on 2026-09-30 from one idle Claude Code 2.1.285 pane on Herdr 0.9.0 whose view had been left scrolled back, within seconds of each other and with read-only commands.
They are replay inputs, not evidence that every composed scenario was driven live.

## Capture provenance

| File | Command | What it holds |
| --- | --- | --- |
| `pane-get-scrolled.json` | `herdr pane get <pane>` | The pane's scroll position: 1595 rows back from the bottom, 39 viewport rows. |
| `scrolled-visible.ansi` | `herdr pane read <pane> --source visible --format ansi` | The window the view showed: old transcript whose bottom-most prompt glyph is the echo of a submitted message. |
| `live-recent.ansi` | `herdr pane read <pane> --source recent --lines 200 --format ansi` | The bottom-anchored read of the same pane, ending in its idle, empty composer and footer rows. |

## Edits to the recordings

The transcript text is private, so every letter outside the rows below was replaced with `x` and every digit with `0`; escape sequences, glyphs, punctuation, spacing, and line breaks are unchanged.
The rows kept readable are the ones the tests depend on: the echoed message rows, the composer row, and the three footer rows.
The inbox path inside the echoed message was replaced with a neutral path of the same length, so its wrapping is unchanged.
`live-recent.ansi` keeps the last 80 of the 200 recorded rows, which is still taller than the 39-row viewport.
`pane-get-scrolled.json` keeps the recorded scroll metrics and replaces the pane, tab, and workspace ids with the ids the tests use; the session, working-directory, and title fields were dropped.

The typed-draft case is composed, not recorded: the test types a draft into the empty composer row of `live-recent.ansi`.
