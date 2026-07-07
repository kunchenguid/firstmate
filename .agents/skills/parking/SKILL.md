---
name: parking
description: Capture, resurface, refine, and promote the captain's half-formed ideas. Use when the captain invokes /parking or asks to review, refine, or clean up their parking lot ("review my parking lot", "parked ideas", "refine ideas", "what's in parking"), when a parking-ritual cron prompt fires, or when handling a parking capture trigger ("Parking:", "park this", "put this in parking"). The always-on capture reflex is contracted in AGENTS.md section 6; this skill owns the store schema, capture mechanics, daily/weekly rituals, decay, clustering, cron scheduling with self-re-arm, and promotion via jira-connect.
user-invocable: true
metadata:
  internal: true
---

# parking

The parking lot is the captain's idea garden: a zero-friction place to capture half-formed ideas mid-conversation, resurface them on a daily and weekly cadence, refine them in place, and promote the ready ones into tracked work.
It is pre-backlog staging plus a long-lived garden, not a replacement for the backlog and not a general note store.
Reference material still belongs in `data/learnings.md` and `data/captain.md`.

The store is `data/parking.md`, firstmate-private and gitignored as part of `data/`, the same class as `data/backlog.md`.
It is created lazily on the first capture and is never committed.

## Store schema

One entry per idea in `data/parking.md`:

```markdown
## <id> — <distilled one-liner>
- status: raw | refining | ready | promoted | dropped
- parked: <YYYY-MM-DD>
- last-touched: <YYYY-MM-DD>
- time-sensitive: no | <YYYY-MM-DD deadline>
- context: <what the captain was doing when parked> [ref: <task-id | PR url | file:line>]
- verbatim: "<the captain's original words, preserved untouched>"
- notes:
  - <YYYY-MM-DD>: <original capture, then refinement notes appended over time>
```

Field contract:

- `id`: short kebab slug with a random suffix, the same convention as task ids, e.g. `redshift-cache-idea-k4`.
- `status`: lifecycle field, `raw` on capture, `refining` while notes are being added, `ready` when the captain deems it actionable, then `promoted` (moved into tracked work) or `dropped` (killed but retained for record).
- `parked`: capture date, immutable.
- `last-touched`: updated on every note append or status change; drives the decay nudge.
- `time-sensitive`: `no`, or an absolute `YYYY-MM-DD` deadline. Relative phrases ("by Friday", "before the release") are resolved to absolute dates at capture time.
- `context` and `ref`: what the captain was doing when they parked, plus a back-reference to the task, PR, or file in play so refining later reloads real context.
- `verbatim`: the captain's original words, preserved exactly alongside the distilled line, so a later refinement never loses the raw spark.
- `notes`: dated, append-only refinement log.

Dates are always absolute; convert relative dates at write time.
Keep note prose free of volatile incidental specifics per firstmate's note-hygiene rule (AGENTS.md section 10).

## Capture

Capture is a reflex triggered in normal conversation, no skill invocation needed; the trigger phrases are contracted in AGENTS.md section 6.
The procedure:

1. Grab the referent: the explicit text after `Parking:`, or the idea or thing just discussed.
2. Distill it into a crisp one-liner. Capture `context` and a back-reference `ref` to the current task, PR, or file when one is in play.
3. Preserve the captain's original words in `verbatim`, untouched.
4. Auto-detect time-sensitivity from the language. Resolve any relative deadline to an absolute date.
5. Only if the idea reads time-sensitive but carries no resolvable date, ask exactly one question for the deadline. Otherwise stay silent - no questions.
6. Write the entry with `status: raw`, `parked` and `last-touched` set to today, and confirm in one line: `Parked: <distilled>.` plus `⏰ due <date>` when time-sensitive.

Create `data/parking.md` on the first capture if it does not yet exist.
A non-urgent capture is a single turn with no questions.

## Rituals

Three durable crons fire the rituals. Create them with `CronCreate`, each `durable: true`, local time, with a prompt that invokes this skill's ritual and includes the literal marker string `[parking-lot ritual]` so the cron is identifiable in `CronList` output (for example "[parking-lot ritual] Run the parking-lot morning ritual: review data/parking.md"):

