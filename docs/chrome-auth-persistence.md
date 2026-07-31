# Persistent Chrome login for SSO-gated browser work

Crewmate browser work runs headless and autonomous by default: `chrome-devtools-axi` launches an isolated, throwaway Chrome profile, so it has no session to reuse against an app behind Keycloak or another SSO provider.
Without a persisted profile, every fresh launch lands on the login page with no way to authenticate, which would require the captain to log in interactively for every single check.

This convention gives crewmates a persistent profile directory that already carries a completed interactive login, so a later headless launch against the same directory reuses the saved session cookies until the SSO session itself expires.

## Profile path

The fixed profile directory is `$FM_ROOT/data/chrome-profile`.
`data/` is already gitignored as a whole, so this needs no separate ignore entry and no `config/` override.

## One-time captain setup

Run `bin/fm-chrome-login.sh [start-url]`.
It launches `chrome-devtools-axi` headed with `CHROME_DEVTOOLS_AXI_USER_DATA_DIR` set to the profile path above, opening `start-url` when given.
Complete the login interactively in the opened window, then close it (or run `chrome-devtools-axi stop`).
This is captain-run only: a crewmate never performs this login itself.

## How crewmates consume it

A crewmate doing browser or visual work exports `CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$FM_ROOT/data/chrome-profile"` before invoking `chrome-devtools-axi`, so its launch reuses the persisted session (see `bin/fm-brief.sh`'s browser-work rule, the single owner of that instruction text).
If a crewmate still lands on a login page, the persisted session has expired or was never established.
It must not attempt to authenticate itself: it appends `blocked: {app} needs a fresh manual login via bin/fm-chrome-login.sh` to its status file and stops, per the standard `blocked:` protocol, so firstmate can relay the need for a fresh captain login.

## Known limitation: concurrency

A single Chrome process can hold one `--user-data-dir` at a time.
Two crewmates doing browser work concurrently against the same profile directory will collide.
This is a known limitation; no concurrency handling is built for it.
If concurrent SSO-gated browser work becomes routine, consider giving each concurrent lane its own profile directory (each logged in once via `bin/fm-chrome-login.sh`) rather than building coordination around a single shared directory.

## Expiry

The SSO session eventually lapses, and a crewmate will hit the login-page case above.
The fix is simply re-running `bin/fm-chrome-login.sh`; there is no separate expiry-detection or refresh mechanism.
