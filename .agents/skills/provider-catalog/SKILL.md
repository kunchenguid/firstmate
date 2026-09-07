---
name: provider-catalog
description: Agent-agnostic provider and model catalog for the Cloudflare AI Gateway `opencode` gateway — provider roles, gateway URL segments, token location, retry semantics, and live statuses. Use when checking which provider/model to use, routing through the gateway, or debugging provider auth/URLs across pi, opencode, or any other agent.
---

# Provider Catalog

All agent providers route through Cloudflare AI Gateway `opencode` (BYOK). This skill is the shared, agent-agnostic reference; per-agent chain *design* lives in each agent's own config (`~/.pi/fallback-chains.json` for pi, `~/.config/opencode/opencode-fallback.jsonc` for opencode).

**Live quota and headroom come from `quota-axi`, never from this catalog** — cost/limit rows here are reference facts, not usage state.

Read `references/PROVIDERS.md` for the provider table, gateway URL segments, BYOK mechanics, and known live statuses.

## Deterministic dynamic-route audit

Route health prefers `~/.config/opencode/scripts/dynamic-audit.mjs` (scheduled; hourly cron), never a live LLM probe: transcript at `~/.local/state/opencode-fleet/dynamic-audit.jsonl` ("dynamic-audit.jsonl"). See `references/PROVIDERS.md` §"Deterministic dynamic-route audit" for the test list, log schema, and the interactive-LLM interrogation procedure. Ask the captain before mutating any gateway route — `served_model` counts in the audit log are the evidence base.
