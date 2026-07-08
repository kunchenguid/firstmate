---
name: fleet
description: Render the read-only fleet board and open it for the captain. Use when the captain invokes /fleet or asks to see the fleet board, the whole fleet, or all in-flight work at a glance.
user-invocable: true
---

# fleet

Show the captain the whole fleet as one dark, clickable HTML board.
The board is read-only: generating it never mutates task, state, or data files.

## Steps

1. Generate the board with `bin/fm-fleet-board.sh`.
   It is a fast read-only pass over existing state; it prints the output path (default `$FM_HOME/.lavish/fleet-board.html`) on stdout, so capture that path.
   Add `--live` only when the captain wants each in-flight task's state reconciled against its run-step, which is a slower per-task probe; the default reads the cheap latest-status signal.
   See the script's `--help` for the flags and data sources; do not restate them here.
2. If `lavish-axi` is on `PATH`, open the board for visual review with `lavish-axi <path>`.
   Otherwise tell the captain the board is ready and give them the file path to open in a browser.
3. Keep the reply in captain-facing outcome language: this is the fleet at a glance, not a description of the machinery that drew it.
