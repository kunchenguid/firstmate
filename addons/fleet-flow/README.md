# fleet-flow

The read-only fleet flow reader — the lifecycle, queue, bottleneck and capacity
JSON reader the dashboard consumes as its `fm-flow.v1` observation — moved out
of the Firstmate fork into this add-on repository. The fork's `bin/fm-flow.sh`
is a thin shim that resolves this checkout (`FM_ADDONS_DIR`, default
`$FM_HOME/projects/firstmate-addons`) and execs `fleet-flow/bin/fm-flow.sh`
with `FM_BIN` pointing at the fork's `bin/`; the served dashboard reaches the
reader only through that shim.

## Layout

- `bin/fm-flow.sh` — the `--json` reader: FM_HOME plus recursively registered
  local homes in, one `fm-flow.v1` document out; no endpoint or cache writes.
- `tests/fm-flow.test.sh` — the integration test for that reader over isolated
  durable records; run it with `FM_BIN` pointing at a Firstmate checkout's
  `bin/` (it prints one PASS line for the reader and one for the fork's
  model/skill statistics and outcome-recording readers).
- `bin/fm-flow-check.sh` — the home flow check (below); live once installed.
- `install.sh` — installs the flow check.
- `tests/fm-flow-check.test.sh` — the flow check's integration test.

The reader sources `fm-classify-lib.sh`, `fm-tasks-axi-lib.sh` and
`fm-backlog-transition-lib.sh` from `${FM_BIN:-its own directory}` and runs
the home-addressed `fm-tasks-axi.sh` backlog consumer from the same directory;
those fork files did not move, so a Firstmate checkout copy needs nothing and
this copy runs only with `FM_BIN` naming such a `bin/` (the fork shim always
sets it).

## Home flow check: lane slots and dry

`bin/fm-flow-check.sh <home> [--can-start|--target|--summary]` is the home flow check every lead's `state/flow.check.sh` runs, and it owns the open-lane count against `config/lane-caps` that the `--can-start` hard cap, the over-cap line and the fleet-pulse row share.
A lane whose last status event is `paused`, `blocked` or `failed`, stamped `[at=]` more than 4 h ago, not waiting on you, and still read as that wait by `bin/fm-crew-state.sh`, keeps its worktree and record but stops counting toward the cap, so a ready item takes its slot.
Validating and own busy work read as working there and keep counting; an unstamped wait, or a state that cannot be read within 15 s, keeps counting.
Only those long-wait candidates are probed, in parallel.
`--summary` appends `counted` (open lanes that count) and `dry` (1 when ready = 0 and working < cap) to its row.
A lane whose last event is `parked` leaves the open count and the cap.
`parked [key=lane-cap]` is ready work with its branch kept: `--summary` counts it in `ready`, and `--resume` prints the oldest ones, one per free slot, for the watcher to restart with no steer; `--can-start` sends a free slot to them first.
Any other park names `(resume-on: YYYY-MM-DD | PR URL | captain)`; without it the pulse shows `stalled` and `--summary` counts it in its last column (after `parked`).
`FM_MAIN_HOME` names the main home (default `~/firstmate`).

Moved from Main's `config/fm-flow-check.sh` (sha256 `6e353c9e...4ed2`) in the first commit, then changed.
Install with `fleet-flow/install.sh [--dry-run]`: it copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-fleet-flow/fm-flow-check.sh`, is idempotent, and `--dry-run` writes nothing.
Main's `config/fm-flow-check.sh` then becomes a symlink to that copy, not an exec shim, because `bin/fm-flow.sh` reads its stage-clock policy from that file's text.
Test: `tests/fm-flow-check.test.sh` drives the real check over a fixture Main home and one lead home with stub `fm-tasks-axi.sh` and `fm-crew-state.sh`.

## Install (operator, after merge)

The firstmate-addons lead performs these steps from a checkout of merged `main`; the add-on never writes Main's config.

1. `fleet-flow/install.sh --dry-run`, then `fleet-flow/install.sh` — copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-fleet-flow/fm-flow-check.sh`.
2. `cmp fleet-flow/bin/fm-flow-check.sh "${XDG_DATA_HOME:-~/.local/share}/fm-fleet-flow/fm-flow-check.sh"` — must print nothing.
3. `mv $FM_MAIN_HOME/config/fm-flow-check.sh $FM_MAIN_HOME/config/.bak-$(date +%Y%m%d)-slots` and `ln -s "${XDG_DATA_HOME:-~/.local/share}/fm-fleet-flow/fm-flow-check.sh" $FM_MAIN_HOME/config/fm-flow-check.sh`.

