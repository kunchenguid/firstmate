# Claude accounts: refresh timer

## User outcome

The Claude accounts card and `state/claude-accounts.json` refresh every 5 minutes without anyone running the reader.

## Drive

Run `bash claude-accounts/tests/claude-accounts-timer.test.sh` (throwaway HOME and XDG paths, stub systemctl), or `done-done run claude-accounts-timer`, which also has systemd-analyze verify the generated units. Never install the timer on the host from a branch.

## Evidence

Capture `timer.txt`.
