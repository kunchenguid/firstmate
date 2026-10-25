# Relaunch onto the next pool account

## User outcome

`bin/fm-control.sh <task> relaunch --account next` moves a Claude worker off its current pool account to another `pa_` account, rests the old one only when a fresh reading puts it at or below 15%, and the new launch carries the account's own login folder and no API key or token, so a move can never spend extra credits.

## Drive

In a guarded Herdr lab home under `/tmp` with this checkout's `claude-accounts` installed and a real account at or below 15%: spawn a Haiku worker, relaunch it with `--account <that account>`, then run `relaunch --account next`. While the moved worker runs, read its launch file (`/tmp/fm-<task>+*/launch.*.sh`): the `env -u ... CLAUDE_CONFIG_DIR=<folder>` line must name the new account's registry folder and remove `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`. Record variable names only, never values. Send no key to the worker: Claude's limit screen offers `/usage-credits`, which a tool must never accept.

## Evidence

Keep the account before and after, the rest marker, the moved worker's reply, the removed variable names, whether the folder matched, and any screen that showed an extra-usage offer.
