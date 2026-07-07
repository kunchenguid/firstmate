# parking skill

A firstmate feature: capture the captain's half-formed ideas mid-conversation, resurface them on a schedule, refine them in place, and promote the ready ones to Jira and firstmate intake.

## What it is

- A **capture reflex** contracted in `AGENTS.md` section 6: the phrases `Parking:`, `park this`, and `put this in parking` (and clear near-variants) capture an idea with no skill invocation.
- A **store** at `data/parking.md`: firstmate-private, gitignored as part of `data/`, created lazily on the first capture, never committed. Same class as `data/backlog.md`. Only the format is documented (in `SKILL.md`); the file itself is local state.
- **Rituals** driven by durable crons: a morning and afternoon nudge to refine, and a Friday weekly digest.
- **Promotion** to a Jira issue via the `jira-connect` skill, plus firstmate intake for fleet software work.

## Invocation

- `/parking` or "review my parking lot" runs the review ritual on demand.
- Capture happens automatically on the trigger phrases; no command needed.
- The daily and weekly crons invoke the same rituals on a schedule.

## The cron model and its honest limits

Rituals fire via harness `CronCreate` recurring jobs (`durable: true`, local time):

- Morning: `57 8 * * *` (~8:57am).
- Afternoon: `30 15 * * *` (3:30pm exact, captain-specified; the scheduler's small jitter still applies).
- Weekly digest: `7 17 * * 5` (~Friday 5:07pm).

Two constraints are designed around, not hidden:

1. **7-day auto-expiry.** Harness recurring crons fire a final time and delete themselves after 7 days. The rituals are therefore **self-re-arming**: whenever a ritual runs (or at session start), the skill checks `CronList` and re-creates any parking cron that is missing or within the expiry window. If the captain opens no firstmate session for more than 7 days, the schedule lapses and then self-heals on the next session.
2. **Fires only while a session is live.** A cron fire is missed if no firstmate session is open; recurring crons get no catch-up. This is accepted: the ritual fires when the captain is actually working. The weekly digest and the decay nudge provide backstop coverage for ideas missed on a quiet day.

## Sample entry

```markdown
## redshift-cache-idea-k4 — cache the territory rollup so the dashboard stops timing out
- status: refining
- parked: 2026-07-07
- last-touched: 2026-07-09
- time-sensitive: 2026-07-31
- context: debugging the slow territory dashboard [ref: https://github.com/kunchenguid/firstmate/pull/312]
- verbatim: "park this — what if we just cached the territory rollup, the dashboard keeps timing out"
- notes:
  - 2026-07-07: original capture while the dashboard was timing out mid-review.
  - 2026-07-09: cache invalidation is the hard part; rollup changes hourly, so a 15-min TTL may be enough.
```
