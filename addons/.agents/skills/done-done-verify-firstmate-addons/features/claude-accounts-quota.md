# Claude accounts quota view

## User outcome

Every Claude account signed in on this machine shows how many workers are on it and its 5-hour and 7-day quota left on the dashboard, and `state/claude-accounts.json` carries the same numbers for dispatch. Two logins with the same profile name are told apart by an ordinal ("default 2"), never by an id.

## Drive

Run `bash claude-accounts/tests/claude-accounts.test.sh` from the repository root. It reads a fixture muxr registry through a stub quota-axi and proves both windows per account, a failing account's recorded cause, active rest expiry and its removal at 100/100 headroom, and that no secret field reaches the file. For the card, run `FM_HOME=<throwaway home> claude-accounts/bin/claude-accounts-quota.sh`, build and serve the dashboard with that home and capture the Overview at 390px; `bash fleet-dashboard/tests/run-fork-suite.sh <fork checkout>` covers the card's text, including its visible rest expiry and each account's worker count. For live load, spawn a few Haiku workers in a guarded `/tmp` lab home, then build and serve the dashboard from that home one copy at a time (the build output folder is shared), and capture the Overview card at 390px in light and dark: set the app's own `fm-theme` and load the page again, then check `document.documentElement.dataset.theme` before each shot.

## Evidence

Capture the test output and exit status, and the 390px screenshots in each theme (780x1688 at 2x, the theme the page drew named in the file), in done-done's run evidence directory. Pass only profile folder paths to quota-axi; never open files inside a login folder.