- Morning: `57 8 * * *` (~8:57am).
- Afternoon: `30 15 * * *` (3:30pm exact; the scheduler's small jitter still applies).
- Weekly digest: `7 17 * * 5` (~Friday 5:07pm).

The off-minute morning (8:57) and Friday (5:07) times avoid the fleet-wide :00/:30 pileup; the 3:30pm afternoon time is the captain's deliberate exact choice (documented in `README.md`) and lands on :30 by design.
These crons auto-expire after 7 days, so they are self-re-armed (see below).

**Morning and afternoon.**
Surface time-sensitive items first: anything due soon or overdue is shown loudly at the top.
Then offer one or two non-urgent `raw` or `refining` ideas to dive into.
The afternoon (3:30pm) framing is "want to refine anything before you wrap?"
If the lot is empty, say nothing and do not manufacture a nudge.

**Weekly digest.**
A whole-lot overview: what is aging (decay), what is `ready`, and what is time-sensitive in the coming week.

### Decay nudge

A `raw` or `refining` idea whose `last-touched` is older than 14 days is gently surfaced in the next ritual: "this has sat N days - refine or drop?"
This keeps the lot from becoming a graveyard.
Acting on it (a note append, a status change, or a drop) resets `last-touched`.

### Theme clustering

During a ritual, group related parked ideas and suggest combining them: "3 ideas here all touch Redshift access - combine into one effort?"
This turns scattered sparks into a single deliberate effort.
Clustering is a suggestion, not an automatic merge; the captain decides.

### Self-re-arm against the 7-day expiry

Harness recurring crons fire a final time and delete themselves after 7 days.
The skill keeps its own schedule alive rather than relying on a core-script change: whenever a ritual runs (a cron fire or an on-demand `/parking`), first run `CronList`, and for each of the three parking crons that is absent or within the 7-day expiry window, re-create it with `CronCreate` using the exact expression above.
Identify a parking cron in `CronList` output by a stable match key: BOTH its exact cron expression (one of `57 8 * * *`, `30 15 * * *`, `7 17 * * 5`) AND the literal marker string `[parking-lot ritual]` in its prompt text.
This is idempotent: never create a duplicate of a cron whose expression+marker match key is still live and outside the window, and re-create only the missing or near-expiry ones.

If no firstmate session opens for more than 7 days, all three crons lapse; the next ritual or `/parking` re-arms them.
This lapse-then-self-heal behavior is the accepted tradeoff documented in `README.md`.

## Refinement and promotion

Refine in place until an idea is `ready`: during a ritual or on demand, append dated notes, add sub-ideas, and bump `raw -> refining -> ready`. `last-touched` updates on every change.

**Promote (`ready` -> `promoted`).**
When the captain wants a `ready` idea promoted:

1. Load the `jira-connect` skill and create a Jira issue: title is the distilled one-liner, body is the refinement notes, and add the deadline when the idea is time-sensitive. Record the returned Jira issue key.
2. Flip the parking entry to `status: promoted` with a pointer to the Jira key, and update `last-touched`.
3. When the idea is also fleet software work firstmate should execute, ALSO run firstmate's normal intake (AGENTS.md section 7): resolve the project, classify ship versus scout, and spawn the crewmate. Record both the Jira key and the resulting backlog id / PR / report on the parking entry.

**Promote-to-scout.**
An idea that is really a question ("would X work?") promotes straight to a firstmate scout task: firstmate investigates and reports, no commitment.
Still file the Jira issue when the captain wants it tracked there.

**Fallback when `jira-connect` is unavailable.**
Create a local `data/backlog.md` entry instead, and warn the captain that the idea was queued locally rather than filed in Jira.
Still flip the parking entry to `promoted` with a pointer to the backlog id.

**Drop (`dropped`).**
A killed idea is retained for record, not deleted immediately.
Prune `dropped` (and old `promoted`) entries periodically to keep the lot scannable.
Non-software ideas have no promote target; they live, refine, and drop in the lot, which is fine.
