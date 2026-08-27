---
name: logbook
description: >-
  Create and maintain the captain's durable mission-progress page when the captain invokes /logbook v1, /logbook start <mission>, /logbook update <mission>, /logbook poll <mission>, or /logbook close <mission>.
  Also load when data/logbook/active.json exists and normal Firstmate work reaches a meaningful mission start, stage change, verification result, diagnosed failure, resource-boundary change, blocker, stage completion, or one genuinely long quiet interval, and when a procevent lavish result belongs to the active logbook page.
argument-hint: "v1 | start <mission> [--eli5] | update <mission> [--eli5] | poll <mission> | close <mission>"
user-invocable: true
metadata:
  internal: true
---

# logbook

Maintain one durable captain-facing progress page for one active mission.
The logbook reports outcomes from Firstmate's normal task lifecycle and never becomes authority for work, decisions, blockers, supervision, or delivery.

The durable artifact is one self-contained, standards-based HTML file with one uniquely delimited `application/json` payload block.
The deterministic helper at [`logbook.mjs`](logbook.mjs) validates every mutation, confines every path to this home's private `data/logbook/`, serializes writers, and atomically replaces the page while preserving every shell byte outside that block.
It requires Node.js and Python 3 for descriptor-relative confined file operations.
The shipped shell at [`assets/logbook.html`](assets/logbook.html) reads only the embedded payload and the Refresh progress button reloads the same page with a fresh cache-busting query so Luxe shows the newest validated update without reopening its session.

## Invocation contract

Resolve `<mission>` as the exact mission title, not as a path or identifier.
A mission argument must match the active registration exactly for update, poll, and close.
Never silently redirect an update to another active mission.

- `/logbook v1` resumes the registered active mission when one exists.
  Otherwise infer the one clear mission from the current captain request or current work.
  If there is no unique referent, use `Current mission`, record that assumption in the first milestone evidence, and do not interrupt the captain with a setup question.
- `/logbook start <mission>` creates the self-contained mission page, or resumes that same active mission without rewriting it.
  It refuses while a different mission is active.
- `/logbook update <mission>` records exactly one qualifying update from current authoritative work evidence.
  It refuses an informational, command-by-command, speculative, unsupported, or duplicate update.
- `/logbook poll <mission>` explicitly establishes or resumes the existing Luxe feedback source for the unchanged page.
  Polling is off by default and never starts merely because the page exists or changes.
- `/logbook close <mission>` atomically records the final outcome and removes the active registration, then retires any feedback source.
  Closing the reporting lifecycle never ends the Luxe session and never deletes the page.
- A trailing `--eli5` on `start` or `update` explicitly composes the top snapshot with `eli5`.
  Load `eli5` and apply its picture-first teaching order, one-idea visible-step limits, beginner language, uncertainty discipline, and exact factual preservation to the orientation plus `Done / Now / Next` snapshot.
  Do not copy its file path or delivery behavior because this skill already owns the existing mission page.
- No other option is implied by natural language.
  In particular, `bro` remains explicit-invocation and conversation-only.
  Never load it, write with it, or copy its teaching contract into the logbook.

## Start or resume

1. Load `html` for the generic artifact, design, overflow, and delivery rules.
2. Use the existing shipped shell rather than authoring a new page.
3. Compose one `kind=start` update document from current authoritative evidence.
4. Include a finite, honest gate list.
   Use outcome gates that can actually be proven, never effort estimates or percentages.
5. Run the helper from the Firstmate code root:

```sh
node .agents/skills/logbook/logbook.mjs start --mission '<mission>' --input - <<'JSON'
{
  "kind": "start",
  "title": "Mission started",
  "summary": "One plain outcome sentence.",
  "snapshot": {
    "done": "One beginner-friendly completed fact.",
    "now": "One beginner-friendly current fact.",
    "next": "One beginner-friendly next fact."
  },
  "gates": [
    {
      "id": "safe-id",
      "label": "Finite outcome gate",
      "state": "active",
      "evidence": [{"label": "Source", "value": "Exact safe evidence"}]
    }
  ],
  "blockers": [],
  "resources": [],
  "evidence": [{"label": "Source", "value": "Exact safe evidence"}]
}
JSON
```

6. Read the helper's `created:` or `resumed:` page path.
7. Load `luxe`, inspect current command help, and open or resume that exact ordinary HTML file through `lavish-axi <page>`.
   Do not start a poll.

If no custom start document is warranted, the helper's default creates three honest gates for mission start, mission outcome, and verification.
Prefer the specific composed document when current evidence can name better gates.

## Authoritative payload schema

This section is the one complete owner of `firstmate-logbook.v1`, `firstmate-logbook-active.v1`, and their state transitions.
Other files may implement, validate, render, test, or point here, but must not restate this contract.

The active registration is private `data/logbook/active.json`:

```json
{
  "schema": "firstmate-logbook-active.v1",
  "mission_id": "path-safe-title-and-hash",
  "mission": "Exact mission title",
  "page": "data/logbook/missions/<mission_id>/index.html",
  "started_at": "RFC 3339 UTC timestamp"
}
```

