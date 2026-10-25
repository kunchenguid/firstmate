# host-memory

The per-home host memory sampler lives here, with its existing lifecycle API.
`bin/fm-host-memory-lib.sh` is the optional watcher source entrypoint.
The current fork still uses its own copy until a later fork-side hook lands.
This first slice relocates the sampler only; the admission rule and alert presentation still live in the fork.
Kun's diagnostic guard must remain intact when the admission rule moves: the add-on may add a refusal, never override Kun's refusal.

## Layout

- `bin/fm-host-memory-lib.sh` - watcher source entrypoint, resolving fork dependencies through the watcher's `SCRIPT_DIR`.
- `bin/fm-host-memory-sampler.sh` - the sampler, providing lifecycle functions (`fm_memory_sampler_ensure`,
  `fm_memory_sampler_stop`, `fm_memory_sampler_matches`,
  `fm_memory_sampler_tick`, `fm_memory_sampler_interrupt`,
  `fm_memory_sampler_cleanup`), and executable as
  `run <HOME> <STATE> <CONFIG>` for the one sampler loop per home.
- `bin/fm-mem-gate.sh` — the memory gate for heavy jobs (below); unlike
  the sampler it is live once installed.
- `install.sh` — installs the gate and `fm-heavy-adopt` timer.
- `tests/fm-mem-gate.test.sh` — the gate's integration test.
- `tests/fm-heavy-adopt.test.sh` — fixture-backed mover install, traversal and uninstall test.

## Sampler contract

- CLI: `fm-host-memory-sampler.sh run <HOME> <STATE> <CONFIG>`; any other
  argv exits 2, a missing state directory exits 1, an already-held sampler
  lock exits 0. Sourced, it provides the `fm_memory_sampler_*` functions
  above; the watcher calls `fm_memory_sampler_ensure` to start (or reuse)
  the loop and `fm_memory_sampler_stop` to end it.
- Cadence: one sample every `FM_HOST_MEMORY_SECS` (default 10), each tick
  calling the fork guard as
  `fm-jev-mem-guard.sh --config <CONFIG>/host-memory --record
  <STATE>/host-memory.tsv --owned-top-task <STATE> --state-dir ...`.
  The guard itself stays in the fork and is not moved.
- Verdicts: the guard prints `<verdict>\t<summary>` where verdict is
  `OK`, `WAIT`, `ALERT`, or `UNKNOWN`. `WAIT` and `OK` clear the alert
  latch and record nothing further; only the first `ALERT` of an episode
  wakes (later `ALERT` rows in the same episode are quiet until a
  `WAIT`/`OK` clears the latch).
- Alert: one durable wake `check host-memory` with reason
  `check: host memory ALERT: <summary>; <action>`, one row
  `<epoch>\t<task>\t<reason; action>` in
  `<STATE>/host-memory-interrupts.tsv`, one latch file
  `<STATE>/.host-memory-alerted`, and one owned-task interrupt attempt via
  the sibling control entry beside it (`fm-control.sh <task> interrupt`;
  its output becomes the recorded action). A top consumer this home does
  not own is recorded as skipped, never interrupted.