The symlink is deliberate, not an exec shim: `bin/fm-flow.sh` reads its stage-clock policy from that file's text.

## Frozen contract (identical to the fork)

- CLI: `FM_HOME=<home> fm-flow.sh --json [--now <unix-seconds>] [--checks]
  [--capacity]`; every other invocation prints the usage line and exits 2.
- Output: one `fm-flow.v1` document with `homes`, `lanes`, `queue`,
  `bottlenecks`, `capacity` (null unless `--capacity`), `executed_24h`,
  `executed_7d`, `time_to_merge` (median, nearest-rank P85),
  `time_to_merge_by_home`, `trend_7d`, `trend_7d_by_home` and `limitations`;
  `at` carries the effective now.
- Open lanes include their recorded `kind`, `project`, in-flight backlog
  `hold_kind` / `hold_reason`, and a `parked_reason` only when the matching
  project appears in a captain-shared park, pause, starvation or soft-pause
  note.
- An in-flight captain or external backlog hold contributes an `open_waits`
  entry with unknown age; no timestamp is inferred from backlog prose.
- Read-only: no endpoint or cache writes. Missing or unavailable probes yield
  null with a limitation, never a fabricated zero; live capacity observations
  carry their own timestamp, independent of `--now`.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time:

| moved file | sha256 at the fork commit | sha256 here |
| --- | --- | --- |
| `bin/fm-flow.sh` | `fa7ef5bf41d759b483393bccd7bc867daeb13111c87dd7c444ef66bd6a8ba4f1` | `fa7ef5bf41d759b483393bccd7bc867daeb13111c87dd7c444ef66bd6a8ba4f1` |
| `tests/fm-flow.test.sh` | `a0fdc3349fa899c9b12897797d2051187b1e321db70e8e136be6f7bd38e9e93d` | `a0fdc3349fa899c9b12897797d2051187b1e321db70e8e136be6f7bd38e9e93d` |

Treat any future diff against the fork file as a contract change, not a
refactor.

Contract change since the move (mem-gate-wrappers): the capacity
census reads the gate policy from the installed gate
`${XDG_DATA_HOME:-~/.local/share}/fm-host-memory/fm-mem-gate.sh` when it
exists (Main's `config/fm-mem-gate.sh` is then a one-line shim to it), else
from `config/fm-mem-gate.sh` as before, and `gate_source` names the file it
read.

Contract change (approval audit D16): the capacity pressure is the memory
gate's own sustained reading, the lower of `some` avg10 and avg60, under
`memory_pressure_percent`; it replaces the raw `memory_some_avg10_percent`,
which counted 10-30 s spikes the gate lets pass.

Contract change at the shim swap: the reader takes `FM_BIN` for the fork
helper libraries and the fork copy became the shim, so this repository now
holds the only reader.

## Proofs

At move time the fork copy and this copy were run side by side on synthesized
fixture homes with a frozen clock and redirected `/proc`, `/tmp` and PATH
stubs, and their `fm-flow.v1` JSON diffed byte for byte; the harness lived
with that task's evidence and ended `ALL CHECKS PASSED`.

At the shim swap the moved integration test ran against this checkout with
`FM_BIN` naming a Firstmate `bin/` and printed both PASS lines, and the fork
shim was proven live: `FM_HOME=<Main home> bin/fm-flow.sh --json --capacity`
through the shim reported the real installed memory/emulator/Gradle limits,
not unknown.

CI note: `.github/workflows/addons-ci.yml` ShellChecks and syntax-checks the
shell scripts in an add-on's top level and its `bin/` and `tests/`
subdirectories, so both moved files are covered; they passed at move time
with no exclusion.
