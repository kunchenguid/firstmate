# Totmann resume-chooser wording verification

Audience: maintainer verification.

This record supports the summary-vs-full resume chooser markers owned by `bin/fm-totmann-relaunch-lib.sh` (half 2b).
The chooser appears after a `--continue` relaunch onto a large session and is answered by the dead-man with the default, so its vocabulary must match a measured rendering, never a guess.

## Wording source

Measured on 2026-08-26 from the installed Claude Code bundle version 2.1.246 (`/home/fridjof/.local/share/claude/versions/2.1.246`).
The same dialog was observed live in `firstmate:0` on 2026-08-26 during a dead-man revival; the journal entry under `data/umbau-2026-08/journal.md` records the 9h44m / 540k variant and that plain Enter selected "Resume from summary".

Extraction command:

```sh
strings -n 8 /home/fridjof/.local/share/claude/versions/2.1.246 | grep -E 'Resume from summary|Resuming the full session'
```

Observed strings (verbatim):

- `This session is ${...} old and ${...} tokens.` - the chooser title line; the live observation rendered it as "This session is 9h44m old and 540k tokens."
- `Resuming the full session will consume a substantial portion of your usage limits. We recommend resuming from a summary.` - the question body.
- `Resume from summary (recommended)` - option 1, value `compact`, highlighted first.
- `Resume full session as-is` - option 2, value `continue`.
- `Don't ask me again` - option 3, value `never`.

## What the markers pin

`FM_TOTMANN_RESUME_DIALOG_REGEX` defaults to two independent verbatim substrings of that rendering: the question sentence prefix `Resuming the full session will consume` and the option label `Resume from summary`.
No single vendor string is load-bearing.
The numbered "N. label" row shape in the test fixture follows the verified menu rendering documented at `dialog_choice_pending()` in `bin/fm-anstoss.sh`.
Plain Enter selecting the highlighted first option was measured live on 2026-08-26 (journal entry above).

## Refresh

Re-run the extraction command against the then-installed version and compare against the regex default and the fixture in `tests/fm-totmann-relaunch.test.sh` section 6.
A changed rendering is fixed in both places together.
