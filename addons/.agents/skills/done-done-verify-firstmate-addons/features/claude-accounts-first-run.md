# Claude account first-run check

## User outcome

A newly added Claude account in the pool starts both headless and as an interactive worker without a first-run gate, so the pool can send it work; a real consent or login screen, if one ever shows, is reported to the lead and never accepted by a tool.

## Drive

Pick the account's profile folder from `claude-accounts-pick status <id> --json`. Headless: `claude auth status` (exit status only) and one tool-less `claude -p --model claude-haiku-5-5` turn with that folder as `CLAUDE_CONFIG_DIR`, in a fresh folder under `/tmp`. Interactive: in a guarded Herdr lab home under `/tmp` with this checkout's `claude-accounts` installed, spawn a Haiku worker, relaunch it with `--account <id>`, and record every distinct screen until it replies. Keep the lab outside any Firstmate home: a parent `CLAUDE.md` that imports files outside the folder raises Claude's "Allow external CLAUDE.md file imports?" dialog, which belongs to the folder, not the account. Send no key to any prompt.

## Evidence

Keep the headless answer, every recorded screen, the lines that look like a trust, consent, login, theme, import or terms prompt (or the statement that none showed), and the worker's reply. Workspace trust for the worker's own folder is written by the normal spawn path; any other gate goes to the lead with the exact screen text.
