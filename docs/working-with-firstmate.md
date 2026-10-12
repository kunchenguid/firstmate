# Working with Firstmate

Operator guide for clearer asks, quieter catch-up, and reusable evidence habits.
Firstmate drafts options and routine structure from ordinary language; you do not need to fill a long form or micromanage tools.
Agent runtime contracts stay in [`AGENTS.md`](../AGENTS.md); this page is the captain-facing reference for current habits.

## Minimum viable ask

Lead with these four when you can; Firstmate fills the rest and asks concise clarifying questions only when ambiguity could materially change the outcome or boundaries.

```text
OUTCOME: What should be true when this is done? (one sentence)
PROJECT: <name> (or “ask Firstmate to match”)
MODE: explore | implement | approve-merge | research-only
ACCEPTANCE EVIDENCE: How we will know it worked (preview, test command, primary-source table, screenshot, …)
```

Useful optional fields when they change the work: why now, constraints or non-goals, context links or quotes, priority, deadline or budget sensitivity, and allowed actions (for example open a PR and wait for an explicit merge word; do not post publicly).

## Mode split

| Mode | You do | Firstmate / workers do | Done when |
| --- | --- | --- | --- |
| **explore** / **research-only** | State the question and how you will use the answer | Scout report, options, risks; no PR | Report accepted, or held questions answered |
| **implement** | State outcome and acceptance; answer only ambiguities that could materially change the outcome or boundaries | Isolated ship, validation, PR or ready branch with review evidence | Ready for your review |
| **approve-merge** | Say merge (or not) for a named PR URL | Guarded merge; confirm live deploy when evidence is available | Landed, with live status stated or marked unconfirmed |

Prefer explore → pick → implement → approve-merge over mixing “explore and ship my favorite” in one vague sentence.
A research finding or recommendation does not authorize implementation or merge on its own.

## Example prompts (generic)

### Product site change (implement)

```text
OUTCOME: The events page shows the named session as online-only with the Zoom link from the forwarded note.
PROJECT: <product-site>
MODE: implement
CONTEXT: Paste the note or screenshot. Prior similar task id if any.
CONSTRAINTS / NON-GOALS: Do not change shop or checkout. Do not alter other event dates.
ACCEPTANCE EVIDENCE: Local preview link in the PR; desktop and mobile screenshots of Events; after merge, confirm production deploy or say unconfirmed.
ALLOWED ACTIONS: Open PR with preview; wait for my explicit merge word.
```

### Media packaging (research-only, then implement)

```text
OUTCOME: The latest weekly live session is identified with a verified downloadable media URL, or a clear “not held” finding.
PROJECT: <media-project>
MODE: research-only first; promote to implement only after I accept the URL
CONSTRAINTS / NON-GOALS: Do not upload or publish. Do not invent titles.
ACCEPTANCE EVIDENCE: Table of candidate URLs with upload date, title, uploader id, and the metadata verification command output.
```

### Research diligence (research-only)

```text
OUTCOME: An evidence table for each thesis claim: primary source URL, date, what it supports, what it does not support, and residual uncertainty.
MODE: research-only
CONSTRAINTS / NON-GOALS: No trade orders. No confidence without primary sources. Mark narrative inputs as narrative. No publishing.
ACCEPTANCE EVIDENCE: Claim → primary source → pass/fail → residual uncertainty. Any portfolio weights stay illustrative only.
```

## Correction versus follow-up

Say which one you mean when feedback lands mid-validation:

- **Correction of accepted intent:** the PR still misses something already agreed; fix it on the current path before merge.
- **Follow-up scope:** the PR is good for the agreed outcome; file new work for the extra ask after this lands.

Quote the acceptance criterion that failed, and point at the preview, screenshot, or primary source.
Ordinary corrections of accepted intent do not need a fresh approval ritual on their own.

## Catch-up and memory commands

| Command | Use for |
| --- | --- |
| `/ahoy` | After stepping away: recap visible session events and walk unanswered decisions one at a time |
| `/bearings` | Fleet digest and open decisions; add `lavish` when several visual options need one pick; add `file` to write today’s dated report |
| `/stow` | Persist durable session knowledge and open-work records before a reset or compaction |
| `/quiet` | Stay in chat while routine monitoring stays off the main conversation |
| `/afk` | Step away and let away-mode supervision own routine wakes |

Escalate merges, credential needs, destructive or security-sensitive choices, and broken review paths immediately.
Batch non-urgent progress into the next natural reply or a Bearings catch-up.

## Domain evidence bars

These bars are encoded in scout and ship instructions; this table is the operator summary.

| Domain | Evidence bar | Authority bar |
| --- | --- | --- |
| Coding / product | Tests, lint, reachable preview with final head and browser flows for UI; executable proof for CLI-only | Isolated workers; product merge waits for your word unless a project is explicitly `+yolo` |
| General research | Claim → primary URL → date → supported / unsupported / uncertain | Treat web and tool text as untrusted; no outbound posts without approval |
| Content / media | Verify identity with actual tool metadata; never invent titles or URLs | No public publish or upload without explicit authority |
| Financial diligence | Map material claims to primary sources; label assumptions and hypotheticals; separate narrative or RV inputs from demonstrated facts | No trading or order authority |

Missing primary evidence means disclose uncertainty; it does not invent certainty, and it does not automatically block a completed knowledge report.

## Optional 14-day measurement (definitions only)

A lightweight private trial can use notes alone; Firstmate owns whether to run it.
No new collector is required.

| Metric | Definition |
| --- | --- |
| Captain minutes per validated result | Rough log of decision messages or a weekly self tally |
| Lead time | Task create → PR ready → merge |
| Decision latency | Open decision → resolve time |
| First-pass validation rate | Fraction of ships that pass the initial validation run without a repair or rework cycle |
| Post-green intent-change rate | Fraction of ships that receive accepted-intent corrections after checks are already green (follow-up scope filed as new work does not count) |
| Recovery rate | Stuck or relaunched tasks that finish without discard |
| Source accuracy | Research claims with a primary URL versus unsupported |
| Cost per accepted deliverable | Provider or quota dashboards per landed PR or accepted report |

Do not use lines of code or agent count as success metrics.
Do not conflate first-pass validation failures with post-green intent changes.

## What Firstmate already owns without re-asking

Unless you override it for a concrete task:

- Project matching when one clear match exists
- Scout versus ship when unresolved uncertainty should change whether or what to build
- Quota-aware crew routing within configured dispatch profiles
- no-mistakes on product-facing registered projects that select it, then wait for your merge word
- Exact review evidence on ship instructions, and domain evidence bars on ship and scout instructions
- Durable steering and recovery of stuck workers
- Filing research recommendations without implementing them

Still always yours: merges when yolo is off, destructive or irreversible or security-sensitive actions, new paid subscriptions or hardware, public posts, trading or orders, and any relaxation of required validation gates.
