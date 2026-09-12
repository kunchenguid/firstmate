# Prime Agent

This slice registers Prime Agent as a distinct Pi-family harness and covers detection, crewmate/scout launch, and control mechanics.
Herdr pane classification and detached-daemon-session retirement land in the following adapter slices; primary supervision does too, so a secondmate launch is refused here.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
The launch-boundary marker `FM_PI_HARNESS=prime-agent` is what disambiguates it when paired with the Pi-family marker, the same Firstmate-owned mechanism `FM_PI_HARNESS=pi-signed` uses for the signed wrapper.
Prime Agent's own `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1` are session-wide inherited values and are deliberately not detection evidence: an unmarked Prime Agent session stays Pi-family.
`../../../bin/fm-harness.sh` checks the Prime Agent marker before `CLAUDECODE` and the unmarked Pi result, and after the cursor, gemini, rovo, and omp marker arms.
Those four therefore keep their identity when one of them is started by hand inside a Prime Agent session.
grok is deliberately not among them: `GROK_AGENT=1` is already tested after the unmarked Pi result, so a grok session started inside any Pi-family session has always resolved to that family, and reordering it belongs outside this slice.
An explicit `FM_PI_HARNESS=pi` or `FM_PI_HARNESS=pi-signed` is therefore what a Pi or Pi-signed session carries, and neither is ever relabelled.
The marker without `PI_CODING_AGENT=true` is ignored, so it cannot relabel a Claude or unrelated process.
The marker can itself leak into a Claude pane of the same session, so when `CLAUDECODE=1` is present it is a precedence override rather than evidence, the same boundary `FM_OMP_HARNESS=omp` uses: the verdict is `prime-agent` only when a `prime-agent` process sits within eight parents, and otherwise falls through to `claude`.
With `CLAUDECODE` absent the marker stands alone and no ancestry is required.
Prime Agent does not clear the foreign markers it inherits either, so a prime-agent launch clears `CLAUDECODE` and `GROK_AGENT` in its own template and rides the shared launch prefix that clears `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, and `GEMINI_CLI`, which is what keeps a prime-agent worker started under a cursor or gemini primary from resolving as that primary.

Detection was verified against Prime Agent 0.9.1 on Linux, with earlier checks against 0.7.1 and 0.7.2.

## Launch and control

`../../../bin/fm-spawn.sh` launches a prime-agent crewmate or scout on the same single-positional brief and `-e` extension shape as Pi, establishing `FM_PI_HARNESS=prime-agent` so the worker identifies itself, passing `--model` and `--thinking`, and writing the turn-end notification extension to `state/<task-id>.prime-ext.ts` outside the worktree.
`../../../bin/fm-teardown.sh` removes that extension with the rest of a task's wiring, and `fm_control_harness_wiring_paths` lists it so a relaunch onto another harness retires it.
Control mechanics are Pi's, verified on Prime Agent 0.9.1: a single `Escape` cancels a turn, the composer is left empty afterwards so no clear key is needed, and `/quit` exits.
`../../../bin/fm-spawn.sh --help` owns the executable-preflight mechanics: a missing `prime-agent` executable on PATH refuses before endpoint or metadata creation.

## Scope of this slice

Detection keys on the explicit `FM_PI_HARNESS=prime-agent` launch marker only, so a firstmate-launched worker identifies itself while a Prime Agent PRIMARY still resolves as Pi-family exactly as it did before.
Ambient auto-detection of that primary, and a prime-agent secondmate, arrive with the supervision slices that give the value a supervision model, a supervision snippet, and the primary supervision extensions; a secondmate spawn is refused here rather than launched unsupervised.
