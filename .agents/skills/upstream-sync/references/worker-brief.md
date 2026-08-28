# Worker brief template

Firstmate scaffolds with `bin/fm-brief.sh <task-id> firstmate --mode no-mistakes`, adding `--herdr-lab` when the tier is `monthly` or the sync is already known to touch Herdr backend or lab code, and replaces `{TASK}` with the block below.
Fill exactly eight values; every other line is fixed text.

| Placeholder | Value |
| --- | --- |
| `UPSTREAM_BASE` | `git rev-parse --short=12 upstream/main` at intake |
| `SNAPSHOT` | short hash of the latest `chore: snapshot upstream main` first-parent commit on `origin/main`, or the window end commit when a catch-up log row names an older one; take it from the skill's intake command block, not by hand |
| `SETTLED` | window end commit from the newest catch-up log row, empty when no row names one; the worker cannot re-derive it after branching at `upstream/main` |
| `VERDICT_INPUT_1`, `VERDICT_INPUT_2`, `VERDICT_INPUT_3` | the three behavior entries, one per placeholder in the "Verdict-table inputs" section, copied by the dispatcher from backlog item `upstream-sync-20260829-verdict-inputs` |
| `TIER` | `weekly` or `monthly`, from the skill's tier rule |
| `DATE` | the sync date, `YYYY-MM-DD` |

```markdown
## Task: {TIER} upstream sync of withally/firstmate onto kunchenguid/firstmate

This is SHARED TRACKED firstmate material: load `firstmate-coding-guidelines` before editing anything.
Then load `upstream-sync` and follow its "Worker checklist" step by step; it owns every command.
`docs/upstream-sync.md` owns the rules those commands implement.

Recorded values:

- UPSTREAM_BASE: `{UPSTREAM_BASE}`
- SNAPSHOT: `{SNAPSHOT}`
- SETTLED: `{SETTLED}`
- VERDICT_INPUT_1, VERDICT_INPUT_2, VERDICT_INPUT_3: see the "Verdict-table inputs" section below.
- TIER: `{TIER}`
- DATE: `{DATE}`

## Verdict-table inputs

The dispatcher copied these three shortlisted behaviors from backlog item `upstream-sync-20260829-verdict-inputs`.
Evaluate each input against current upstream under the doc's keep rule during the audit, and carry the result into the relevant PR verdict evidence.
If an input has no matching audited fork PR, record that fact and the resulting keep-rule disposition in `Follow-ups` rather than silently omitting it.

- `{VERDICT_INPUT_1}`
- `{VERDICT_INPUT_2}`
- `{VERDICT_INPUT_3}`

Fixed rules:

- Bind UPSTREAM_BASE, SNAPSHOT, and SETTLED as shell variables from the recorded values above before running any checklist command, and stop if UPSTREAM_BASE or SNAPSHOT is empty.
- Evaluate all three verdict-table inputs against current upstream with the doc's keep rule, and account for each in the relevant verdict evidence or in `Follow-ups` when no audited PR carries it.
- Branch at UPSTREAM_BASE; never merge origin/main into it.
- Audit only the first-parent commits in SNAPSHOT..WINDOW_END, where the skill's step 4 pins WINDOW_END from `origin/main` at listing time; never re-read `origin/main` for it later.
- Decide every keep by the doc's keep rule yourself; no mid-flight approval.
- Cherry-pick kept PRs with `-x`; upstream wins every conflict.
- Run only the TIER's validation from the skill; CI's portable shards and its required Herdr lane on the PR are the weekly full gate.
- Append the catch-up log row before shipping, recording that pinned WINDOW_END as the row's `Window end commit`, and commit it with `git add docs/upstream-sync.md && git commit -m 'docs: record the {DATE} catch-up'`, advancing the `Next monthly full run` line on a monthly tier; a row that is uncommitted or added after the PR is open is never validated and never reaches `origin/main`.
- Ship the PR with `no-mistakes axi run --skip rebase --intent "{TIER} upstream sync of withally/firstmate onto kunchenguid/firstmate at {UPSTREAM_BASE}"`; `--intent` is required to start a run, and a cutover branch is cut from `upstream/main`, so rebasing it onto the fork's `origin/main` would replay the divergent fork history back onto the new base and undo the adoption.
- Unrelated breakage is a `Follow-ups` entry in the PR, never a fix on this branch.
- If the kept diff selects the `real-herdr-gated` family per the skill's `comm -12` check against `bin/fm-test-run.sh --list`, and this brief was not scaffolded with `--herdr-lab`, stop with `blocked: sync touches Herdr, brief needs --herdr-lab` and wait.
- If that check selects the family and this brief does carry the lab contract, run the family locally per the skill's step 10; do not block a second time.
- PR title: `chore: snapshot upstream main for {DATE}`; PR body carries the verdict table, `Tier: {TIER}`, the validation commands run, and `Follow-ups`.
- Never push to `upstream`; never merge.
```
