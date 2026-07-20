---
name: fleet-quota
description: >-
  Show combined subscription headroom across every agent provider before dispatching work, so harness and model are chosen against real remaining quota.
  Merges quota-axi (authoritative for Codex, and Grok when signed in) with the /opt/claude multi-seat balancer (the five Anthropic seats with 5h and 7d usage, rate-limit flags, and the balancer's own pick), and prints one summary plus an evidence-backed dispatch recommendation.
  Load when the captain asks about quota, headroom, or remaining capacity; before a spawn when capacity is uncertain; or when Claude, GPT/Codex, or Grok routing is being discussed.
  Read-only: it never mutates the active account or selects a seat.
user-invocable: true
metadata:
  internal: true
---

# fleet-quota

One place to see remaining subscription headroom across the whole fleet before dispatching a worker.
Run the tool, read its summary, and let its recommendation inform the harness and model choice for the next spawn.

## When to load

- The captain asks about quota, headroom, remaining capacity, or "which account/harness has room".
- Before a spawn when capacity is uncertain and picking the wrong provider would rate-limit.
- When Claude vs GPT/Codex vs Grok routing is being discussed for a task.

## Run it

```
bin/fm-quota.sh            # human-readable combined summary + recommendation
bin/fm-quota.sh --json     # combined machine-readable object for scripts
bin/fm-quota.sh --provider codex,grok   # restrict the quota-axi half
```

`bin/fm-quota.sh --help` is the authoritative owner of flags, environment overrides, the JSON shape, and the recommendation logic.

## What it reports

- Per-provider remaining headroom from `quota-axi` (Codex is authoritative; Grok/Cursor/Copilot show when signed in).
- The five Anthropic seats from the `/opt/claude` balancer: per-seat 5h usage, plan-wide 7d usage, rate-limit flags, and the balancer's current pick.
- One evidence-backed dispatch recommendation (claude-opus / pi-codex / pi-grok, or the DeepSeek `ds` fallback when nothing subscription-backed has room), scored by remaining headroom.

## Portability and boundaries

- Fail-soft: a host without `/opt/claude` still gets quota-axi-only output; a host without `quota-axi` still gets the balancer's Claude seats; both absent still produces a valid answer.
- No secrets: output carries usage percentages, status strings, and seat labels only, never credentials or tokens.
- Advice, not routing: this tool does not change accounts or dispatch anything.
  `bin/fm-dispatch-select.sh` owns the deterministic `quota-balanced` strategy; feeding multi-Claude into that selector is a separate follow-up, not part of this skill.

## Why not extend quota-axi for multi-Claude

quota-axi's Claude provider is single-OAuth by design (it reads one `~/.claude/.credentials.json`, with no config-dir override), and quota-axi ships as a compiled `dist/` build from the external `kunchenguid/quota-axi` repo, so an in-repo patch would be overwritten on update.
The `/opt/claude` balancer already tracks all five seats natively from a local usage database without hammering the Claude quota endpoint (which rate-limits after a single probe).
So the multi-Claude view comes from the balancer, and this skill combines the two sources rather than forking quota-axi.
