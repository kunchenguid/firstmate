---
name: human-text-discipline
description: >-
  Agent-only writing discipline for text a human reads for its own sake.
  Use before writing or editing a pull request body, a commit message, or a captain-facing chat message.
  Owns the checkable list of AI tells and their fixes, plus the positive target that keeps corrected prose from reading as sterile.
user-invocable: false
metadata:
  internal: true
---

# human-text-discipline

Load this before writing or editing text a person reads directly: a pull request body, a commit message, or a captain-facing message.
Its companion is `agent-doc-discipline`, which disciplines documents an agent consumes to act; that skill's test is that a fresh session can act on the document, while this skill's test is that a person reads the text as written by a person for them.
It is not a second owner of `AGENTS.md` section 9.
Section 9 owns what a captain-facing message must contain and how internal terms are translated.
This skill owns how the prose reads once that content is decided.
Where they meet, section 9 decides substance and this skill decides wording, and neither restates the other.

Not for documents an agent reads: those follow `agent-doc-discipline`.
Not for maintained project prose: those follow the audience owner in `docs/documentation-audiences.md`.

## The other failure: sterile prose

Removing tells is half the job.
Flat, voiceless text is as obviously machine-made as purple text, so the rewrite must also add a human signal.
Four moves carry most of it:

- Hold an opinion instead of neutrally listing both sides.
- Vary sentence length: a short sentence, then a longer one that takes its time.
- Admit complexity, because "impressive and a little unsettling" beats "impressive".
- Be specific, because a name, a number, or a concrete detail is the strongest human signal there is.

## The tells

Each entry names the observable pattern and the fix.
Scan for the pattern, apply the fix, then confirm the fix did not flatten the sentence.

### Content

1. Puffery: "pivotal moment", "testament to", "evolving landscape", "setting the stage", "indelible mark".
   Delete it and state what actually happened.
2. Promotional adjectives used as praise: "vibrant", "groundbreaking", "renowned", "seamless", "robust", "cutting-edge".
   Replace with a neutral description or a number.
3. Superficial "-ing" tails: a comma followed by "highlighting", "ensuring", "showcasing", "reflecting", or "fostering" with no fact after it.
   Cut the tail, or expand it into the concrete fact it gestures at.
4. Vague attribution: "experts believe", "industry reports suggest", "it is widely regarded".
   Name the source or delete the claim.
5. Formulaic framing: "Despite the challenges, X continues to thrive".
   Replace it with the specific facts behind the framing.
6. Generic conclusion: "The future looks bright", "This is a big step forward".
   State the specific next step or result, or delete the sentence.

### Diction

7. Fancy ways to say "is": "serves as", "stands as", "boasts", "features", "represents".
   Use "is" or "has".
8. "Not just X but Y", and its cousin "It is not merely X, it is Y".
   State the point directly instead of staging it as a contrast.
9. AI vocabulary: additionally, crucial, delve, enhance, foster, garner, interplay, intricate, landscape (abstract), pivotal, showcase, tapestry, testament, underscore, vibrant.
   Replace with the plain word a person would say.
10. Abstract metaphor nouns: substrate, wedge, vector, locus, nexus, primitive, harness (as metaphor), surface (as in "API surface"), bedrock, scaffolding, flywheel, north star.
    Use the concrete word the metaphor stands for.
11. A feeling instead of a fact: "the database stays close at hand".
    Name the mechanism or the number the reader can act on.
12. A weak verb propped up by an adverb: "significantly improves", "runs quickly".
    Use a stronger verb or the measured number.
13. Hedging: "could potentially possibly", "it might be argued that".
    Reduce it to the single honest word, such as "may".
14. Filler: "in order to", "due to the fact that", "it is important to note that".
    Use "to", "because", or delete it.
15. Synonym cycling: protagonist, main character, central figure, hero all in one paragraph.
    Pick one word and repeat it.
16. The plain word: "utilize" becomes "use", "leverage" becomes "use", "facilitate" becomes "help", "numerous" becomes "many", "in the event that" becomes "if".
    The fancier synonym is rarely clearer.

### Structure

17. Forced rule of three: ideas padded or trimmed to arrive in threes.
    Use the natural number, even when that is two or four.
18. False ranges: "from X to Y" where X and Y are not on a meaningful scale.
    List the items directly.
19. Dense sentences the reader must backtrack to parse.
    Split into two sentences or drop a clause, one idea per sentence.
20. Passive voice that hides a known actor: "queries are validated".
    Name the actor: "the compiler validates queries".
    Passive stays only when the actor is unknown or genuinely irrelevant.

### Mechanics

21. An em dash as punctuation.
    End the sentence or use a comma, never a dash, an en dash, or parentheses as a substitute.
22. A colon as a mid-sentence connector: "If you are coming from X: instead, do Y".
    Rewrite so the point stands on its own without the comparison framing.
23. Boldface on every proper noun or acronym.
    Bold only what a scanner must find.
24. Inline-header list items whose bold label restates the line: "**Performance:** Performance improved".
    Convert them to prose; a bold lead-in that names the item and is followed by genuinely new detail is fine, not a tell.
25. Title case headings.
    Use sentence case.
26. Decorative emojis in headings or bullets.
    Remove them.
27. Curly quotes.
    Use straight quotes.
28. Chatbot phrases: "Of course!", "I hope this helps!", "Let me know if you need anything else".
    Remove them.
29. Sycophantic openers: "Great question!", "You are absolutely right!".
    Respond directly to the substance.

## Before you send

Ask one audit question: what still makes this obviously machine-written?
Walk the tells above once more against the answer.
Then confirm the positive side survived the edit: at least one opinion, at least one sentence that breaks the rhythm, and at least one specific name or number where generality was possible.
