# README content architecture

## The first-screen test

Without scrolling, a new visitor should understand:

1. What is this?
2. What can it do for me?
3. What should I look at next?

The hero should answer the first two. The next module should provide proof.

## Plain-language sequence

Use this sequence unless the repository has a stronger information need:

```text
Value → Proof → Mechanism → First use → Detail
```

Do not begin with architecture, contributor instructions, a command, or a long table of contents when the project is unfamiliar.

## Editing rules

- Replace internal jargon with a concrete outcome.
- Explain the mechanism once; remove repeated versions of the same promise.
- Put the shortest working install path before advanced configuration.
- Keep limitations visible when they affect user choice.
- Prefer one example that succeeds end-to-end over many disconnected snippets.
- Use “we” or direct language when it reduces distance, but do not fake community size.

## Visual-to-text division

Use visuals for hierarchy, identity, comparison, sequence, and proof. Use Markdown for explanation, commands, API details, links, compatibility, and contribution instructions.

If a sentence needs to be copied, searched, translated, or frequently updated, keep it out of SVG.
