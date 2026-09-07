# Provider & Model Catalog (agent-agnostic)

Shared reference for every agent that routes through Cloudflare AI Gateway `opencode` (BYOK). Per-agent chain design lives in that agent's config, not here. Live quota: use `quota-axi`.

## Chain preference (captain's standing directive — superseded 2026-09-01)

The historical "Lead PGS free band → paid-first through zen → go → GOAT → Z.AI → CF → OpenRouter → Zen → free tail" directive is **superseded for interactive chains** as of 2026-09-01 (decision A v5). The live ladders per agent live in each agent's own config:

- Opencode interactive chains — `~/.config/opencode/opencode-fallback.jsonc` (owner). Now the GLM-5.1 ladder (`big-pickle → opencode-go/glm-5.1 → commandcode/zai-org/GLM-5.2 → openrouter/z-ai/glm-5 → opencode-zen/glm-5.1`) on every `agents.*` and `categories.*` entry; PGS, Cloudflare Workers, Z.AI Coding Plan, and the openrouter `:free` trio are dropped.
- Pi default chain — `~/.pi/fallback-chains.json` → `default` key (added 2026-09-01). Same GLM-5.1 ladder; activates via `fallback/default` model string.
- Pi GATE chain — `~/.pi/fallback-chains.json` → `gate` key (unchanged 2026-09-01, gate-chain v4: openrouter `:free` trio first, gemini-2.5-flash demoted, `phoenixgrove/glm-5.3-flash` kept as manual tail; CF `@cf` and opencode-go excluded: no 1M models in either pool).

Reasoning effort stays low for targeted, well-understood work (e.g. no-mistakes review/fix steps); high reasoning is reserved for ambiguous investigation or design.

