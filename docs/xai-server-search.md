# xAI server-side search (web_search / x_search)

Fleet workers call xAI's built-in **Web Search** and **X Search** through `bin/fm-xsearch.sh`.
This is the xAI Responses API path under SuperGrok OAuth (or an optional console API key).
It is **not** the X Developer API and **not** firstmate X-mode (public `@myfirstmate` mentions).

## When to use it

- Need live posts or trends from X (Twitter) with Grok's `x_search`.
- Need xAI-hosted web search (`web_search`) rather than a local `webfetch` / Exa tool.
- Any harness (OpenCode, Pi, Grok CLI, Claude, Codex) can shell out to the helper; Pi's default agent loop does not attach these built-in tools today.

Default coding harnesses still use their local tools until a worker explicitly runs this helper (or an OpenCode custom tool that wraps it).

## Auth

No firstmate secret plumbing and nothing to commit.

Resolution order inside `bin/fm-xsearch.sh`:

1. `XAI_API_KEY` in the environment (optional pay-as-you-go console key).
2. `FM_XAI_AUTH_FILE` when set (OpenCode/Pi-shaped JSON with an `xai` OAuth entry).
3. OpenCode store: `${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json`.
4. Pi store: `~/.pi/agent/auth.json`.

SuperGrok / X Premium OAuth already used by OpenCode or Pi is enough.
The access token is sent as `Authorization: Bearer` to `https://api.x.ai/v1`.
Near-expiry OAuth tokens are refreshed against `https://auth.x.ai/oauth2/token` and written back to the same store (mode `600`) when possible.

Sign in once with OpenCode `/connect` → xAI (SuperGrok) or the equivalent Pi login.
You do not need a separate `XAI_API_KEY` for OAuth.

## API shape

- Endpoint: `POST /v1/responses` only.
- Chat completions rejects `type: x_search` (HTTP 422).
- Prefer a Responses-capable model such as `grok-4.5` (the helper default).
- Tools are request-level: `[{ "type": "web_search" }]`, `[{ "type": "x_search" }]`, or both.

## CLI

Authoritative flags and exit codes live in the script header and `--help`.

```sh
# Both tools (default), print assistant text + usage counters on stderr
bin/fm-xsearch.sh 'What are people saying on X about firstmate?'

# X Search only, bounded handles and dates
bin/fm-xsearch.sh --tool x_search \
  --allowed-handle elonmusk \
  --from-date 2026-07-01 \
  --max-tool-calls 2 \
  'Latest status posts'

# Dry-run: print the JSON body only (no auth, no network)
bin/fm-xsearch.sh --dry-run --tool web_search 'ping'

# Full API JSON
bin/fm-xsearch.sh --json --tool both 'summarize recent coverage'
```

Prompt text can come from argv, `--prompt-file`, or stdin (`-`).
Tokens are never printed.

## Cost and guardrails

xAI prices `web_search` and `x_search` per invocation (see current [tools pricing](https://docs.x.ai/developers/pricing#tools-pricing)), plus ordinary token usage.
Multi-hop answers can issue several tool calls per user question.
The helper defaults to `--max-tool-calls 3`.
Image and video understanding on `x_search` are opt-in flags and cost more.
Confirm in the xAI console whether SuperGrok Heavy absorbs tool usage or shows separate tool line items before wide fleet rollout.

## OpenCode attachment

OpenCode's bundled `@ai-sdk/xai` understands `xai.web_search` / `xai.x_search`, but the default coding agent loop does not attach those provider tools for fleet turns.
Practical options:

1. **Preferred for any harness:** call `bin/fm-xsearch.sh` from the worker shell when live X/web search is required.
2. **OpenCode custom tool:** add a small tool under `~/.config/opencode/tools/` (or a project's `.opencode/tools/`) that shells out to this script.
   See [custom tools](https://opencode.ai/docs/custom-tools/) and the copyable example at [docs/examples/opencode-xai-search-tool.ts](examples/opencode-xai-search-tool.ts).

## Related

- Script inventory: [scripts.md](scripts.md)
- X-mode (public mentions, different subsystem): [configuration.md](configuration.md#x-mode-env)
- xAI docs: [tools overview](https://docs.x.ai/developers/tools/overview), [X Search](https://docs.x.ai/developers/tools/x-search), [Web Search](https://docs.x.ai/developers/tools/web-search)
- Behavior tests: `tests/fm-xsearch.test.sh`
