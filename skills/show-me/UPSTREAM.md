# Upstream provenance

This directory vendors a third-party skill; firstmate did not author its content.

| Field | Value |
|---|---|
| Skill name | `show-me` |
| Upstream project | HumanLayer |
| Upstream path | `skills/show-me/SKILL.md` in the HumanLayer public skills repository |
| Companion reference vendored | `visual-pr`'s `show-me` reference from the same repository |
| Retrieved | 2026-09-28, by the firstmate home that commissioned this vendor copy |
| Retrieval method | GitHub contents API, stored verbatim before vendoring |
| License | MIT, upstream copyright (c) 2026 HumanLayer |
| License text | [upstream-LICENSE.txt](upstream-LICENSE.txt), copied verbatim |
| Vendored bytes | [SKILL.md](SKILL.md) |
| Upstream fingerprint | SHA-256 `434a2346cc95e313b0d367d477dda2e23ba642dd2181757415a09500664af100` at retrieval |

## What is original here and what is not

- [SKILL.md](SKILL.md) is the upstream file byte-for-byte: same frontmatter, same diagram menu, same judgement note.
  Nothing upstream was rewritten, reordered, deleted, or reworded, and no firstmate sentence was inserted into it.
- [upstream-LICENSE.txt](upstream-LICENSE.txt) is the upstream license byte-for-byte.
- [FIRSTMATE.md](FIRSTMATE.md) is firstmate-authored delivery adaptation.
  It lives beside the vendored file rather than inside it, so the vendored body stays a single-freestanding-upstream-copy and the local additions stay separable and deletable.
- This repository makes no originality claim over the upstream body.

## Why the adaptation is a sibling file rather than an appended section

Pi's `/skill:name` command reads exactly one file: the skill's own `SKILL.md`, with its frontmatter stripped.
That was confirmed by reading the installed pi 0.84.2 package source, not inferred from a changelog.
Appending firstmate prose to the vendored body would have broken the byte-for-byte guarantee while still being loaded, so both properties could not be kept by appending.
Keeping it as a sibling keeps the vendored copy verifiable, at the cost documented in [FIRSTMATE.md](FIRSTMATE.md): a forced skill load does not automatically deliver the sibling, so the pointer has to be explicit.

## Local material held for audit

The three files the vendor copy was checked against - the upstream `SKILL.md`, the `visual-pr` reference, and the upstream license - are also kept in the commissioning firstmate home's private task record at `data/fm-show-me-skill/upstream/`.
That directory is gitignored private state, so this table plus the vendored license are the tracked record of provenance.

## Removing this vendor copy

Delete the `skills/show-me/` directory.
It carries no scripts, no installed package, no registration in any config, and no hook into firstmate's supervision chain, so removal leaves nothing behind.
