# parking skill

A firstmate feature: capture the captain's half-formed ideas mid-conversation, resurface them on a schedule, refine them in place, and promote the ready ones into firstmate intake (and, optionally, an external tracker).

## What it is

- A **capture reflex** contracted in `AGENTS.md` section 6: the phrases `Parking:`, `park this`, and `put this in parking` (and clear near-variants) capture an idea with no skill invocation.
- A **store** at `data/parking.md`: firstmate-private, gitignored as part of `data/`, created lazily on the first capture, never committed. Same class as `data/backlog.md`. Only the format is documented (in `SKILL.md`); the file itself is local state.
- **Rituals** driven by durable crons: a morning and afternoon nudge to refine, and a Friday weekly digest.
- **Promotion** into firstmate intake for fleet software work, and optionally into an external tracker (for example Jira via `jira-connect`) when a tracker skill is available.

## Invocation

- `/parking` or "review my parking lot" runs the review ritual on demand.
- Capture happens automatically on the trigger phrases; no command needed.
- The daily and weekly crons invoke the same rituals on a schedule.

## The cron model and its honest limits

Rituals fire via harness `CronCreate` recurring jobs (`durable: true`, local time):

- Morning: `57 8 * * *` (~8:57am).
- Afternoon: `30 15 * * *` (3:30pm, a sensible mid-afternoon default; adjust to taste; the scheduler's small jitter still applies).
- Weekly digest: `7 17 * * 5` (~Friday 5:07pm).

Two constraints are designed around, not hidden:

1. **7-day auto-expiry.** Harness recurring crons fire a final time and delete themselves after 7 days. The rituals are therefore **self-re-arming**: whenever a ritual runs (a cron fire or an on-demand `/parking`), the skill checks `CronList` and, for each of the three parking crons, either creates it when none matches its key or delete-then-creates it when a matching cron is live - always delete-then-create, because `CronList` exposes no creation time, age, or expiry timestamp to tell a near-expiry cron from a fresh one. If the captain opens no firstmate session for more than 7 days, all three crons lapse and then self-heal on the next ritual or `/parking`.
2. **Fires only while a session is live.** A cron fire is missed if no firstmate session is open; recurring crons get no catch-up. This is accepted: the ritual fires when the captain is actually working. The weekly digest and the decay nudge provide backstop coverage for ideas missed on a quiet day.

## Sample entry

```markdown
## cache-rollup-idea-k4 - cache the expensive rollup so the dashboard stops timing out
- status: refining
- parked: 2026-07-07
- last-touched: 2026-07-09
- time-sensitive: 2026-07-31
- context: debugging the slow dashboard [ref: myapp#312]
- verbatim: "park this - what if we just cached the rollup, the dashboard keeps timing out"
- notes:
  - 2026-07-07: original capture while the dashboard was timing out mid-review.
  - 2026-07-09: cache invalidation is the hard part; the rollup changes hourly, so a 15-min TTL may be enough.
```
