---
name: brain-query
description: >-
  Query firstmate_ops.db for fleet context, decisions, and lessons.
  Load before dispatching a firstmate-repo worker that needs fleet context.
  Teaches workers how to find and use fm-brain.sh, extract compact results,
  and corroborate brain content with live sources.
user-invocable: false
metadata:
  internal: true
---

# brain-query

Query `firstmate_ops.db` for durable fleet context.

## When to load

Load this skill before dispatching a firstmate-repo worker whose brief says
"query the brain" or whose task would benefit from prior fleet knowledge.
Also load when you are about to query the brain yourself outside the normal
session-start digest.

## How to query

The query helper is at `FM_ROOT/bin/fm-brain.sh`:

```
FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$FM_ROOT/bin/fm-brain.sh" query "<question>" <max-results>
```

Do NOT use a relative path — the helper may be absent from a treehouse
worktree checkout. Always resolve from `FM_ROOT` (the firstmate home root).

Example:
```
query=$(FM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) \
  "$FM_ROOT/bin/fm-brain.sh" query "why was N5 declined" 3)
```

The helper returns clean JSON with stderr captured separately.
Under `set -eu`, capture stdout into a variable and parse it:
```
echo "$query" | jq '.hybrid.results[] | {source_key, summary, heading_path, chunk_text}'
```

If `jq` is unavailable, use Python:
```
echo "$query" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
for r in d.get('hybrid', {}).get('results', []):
    print(f'[{r[\"source_key\"]}] {r[\"summary\"]}')
    print(f'  path: {r.get(\"heading_path\",\"\")}')
    print(f'  text: {r.get(\"chunk_text\",\"\")[:200]}')
"
```

## Compact extraction pattern (avoids metadata noise)

The helper output includes FTS/vector metadata and model status that
are not relevant to the answer. Extract only the results:

```bash
# via jq
echo "$query" | jq '.hybrid.results[] | {source_key, summary, chunk_text, heading_path}'

# via python
echo "$query" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
r = d.get('hybrid', {}).get('results', [])
for res in r:
    print('---')
    print('source:', res.get('source_key'))
    print('summary:', res.get('summary'))
    print(res.get('chunk_text', '')[:300])
    print()
"
```

## How to interpret results

Each result has:

| Field | Purpose |
|---|---|
| `source_key` | Which artifact produced this span (e.g. `selection_capsule:fm.dec.n5_declined`) |
| `summary` | One-line description of the finding |
| `heading_path` | Section heading in the source document |
| `chunk_text` | The actual lesson text (may be truncated to ~7500 chars) |
| `status` | `current` or `superseded_by` — a superseded lesson is historical |
| `combined_score` | Hybrid rank score (higher = more relevant) |

## Corroboration rule (MANDATORY)

The brain is **context + history**, NOT authority for:

- Current Git HEAD / branch state
- PR status (open, merged, closed)
- Backlog state
- Quota windows
- Live served status

Always corroborate operational facts with live tools:
- `gh-axi` for GitHub state
- `tasks-axi` for backlog state
- `quota-axi` for window headroom
- Direct `git` for HEAD / branch

A brain query that returns a commit SHA or PR URL is **durable historical**
evidence — check with `gh` or `git` before acting on it.

## Retrieval quality notes

- Broad queries may return unrelated results before relevant ones.
  If the top results are off-target, query more specifically.
  A targeted follow-up query often recovers the correct frame.
- The brain has 100% vector coverage (BGE-small 384-dim) as of 2026-08-06.
- Results are capped at the configured `max_results` (default 5, max 20).
- No live verification is performed — the helper is pure retrieval.

## Friction history

Friction findings from the Luna brain probe (2026-08-06):

1. **Path discovery**: the helper must be resolved from `FM_ROOT`, not a
   relative worktree path, because treehouse checkouts may predate it.
2. **JSON extraction**: the output includes large metadata sections. Use the
   compact extraction pattern above.
3. **Ranking noise**: broad queries may surface unrelated results.
   Query specifically, and follow up with narrower queries.
4. **Claim-ceiling awareness**: the brain's results are explicitly labeled as
   "local retrieval candidates, not truth or freshness proof."
   Always corroborate live.

## Populating the brain (firstmate only)

Only firstmate writes to `firstmate_ops.db`. Workers never write directly.
Workers report findings through the standard closeout flow; firstmate ingests
at closure boundaries (PR merged, scout completed, decision finalized).

Population uses `bin/fm-brain.sh add <task-id> --kind scout|decision --summary "<text>" --ref "<url>"`.

## Multi-brain oracle query (AXI tool)

For cross-brain queries, use the oracle AXI tool:

```
fm-oracle-axi query "<question>" <max-results>
```

This queries all registered brains in the estate and returns merged results
with per-brain attribution. Example:

```
fm-oracle-axi query "UM5 governance rules and engine capabilities" 3
```

Returns JSON with:
- `answers[]` — each brain's results with attribution (brain name, coverage %)
- `errors[]` — any skipped or errored brains with reason
- Per-result source_key, summary, chunk_text, combined_score

### Brain registry

The registry at `data/brains/brain_registry.json` lists all known brains:

- `firstmate_ops` — fleet operations, decisions, scout findings
- `um5_ops` — UM5 engine governance, served runtime proofs
- `crof_ops` — CROF engine knowledge, ARC-AGI study data

### Oracle health check

```
fm-oracle-axi health
```

Returns integrity status of every registered brain. Run before trusting
oracle results from a brain that may be stale or damaged.

### When to use oracle vs single-brain query

- Use **fm-brain.sh query** (single-brain) when: the question is scoped to
  firstmate fleet context only (decisions, captain prefs, ops registry).
- Use **fm-oracle-axi query** (multi-brain) when: the question spans domains
  (e.g., "what do we know about UM5's governance?" needs both firstmate
  scout findings AND UM5's own governance lessons).
- The oracle always returns per-brain attribution — trust claims at the
  brain level (firstmate_ops for fleet context, um5_ops for UM5 internals).
