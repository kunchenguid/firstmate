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
   It prints the output path (default `$FM_HOME/.lavish/fleet-board.html`) on stdout; capture that path.
   See the script's `--help` for the `--out` flag and its data sources; do not restate them here.
2. If `lavish-axi` is on `PATH`, open the board for visual review with `lavish-axi <path>`.
   Otherwise tell the captain the board is ready and give them the file path to open in a browser.
3. Keep the reply in captain-facing outcome language: this is the fleet at a glance, not a description of the machinery that drew it.
