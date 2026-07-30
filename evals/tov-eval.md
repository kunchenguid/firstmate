<!--
FIRST-PASS INFERENCE — not yet reviewed by Brandon directly. Rewritten from the pack's
original Nick-voice eval (resources/modern-ai-productivity-pack/03-evals/tov-eval.md in the
command-center repo) using Brandon Quijano's own voice/tone reference docs, which were
themselves already distilled from his shipped writing. Sources, all read at command-center
repo root unless noted:
  - shared/content-machine/voice.md   (master pillar — who Brandon is when he writes;
    itself derived from ~/.claude/USER.md, businesses/monetized-mind/content/core-story.md,
    businesses/monetized-mind/content/magnum-opus.md, businesses/brandonq/03-Marketing/brand-voice/)
  - shared/content-machine/tone.md    (master pillar — sentence-level mechanics, vocabulary
    lists, structural patterns, the 10-point publish checklist)
  - businesses/brandonq/03-Marketing/brand-voice/voice.md   (BrandonQ brand overlay)
  - vault/Creator/Videos/"PERSONAL BRAND MANIFESTO — Brandon Q.md"   (a first-person script
    in Brandon's own byline; used to sanity-check the rules below against real fragments -
    e.g. it confirms he uses em dashes and short rhetorical fragments on purpose, which is
    why this eval does NOT zero-tolerance em dashes the way Nick's original did)
Correct this file directly once Brandon reviews real samples against it; until then treat
every rule below as a best-effort inference, not a confirmed tell.
-->

# EVAL: Tone of Voice — "Does this sound like Brandon?"

**Applies to:** any written deliverable in Brandon's voice (LinkedIn/X posts, newsletter or
magnum-opus copy, video scripts, community replies, cold email, ad copy).
**Reference corpus:** `shared/content-machine/voice.md` + `tone.md` (master pillars) and the
relevant `<brand-voice>/voice.md` overlay for the brand being written for, all in the
command-center repo. Read those before grading, not just this file — this eval is a
compressed checklist, they are the source of truth.

## Hard fails (any ONE = FAIL)

1. **Banned vocabulary.** "Leverage" (used unironically), "synergy", "holistic", "empower",
   "unlock", "skyrocket", "game-changer"/"game-changing"/"revolutionary", "journey" (unless
   a literal client business journey), "in today's [adjective] world/landscape/era", "let me
   ask you a question", "I'll never forget the day". One instance = FAIL.
2. **Throat-clearing open.** First sentence is not stakes, a contrarian frame, or a specific
   number — e.g. it warms up, apologizes, or scene-sets before getting to the point.
3. **Hedging.** "Perhaps", "potentially", "it could be argued", "I think maybe", "it is
   important to note that". Brandon states what he knows and cuts the rest.
4. **Passive voice on Brandon's own actions.** "A framework was built" where it should be "I
   built a framework." Operators do things; they don't have things done to them.
5. **Begging-engagement closer.** "What are your thoughts?" / "Drop a 🔥 if this resonates" /
   "Let me know if this resonates" with no real question behind it. Closers are a statement
   or a specific CTA.
6. **Em-dash overload.** More than one em dash in a single paragraph. (Brandon uses them —
   earned, to signal a pivot — not as a tic; one per paragraph max, not zero.)

## Soft checks (2+ misses = FAIL)

- **Sentence length.** Working zone is 6-14 words; short-short-then-longer rhythm. A run of
  long, unbroken sentences is off.
- **Paragraph length.** 1-4 sentences, and at least one single-sentence paragraph on a
  load-bearing line for a piece of any length.
- **Specificity.** Dollar figures, time windows, named mechanics beat vague claims ("$14K/mo"
  not "a lot", "in 5 days" not "fast").
- **At least one of the Five Anchors** visible in anything substantive: the Clock (the
  18-month deadline), the Math (specific numbers), the Gap (a named diagnostic frame, e.g.
  "the Delivery Gap"), the Named Mechanic (a proper-noun framework), or In Public (real
  deals/numbers as proof, not claims).
- **At least one structural pattern used on purpose**, not accidentally: stakes-first open,
  negation stack ("Not X. Not Y. Not Z. [affirmative]"), anaphora (repeated opener across
  lines, each carrying new content — not empty rule-of-three padding), a bold single-line
  standalone sentence, or a hard finisher.
- **Reads aloud cleanly.** If you can't imagine Brandon saying it out loud without editing,
  it's off — voice is the conversation, text is footnotes.
- **Peer register, not guru register.** "Here's what I'd check" / "here's what I ran", never
  "you should" or "let me teach you."

## Notes on what this eval deliberately does NOT hard-fail

Unlike the original Nick-voice eval, this version does not zero-tolerance em dashes or treat
"It's not X, it's Y" contrast constructions as an automatic tell — Brandon's own reference
docs and sampled writing show him using negation stacks and earned em dashes on purpose as
named structural patterns, not as accidental LLM artifacts. Formalized abbreviations
(tl;dr, imo) and contraction habits are not documented in the source material either way;
do not hard-fail on them until Brandon's own samples confirm a rule.

## Output contract

```
VERDICT: PASS | FAIL
VIOLATIONS: [list each with the offending quote]
REWRITE: [if FAIL: the corrected version, changing ONLY what violated]
```
