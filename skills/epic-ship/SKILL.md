---
name: epic-ship
description: Ship a finished epic per repo through the gated flow. Requires the full epic branch to pass no-mistakes first, then wraps bin/fm-epic-ship.sh to open the epic-to-staging test-vehicle PR and, after that merges, the epic-to-production delivery PR (a repo without staging ships one epic-to-production PR). The engine opens or re-reports PRs and records their URLs but NEVER merges - the captain or configured merge authority merges. Use when every story has merged into epic/<slug>. Final skill in the epic pipeline.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of five epic-pipeline skills (epic-new -> epic-scaffold -> epic-review -> epic-handoff -> epic-ship) that share one voice and one output format. This skill DRIVES bin/fm-epic-ship.sh; it must not reimplement that script's PR logic - defer to `fm-epic-ship.sh --help` for the exact contract. -->

# epic-ship

Ship a finished epic per repo through its ordered gates.
The PR mechanics are done by the engine, not by hand:

    bin/fm-epic-ship.sh <slug> <repo>

`fm-epic-ship.sh --help` is the single owner of the exact contract, flags (including `--dry-run`), and overrides - defer to it rather than duplicating them here.

## Preconditions

- Every story in the epic has merged into `epic/<slug>`; the epic is complete on that branch.
- The full `epic/<slug>` branch has passed **no-mistakes** as one whole.
  Per-story no-mistakes does not substitute - the full-epic gate owns validation, and it runs before any delivery PR.

## The gate ordering (do not skip or reorder)

1. Epic complete on `epic/<slug>` - all stories merged in.
2. Run no-mistakes on the whole epic branch. Proceed only when it is GREEN.
3. `bin/fm-epic-ship.sh <slug> <repo>` opens the **epic -> staging** test-vehicle PR, so staging exercises the epic before production.
   A repo with no staging branch ships a single **epic -> production** PR instead.
4. After the staging PR merges, re-run `bin/fm-epic-ship.sh <slug> <repo>` to open the **epic -> production** delivery PR.
5. The captain or configured merge authority merges each PR. The epic closes on the production merge.

The command is idempotent and driven by live git truth, so re-running always does the next right thing: it opens the staging PR, then (once staging contains the epic) the production PR, and it re-reports an already-open PR rather than duplicating it.
When `epic/<slug>` does not merge cleanly into staging, the engine cuts a `resolve-epic/<slug>` branch from staging for a human or agent to resolve, keeping `epic/<slug>` clean for the production PR.

## It never merges

`fm-epic-ship.sh` only opens or re-reports PRs and records their URLs.
Merging is the captain's or the configured merge authority's decision - this skill and the engine never merge, and never merge a red PR.

## Output

Report back exactly this shape:

- **Stage:** ship
- **Epic:** `<slug>` -> repo `<repo>`
- **no-mistakes:** GREEN (required before this step), or stop here if not
- **PR opened:** the full `https://...` URL and its base (staging or production), or the already-open PR the engine re-reported
- **Awaiting:** captain / merge-authority merge
- **next:** after the staging PR merges, re-run /epic-ship for the epic -> production delivery PR; the epic closes on the production merge