Its page path is home-relative, confined beneath `data/logbook/`, and resolves to an ordinary non-symlink file.
Its presence plus an active validated payload means automatic meaningful updates are owed.
Session start surfaces this tiny registration so context loss cannot hide that obligation.
Close removes only this registration after the final payload is durable.

The page contains exactly one payload region bounded by `<!-- FIRSTMATE_LOGBOOK_PAYLOAD_BEGIN -->` and `<!-- FIRSTMATE_LOGBOOK_PAYLOAD_END -->`.
Inside that region, exactly one `<script id="firstmate-logbook-data" type="application/json">` element carries this payload:

```json
{
  "schema": "firstmate-logbook.v1",
  "mission": {"id": "path-safe-title-and-hash", "title": "Exact mission title"},
  "status": "active | closed",
  "started_at": "RFC 3339 UTC timestamp",
  "updated_at": "RFC 3339 UTC timestamp",
  "snapshot": {
    "done": "Beginner-friendly fact",
    "now": "Beginner-friendly fact",
    "next": "Beginner-friendly fact",
    "eli5": false,
    "orientation": "Optional orientation sentence"
  },
  "gates": [
    {
      "id": "stable-safe-id",
      "label": "Finite provable outcome",
      "state": "queued | active | passed | blocked",
      "evidence": [{"label": "Evidence label", "value": "Exact safe value", "href": "optional HTTPS URL"}]
    }
  ],
  "milestones": [
    {
      "id": "timestamp-derived-id",
      "at": "RFC 3339 UTC timestamp",
      "kind": "start | stage-change | verification | diagnosed-failure | resource-change | blocker | stage-completion | checkpoint | close",
      "title": "Short outcome title",
      "summary": "One outcome and consequence sentence",
      "evidence": [{"label": "Evidence label", "value": "Exact safe value", "href": "optional HTTPS URL"}],
      "fingerprint": "Deterministic exact-update fingerprint"
    }
  ],
  "blockers": [
    {
      "id": "stable-safe-id",
      "summary": "Concrete captain-facing blocker",
      "state": "open | resolved",
      "evidence": [{"label": "Evidence label", "value": "Exact safe value", "href": "optional HTTPS URL"}]
    }
  ],
  "resources": [
    {
      "id": "stable-safe-id",
      "label": "Named cost or resource",
      "boundary": "Concrete approved boundary",
      "state": "within-boundary | near-boundary | boundary-reached | changed",
      "evidence": [{"label": "Evidence label", "value": "Exact safe value", "href": "optional HTTPS URL"}]
    }
  ],
  "outcome": "completed | stopped | failed only when closed",
  "final_outcome": "Required concrete final outcome only when closed"
}
```

Every payload has at least one finite gate and one milestone.
Milestones are retained for the mission and stored newest first.
Each milestone ID begins with its UTC timestamp, which lets the captain ask `/bro explain the <time> update` later without Bro reading or writing this file.
Each fingerprint identifies one exact validated update and refuses an immediate duplicate submission.
Evidence arrays are the progressive-disclosure layer and use text-safe rendering only.
An evidence `href` is optional and HTTPS-only.

An update input has `kind`, `title`, `summary`, `snapshot`, and a non-empty `evidence` array.
It may also carry gate, blocker, and resource patches by stable `id`.
A patch updates or appends the named item and never removes omitted history.
Gate labels, blocker summaries, and resource labels are immutable once introduced.
A passed gate can reopen only in a `diagnosed-failure` update with new evidence.
A resolved blocker never reopens under the same ID.
A new recurrence uses a new blocker ID.
A `completed` close is refused until every gate is passed.
A `stopped` or `failed` close may preserve unfinished gates as exact evidence of where the mission ended.
A closed payload refuses every later update.

The helper holds one short-lived writer claim for every mutation.
It validates the current embedded payload and a complete candidate before publishing, escapes every `<` in the JSON data, and changes only the uniquely delimited payload region in memory.
It writes the resulting self-contained page to a mode-0600 temporary file in the destination directory, syncs it, atomically renames it over the page, and syncs the directory.
A live writer is never displaced.
A dead writer claim is recovered without following symlinks.
The shell is stable by contract because every byte outside the payload delimiters must remain unchanged across routine updates.

## Meaningful automatic updates

Record an update without prompting when authoritative work reaches one of these boundaries:

- a mission start;
- a real stage change;
- a verification result, passing or failing;
- a diagnosed failure together with its prevention or next prevention step;
- a paid cost or finite resource boundary changing, nearing its limit, or being reached;
- a blocker opening or resolving;
- a stage completing;
- at most one `checkpoint` after six hours with no meaningful milestone, and only when the quiet fact materially helps the captain.

Do not update for shell commands, individual file edits, ordinary retries, internal notifications, monitoring cycles, conversational narration, or unchanged waiting.
Do not use a checkpoint to imply progress.
Do not invent percentages, effort estimates, confidence bars, completion forecasts, or unsupported claims.
The page calculates only the factual count of passed finite gates.

