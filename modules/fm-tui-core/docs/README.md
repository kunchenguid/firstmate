# fm-tui-core

## Usage

`npm --prefix modules/fm-tui-core run run` runs the dependency-free executable checks on Node 20 or newer.
Import `buffer`, `put`, `sprite`, `ticker`, `plain`, `diff`, `display`, and `terminal` from `src/index.mjs`.
For example: `const view = display(terminal(), { clean: true }); view.draw(buffer(80, 24)); view.close();`.

## Layout

Follow the [shared template](../../TEMPLATE.md): pure cell operations in `src/core`, display orchestration in `src/usecases`, the terminal interface in `src/ports`, stream I/O in `src/adapters`, and colocated tests with an in-memory terminal.
This package imports no application or state-reader code and starts nothing on import.

## Ports

`Terminal` exposes `tty`, `color`, and `write(text)`; the real stream adapter and fake terminal implement the same contract.
`display(port, options)` returns `animated`, `draw(grid)`, and idempotent `close()`; callers own timers and always close on exit.

## Configuration

There is no persistent configuration, state directory, model, or persona in this pure library.
`clean` and `noUi` disable animation even on a TTY; the stream adapter honors `NO_COLOR`, including an empty value.
A non-animated display writes exactly one static frame without escape sequences; later meaningful messages belong to the application's plain-text adapter.

## Limits

Buffers contain `[character, paletteIndex]` cells and reserve the last column against autowrap; viewports are bounded to 300 columns and 1000 rows.
The six-color palette, clipped row-array sprites, and caller-driven ticker need no framework or asset loader.
Sprite rows are trusted source assets using single-cell glyphs; use `clean` for external strings before putting them in a buffer.
`clean` removes terminal controls but does not redact credentials; callers must not pass secrets to the view.
Animated output changes only differing cells, never clears the whole screen, and remembers previous cell values even when a caller reuses a buffer.

## Verification

`bin/fm-test-run.sh tests/fm-modules.test.sh` exercises both shared libraries and their actual process-event composition.
Core tests cover clipping, 24-frame continuity, 100x30/80x24 output and color suppression; fake-backed display tests cover quiet mode, reused buffers, empty-write suppression and exit restoration.
Stream adapter tests check TTY capability and environment handling without depending on vendor-specific terminal output.
