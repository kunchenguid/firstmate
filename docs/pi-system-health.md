# Pi system-health indicator

The project-local Pi extension adds a compact system-health status beside Pi's built-in footer information.
It uses `ctx.ui.setStatus()` with the unique key `firstmate-system-health`, so Pi's token, context, model, and other extension status displays remain intact.

The status reports `RAM <percent> free` and sampled aggregate `CPU <percent>` utilization.

The RAM value is available memory, and its source is platform-specific so that the number stays truthful on the Captain's Mac.
On macOS the extension reads `vm_stat` page counters and reports `(total pages - wired pages - compressor-occupied pages) / total pages`.
macOS treats active, inactive, speculative, and purgeable pages as reclaimable, so counting only wired and compressor-occupied pages as unavailable matches the percentage `memory_pressure` reports, within rounding.
Node's `os.freemem()` is deliberately **not** used on macOS: it counts only wholly unused pages, which reads as a single-digit percentage on an idle Mac that macOS itself reports as roughly two thirds free.
On every other platform `os.freemem()` is truthful and is used directly as the free-to-total ratio.
The value is available memory, not a macOS memory-pressure classification.

The CPU value is calculated from deltas between `os.cpus()` time snapshots rather than from a load-average label.
Swap is intentionally omitted because this extension does not have a compact, truthful, cross-platform swap source.

Sampling starts at `session_start`, refreshes every three seconds, and is cleared at `session_shutdown`.
The startup path clears an existing timer before creating one, so reload and in-process session replacement do not accumulate samplers.
Sampling is asynchronous and its result is cached, so nothing is measured from `render()` or on a repaint.
The macOS `vm_stat` read is the extension's only subprocess: it is invoked without a shell, bounded by a one-second timeout, and never runs more than once at a time.
A sample that resolves after a shutdown or reload is discarded rather than restoring a cleared status.
If `vm_stat` is missing, fails, or times out, the memory metric is omitted instead of falling back to a misleading value.
The extension performs no network access, telemetry persistence, machine-measurement persistence, Herdr configuration, or supervision work.

Use `/system-health` to report the latest values.
Use `/system-health toggle`, `/system-health on`, or `/system-health off` to control the status display for the current Pi extension lifetime.
Unavailable sources are omitted from both the status and the command report instead of being represented as invented values.
Semantic `muted`, `warning`, and `error` tones use Pi's active theme palette, which keeps the default Rose Pine Moon presentation calm until a threshold is crossed.
Thresholds are evaluated against the same rounded percentage that is displayed, so two readings shown as the same number always carry the same colour.

Regression entry points:

```sh
tests/fm-pi-system-health.test.sh
tests/fm-pi-primary-types.test.sh
bin/fm-doc-audience-check.sh
```
