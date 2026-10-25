# sentinel

The restart-recovery add-on. The sentinel runs outside the agent runtime, so it
survives a runtime restart that kills every agent and watcher in the runtime
server's process tree. It re-arms supervision: it reconciles the home's direct
reports, relaunches a lane that came back outside its recorded worktree, nudges
a lane whose turn was lost, and wakes the primary session.

The sentinel's own code lives here (`bin/fm-sentinel.sh`). It calls the host
tool's scripts and libraries from the home's checkout (`$FM_HOME/bin`) and
copies none of them. After a Herdr restart it also restores a recorded Claude model when a direct
report resumed without its `--model` argument, then checks each registered,
local, unparked lead home with that home's own sentinel state and relaunch tools.

## Layout

- `bin/fm-sentinel.sh` — the sentinel: `tick`, `loop`, `reconcile` and `unit`.
  Its CLI, state files and knobs are documented in its header.
- `install.sh` — copies the sentinel to `${XDG_DATA_HOME:-$HOME/.local/share}/fm-sentinel`
  and points the `fm-sentinel` user unit at that copy for one home.
- `uninstall.sh` — restores the unit to its text from before the first install,
  restarts the service on it, and removes the installed copy.
- `tests/` — see Checks.

## Install

    sentinel/install.sh [--dry-run] <fm-home>

Install is idempotent. It records the unit as it was before the first install
(`unit.before` in the installed copy's folder), and writes a timestamped
`fm-sentinel.service.bak-sentinel-addon-<epoch>` beside the unit whenever a
later install replaces a unit it did not write. It restarts the service in the
same step it rewrites the unit, so the sentinel never stops without starting
again. A rerun with nothing to change prints `already installed` and restarts
nothing. `--dry-run` prints the unit and copy changes and writes nothing.

## Uninstall

    sentinel/uninstall.sh [--dry-run]

Uninstall writes back the pre-install unit, restarts the service on it, and
removes the installed copy, so after install and uninstall the unit is the one
from before. It refuses when no unit existed before install, because a restart
then would have nothing to restore to; the sentinel keeps running until the
owner stops it by hand. Running it again when nothing is installed prints
`not installed`.

## Checks

- `bash sentinel/tests/fm-sentinel-install.test.sh` — hermetic: a throwaway HOME
  and XDG dirs and a stub `systemctl` on `PATH`. The real user manager is never
  read or changed.
- `bash sentinel/tests/fm-sentinel-model-relaunch.test.sh` — fixture-based check
  that only a Claude pane missing its recorded model is relaunched, once per event.

The restart tests (dead relaunch, restart resume, and the live Herdr e2e) are
not in this slice yet; they follow in a second slice.

## Requirements: fork-only hook points

The sentinel targets the Firstmate checkout the homes run today (the fork). It
depends on two hook points that unmodified Kun does not provide:

- `fm-control.sh exit` writes `state/<id>.exit`. The stopped-on-purpose guard
  reads that record; without it a lane exited on purpose can be relaunched after
  a host restart.
- `fm_backend_agent_state` takes four arguments, including the lane's meta and
  task id, which the fork's version uses to classify an unknown Herdr pane.

Running the sentinel on unmodified Kun needs both. Later fork-exit slices own
them.
