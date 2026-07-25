# Harness build-stamp drift verification

Audience: maintainer verification.

This record supports the current guarantee that a documented harness fact cannot silently expire.
Every fact in the `harness-adapters` skill was established by one manual observation against one build, and nothing used to compare those stamps to the installed runtimes.
`bin/fm-harness-drift.sh` is that comparison; its header owns the exact flags and line formats, and `.agents/skills/bootstrap-diagnostics/SKILL.md` owns the response to a reported line.
Task chronology and delivery transcripts stay in private reports or PR evidence.

## Mechanism

The recorded stamps live in one fenced `fm-harness-builds` block in `.agents/skills/harness-adapters/SKILL.md`, one `<harness> <version>` line each.
That block is the single owner of the newest build each harness section's facts were checked against; the dated stamps inside the surrounding prose are historical observation records, not the compared value.
The check parses that block, probes each harness with a bounded `<harness> --version`, and takes the first dotted version token of the output.

It distinguishes three per-harness outcomes: the stamp equals the installed build (silent), the stamp differs in either direction (drift), and the harness is absent (drift).
A stamp ahead of the installed build is drift, not a match, because it describes a build nobody is running.
The check is detect-only: it never edits the skill, never installs anything, and always exits 0, so drift never blocks a session.
`bin/fm-bootstrap.sh` runs it among the read-only detect checks, so it also runs in a lock-refused detect-only session.

## Verified on 2026-07-25

Installed builds, from the harness binaries on PATH:

```sh
for h in claude codex opencode pi grok; do
  printf '%s: ' "$h"
  command -v "$h" >/dev/null 2>&1 && "$h" --version 2>&1 | head -1 || echo "NOT INSTALLED"
done
```

Exact output:

```
claude: 2.1.220 (Claude Code)
codex: codex-cli 0.145.0
opencode: 1.18.3
pi: NOT INSTALLED
grok: grok 0.2.112 (9bbd559437aa) [stable]
```

Recorded stamps at the time of this record:

```sh
bin/fm-harness-drift.sh --stamps
```

Exact output:

```
claude 2.1.219
codex 0.144.4
grok 0.2.103
opencode 1.18.4
pi 0.80.6
```

Drift report:

```sh
bin/fm-harness-drift.sh
```

Exact output:

```
HARNESS_DRIFT: claude recorded 2.1.219, installed 2.1.220
HARNESS_DRIFT: codex recorded 0.144.4, installed 0.145.0
HARNESS_DRIFT: grok recorded 0.2.103, installed 0.2.112
HARNESS_DRIFT: opencode recorded 1.18.4, installed 1.18.3
HARNESS_DRIFT: pi recorded 0.80.6, not installed here
```

All five verified harnesses had drifted when the check was introduced, which is why the mechanism matters more than any single stale fact.
The opencode line shows the doc-ahead direction, and the pi line shows the absent case.
The silent case is covered by `tests/fm-harness-drift.test.sh`, which also pins the version-parsing shapes above, the malformed and missing stamp-source reports, and the read-only property.

## Known limit

The check compares build identity, not fact validity.
A harness can update without changing any documented fact, so a drift line means "re-verify before relying on this", never "this fact is wrong".
Clearing a line requires re-verifying that harness's facts and re-stamping its line in the skill; the check deliberately cannot do that itself.
