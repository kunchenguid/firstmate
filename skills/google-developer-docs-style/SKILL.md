---
name: google-developer-docs-style
description: >-
  Apply Google developer documentation style to technical prose.
  Use before writing or editing project documentation, READMEs, ADRs, operator guides, error messages, UI copy, or PR descriptions that should follow Google developer documentation conventions.
---

<!-- maintainers: public installer-facing skill. Procedure owner for both firstmate and project workers. Firstmate loads `.agents/skills/google-developer-docs-style/SKILL.md`, a stub that points here. -->

# google-developer-docs-style

Apply [Google developer documentation style](https://developers.google.com/style) to technical prose.
This skill distills agent-actionable procedures.
It does not copy the live guide into Git.
Use official URLs as the lookup owner when this skill points you there.

## When to load

Load before writing or editing:

- READMEs, ADRs, and architecture or operator guides
- API, CLI, or product reference pages
- Error messages, UI copy, and in-product help
- Pull request descriptions and release notes aimed at developers

For general prose clarity outside Google documentation conventions, load `writing-clearly-and-concisely` only when a non-Google grammar or rhetoric question remains after applying this skill.

## Scope and overrides

Resolve style in this order:

1. Project-specific style for the repo or product you are documenting.
2. This skill and the official Google guide it summarizes.
3. Third-party references the Google guide names when steps 1 and 2 do not answer the question:
   - Spelling: [Merriam-Webster](https://www.merriam-webster.com/)
   - Nontechnical style: *The Chicago Manual of Style*, 17th edition
   - Technical style: [Microsoft Writing Style Guide](https://learn.microsoft.com/en-us/style-guide/welcome/), when its guidance fits your domain

When the Google guide and a project rule conflict, follow the project rule and stay consistent within the document.

This skill does not override Firstmate captain-facing chat rules in `AGENTS.md` section 9.
It does not override Firstmate tracked Markdown repo rules such as one sentence per line, plain dashes, or no agent co-author.
Apply those repo rules to firstmate shared tracked material even when this skill would choose different formatting for product documentation elsewhere.

## Installation

Copy or link this directory into a project worker's skill discovery path:

- `.agents/skills/google-developer-docs-style/` (recommended)
- `.claude/skills/google-developer-docs-style/` (Claude Code)

From the firstmate repository, the source path is `skills/google-developer-docs-style/`.
Installers such as [skills.sh](https://skills.sh) can add the same directory from the published firstmate repo.

## Project AGENTS.md trigger

Add this exact line to the project's always-loaded agent instructions when the project adopts Google developer documentation style:

```md
- `google-developer-docs-style` - load before writing or editing project documentation, READMEs, ADRs, operator guides, error messages, UI copy, or PR descriptions that should follow Google developer documentation style.
```

## Authoritative lookup

Start from these Google guide entry points, then follow cross-references inside the guide:

- [Highlights](https://developers.google.com/style/highlights)
- [Voice and tone](https://developers.google.com/style/tone)
- [Text-formatting summary](https://developers.google.com/style/text-formatting)

Do not scrape or vendor the full guide, the word list, or third-party references into Git.

## Voice and tone

Write like a knowledgeable friend who respects the reader's time.

- Be conversational, friendly, and respectful without slang, zaniness, or hype.
- Prefer clear, direct sentences over formal or flowery phrasing.
- Avoid buzzwords, jargon, clichés, pop-culture references, and culturally specific jokes.
- Avoid "simply", "just", "easy", and "quickly" in procedures.
- Avoid "please" in step-by-step instructions.
- Avoid exclamation marks except where the product truly requires them.
- Do not pre-announce future features in documentation.
- Write for a global audience with varying English proficiency.
- See [Write for a global audience](https://developers.google.com/style/translation) and [Write accessible documentation](https://developers.google.com/style/accessibility).

## Person, voice, and sentence shape

- Address the reader as **you**, not **we**, unless **we** clearly means your organization in narrative context.
- Use active voice so the actor is obvious.
- Put conditions, prerequisites, and scope **before** instructions, not after.
- Prefer short sentences; break up dense paragraphs with headings and lists.
- Define acronyms on first use when they are uncommon in the document.

## Headings and titles

- Use sentence case for document titles, section headings, and navigation labels.
- Follow a logical heading hierarchy without skipping levels.
- Make headings descriptive so they make sense out of context.
- Details: [`references/lists-and-headings.md`](references/lists-and-headings.md)

## Lists

- Use numbered lists for sequences, steps, and ordered priorities.
- Use bulleted lists for unordered options, examples, or collections.
- Use description lists for term-and-definition sets or run-in headings with explanations.
- Introduce most lists with a complete sentence, not a fragment completed by the list.
- Keep list items in parallel grammatical form.
- Use serial commas in inline and comma-separated lists.
- Details: [`references/lists-and-headings.md`](references/lists-and-headings.md)

## Text formatting

- Put code, filenames, class and method names, HTTP status codes, console output, and placeholders in code font.
- Put UI element labels in **bold**, not code font.
- Use italics sparingly for introducing terms or semantic emphasis, not for routine stress.
- Reserve underlining for link text.
- Do not override global font, size, or color for decoration.
- Use `and`, not `&`, in headings and body text unless reproducing a UI label that contains `&`.
- Details: [Text-formatting summary](https://developers.google.com/style/text-formatting)

## Dates and times

- Prefer spelled-out dates: `January 19, 2017`.
- Use the 12-hour clock with a space before AM or PM: `3 PM`, `3:45 PM`.
- Avoid ambiguous numeric-only dates such as `04/05/09`.
- When numeric-only dates are required, use ISO 8601: `2017-04-15`.
- Avoid seasons; name months or quarters instead.
- Details: [Dates and times](https://developers.google.com/style/dates-times)

## Links and cross-references

- Use link text that describes the destination, not "click here" or bare URLs in prose.
- Prefer **see** to introduce links and cross-references when it fits naturally.
- Explain unexpected link behavior such as downloads or new tabs.
- Details: [`references/link-and-crossref.md`](references/link-and-crossref.md)

## Accessibility and inclusion

- Write so meaning survives without color, images, punctuation quirks, or directional cues alone.
- Provide alt text for informative images; use empty alt text for decorative images.
- Do not put essential information only in images, tables rendered as images, or icons without labels.
- Avoid directional language such as "above" or "click the icon on the right" when describing UI or document structure.
- Prefer semantic HTML or Markdown structure over visual styling alone.
- Details: [`references/accessibility-and-global.md`](references/accessibility-and-global.md)

## Images

- Provide meaningful alt text that states the image's purpose, not its filename.
- Prefer SVG or high-resolution sources when practical.
- Do not use images of text, code, or terminal output when real text works.
- Details: [Diagrams, figures, and other images](https://developers.google.com/style/images)

## Word list without vendoring

For spelling, capitalization, hyphenation, and preferred product terms, consult the official [word list](https://developers.google.com/style/word-list) at lookup time.
Do not copy the word list into the repo.
Procedure: [`references/word-list-lookup.md`](references/word-list-lookup.md)

## Editorial judgment

This skill states conventions, not a linter.
When a rule would harm clarity for your readers or domain, depart consistently and document the project-specific choice in the project's style owner.
The Google guide itself permits breaking rules when the result is clearer.
