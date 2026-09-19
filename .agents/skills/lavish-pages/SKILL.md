---
name: lavish-pages
description: >-
  Agent-only style contract for captain-facing Lavish pages.
  Load before writing or revising a review, report, or decision page the captain will read.
  Do not load this for the generated fleet board.
user-invocable: false
metadata:
  internal: true
---

# Lavish pages

This skill is the single owner of how a captain-facing Lavish page speaks.
`AGENTS.md` section 9 still owns chat.
The written scout report may keep technical evidence.
The generated fleet board is owned by `bin/fm-bearings-board.sh`, not this skill.

Load this before writing or revising a review, report, or decision page the captain will read.
A scout brief that offers the Lavish loop names this file as a required read before that page is written.
Open the matching `lavish-axi playbook` entries for host and layout recipes; this skill owns captain language and wins when a playbook would put paths, code, identifiers, or completeness into the main flow.
Serve the page with current `lavish-axi` help.

## Contract

A page fails this contract if the captain has to translate it before deciding.

1. **Write in the captain's language.**
   Use the captain's nouns from `AGENTS.md` section 9.
   Translate every internal term on first use; after that, the plain name is enough.
2. **Lead with the decision or the outcome, not the method.**
   The first screen names what is true and what is being asked.
   Survey method, tooling, and how the page was built stay out of the lead.
3. **Keep the main flow human.**
   No file paths, function names, line numbers, identifiers, or raw code in the main flow.
   A clearly separated technical appendix may keep all of that.
4. **Use a table only when comparing like with like.**
   A sentence or a diagram otherwise.
5. **Prefer a diagram over a paragraph for anything with structure.**
   Flow, ownership, sequence, and splits are structure.
6. **Never write "simply", "just", "obviously", or "of course".**
7. **End with the next move.**
   Every page closes with what the captain should do next, or an explicit "nothing needed".
8. **Make it readable on a phone.**
   One column by default.
   Short sentences.
   No wide multi-column tables in the main flow.

Completeness does not disappear: it moves to the appendix.
A page that follows this should still be useful, not thin.
Shortening prose never weakens a safety requirement, an option the captain must see, or a consequence.

## Pass test

Read the first screen aloud.
If a capable person who does not run this fleet would not know the decision and the next move, rewrite the main flow.
