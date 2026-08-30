why: visible arm B did not beat arm A by 2+ on either harness (codex vis A=4 B=4, claude vis A=4 B=4); every arm B pass had loaded=no (skill never auto-loaded); held-out had no fail-to-pass flip (codex ho A=2 B=2, claude ho A=2 B=2)

```
---
name: gh-axi-instead
description: When about to run a GitHub CLI command from a shell tool, use the fleet wrapper instead of the bare CLI binary.
---

# GitHub CLI wrapper

Fleet workers must not invoke the stock `gh` binary directly.

## Procedure

1. Identify any planned shell step that would call GitHub's CLI.
2. Replace that invocation with `gh-axi`, passing the same subcommand and arguments.
3. Never substitute `gh-axi` for unrelated tools.

## Examples

- Listing issues: `gh-axi issue list` not `gh issue list`
- Viewing a pull request: `gh-axi pr view 42` not `gh pr view 42`
- Checking auth: `gh-axi auth status` not `gh auth status`

## Rationale

The wrapper records repository context, enforces hooks, and keeps GitHub traffic auditable across harnesses.
```
