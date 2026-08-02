# Provenance of the bundled planning disciplines

These files are vendored copies of Matt Pocock's public skills, kept here so the `planner` skill can hand them to a planner worker by absolute path on any runtime.
They are reference documents read by path, never installed skills.

## Upstream

- Source: https://github.com/mattpocock/skills
- Commit: `2ab958093e83e0ec752e6c1c5932da465bf23e0c`
- Commit date: 2026-07-28
- Vendored: 2026-08-02
- License: MIT, Copyright (c) 2026 Matt Pocock, retained verbatim in [`LICENSE`](LICENSE) beside this file.

## Why the files are named this way

No bundled file is named `SKILL.md`, and none sits one level under a skills root.
Harnesses discover skills by scanning `<skills-root>/*/SKILL.md`, so this layout keeps the bundle off every harness's skill index.
That buys two things: the bundle costs no context in any session that never opens it, and it can never shadow or be shadowed by a separately installed copy of the same skill.

The flat names also keep the bundle from colliding with a locally installed copy at `.agents/skills/<name>/`.
A locally installed copy is typically listed in `.git/info/exclude`, and git silently overwrites an ignored working-tree file on a fast-forward rather than refusing.
Tracking these files at their upstream paths would therefore destroy a captain's local installs without a warning, on every home that updates.

| Bundled file | Upstream path |
| --- | --- |
| `grilling.md` | `skills/productivity/grilling/SKILL.md` |
| `grill-me.md` | `skills/productivity/grill-me/SKILL.md` |
| `grill-with-docs.md` | `skills/engineering/grill-with-docs/SKILL.md` |
| `domain-modeling.md` | `skills/engineering/domain-modeling/SKILL.md` |
| `domain-modeling.CONTEXT-FORMAT.md` | `skills/engineering/domain-modeling/CONTEXT-FORMAT.md` |
| `domain-modeling.ADR-FORMAT.md` | `skills/engineering/domain-modeling/ADR-FORMAT.md` |
| `tdd.md` | `skills/engineering/tdd/SKILL.md` |
| `tdd.tests.md` | `skills/engineering/tdd/tests.md` |
| `tdd.mocking.md` | `skills/engineering/tdd/mocking.md` |
| `to-spec.md` | `skills/engineering/to-spec/SKILL.md` |
| `to-tickets.md` | `skills/engineering/to-tickets/SKILL.md` |

`domain-modeling` is bundled because `grill-with-docs` delegates to it.
`tdd` is bundled as the acceptance-seam reference the planner consults when shaping a test contract; the planner never executes its loop.

## What was changed, and nothing else

Every body is upstream's, except the lines below.
Front matter is untouched, so a later refresh diffs cleanly against upstream.

| File | Upstream | Bundled |
| --- | --- | --- |
| `grill-me.md` | ``Run a `/grilling` session.`` | ``Run a grilling session: read and follow `grilling.md` beside this file.`` |
| `grill-with-docs.md` | ``Run a `/grilling` session, using the `/domain-modeling` skill.`` | ``Run a grilling session: read and follow `grilling.md` beside this file, using `domain-modeling.md` beside this file.`` |
| `domain-modeling.md` | relative links to `CONTEXT-FORMAT.md` and `ADR-FORMAT.md` | the same targets under their bundled names |
| `tdd.md` | relative links to `tests.md` and `mocking.md` | the same targets under their bundled names |
| `tdd.md` | ``It belongs to the review stage (see the `code-review` skill), not the red → green implementation cycle.`` | the same sentence without the pointer to an unbundled skill |
| `to-spec.md`, `to-tickets.md` | ``run `/setup-matt-pocock-skills` if not`` | take the tracker and label vocabulary from the target project's established conventions, and never run a setup skill that writes configuration into the project |
| `to-tickets.md` | ``depends on the tracker `/setup-matt-pocock-skills` configured`` | depends on the tracker the project already uses |

Three upstream skills are deliberately **not** bundled:

- `setup-matt-pocock-skills` writes `docs/agents/*.md` and edits the project's `AGENTS.md` or `CLAUDE.md`.
  A planner never writes project configuration, and firstmate never writes a project's `AGENTS.md` directly, so its job is replaced by the planner's read-only tracker-resolution step.
- `code-review` and `diagnosing-bugs` belong to review and diagnosis lifecycles that keep their own owners.

The per-skill `agents/openai.yaml` display metadata is omitted; it configures an installed skill's interface, which this bundle deliberately does not have.

## Refreshing the bundle

Re-copy from a current upstream checkout, then re-apply exactly the table above.
Update the commit pin and the vendored date here in the same change.
Adapt only paths, issue-tracker assumptions, and delegation wording; anything further belongs in the `planner` skill, which is the owner of how these disciplines are used.
