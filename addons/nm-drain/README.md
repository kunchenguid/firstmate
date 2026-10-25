# nm-drain

A planned drain for updating the shared pipeline service that every lane uses.
Main starts the drain and tells the leads to start no new pipeline run.
A watcher check asks Main for go once no run is active, and caps the drain at 60 minutes.
Main then says go, and the update runs without forcing a restart over live runs.
It replaces three overlapping one-shot checks (`nm-quiet`, `nm-update` and `nm-upgrade`).

## Use

`nm-drain.sh <command> <fm-home>`, run by Main:

- `start` records the drain start in `<fm-home>/state/.nm-drain`.
- `status` prints the drain, the installed no-mistakes version and target, and each active run with its current step.
  It is read-only.
- `go` refuses while any run is active.
  Otherwise it runs `no-mistakes update -y`, verifies the new version, and confirms that the daemon restarted onto it.
  If the update left the old daemon running, `go` runs `no-mistakes daemon restart`, whose own guard refuses while a run is active.
  It never passes `--force`.
  It also refuses when the cached latest release is not the approved target (`NM_DRAIN_TARGET`, default `v1.84.0`).
  It logs to `<fm-home>/state/.nm-drain.log`.
- `stop` ends the drain.
- `check` is the watcher check.
  With no drain it prints nothing.
  It prints one line asking for go the first time the active count is 0.
  After 60 minutes with no go (`NM_DRAIN_CAP_SECS`), it prints one line and clears the drain.

A run counts as active when its status is `pending` or `running`, which is exactly what `no-mistakes update` refuses on.
That includes a run that only monitors its PR and CI after the push.
A daemon restart would only mark such a run `ci_monitor_interrupted` and leave its PR open, but the update still refuses on it without `--force`, and `--force` needs you.
`status` shows how many active runs are only in PR/CI monitoring.
The state database is read only from a backup copy, which is deleted right after.

## Install

`nm-drain/install.sh [--dry-run] <main-fm-home>` copies `nm-drain.sh` to `${XDG_DATA_HOME:-~/.local/share}/fm-nm-drain/`.
It writes the shim `state/0-nm-drain.check.sh`, registers it with `bin/fm-check-register.sh`, and retires the three old checks with `bin/fm-check-unregister.sh`.
`--dry-run` prints those steps and writes nothing.
The `0-` id sorts the check first, because a check that wakes ends the watcher's sweep, so a check that wakes on every sweep starves every check after it.

## Test

`nm-drain/tests/nm-drain.test.sh` drives the CLI, the check and `install.sh` end to end, both as `--dry-run` and as a real install that must register and retire the old checks even with `FM_STATE_OVERRIDE` exported empty.
It uses a throwaway home, HOME and state database, with a fake `no-mistakes` first on `PATH` that records every call and fails on `--force`.
