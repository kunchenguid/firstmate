# Pi system-health indicator

The project-local Pi extension adds a compact system-health status beside Pi's built-in footer information.
It uses `ctx.ui.setStatus()` with the unique key `firstmate-system-health`, so Pi's token, context, model, and other extension status displays remain intact.

The status reports `RAM <percent> free` from Node's OS-reported free-to-total memory ratio and sampled aggregate `CPU <percent>` utilization.
The RAM value is explicitly free memory, not macOS memory pressure, because Node's portable `os.freemem()` value does not provide that pressure classification.
The CPU value is calculated from deltas between `os.cpus()` time snapshots rather than from a load-average label.
Swap is intentionally omitted because this extension does not have a compact, truthful, cross-platform swap source without adding subprocess or filesystem work.

Sampling starts at `session_start`, refreshes every three seconds, and is cleared at `session_shutdown`.
The startup path clears an existing timer before creating one, so reload and in-process session replacement do not accumulate samplers.
The extension performs no network access, telemetry persistence, Herdr configuration, supervision work, subprocess execution, or filesystem scan.

Use `/system-health` to report the latest values.
Use `/system-health toggle`, `/system-health on`, or `/system-health off` to control the status display for the current Pi extension lifetime.
Unavailable sources are omitted from both the status and the command report instead of being represented as invented values.
Semantic `muted`, `warning`, and `error` tones use Pi's active theme palette, which keeps the default Rose Pine Moon presentation calm until a threshold is crossed.

Regression entry points:

```sh
tests/fm-pi-system-health.test.sh
tests/fm-pi-primary-types.test.sh
bin/fm-doc-audience-check.sh
```