**no-mistakes reviewer pin (deterministic):** no-mistakes launches its pi reviewer via `agent_args_override` in `~/.no-mistakes/config.yaml` (tracked here as `dot_no-mistakes/config.yaml`): `[--no-context-files, --model, "fallback/gate"]` — the 1M-only cost-ordered ladder in `~/.pi/fallback-chains.json` (current order documented in the config's prose; see `dot_no-mistakes/config.yaml`). pi-fallback-provider activates on the `fallback/gate` model string: 429/5xx/timeout retryable, 400/401/403 non-retryable with 5-min provider cooldown.

## Cheapest-qualified-lane dispatch rule (spawn selection)

- **Rule:** when a dispatch resolves to multiple *qualified* lanes — lanes that
  meet the task's reasoning-class, capability, and runway gates — prefer the
  cheapest qualified lane, ranked by blended tokens-per-dollar from the current
  catalog snapshot (`models.snapshot.json` in this skill; per-provider rates in
  `PROVIDERS.md` — never duplicated elsewhere).
- **Scope:** applies to dispatch-time selection among eligible lanes
  (unbound sessions and utility classes). Pinned classes keep their pins;
  cheapest-qualified never downgrades a reasoning-class requirement.
- **Relationship to the fallback ladder:** this rule picks the lane *before*
  work starts; the fallback ladder is reactive, stepping only after the active
  lane fails or exhausts. A cheapest-lane choice does not reorder the ladder.

## Gateway routing (BYOK)

All baseUrls sit under `https://gateway.ai.cloudflare.com/v1/a7fa198dd5b359a187c671064fe6b36e/opencode/…` with header `cf-aig-gateway-id: opencode` and the gateway token.

**Token:** `$CF_AI_GATEWAY_TOKEN` (exported from `~/.zshenv`, reading `~/.config/opencode/.cf-ai-gw-token`). The token covers both the `/ai/*` (Workers AI REST) and `/ai-gateway/*` planes. BYOK upstream keys live in the gateway dashboard (alias `default`); clients authenticate with the gateway token only, which the gateway does not forward upstream.

| Provider | URL segment | Notes |
|---|---|---|
| opencode-zen | `custom-opencode-zen/v1` | primary quality (big-pickle) + free tier |
| opencode-go | `custom-opencode-go/v1` | subsidized pool (kimi-k2.6, deepseek-v4-flash) |
| commandcode | `custom-commandcode/v1` | GOAT paid pool (Kimi-K2.6, DS-V4-Flash) |
| zai-coding | `custom-zai-coding/v4` | Z.AI Coding Plan Lite; **`/v4`, not `/v1`** |
| phoenixgrove | `custom-phoenixgrove/v1` | GLM-5.3-flash, deepseek-v4-flash |
| openrouter | `openrouter/v1` | native passthrough slug, **NOT `custom-`** |
| cloudflare | `custom-cloudflare/v1` | @cf lane (Workers AI, free tier) |

**URL version-segment rule:** the gateway strips a trailing version-like segment from the custom provider's `base_url` before appending the request path; carrying the version in the request URL restores correctness.

## Identity tracking (cf-aig-metadata)

All agents route through the same gateway, but the dashboard can distinguish traffic by harness+model+host using the `cf-aig-metadata` header.

### Purpose

1. **Fleet-wide observability**: Track which harness/host combination generates traffic
2. **Cost attribution**: Attribute costs to specific agents/machines
3. **Quota isolation**: See which secondmate or background task exhausts plan windows
4. **Debuggability**: Trace a single task's request chain across the gateway
5. **No upstream exposure**: Metadata stays in gateway logs, never forwarded to providers

### Metadata schema

```json
{
  "harness": "<agent-name>",
  "host": "<machine-hostname>",
  "agent": "<role>"
}
```

**Fields:**
- `harness`: The agent harness name (opencode, pi, claude, codex, kimi-code, muse, grok)
- `host`: The machine hostname (dynamic via chezmoi template)
- `agent`: The agent role on that machine (primary, secondmate-telegram, etc.)

### Harness implementation

| Harness | Config file | Mechanism |
|---------|-------------|-----------|
| OpenCode | `~/.config/opencode/opencode.json.tmpl` | `headers` object in provider config |
| Pi | `~/.pi/agent/models.json.tmpl` | `headers` object in provider config |
| Claude Code | `~/.zshenv.tmpl` | `ANTHROPIC_CUSTOM_HEADERS` env var |
| Kimi-code | `~/.kimi-code/config.toml.tmpl` | `custom_headers` TOML table |
| Codex | `~/.codex/config.toml.tmpl` | `http_headers` in provider config |
| Muse | `~/.config/muse/settings.json.tmpl` | `headers` in `endpoint_transport` |
| Grok | `~/.grok/config.toml.tmpl` | `http_headers` in provider config |

**Example (OpenCode):**
```json
{
  "provider": {
    "cf-aig-dynamic": {
      "options": {
        "headers": {
          "cf-aig-gateway-id": "opencode",
          "cf-aig-metadata": "{\"harness\":\"opencode\",\"host\":\"{{ .chezmoi.hostname }}\",\"agent\":\"primary\"}"
        }
      }
    }
  }
}
```

**Example (Claude Code env):**
```bash
export ANTHROPIC_CUSTOM_HEADERS=$'cf-aig-gateway-id: opencode\ncf-aig-metadata: {"harness":"claude","host":"{{ .chezmoi.hostname }}","agent":"primary"}'
```

### Chezmoi template variables

All harness configs use `.tmpl` extension and interpolate hostname dynamically:

```text
{{ .chezmoi.hostname }}      # Short hostname (e.g., "nasbox")
{{ .chezmoi.fqdnHostname }}  # Fully qualified (e.g., "nasbox.lan")
```

**Fleet deployment:** Each machine automatically reports its own hostname when chezmoi applies the templates — no manual config per machine.

### Dashboard usage

In the Cloudflare AI Gateway dashboard:

1. **Filter by harness**: `metadata.harness == "opencode"`
2. **Filter by host**: `metadata.host == "nasbox"`
3. **Filter by agent role**: `metadata.agent == "primary"`
4. **Cost attribution**: Group by `metadata.harness` and `metadata.host`
5. **Quota isolation**: See which `metadata.agent` exhausts plan windows first

**Note:** The `cf-aig-gateway-id: opencode` header is required for gateway routing; the `cf-aig-metadata` header is additional identity context that appears in logs but doesn't affect routing.

## Hermes integration (fleet job scheduler)

Hermes is a job scheduler, not an AI agent harness. It orchestrates cron jobs and MCP servers that may make AI calls.

### Architecture

- **Hermes**: Cron job runner + API server + MCP host
- **Job scripts**: Shell/Python scripts invoked by Hermes (may make AI calls)
- **MCP servers**: Model Context Protocol servers (may make AI calls)
- **Identity**: Each job/MCP server reports its own identity through gateway

### Configuration

**Config file**: `~/.config/hermes/config.yaml.tmpl`

```yaml
# Hermes doesn't directly make AI calls, but documents gateway routing
# for the scripts it invokes. See ~/.hermes-env for gateway configuration.
```

**Environment file**: `~/.hermes-env.tmpl`

```bash
# Route job scripts through CF AI Gateway with identity tracking
export ANTHROPIC_BASE_URL="https://gateway.ai.cloudflare.com/v1/a7fa198dd5b359a187c671064fe6b36e/opencode/compat"
export ANTHROPIC_API_KEY="${CF_AI_GATEWAY_TOKEN}"
export ANTHROPIC_CUSTOM_HEADERS=$'cf-aig-gateway-id: opencode\ncf-aig-metadata: {"harness":"hermes","host":"{{ .chezmoi.hostname }}","agent":"cron-job"}'

# Model route for scripts to use
export HERMES_MODEL_ROUTE="cf-aig-dynamic/dynamic/TUI"
```

### Job script template

```bash
#!/bin/bash
# Hermes job script with AI gateway routing
set -euo pipefail
source ~/.hermes-env

# Make AI call through gateway with identity tracking
response=$(curl -s -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
  -H "Content-Type: application/json" \
  -H "cf-aig-gateway-id: opencode" \
  -H "cf-aig-metadata: {\"harness\":\"hermes\",\"host\":\"{{ .chezmoi.hostname }}\",\"agent\":\"daily-summary\"}" \
  -d "{\"model\": \"$HERMES_MODEL_ROUTE\", \"messages\": [{\"role\": \"user\", \"content\": \"Generate daily summary\"}]}")

# Process response...
```

### Identity metadata

```json
{
  "harness": "hermes",
  "host": "<machine-hostname>",
  "agent": "<job-name>"
}
```

**Fields:**
- `harness`: Always "hermes" (identifies the scheduler)
- `host`: Machine hostname (dynamic via `{{ .chezmoi.hostname }}`)
- `agent`: Job-specific identifier (e.g., "daily-summary", "mcp-mybrain")

### Fleet deployment

When chezmoi applies these templates to fleet machines:

1. Each machine gets correct hostname in metadata
2. Job scripts automatically route through gateway
3. Dashboard shows which host/job made which AI calls
4. Cost attribution per host and job type

### MCP server integration

MCP servers hosted by Hermes can also use gateway routing:

```python
# mybrain-mcp-server.py
import anthropic
import os

client = anthropic.Anthropic(
    base_url=os.environ["ANTHROPIC_BASE_URL"],
    api_key=os.environ["ANTHROPIC_API_KEY"],
    default_headers={
        "cf-aig-gateway-id": "opencode",
        "cf-aig-metadata": '{"harness":"hermes","host":"' + os.environ.get("HOSTNAME", "unknown") + '","agent":"mcp-mybrain"}'
    }
)

# Use client for AI calls...
```

## Provider roles

| Provider | Role | Cost |
|---|---|---|
| opencode-zen | primary quality (big-pickle) + free tier | free ~200/day / paid |
| opencode-go | subsidized pool | $5 first mo → $10/mo |
| commandcode (GOAT) | paid pool | $10/mo → usage |
| zai-coding | Z.AI Coding Plan Lite, credits-based | $18/mo |
| phoenixgrove | GLM-5.3 exclusive band, free + paid tiers | $4–$195/mo / $5+ per-token |
| cloudflare | Workers AI @cf lane, free tier | $0 |
| openrouter | GLM-5 overflow + free ladder | $0 / pay |

## Model ids

Model ids are the upstream API model names sent through the gateway verbatim — never rename them. Display names may carry a `· CF GW` marker (pi), but pi's picker shows `id [provider]` regardless.

## Gemini 2.5 Flash — limits surfaced live (2026-08-30)

**Model:** `gemini/gemini-2.5-flash` — Google Generative AI (AI Studio), native `google-generative-ai` API type in pi. Input 1,048,576 tok (real 1M), output 65,536, ~0.6 s latency. Key: `~/.config/opencode/.google-key` (AQ.* OAuth-derived token; captain handles rotation on expiry).

**pi wiring rule (verified):** the provider MUST declare `"api": "google-generative-ai"` with `baseUrl https://generativelanguage.googleapis.com/v1beta`. pi's `openai-completions` path 400s against Gemini's OpenAI-compat endpoint: pi (OpenAI SDK) sends OpenAI-only fields — `store: false`, `max_completion_tokens`, `stream_options` — that Gemini's compat layer rejects, and pi 0.84.2 has no compat flag to strip them. The native API type avoids the whole class.

**Surfaced limit (hard wall):** free tier is `GenerateRequestsPerDayPerProjectPerModel-FreeTier = 20 requests/day/model/project`. A no-mistakes run costs ~10–30 model calls across review/test/document/lint/PR agents → **one busy run exhausts the daily budget**. Gemini free tier cannot be a pipeline primary; use as light fallback, or move the Google key to AI Studio paid tier (removes the 20/day wall).

**Reliability quirk:** gemini-2.5-flash intermittently wraps its structured JSON in markdown code fences (```json …```), which pi's output parser rejects → step-level parse failures, nondeterministic (retries usually pass). Treat as a tax when it drives structured-output steps.

**Long-term free 1M-context candidates (ranked):**
1. **`opencode/gemini-3-flash`** via the opencode (zen Console) provider — 1M context, standing free tier (not a promo window), and Console free-tier limits are per-model, so it has its own window separate from big-pickle.
2. **Google AI Studio free** (native key, above) — 20/day wall.
3. **OpenRouter `:free` models with 1M ctx** (e.g. gemini-2.5-flash:free) — 1000/day shared free-tier bucket only while the account holds a $10+ credits balance ("high-balance" tier; our key is exhausted, so currently 50/day).

## Known quirks

- `zai-coding` uses `/v4` in the gateway URL (all others `/v1`).
- `openrouter` keeps the native passthrough slug (`openrouter/`, not `custom-openrouter/`).
- GPT routing (opencode): `opencode/gpt-5.x` works · `opencode-go/gpt-5.x` fails "Model not supported" · `opencode-zen/gpt-5.x` HTTP 400 (chat/completions, not `/v1/responses`).

## pi retry semantics (pi-fallback-provider)

Non-retryable: 400/401/403. Retryable: 429/5xx/timeout. Provider cooldown after failure: 5 min. Per-request timeout: 10 s. Chains referenced as `fallback/<name>` in `~/.pi/agent/settings.json`.

## Live statuses (dated; verify with quota-axi)

- 2026-08-30: big-pickle → FreeUsageLimitError (falls through); zai-coding → 429, weekly reset 2026-09-02.

## PGS coding tester plan (2026-09-01)

Captain holds a PGS coding tester plan covering `deepseek-v4-flash-0731` + `glm-5.3-flash`. Key: `~/.agents/keys/phillias/.phoenixgrove-coding-plan-key` (pgsk_…; deployed to the `phillias` keys profile). Verified plan behavior:

- baseURL unchanged (`https://api.pgsgrove.com/v1`) — zero client config changes; the key swap is a dashboard BYOK update on the gateway's custom-phoenixgrove upstream.
- `/v1/usage` (HTTP 200) returns percent-based windows: `weekly_used_percent`, `daily_used_percent`, `api_share_of_weekly_percent`, `weekly_resets_at` (2026-09-08T01:56Z). No bank/credits endpoint.
- Plan models complete while usage stays 0% → plan-subsidized, NOT per-token. The old PGS key bills per-token (insufficient-credits errors on 2026-08-31 were billing, not path/gateway).

## Free-model probe results (2026-08-31, via gateway)

- `opencode-zen/nemotron-3-ultra-free`: works, tool-calling verified (function call, finish=tool_calls) — best free agentic model.
- `opencode-zen/deepseek-v4-flash-free`: FreeUsageLimitError (busy, retryable).
- `opencode-zen/gemini-3-flash`: 500 via `custom-opencode-zen/v1` (opencode-zen passthrough slug = 400 Invalid provider).
- `custom-cloudflare` @cf lane: 502 code 2006 for both `@cf/zai-org/glm-4.7-flash` and `@cf/deepseek-ai/deepseek-v4-flash` (broken that day; recheck).
- phoenixgrove custom lane serves ~38 models (glm-4.7-flash, qwen-3.8-27b, gemma-4-31b respond); PGS bills per-token on the old key — treat PGS as paid except on the coding plan above.


## Free-lane probe results (2026-09-01, via gateway)

- `custom-nvidia-nim` (`https://integrate.api.nvidia.com/v1` upstream): `nvidia/nemotron-3-super-120b-a12b` 200 OK, 1M ctx. Whole nemotron-3 family on one free `nvapi-` key, BUT ~40 RPM is **account-wide** across all NIM models (shared pool, no SLA, increases never granted) — gate/aux lane, not workhorse. Catalog churns: `nemotron-3-nano-30b-a3b` hit end-of-life 2026-09-01; verify slugs at call time.
- `google-ai-studio` (native gateway provider, BYOK): works via the **native path only** — `/google-ai-studio/v1beta/models/gemini-3.6-flash:generateContent` → 200. The OpenAI-compat `/v1/chat/completions` on that route 404s. Free tier is `$0` tokens with no billing, but the hard wall is **20 requests/day/model/project** (see the Gemini limits section above) — light fallback only, never a pipeline primary.
- `cerebras` (native gateway provider, BYOK): works after paygo migration (+$5 credit, card linked). `gpt-oss-120b` → 200. Live envelope: **5 RPM / 150 per hour / 2,400 RPD, 30K TPM / 1M TPD** — low request rate, big token budget: large single completions, not tool loops. `zai-glm-4.7` is now `model_archived` — Cerebras free catalog is effectively gpt-oss-120b only and churns repeatedly; never hardcode a lone Cerebras model id.
- `custom-phoenixgrove` route verified 2026-09-01 (200) — phoenixgrove now transits the gateway (`custom-phoenixgrove/v1`) instead of direct `api.pgsgrove.com`.
- Workers AI GLM is **metered**, not free: `@cf/zai-org/glm-5.3` $1.40/$4.40 per M in/out, `glm-5.3-flash` $0.15/$0.50 (REST models/search pricing, verified 2026-09-01). The 10K Neurons/day free allowance evaporates instantly on 120B-class agent traffic — avoid GLM on Workers AI for free lanes.
- **GitHub Models: fully retired 2026-07-30** (changelog; live brownout 410 `github_models_retirement_brownout` confirmed 2026-09-01). Do not wire it anywhere.

## Gate chain (pi-fallback-provider)

Chain order is owned by `private_dot_pi/fallback-chains.json` and summarized in `dot_no-mistakes/config.yaml` (gate-chain v4: openrouter :free trio first, gemini-2.5-flash demoted after live performance issues, `phoenixgrove/glm-5.3-flash` kept as manual tail). CF @cf and opencode-go excluded: no 1M models in either pool. opencode-zen gemini-3.5-flash is PAID (zen free tier is sub-1M only).

## Dynamic routes on the `opencode` gateway (2026-09-04)

The gateway runs named dynamic routes (CF "dynamic routing", OpenAI-compatible
endpoint `…/opencode/compat/chat/completions`, model string `dynamic/<name>`).
Route contents will churn — this catalog records *purpose*, not lane lists:

- `TUI` — daily-driver, lowest-version models (GLM-5.1-class or cheapest flash
  variants), **subsidized plans first** (opencode-go → z.ai→ go/zen pools).
- `high` — latest-version models (`GLM-5.3` class, fable, astra when a lane
  appears) from reliable providers; aihubmix GLM discount lane sits top.
- `pr-gate` — free-as-possible 1M-ctx CI/background "second set of eyes"
  ladder; faithful to the hand-tuned pi gate chain.
- `vision` — image-capable chat lanes (GLM-4.5V via together, gemini-2.5-flash
  via google-ai-studio, zen/openrouter gemini variants).

Owner defaults (2026-09-04): pi `default` chain = `cf-aig-dynamic/dynamic/TUI`
exactly; pi `gate` chain = `cf-aig-dynamic/dynamic/pr-gate` exactly;
opencode.json `model` = `cf-aig-dynamic/dynamic/TUI` with the legacy local
ladder remaining as the fallback tail.

### Custom providers (gateway BYOK, dashboard-only management)

REST `/ai-gateway/...` surfaces routes/logs only — **custom providers are
dashboard-edited**, not token-manageable. URL segment beats shared rules:
`custom-<name>/<version-tag>` where `<version-tag>` must be re-supplied in the
URL (e.g. `custom-zai-coding/v4`) — the gateway strips trailing version-like
segments from the base_url. Confirmed segments: `custom-aihubmix/v1`,
`custom-together/v1`, `custom-deepinfra/v1` (upstream 404s on all shapes — base
URL suspect), `custom-friendli/v1`, `custom-zai-coding/(v4 or /api/coding)`,
`custom-commandcode/v1`, `custom-nvidia-nim/v1`, `custom-phoenixgrove/v1`,
`custom-opencode-zen/v1`, plus native `openrouter/` + `google-ai-studio/`.
DYNAMIC-route caveat: model nodes naming bare custom-provider names
(`aihubmix`, `deepinfra`, `friendli`) error `Provider not found` — use the
`custom-` prefix form.

### In2.5 discounts / billing states (2026-09-04)

- aihubmix: glm-5.3 discount — keep lane 1 in `high`.
- friendli: BYOK key repaired; credits live on team `fndycazh1NMA` but the
  stored key needs to be a **team-scoped** key (dashboard) before billing
  succeeds.
- deepinfra: `$10 credits` exist, but the provider 404s everywhere; base URL
  correction pending captain.
- opencode-zen: confirmed flaky (`500/401` intermittent) on gemini lanes.
- commandcode: healthy; monthly limit resets Sept 12.
- openrouter `thinkingmachines/inkling:free`: agentic-harness-gated upstream —
  excluded from all gateway dynamic routes (kept in pi's local chain).
- together: `$10` credit added; catalog confirmed cheap (glm-5.3 $1.4/$4.4,
  glm-5.3-Flash $0.15/$0.50, FP8/FP4 rate $0) — lane usable once credits clear.

## pi + opencode wiring for dynamic routes

- pi (`private_dot_pi/private_agent/models.json`): provider `cf-aig-dynamic`
  with baseUrl `…/opencode/compat`, `api: openai-completions`, gateway token,
  `cf-aig-gateway-id` header, and model keys `dynamic/TUI|dynamic/high|dynamic/pr-gate|dynamic/vision`.
- pi (`~/.pi/fallback-chains.json`): `default` ⇒ single `cf-aig-dynamic/dynamic/TUI`;
  `gate` ⇒ single `cf-aig-dynamic/dynamic/pr-gate`.
- opencode (`dot_config/opencode/opencode.json`): provider `cf-aig-dynamic`
  with the four dynamic-route model keys; top-level `model` = `cf-aig-dynamic/dynamic/TUI`;
  agent/category chains unchanged (fallback jsonc tail unchanged).
- hermes: provider config lives outside `dot_config/hermes/config.yaml.tmpl`
  (its template has no model/provider keys) — to be wired once hermes's
  provider config file location is confirmed by the captain.

## Gateway route node types beyond the linear ladder (2026-09-05)

RouterModule nodes beyond `model`/`start`/`end`, from the CF dynamic-routing
reference:

- `percent` — probabilistic split across outputs (A/B, gradual rollout).
  Stateless per request. The valuable shapes for the fleet: canarying a
  cheaper lane on 5–10% of TUI traffic before re-ordering the ladder
  (evidence over paper prices), and splitting shared account-wide rate pools
  (e.g. the ~40 RPM nvidia-nim nemotron family) across two key entries.
- `conditional` — if/else on expressions over the request body, headers, or
  custom metadata (e.g. `user_plan == "paid"`). The high-value node for us:
  attach metadata like `crew=firstmate` / `crew=mybrain` / `class=gate` at the
  harness layer and ONE route can dispatch firstmate interactive → high,
  secondmate/telegram → TUI, review/gate traffic → pr-gate — no new provider
  entries per agent. Conditions on model ids (e.g. starts-with
  `claude-fable`) also let one route serve multiple lane families by name.
- `rate_limit` / `budget_limit` — enforce per-key/per-period request or cost
  quotas whose breach walks the node's fallback edge instead of failing:
  self-limiting guardrails on subsidized lanes so a runaway agent can never
  drain a plan window faster than the chain can re-route.

## Budget-access playbook (2026-09-05 pricing facts)

Ranked cheapest-first for accessing openai/anthropic/xai/kimi-class traffic
without the $100+/mo native-subscription seats:

- **OpenRouter PAYG + `:free` trio**: 5.5% platform fee on credit purchases
  ($0.80 min per purchase), zero token markup — provider list rates pass
  through. Free-model ceiling 50 req/day, **1,000/day after a $10 deposit**
  (one-time, never expires) at 20 RPM. Separate 1M-requests/mo PAYG band
  before a 5% per-request fee. `openrouter/free` router picks arbitrary free
  models; `:floor` routes to the cheapest provider for a chosen model;
  `max_price` caps spend per call. Below ~$15/mo the $0.80 floor dominates
  (5–25% effective tax); above ~$50/mo single-provider, a direct key beats
  OpenRouter by the 5.5%; above ~$5k/mo, negotiated enterprise tiers win.
- **Direct provider credits** (OpenAI $5 min, Anthropic $5 min, xAI, Kimi
  API): per-token, no platform fee, no subscription. Right choice above
  ~$50/mo per provider.
- **Plan/subsidized lanes already in the chains**: z.ai Coding Lite ($18/mo),
  opencode-zen console free (~200/day), PGS coding-tester plan (glm-5.3-flash
  + deepseek-v4-flash-0731 plan-subsidized — verified 2026-09-01), GOAT
  monthly pool (resets Sept 12), aihubmix glm-5.3 discount (TUI lane 1),
  together `$0` FP8/FP4 quantized GLM items, nvidia-nim nemotron (free, 40
  RPM account-wide), cerebras paygo ($5 + card, big TPM small RPM).
- **Google AI Studio**: $5 min via AI Studio, then $0.15/$0.50 MTok flash —
  strongest budget agentic lane (1M ctx), reachable natively through pi's
  `google-generative-ai` api type.
- **Cursor: has no BYOK/per-token bridge.** Seat-based subscription,
  workstation-scoped identity, machine-locked; wire it at most as a paid TUI
  lane, never a model lane.

## Auth-shape clarifications (2026-09-05)

- **pi-signed** is not a different harness: it is the signed wrapper identity
  of the pi coding agent (exact `pi-signed` wrapper parent around the Pi
  binary, foreground name `pi-launcher`). Firstmate records the identity as
 -is and refuses rather than silently falling back when the wrapper is
  missing. The signed wrapper is what keeps the launch provenance legitimate;
  there is no separate provider behind it.
- **OpenRouter PAYG vs subscriptions**: OpenRouter gives *API-key pass-through
  list pricing*, which is NOT the same as a harness subscription rate — you
  pay the provider's listed per-token price (their $186/mo-example is
  identical either way) plus OpenRouter's 5.5%. Harness/OAuth subscriptions
  (Claude Code 5-hour windows, Codex/Cursor seats) are different accounting
  systems with their own subsidized lanes and can be *cheaper per hour of
  agent use* than PAYG when the model is subscription-exclusive. They are a
  per-seat recurring fixed cost; our budget goal is to stay per-token and let
  `TUI`'s plan-subsidized lanes absorb interactive volume.
- **Harness-recognition gates** are a real auth-shape class to watch:
  openrouter gate-checks the calling harness before honoring some price bands
  (verified: `thinkingmachines/inkling:free` 403s through the gateway because
  the harness signature doesn't survive the hop; same model works from pi
  directly, or from Ori Harness). Budget implication: harness-gated models can
  only be reached via their recognized client, so "one harness for everything"
  is not a pricing win — per-(harness, provider) headphones stay necessary
  where the gate exists.

## Harness fleet admin cost (2026-09-05)

Verified-shape notes for standing up each additional TUI in the fleet,
roughly uniform: install once (npm/curl), login once (browser/OAuth or key
paste into its native provider dir), then quota-axi picks headroom up
automatically from its local auth dir (claude/codex/opencode/grok/kimi/
cursor providers are all already-read). Recurring maintenance is version
upgrades plus trust-dialog acceptance on fresh worktrees; no recurring
provider-edit work is added per harness (all harnesses point at the same
`cf-aig-dynamic` provider entry, so dynamic-route lane changes stay
config-free).
## Deterministic dynamic-route audit (2026-09-06)

`~/.config/opencode/scripts/dynamic-audit.mjs` (source: dotfiles
`dot_config/opencode/scripts/executable_dynamic-audit.mjs`) is the scheduled,
fully deterministic audit of the `cf-aig-dynamic` routes — no LLM step exists;
LLM interpretation happens only when the captain interrogates it, reading the
audit log rather than re-probing the gateway.

**Why the tests exist:**

1. `config-drift` compares the route keys declared in
   `dot_config/opencode/opencode.json`, `~/.pi/agent/models.json`, and the
   `default`/`gate` chain entries in `~/.pi/fallback-chains.json` against the
   purpose list in "Dynamic routes" above. Catches route renames made
   dashboard-side, stale agent configs, unresolved merges in the chains file,
   and purpose entries dropped from the catalog without a code change.
2. `route-probe` sends one fixed 4-token completion (`dynamic/<route>`) per
   route and logs HTTP code, latency, the upstream model id each route served,
   and `retry-after` / `cf-aig-status` headers on 429/5xx. 429/5xx/timeout is
   recorded as *routing evidence*, never a tool failure — repeated
   `status":"limited"` on a route is a lane-health fact, not a broken audit.

**Log (the interrogation substrate):** append-only JSONL at
`~/.local/state/opencode-fleet/dynamic-audit.jsonl`:

```
{"ts":"…","test":"route_probe","route":"dynamic/high","status":"ok","http":200,"latency_ms":589,"served_model":"z-ai/glm-5.3"}
```

`served_model` history is ground truth for which upstream each route currently
maps to; diff it against the "Dynamic routes" purpose definitions when
rebuilding routes. `config_drift` events name the exact file and key so a
rebuild starts from the diff.

**Usage:**
- Scheduled: hourly cron (`node ~/.config/opencode/scripts/dynamic-audit.mjs`), exits 0 clean / 1 drift / 2 machinery failure — transient 429/5xx/timeout never fails the tool, they're evidence the skill reads.
- `tail -F ~/.local/state/opencode-fleet/dynamic-audit.jsonl` to follow.
- Interrogation (captain-triggered, interactive): aggregate `route_probe` events per route — `served_model` counts, latency percentiles, 429/limited frequency/retry-after rate — and check the ladder against the purpose definitions in "Dynamic routes" above.
- **LLM proposals are interactive-only:** the captain triggers them on request ("interrogate the audit"); there is no scheduled LLM step. Any LLM run reads
  these logs — never re-probes the gateway on its own authority.

### Why the tests exist (design rationale)

The catalog reacts to invisible churn: dynamic-route contents change dashboard-side only, provider windows exhaust silently, and the last human-visible signal is often a failed chain somewhere. Recording each route's served_model per test run plus the provider availability aggregate gives every lane a *replayable history* of when the route healthy and who served it — the same ground truth `quota-axi` provides for quota, here for route/availability identity.

### Test 3: `provider_window` — the availability probe

`dot_local/bin/big-pickle-watch.sh` (source: `~/.local/bin/big-pickle-watch.sh`, cron-entry: * per-minute, both direct zen route + gateway BYOK lane, CSV). It is the design template the audit extends:

| Column | Curl response dependency |
|---|---|
| ts | wall-clock test start (ISO-8601) |
| route | direct | gateway which of two parallel lanes |
| http_code | probe return code (000 = never connected) |
| result | ok | limited | error | timeout (the four cardinal outcomes, categorizing every curl exit) |
| latency_ms | curl `%{time_total}` |
| err_type | upstream's own error.type field — the direct route's canonical exhaustion signal (`FreeUsageLimitError`) |
| retry_after_s | the strongest server-side signal, `Retry-After` from 429s |
| rate_headers | ratelimit/exhaustion headers preserved for trend reading |

The audit (`executable_dynamic-audit.mjs`, Test 3) folds this CSV into a
`provider_window` log event per route every hour with 24h ok/limited/timeout
aggregates: a single JSONL record per route telling a reviewing agent what the
last day of lane health actually looked like without reading the raw minutes.

Design principles (applies to both):
- **Write everything down, decide nothing.** The scheduled layer never mutates
  the gateway, routes, or provider config; scheduled logs are committed to disk
  for later review.
- **LLM proposals only on manual interrogation:** the captain (or the agent
  reading the skill after captain's request, via structured review) examines
  the logs and drives route-adjustment edits; any LLM formulation is a read of
  the record, and then proposes for human confirmation.
- **Both logs are cheap and structure-stable:** the audit log is JSONL keyed by
  `test` (`route_probe` / `config_drift` / `provider_window`); the CSV has a
  fixed 10-column header (see script header), published as a stable format
  others can parse.
