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
