---
name: status-update
description: >-
  Refresh the Modus-Adyen-Client project's status reporting on demand.
  Use when the captain invokes /status-update or asks to refresh, update, or roll the project's
  status, ledger, or daily/weekly report so he can send credible updates to his boss.
user-invocable: true
metadata:
  internal: true
---

# status-update

Refresh `docs/status/ledger.md`, `docs/status/timeline.md`, and the generated reports and exports in the Modus-Adyen-Client project, so the captain can send credible daily and weekly updates without writing them by hand.

## The evidence rule - the whole point of this skill

A merged PR, a commit title, a plan document, or a ticked checkbox is never sufficient evidence on its own.

- **demoable** requires that a human could show it working right now on a running instance.
- **done** requires proof it works end to end, named in the evidence column.
- **in-progress** is as far as a merged PR alone ever justifies.
- **not-started** is the default for anything nobody has assessed; never guess a status for it, and give it confidence `low`.

This project has already been burned by skipping this rule: `docs/roadmap.md` records three Phase 1 waves marked complete because an archived prototype completed them, a prototype later stripped from the repo.
Never promote anything to `demoable` or `done` without the captain's confirmation.
A **downgrade** needs no confirmation - if evidence has evaporated, say so and apply it.

## What it does

1. **Gather what actually changed** since `docs/status/ledger.md`'s last update date:
   - merged PRs and landed commits in the project since that date
   - new or changed files under `docs/evidence/`
   - any scout report naming a requirement id
   - Ask the captain whether anything happened outside the repo - a demo given, a manual run, a decision made.
     Much of this project's real progress looks exactly like that.

2. **Propose ledger changes as a short list, each with its evidence**, for the captain to accept or correct in one reply.
   State the requirement id, current status, proposed status, and the evidence line that justifies it.
   Apply the evidence rule above; never propose a promotion you cannot back with working-right-now or end-to-end proof.
   Downgrades ship without asking; every other change waits for his answer.

3. **Apply only the confirmed changes** to `docs/status/ledger.md`, re-roll `timeline.md`, write `docs/status/reports/YYYY-MM-DD-daily.md`, and, on the weekly cadence, `docs/status/reports/YYYY-Www-weekly.md`.
   Firstmate never writes to a project (`AGENTS.md` hard rule 1), so dispatch this as one ship task through the project's registered delivery path (`AGENTS.md` section 7), briefed with the confirmed changes verbatim so the worker applies exactly what the captain approved and nothing else.
   - Daily is a few lines: what moved, what is next, what is blocking.
     Readable on a phone.
   - Weekly leads with the capability delta, never activity: what a user can do now that they could not do last week, what is still not possible, the phase table, the Phase 1 ETA, next week, and the decisions waiting on the captain.
   - If nothing genuinely changed, say so plainly in the daily report rather than manufacture progress.
     A quiet day admitted is more credible than one padded out.

4. **Regenerate the boss-facing exports** in the same task, by running the project's status-export script to produce the Excel workbook and ready-to-paste HTML email bodies under `docs/status/exports/`.
   The captain cannot send markdown to his boss - tell him exactly which file to attach and which HTML body to paste; the markdown stays internal.

5. **Offer the visual board refresh as a separate step**, only after the above lands - it is not always wanted.

6. **Report to the captain**: what changed, what is now ready to send and where it is, and anything that still needs his answer.

## Notes

- The first run with no prior ledger date, or a ledger the captain says is unreliable, is a full re-assessment rather than a delta - gather from the whole project history instead of since-date.
- Keep the proposal list short and scannable; a long unreadable list defeats "confirm in one reply" as surely as skipping the confirmation would.
