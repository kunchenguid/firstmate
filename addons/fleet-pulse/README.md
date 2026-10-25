# fleet-pulse
- `install.sh [--dry-run] <home>` installs `chat-tsv.py`; when `state/fleet-pulse.check.sh` still globs only `data/fm-retro-*/report.md` under the main home, it retargets that wake to `bin/fleet-retro-due.sh`.
- `bin/newest-retro-report.sh <main-home>` prints the newest `data/*retro*/report.md` across the main home, homes listed in `data/secondmates.md`, and sibling `~/.treehouse/firstmate-*/*/firstmate` homes, by mtime (override the treehouse root with `FM_TREEHOUSE`).
- `bin/fleet-retro-due.sh <main-home>` wakes once when that newest report is missing or at least 60 h old (at most every 12 h via `state/.fleet-retro.last`); the pulse check calls it so a retro that ran in another home stops the early ask.
- Retro refreshes current redacted captain chat with `FM_HOME=<main home> <addons>/fleet-pulse/bin/chat-tsv-refresh.sh`, appending only new rows to private `<main home>/data/chat.tsv`.
- Set `CHAT_TSV_TRANSCRIPTS` to override the Claude projects directory; the refresh refuses to run without `FM_HOME`, and the extractor refuses to write unless Git confirms `data/chat.tsv` is ignored.
- Rows contain UTC ISO-8601 `at`, session-cwd-basename `work` (or `main` for the home checkout/missing cwd), and flattened `text`; metadata, sidechains, tool results, commands, reminders, injected wake text, XML wrappers, mirrors, summaries, and artifact wrappers are filtered while human text outside wrappers is retained.
- Every drop and truncation reason is counted on stderr without message text; secrets/codes are redacted and text is capped at 4000 characters with `[truncated]`.
- The output and sidecar are mode 600, the data directory is mode 700, and `uninstall.sh <home>` removes only the installed script.
## Check
- `bash tests/newest-retro.test.sh` covers newest-across-homes, older-main/newer-sibling not due, none or all-old due, wake-mark suppression, and non-`*retro*` dirs ignored, with disposable fixture homes.
- `bash tests/chat-tsv.test.sh` covers wrapper filtering, mixed human text, audit counts, redaction, truncation, permissions, idempotency, and incremental refresh with disposable fixtures.
- `bash tests/gate-audit.test.sh` covers pass/card ordering, later failure, card-only/missing rows, and number-only matching.
- `bin/gate-audit.sh <checks-gate.log> <pr-url>...` prints each URL with `pass` only when its latest non-card row says pass; otherwise it prints `bypass`.