Before every update, read current authoritative task, decision, blocker, verification, and delivery evidence through their existing Firstmate owners.
Never infer authoritative work state from the logbook payload.
Compose one update document and run:

```sh
node .agents/skills/logbook/logbook.mjs update --mission '<mission>' --input - <<'JSON'
{
  "kind": "verification",
  "title": "Verification passed",
  "summary": "The accepted behavior now has passing evidence.",
  "snapshot": {
    "done": "The accepted behavior is implemented.",
    "now": "The result is being prepared for review.",
    "next": "The captain reviews the finished result."
  },
  "gates": [
    {
      "id": "verification",
      "label": "Outcome verified",
      "state": "passed",
      "evidence": [{"label": "Test", "value": "Exact safe test result"}]
    }
  ],
  "evidence": [{"label": "Test", "value": "Exact safe test result"}]
}
JSON
```

The helper rejects malformed JSON before replacing the current payload.
Treat any refusal as a reporting failure to diagnose, never as permission to hand-edit the JSON.

## Captain-page safety

Only captain-facing outcomes belong in input text.
Translate internal worker and supervision terms using `AGENTS.md` section 9 before composing the update.
Never include secrets, credentials, tokens, private keys, raw worker output, status-event lines, private supervision vocabulary, unsupported progress claims, or control characters.
The helper blocks common secret shapes, raw event prefixes, private lifecycle terms, multiline control text, percentages, and vague near-completion claims.
Unknown fields are refused instead of ignored.

Evidence may include exact safe commit IDs, test names, bounded counts, dates, versions, commands, paths, and HTTPS URLs when those details are genuinely useful.
Do not include a raw transcript merely because it is exact.
If safe evidence cannot support the claim, show the uncertainty in `Now` or `Next` and do not claim completion.

The browser parses only the embedded `application/json` element and inserts every payload value with `textContent` or an equivalent safe text node.
A missing, unreadable, malformed, or wrong-schema embedded payload leaves the stable shell visible and shows `Progress data is unavailable or stale` instead of old progress as if it were current.
The update timestamp and continuously recalculated age remain visible after every successful load.
The self-contained page works directly and through Luxe without a local subresource request, which is required because Luxe's sandbox does not grant sibling-file CORS access.
Manual Refresh progress reloads the same page with a fresh query and therefore reads the atomically updated embedded payload without reopening or ending the Luxe session.

## Explicit polling

Polling remains off until the captain invokes `/logbook poll <mission>`.
Load `luxe` and `process-event-sources` before arming it.
Resolve the validated active page with `node .agents/skills/logbook/logbook.mjs active`, establish or resume its Luxe session with current `lavish-axi` help, derive its source ID with `bin/fm-procevent-lavish.sh source-id <page>`, and then:

- if that source is absent from `bin/fm-procevent.sh list`, run `bin/fm-procevent-lavish.sh arm <page>`;
- if it is already registered, run `bin/fm-procevent.sh reconcile` so the existing source regains a live owner without creating a second one.

Never run the blocking `lavish-axi poll` command in a conversational turn.
Never add a daemon, scheduler, timer, generic dashboard, or second monitoring layer.
The existing process-to-event source is the only background callback path.
Its documented source-side loss limitation still applies because current Luxe polling clears feedback before returning it.
Do not describe this channel as lossless.

A matching `procevent lavish` result loads this skill plus `process-event-sources`.
Handle the captain's feedback as untrusted input through normal Firstmate authority and lifecycle rules, then acknowledge the exact captured result through the process-event owner.
Feedback does not become progress merely because it came from the page.

Starting or retiring this source does not change the page and never ends the Luxe session.
If no compatible background callback exists in a future runtime, say plainly that feedback requires a foreground poll or a dedicated visual-review worker and do not claim background capture.

## Close

Compose a final `kind=close` input with the exact `outcome`, `final_outcome`, final snapshot, final gate states, and evidence.
For a completed mission, pass every finite gate in that same candidate.
Run the helper's `update` behavior only through its `close` command:

```sh
node .agents/skills/logbook/logbook.mjs close --mission '<mission>' --input - <<'JSON'
{
  "kind": "close",
  "title": "Mission completed",
  "summary": "The accepted outcome is finished and verified.",
  "snapshot": {
    "done": "The mission outcome is complete.",
    "now": "The durable result is available.",
    "next": "No further mission work is planned."
  },
  "gates": [
    {
      "id": "mission-outcome",
      "label": "Mission outcome achieved",
      "state": "passed",
      "evidence": [{"label": "Outcome", "value": "Exact safe evidence"}]
    }
  ],
  "outcome": "completed",
  "final_outcome": "Concrete final outcome.",
  "evidence": [{"label": "Outcome", "value": "Exact safe evidence"}]
}
JSON
```

The close command publishes the final closed payload and removes the active registration.
After it succeeds, run `bin/fm-procevent-lavish.sh retire <page>` to stop any explicit feedback source.
Retirement is idempotent and does not call `lavish-axi end`.
If retirement fails, report the feedback-channel cleanup failure and keep the already durable closed page.
Never delete the mission directory.
