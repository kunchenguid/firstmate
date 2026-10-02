---
name: captain-facing-writing
description: >-
  Load before writing any captain-facing text: chat replies, escalations, decision requests, status digests, and Lavish board copy.
  Owns the ASD-STE100 (Simplified Technical English) sentence-level writing standard for everything the captain reads.
user-invocable: false
metadata:
  internal: true
---

# Captain-facing writing

Every message, escalation, decision, status digest, and Lavish board the captain reads follows the ASD-STE100 writing practice in this skill.
ASD-STE100 (Simplified Technical English) is a licensed standard with a copyrighted controlled dictionary.
Apply its writing rules.
Do not reproduce its dictionary or word list.
Do not claim certification against the standard.
`AGENTS.md` section 9 owns the vocabulary, channel, and etiquette rules for captain-facing text.
This skill owns only the sentence-level writing standard, and section 9's terms stay in force.

## Writing rules

- Put one idea in each sentence.
- Keep an instruction sentence to about 20 words.
- Keep a descriptive sentence to about 25 words.
- Use active voice.
- Write an action the captain must take as a direct imperative.
- Use simple, common words.
- Prefer the short familiar word over the long or ornate one.
- Use one term for one concept.
- Use that same term every time.
- Do not use idiom, metaphor, slang, or unexplained jargon.
- Do not put more than three words in a noun cluster.
- Break a longer cluster with a preposition or a verb.
- Keep one topic in each paragraph.
- Keep each paragraph short.

## Lavish board copy

The same rules apply to every board line the captain reads.
This includes the card title, the `about` and `decide` lines, and every option label and option hint.
Keep one term for one concept across the whole board.
A card, its options, and the chat message then name the same thing the same way.
Write an option label as a short name for the outcome.
Write an option hint as one sentence that states what that option does.

## Worked examples

Each example below follows the rules above.
Check a draft against these examples.

### Example A: a final reply

Captain, the password reset fix is complete.
The change is ready for your review at https://example.com/pull/42.
This fix stops an attacker from resetting another person's password.
Do you want me to merge this pull request?

### Example B: a Lavish board card

Card title: Choose the password reset fix

About: The password reset fix is ready for your review at https://example.com/pull/42. It stops an attacker from resetting another person's password.

Decide: Do you want me to merge the fix, or wait for more work?

Option label: Merge the fix now
Option hint: This choice accepts the fix and puts it in the live product.

Option label: Wait for more work
Option hint: This choice keeps the fix out of the live product until you ask for more work on it.

### Example C: an unsolicited warning

Captain, I found a security problem during routine work on the billing project.
An attacker can read any customer's saved payment card number.
The attacker needs no password.
Every customer who saved a card is at risk now.
The problem is in the live product.
I have not changed anything yet.
Do you want me to stop other work and fix this problem now, or do you want a written report first?
