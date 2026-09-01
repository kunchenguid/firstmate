---
name: slack-react-only
description: >-
  React-only handling of Slack messages from Soran or Juan Miguel that reach the captain.
  Load on a slack-mentions wake, and before reacting to anything either of them sent.
  Owns the two allowed reactions, the four-minute hold, and the absolute no-text rule.
user-invocable: false
metadata:
  internal: true
---

# Slack react-only

Soran and Juan Miguel are the only two people this covers.
For a message from either of them that reaches the captain, firstmate adds one emoji reaction and nothing else.

## The one hard rule

**Never write text.**
No reply, no thread reply, no DM, no "on it", no acknowledgement in words.
A reaction is the entire response.

This is stricter than the `slack-browser` consent gate, which merely requires the captain to approve text before it is sent.
Here there is no text to approve, because text is never an option.
If a message genuinely needs words, that is an escalation to the captain under `AGENTS.md` section 9, not a message firstmate sends.

## Which messages qualify

A message qualifies when **both** hold:

1. The sender is Soran or Juan Miguel, and
2. it actually reaches the captain: a DM from them, or a channel or group message that **@-mentions the captain**.

A channel message from either of them with no @-mention of the captain does not qualify.
A DM qualifies with no @-mention, because a DM is already addressed to him.
Someone else's message in a thread they started does not qualify; go by the sender of the individual message.

## Which reaction

Read what the message is asking for.

| The message | Reaction | When |
| --- | --- | --- |
| Asks the captain to read, look at, review, or look into something | `eyes emoji` (👀) | **Four minutes after the message timestamp**, never sooner |
| Is acknowledgement-only - a thanks, a confirmation, an FYI, nothing to act on | `thumbsupparrot emoji` | Right away |

The four-minute hold on 👀 exists because 👀 means "I am looking at this now".
Reacting instantly reads as automated, and it is a claim the captain has not had time to make.

If a message is both a request and a thank-you, treat it as the request and use the 👀 path.
If it is neither - a question expecting an answer, something needing a decision, or anything urgent - **do not react at all**; surface it to the captain instead.
When it is unclear which of the two applies, surface it rather than guessing; a wrong reaction sent as the captain cannot be taken back cleanly.

## Emoji names

Slack's picker names these with spaces and an ` emoji` suffix:

- `eyes emoji`
- `thumbsupparrot emoji`

The colon form (`:thumbsupparrot:`) and the hyphen form match nothing in the picker.
The label is on the gridcell's child button, not on the gridcell itself.

## Holding the four minutes

Do not sleep for four minutes inside a turn, and do not spin waiting on it.
Register the delay as a wake and let the turn end, then react when it fires.

The message timestamp, not the wake time, starts the clock.
A wake that arrives five minutes late means the hold is already satisfied - react immediately rather than adding four more minutes.

## Mechanics

`slack-browser` owns connecting, finding the conversation, reading, and verifying.
It is the same captain browser session, so the reaction lands under the captain's own name with no bot badge.

Add the reaction and then confirm it by reading back the message's `.c-reaction` aria-labels, which read `1 reaction, react with eyes emoji`.
Do not confirm by counting `<img alt>` in the row: a message body containing the same emoji inline will fool that check.

## What reaches the captain

Nothing, for a routine reaction.
A reaction is not news and does not go in a captain-facing message.
Surface only a message that did not qualify for either reaction and needs him.
