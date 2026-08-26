---
name: slack-announcements
description: >-
  Agent-only style contract for drafting a Slack announcement the captain will post to a channel.
  Load before drafting a new-page, new-tool, capability-launch, brownbag, process-change, or broadcast status message.
  Owns the length target, the section skeleton, the one-clause bullet rule, the no-defence rule, punctuation and formatting limits, and the final deletion pass.
user-invocable: false
metadata:
  internal: true
---

# Slack announcement style

This skill is the single owner of how firstmate drafts a message the captain will post to a channel.
The rules below come from one measured case: a draft announcing a new internal page went from 323 words to 144 before posting, and the captain's section outline survived untouched.
Every cut was prose, none was structure, so treat these as rules rather than preferences.

## Scope

Use this for any message the captain will post to a channel: a new page or tool, a capability launch, a brownbag, a process change, a broadcast status note.
This skill produces a draft and nothing else: the captain posts it.
Never send, schedule, or otherwise publish the announcement yourself, through any channel or tool.

Do not use it for captain-facing chat, PR bodies, commit messages, or project documentation.
Several rules here are the opposite of what those surfaces need, and applying them there deletes detail those readers depend on.

## Assume the first draft is twice as long as it should be

The measured case cut 55% of the words with the outline unchanged.
The excess is explanation, not content.
Draft, then cut to roughly half, and expect to find nothing missing.

## Keep the skeleton, cut the prose

Three or four bold section headers, each answering a question the reader actually has: what this is plus the link, what it counts or does, what makes it trustworthy, what it is not.
That outline survived verbatim through the cut.
Edit inside the sections, never the outline.

The announcement itself uses no markdown emphasis or heading syntax at all: no double-asterisk bold, no hash headings, no underscores for italics, no markdown links, and no backtick code spans.
Slack uses its own mrkdwn rather than markdown, so the markdown-only forms among those, double-asterisk bold, hash headings, and markdown link syntax, show up as literal punctuation.
The forms Slack does share, underscore italics and backtick code spans, are banned as a style choice, because plain unstyled text scans better in an announcement.
Section headers stay bold through Slack's own mrkdwn form instead, a single asterisk on each side of the header text, written as `*What this is*`.
A single-asterisk pair is only ever a bold section header, never inline emphasis on a word or a phrase, and the announcement carries no hash title.

## One clause per bullet

A bullet is an index entry, not a paragraph.
One clause per bullet is the target that binds, and one sentence per bullet is only the floor beneath it, so a bullet trailing a second clause inside a single sentence still fails the rule.
Keep every capability list brief, and hold every bullet in it to that same ladder wherever the announcement lists bullet points.
If a bullet has a second sentence, that sentence is almost always the cut.

Before:

- "A completion is credited to whoever held the ticket the moment it moved to Done, replayed from the ticket's own history, not whoever it happens to be assigned to today. Work finished in July and reassigned in August still credits July's owner."

After:

- "A completion is credited to whoever held the ticket the moment it moved to Done."

## Never defend the claim

This was the single largest source of cut words.
Delete every phrase that pre-empts an objection nobody raised.
These are the phrases the captain cut from the real case, and the pattern is easier to recognise from them than from a definition:

- "never guessed at, and never handed to whoever filed them"
- "that's honest data, not a gap in the page"
- "rather than being fuzzy-matched into a plausible pod"
- "and the page says so itself"
- "Nothing else sneaks in."

A reader who doubts a claim clicks the link.
A reader who does not is being argued with for no reason.

## Keep a reason only when it changes how the thing is used

Not all reasoning is padding.
This sentence survived in full: "Weeks run Thursday to Thursday UTC, deliberately matching the release week, so an activity week and a release cover the same seven days."
A reader comparing the page against a release would otherwise misread it.

The test: does the reason prevent a wrong action, or does it defend the work's credibility?
Keep the first, cut the second.

## No em dashes

Use a colon, a full stop, or restructure the sentence.
In the real case both em dashes that introduced a definition became colons, and the rest of those sentences were split or dropped.

## No intensifiers, no hedges, numerals for numbers

"genuinely went through AgentOS" became "went through AgentOS".
"Nineteen weeks of history so far" became "19 weeks of history".
An adverb survives only when it carries meaning: "what's actually moving through AgentOS" stayed, because it distinguishes real throughput from noise.

## Leave out how it works

An entire closing paragraph covering refresh cadence, credential handling, and build-time embedding was cut wholesale.
Refresh schedules, security posture, generator scripts, and file layout belong on the page or in the repo, never in the announcement.
A reader who needs that detail is already past the announcement.

## Link plainly

Bare domain and path on its own line, no scheme and no label text.
Keep the scheme when the host is not one Slack will auto-link, such as an internal or non-public-suffix hostname.

This does not relax `AGENTS.md` section 9's requirement for a full `https://` URL in captain-facing chat about a PR.
Different audience, different rule: nothing here is a general relaxation of that requirement.

## No pipe characters

That rules out markdown tables, because Slack renders them as noise.

## Never name the captain

An announcement carries no captain attribution.

## Final deletion pass

Run this pass in order before handing the draft over, applying the rules above rather than overriding them:

1. Cut the second sentence of every bullet: it is almost always the cut, so keep it only when it is a load-bearing reason that prevents a wrong action, never when it restates or illustrates the first sentence, as the worked example's cut second sentence does.
2. Cut every clause that defends a claim or pre-empts an objection nobody raised, measured against the quoted phrases in the no-defence rule above rather than against any fixed opener, so a clause reading "that's honest data, not a gap in the page", "and the page says so itself", or "Nothing else sneaks in." is caught exactly as one opening "never", "rather than", or "not a" is.
   Keep only the "what it is not" section's plain statements of what the thing is not, plus any clause that passes that same load-bearing test, so a defensive clause is still cut wherever it sits, including inside that section.
3. Replace every em dash with a colon or a full stop, or restructure the sentence, and never remove a clause separator in a way that leaves a run-on.
4. Cut every sentence about how the thing is built or refreshed.

Then confirm the outline still stands.
