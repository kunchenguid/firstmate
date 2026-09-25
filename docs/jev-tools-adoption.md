# Jev tools for this repository

The project-scoped Claude Code plugin `jev-safe` bundles pinned copies of the
fast-jev-compaction and winnow function hooks. `.mcp.json` registers the pinned
jev-mcp server. `bin/fm-jev-sessionstart.sh` loads `TYPESAFE_API_KEY` through
Firstmate's `.env` reader, starts the local scanner, and starts winnow. The MCP
launcher uses the same key reader and a Node fetch preloader. No credential is
stored in tracked settings.

Before each Jev request, the hooks scan the outgoing request body with Yelp
detect-secrets and reject sensitive path references. A rejected or unavailable
gate falls back to the tool's default behavior. The blocked fixture tests use a
synthetic GitHub-key-shaped string and clean text with `data/captain.md` as its
path, independently.

## Pinned upstream revisions

| Tool | Upstream revision |
|---|---|
| fast-jev-compaction | `e3f262a7f4d42bd8dd32ced30d26176f7cb545b0` |
| jev-mcp | `82720dfb3626b25807f3f58c6a8f77836cbdec4e` |
| winnow | `51d80b945c74c8384bc47fa817179f668289afd8` |

The plugin's vendored hook sources come from the first and third revisions
above; they add the local safety gate at the HTTP boundary. The full upstream
checkouts remain in `.claude/upstreams/` for provenance and updates.

## Synthetic validation sample

The canonical 25-fixture set referenced by the IMAC HANDOFF was not found in
the repository or its `projects/IMAC` tree. These substitute checks used only
synthetic text; no secret or personal information was included in an allowed
request. One request was measured for each tool:

| Tool | Jev latency | Billable input tokens | Output tokens | Estimated input cost | Outcome |
|---|---:|---:|---:|---:|---|
| jev-mcp (`jev_verify`) | 1,780 ms end to end | 453 | 46 | $0.0000190 | verified synthetic claim |
| fast-jev-compaction | 505 ms Jev request; 775 ms total | 578 | 40 | $0.0000243 | compacted synthetic transcript |
| winnow | 701 ms judging; 2,226 ms end to end | 6,784 | not persisted by its event log | $0.0002849 | unchanged result (`nothing_to_prune`) |

Estimated cost uses TypeSafe's published $42 per billion input tokens; output
tokens are currently free. The three requests consumed 7,815 reported input
tokens. Remaining account quota was not exposed by the tools. The winnow event
log records input token use but not output token use.

## Safe-default checks

- `tests/fm-jev-safety-gate.test.sh` blocks the synthetic key and the excluded
  path independently; `tests/fm-jev-hook-guards.test.mjs` verifies fast-jev's
  unset-key and mocked-401 fallbacks and winnow's path-blocked pass-through.
- Upstream tests passed with `TYPESAFE_API_KEY` unset: jev-mcp 223 tests,
  fast-jev-compaction 29 tests, and winnow 80 tests. The test implementations
  exercise API error handling with mocks; no invalid credential was sent to
  TypeSafe.
- A successful fixture call verifies the scanner allowed only synthetic
  content. This sample does not establish complete PII detection for arbitrary
  content; sensitive source paths are rejected before content is sent.

## Cross-Harness Architecture & Boundaries (Claude, Codex, AGY)

The 3 Jev tools operate across agent harnesses according to their supported integration surfaces:

### 1. `jev-mcp` (Universal Cross-Harness Interface)
Exposes 11 typed Jev judgment tools (`jev_verify`, `jev_gate`, `jev_review`, `jev_screen`, etc.) over standard stdio MCP:
- **Claude Code**: Configured via `.mcp.json`.
- **Codex**: Configured via `~/.codex/config.toml` under `[mcp_servers.jev]`.
- **AGY (Antigravity)**: Configured via `~/.gemini/config/mcp_config.json` under `"jev"`.
- **Startup & Fail-Closed Safety**:
  - The launcher `bin/fm-jev-mcp.sh` invokes `server.py --ensure` before launching the Node process.
  - `server.py` requires `.claude/jev-safety/.venv` to exist (failing closed with exit 1 if absent).
  - `ensure()` polls `http://127.0.0.1:48752/health` and requires an expected `{"status":"ok","service":"firstmate-jev-safety"}` response within a bounded 2.5-second deadline; if the server is not ready, it terminates with exit 1.
  - All outbound POST requests from `jev-mcp` are intercepted by `preload.mjs`, matching the service name field (`service: 'firstmate-jev-safety'`) and blocking requests that contain secrets (via detect-secrets), sensitive paths (`data/captain.md`, `.env`), or payloads exceeding 4MB.

### 2. `winnow` & `fast-jev-compaction` (Harness-Specific Specialization)
These two tools rely on Claude Code in-process function hooks (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`):
- **Claude Code**: Uses `winnow` (PostToolExecution hook wrapping `Read`/`Bash`/`Grep`) and `fast-jev-compaction` (TurnComplete hook).
- **Codex & AGY**: Do not support Claude's in-process tool-rewrite hooks. Codex relies on its native command output folding and `compact-adviser` (in `~/.codex/config.toml`), while AGY relies on standard large-window handling and `/stow` state persistence. Both harnesses invoke Jev judgment capabilities through `jev-mcp` on demand.

## Evaluated and not adopted

`jev-review` adds staged JS/TS source screening, evidence selection, severity scoring, reviewer routing, and a local report dashboard.
Its judgments overlap `jev-mcp`'s `jev_review`, `jev_screen`, and `jev_gate` tools and the no-mistakes review pipeline.
It runs no compiler diagnostics, tests, or static analyzers, so its findings are review prompts rather than proof of defects.
It sends full patch and source content to TypeSafe Jev without a local secret/path scanner or payload-size guard, unlike the existing jev-mcp request-body scanner.
We will not add it as a standing gate or dependency.
Reconsider only for a concrete JS/TS repository needing recurring baseline scans or severity-ranked triage, after a bounded internal-only comparison of latency, token use, and review usefulness against the existing Jev review path.