- State files, all under the home's state directory: `host-memory.tsv`
  (one sample row per tick:
  `<epoch>\t<available kB>\t<swap used kB>\t<sustained pressure>\t<verdict>`,
  read by the fork's dashboard history), `host-memory-interrupts.tsv`
  (`<epoch>\t<task>\t<action>`), `.host-memory-alerted` (the per-episode
  latch), `.host-memory-sampler.pid` (`<pid>\t<process identity>`),
  `.host-memory-sampler.lock`, and `.host-memory-sampler.log`. Config is
  read only as `<CONFIG>/host-memory`; thresholds there are owned by the
  guard and never changed here.

## Relocation and integration proof

Originally copied from `umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf`, the sampler now passes `FM_HOST_MEMORY_FORK_BIN` to its child instead of assuming fork libraries are add-on siblings.
The fork's wake/backend libraries, control CLI, watcher identity and current guard remain the dependency owner.
Existing `fm_memory_sampler_*` names, PID validation, cadence, durable wakes and interrupt behavior are unchanged.
No installer changes are needed for the source entrypoint: the fork hook resolves `${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}`.
An absent checkout skips both sourcing and lifecycle dispatch, leaving no sampler and no errors.
Removing the checkout affects the next watcher; restart an existing watcher to unload already-sourced functions.

Run `bash host-memory/tests/fm-host-memory.test.sh <fork-checkout>` through the host memory gate.
It clones the supplied fork into a private temporary directory, isolates HOME/XDG/TMPDIR, runs the fork's guard and sampler journeys unchanged, then reruns them with the optional sampler seams in that scratch copy only.
The absent-addon leg proves an ordinary custom-check wake works without sampler state or errors.
No live home, service, thresholds or supplied fork files are changed.
Run the CI ShellCheck and syntax steps plus the other `host-memory/tests` scripts too.


## Memory gate

`fm-mem-gate.sh <command...>` waits until the host has room, then starts a command in a user scope in `fm-heavy.slice`; with no command it only waits. Room is `MemAvailable` at least `FM_MEM_MIN_GB` (12) and memory pressure (lower of `some` avg10 and avg60) under 40. An emulator job also waits while `FM_EMU_MAX` (2) emulators run, and a Gradle job while `FM_GRADLE_MAX` (1) builds run; those two checks and the start share one host lock.

The installer deploys `bin/fm-heavy-adopt.sh` and enables a 20-second user timer. It retains the existing memory/process-name rule and also moves a process using more than 2 CPU-seconds during the prior interval, plus its descendants, into the heavy scope. Herdr, no-mistakes and agent CLI processes are excluded; descendant expansion stops at each excluded process, while a CPU-heavy child can still move on its own. The threshold is below the 14-30 CPU-seconds measured per worker in the bounded 64-worker reproduction, which drove Herdr run-delay to 54-121 ms/s and CPU PSI `some avg10` to 66%; the integration test uses fixture proc/cgroup trees. Main must replace `firstmate/config/fm-heavy-adopt.sh` with a shim to the installed copy or update the unit's `ExecStart` to `${XDG_DATA_HOME:-$HOME/.local/share}/fm-host-memory/fm-heavy-adopt.sh`.

The installer gives `fm.slice` and `fm-heavy.slice` CPUWeight=20 with user drop-ins, so heavy scopes are weighted against sibling `app.slice`.
IOWeight=20 only works when the user manager delegates `io`; this host delegates no `io` controller and its NVMe uses the `none` scheduler.

The emulator and Gradle caps look past known wrappers to the real program:
`timeout`, `flock` (including `flock <lock> -c <string>`), `nice`,
`ionice`, `env`, `exec`, `NAME=VALUE`, and `bash -c` / `sh -c` (the first
word of the string), so `flock L timeout 60 bash -c "emulator ..."` is
held at the emulator cap. Any other first word is the program, as before.
Not seen: emulators the no-mistakes daemon boots for its test steps, which
never pass through this gate.

Moved from Main's `config/fm-mem-gate.sh` (sha256 `4dd4531e...b682`, its
test `5feb7ddf...2e04`) in the first commit, then changed. Install with
`host-memory/install.sh [--dry-run]`: it copies the gate to
`${XDG_DATA_HOME:-~/.local/share}/fm-host-memory/fm-mem-gate.sh`, is
idempotent, and `--dry-run` writes nothing. Main's `config/fm-mem-gate.sh`
then becomes a one-line shim that execs that copy:

```sh
#!/usr/bin/env bash
exec "${XDG_DATA_HOME:-$HOME/.local/share}/fm-host-memory/fm-mem-gate.sh" "$@"
```

Test: `host-memory/tests/fm-mem-gate.test.sh [gate]` runs the gate with
stub `emulator`, `gradlew`, `pgrep` and `systemd-run`, fixture memory
files (`FM_MEM_GATE_PROC`) and private lock dirs, and checks that a waiting
emulator job does not hold the lock, that wrapped emulator and Gradle jobs
are held at their caps, and that a wrapped emulator starts with a free slot.
