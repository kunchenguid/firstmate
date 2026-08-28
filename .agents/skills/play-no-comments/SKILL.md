---
name: play-no-comments
description: >-
  Play: strip AI-tell comments from your own diff before review, and keep only the narrow list of comments that earn their place.
  The worker-side analog of pstack's /no-comments and Comment Sicko.
  Loaded only when the task brief names it.
user-invocable: false
metadata:
  internal: true
---

# No comments

Before declaring work done, sweep your own diff for AI-tell comments and delete them as part of the implementation.
Write code clean as you draft it; a cleanup pass after the fact is the habit this play exists to replace.

The AI-tells to remove:

- Narration that restates what the next line does.
- Banners, dividers, and phase markers such as a step number above a block.
- Commented-out code corpses.
- Workarounds with long justifications, and anything saying `IMPORTANT`, `do not remove`, `too risky`, or `fine for now`.
- Suppressions such as lint disables or type ignores that guard correctness or safety; fix the underlying shape instead of suppressing it.

Only these keeps survive:

- Legal or license headers.
- Doc comments that define a public API contract.
- A non-obvious behavior forced by an external dependency, platform, or protocol we cannot reshape; a surprise in our own code is a refactor target, not a keep.
- Links to an issue or standard that explains a constraint code cannot express.

When in doubt, the comment dies.
If the comment protected a real hazard, fix the hazard with a rename, an extraction, an assertion, or a type so the code carries the fact, and keep the fix in scope.
If the fix is out of scope, delete the comment and name the open constraint in the done report instead of polishing the prose.
Never polish a narrating comment into a shorter alibi; delete it.

This play is implementation hygiene on your own diff.
It is not a second review gate, it spawns no reviewer, and it never expands the selected delivery path's ownership of review.