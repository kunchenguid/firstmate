# reasonix — Tools, Profiles & MCP

Reference detail for what reasonix can actually do at the tool level, and the failure modes discovered while using it. `SKILL.md` stays focused on the orchestration decision flow (delegate/dispatch/interpret/learn) and points here for anything about reasonix's own capabilities.

## Built-in tools

reasonix's complete built-in toolset (confirmed from source, `docs/SPEC.md`):

```
read_file / write_file / edit_file / move_file / bash / ls / glob / grep
```

That's it — no native web search, no fetch, no browser. Any research capability beyond the local repo comes entirely from MCP servers (below).

**No worktree or container isolation of any kind.** Confirmed from source — zero mentions of "worktree", no Docker/containerization. Its only isolation is an OS-level bash sandbox (bubblewrap on Linux, Seatbelt on macOS) that jails *commands*, not filesystem/branch state. Every dispatch operates directly on the real working tree at `--dir`. If a task genuinely needs isolation, the orchestrator must create a git worktree itself (e.g. Claude Code's own `EnterWorktree`) and point `--dir` at that path — there is no reasonix-native equivalent.

## Subagent profiles

4 built-in read-only profiles: `explore`, `research`, `review`, `security_review`, plus any custom ones the user created with `reasonix subagent create`. Built-in visibility is **workspace-gated** — e.g. `review`/`security_review` need a git diff to review. Always run `reasonix-axi profiles --dir <path>` first; never assume a profile is available just because it's one of the 4 named ones.

**Read-only means literally no write tool.** `explore` (confirmed; likely the same for `research`/`review`/`security_review`) only has `glob`/`grep`/`ls`/`read_file`/`code_index` — no `write_file`. A `task explore` dispatch **cannot** write its findings to a file no matter how explicitly it's asked to — it'll say so and paste the report inline instead, which then hits the inline-truncation cap below with no workaround available at that dispatch. If a long report needs to land in a file (which it usually does — see below), dispatch via `reasonix-axi run` instead of `reasonix-axi task <profile>`, even for a read-only investigation task. `run` has full tool access including `write_file`.

## MCP servers

reasonix can have MCP servers configured exactly like Claude Code — `reasonix mcp list` / `reasonix mcp add <name> <command> [args...] [--env K=V]` / `reasonix mcp remove <name>` (persisted to `reasonix.toml`; remote transports via `--http <url>` or `--sse <url>`). This is how web search (e.g. Tavily), docs lookup (context7), and browser automation (Playwright) get added.

**Never enter an API key yourself** when running `reasonix mcp add ... --env KEY=value` — same "never type credentials into any field" rule that governs everything else, even when the user pastes the key directly in chat and asks you to run it anyway. Give the user the exact command and have them run it themselves (a `!`-prefixed message works from any device that can send a chat message, including mobile — it's not a desktop-only mechanism, though it does require the client to actually support command execution; if a `!`-prefixed message comes back with no execution and no tool result, the client doesn't support it and the user needs a real terminal or SSH session instead).

### Three real MCP failure modes (all confirmed live, none are user error)

1. **Cold-start false-negative** — a freshly-added server can report `MCP server "<name>" is still initializing — call this tool again on the next turn` on its first real dispatch. Usually just `npx` downloading the package for the first time, exceeding the tool-call retry window within one turn — not a real config problem. Fix: pre-warm once outside reasonix (`npx -y <package> --help`) so the package is cached, or instruct the dispatch to wait-and-retry (`sleep 5` then try again, up to ~6 times) instead of giving up after one quick attempt.

2. **Permission-classifier block — RESOLVED, fix confirmed working.** reasonix's own internal tool-classification layer can silently block an MCP tool *before it ever dispatches*, independent of the general `[permissions] mode = "allow"` setting:
   > `MCP server "<name>" no longer classifies tool "<tool>" as an allowed reader; the call was blocked before dispatch — retry from a parent session or update the explicit read-only policy`

   Root cause (confirmed from `docs/SPEC.md` in reasonix's own source): a tool's MCP `annotations.readOnlyHint` maps to reasonix's internal `Tool.ReadOnly()` and **defaults to `false`** — a remote MCP tool is opaque to reasonix, so it only trusts a tool as a safe reader if the server itself declares `readOnlyHint: true` in `tools/list`. `@upstash/context7-mcp` and some of `@playwright/mcp`'s tools (`browser_snapshot`, `browser_find`) don't declare this, so they get blocked by default even though they're genuinely read-only.

   **Do not try to fix it by passing `--permission-mode bypassPermissions`/`auto` on the dispatch call** — that gets blocked by Claude Code's *own* safety classifier (an orchestrator overriding a subagent's permission posture mid-dispatch is correctly flagged as too risky to do on judgment alone). Don't fight that block.

   **The actual fix**: add a per-plugin `trusted_read_only_tools = ["tool-a", "tool-b"]` line to the relevant `[[plugins]]` block in `~/.reasonix/config.toml` (documented in `docs/SPEC.md`'s global-config example, near `default_tools_approval_mode`). This is a persistent, repo-independent config edit — the user's own machine config, not a per-dispatch override, so it's a normal edit to make directly (not the same category as the blocked `--permission-mode` flag). Example, verified working:
   ```toml
   [[plugins]]
   name    = "context7"
   command = "npx"
   args    = ["-y", "@upstash/context7-mcp"]
   trusted_read_only_tools = ["resolve-library-id", "query-docs"]
   ```
   **Get the exact tool names from the installed package's own source, not from web search or training data.** A web search for context7's tool names confidently returned `get-library-docs` — wrong for the actually-installed version (3.2.4); the real tool is `query-docs`, confirmed by grepping `registerTool(` calls in the cached package source under `~/.reasonix/mcp-state/<hash>/<plugin>/cache/npm/_npx/<hash>/node_modules/<package>/dist/index.js` (reasonix caches the resolved npx package there after first use). If a dispatch itself reports the tool names back to you (e.g. "the only tools I have are X and Y"), that live introspection is also authoritative — trust it over a web search that disagrees.

   After adding `trusted_read_only_tools`, verify with a real dispatch calling the tool directly (skip any implied connect step, see failure mode 3) — confirmed this fully resolves the block with zero further errors.

3. **Unnecessary-connect-step red herring** — a dispatch can try an implied "connect" tool-call before the real tool, report failure on *that* step, and never actually attempt the real tool. Observed with Tavily: reported as broken/still-initializing, but a redispatch instructed to call `tavily_search` directly (skip any connect/handshake step) succeeded immediately with 0 retries. When an MCP tool comes back "failed", one retry that explicitly skips any implied setup step is worth doing before concluding it's genuinely broken.

## Inline output truncation (not MCP-specific, but discovered via MCP-tool dispatches)

`reasonix-axi`'s own CLI caps how much inline text it displays/captures, even when the underlying response is much longer — it self-reports the true length ("...truncated, 8849 chars total") while only delivering a fraction of that to the calling shell. This happens *inside* `reasonix-axi` before the text ever reaches Claude Code — it is not something `wc -c` or reading the captured output file harder works around.

**For any report longer than a few short paragraphs, instruct the dispatch to write its full findings to a file** (e.g. `tmp/<topic>.md`) instead of relying on the inline chat answer, then `Read` that file directly. Treat this as the default for design scopes, audits, or anything multi-section — not just a fallback after hitting truncation once.

## Why a dispatch can fail mid-flight, and how to reduce the odds

Confirmed from source (`docs/SPEC.md §6, §3.6`) and from empirically checking `~/.reasonix/sessions/` — none of these are speculation:

1. **No automatic retry/backoff on transient API errors.** `docs/SPEC.md §6` states outright: *"Network layer should apply bounded exponential backoff on 429 / 5xx (interface reserved; implementation may follow)."* This is not implemented yet — a single rate-limit response or transient server error from the model provider can kill the entire dispatch with zero built-in resilience. **Mitigation:** the orchestrator has to be the retry layer reasonix doesn't have yet — if a dispatch errors out with what looks like a transient network/provider issue (not a permission block, not a real logic error), redispatch once before concluding the task itself is broken.

2. **Multiple stacked timeouts, any one of which kills the dispatch.** `reasonix-axi run --timeout <seconds>` (default 600s, caps the whole dispatch) sits on top of `bash_timeout_seconds` (120s, per foreground bash call) and `mcp_call_timeout_seconds`/`call_timeout_seconds` (300-600s, per MCP call). A dispatch doing something genuinely slow (a big install, a slow crawl, a large build) can get killed by whichever cap hits first, producing a truncated/incomplete result rather than a clean error message explaining why. **Mitigation:** pass an explicit `--timeout <seconds>` well above 600 for any task expected to run long, and say so in the dispatch prompt so it isn't a silent surprise.

3. **Context-window compaction can silently degrade very long/broad dispatches.** Long tasks with lots of large tool outputs trigger automatic summarization (`agent.compact_ratio`, default 0.8) that folds older tool results into short placeholders to keep the prompt under budget. This isn't a crash, but a dispatch that reads dozens of files or produces huge intermediate output can lose access to earlier detail by the time it writes its final answer — the final report may quietly be based on compacted/summarized context rather than the original full reads. **Mitigation:** keep individual dispatch scope focused rather than one sprawling investigation; split a genuinely large audit into 2-3 narrower dispatches instead of one giant one.

4. **Dispatch sessions are not reliably persisted the way interactive sessions are.** Confirmed empirically: after ~10 `reasonix-axi` dispatches in one session, `~/.reasonix/sessions/` still only contained stale sessions from months earlier — none of the dispatch session IDs reported back (`20260720-...-deepseek-v4-flash` etc.) showed up there. This is consistent with the earlier-documented `--continue` unreliability (it resumed an unrelated old session, not any recent dispatch). **Practical implication:** if a dispatch fails mid-flight, there is likely no session to `--resume`/`--continue` into to recover partial progress — treat each dispatch as closer to fire-and-forget than a resumable session, and for anything expensive/long, have it write partial progress to a file as it goes rather than relying on session continuity as a safety net.

5. **Some tools are hard-refused in headless/non-interactive dispatches, not just permission-classified.** `docs/SPEC.md §3.6` notes that `remember`/`forget` calls specifically "are refused rather than auto-approved" in non-interactive headless runs or sub-agents, regardless of permission mode — a different, stricter mechanism than the MCP permission-classifier block above. If a dispatch's own plan happens to depend on a tool that's hard-refused this way, it can't complete that step cleanly. Unlikely to matter for typical orchestrator dispatches (research/code tasks rarely need `remember`/`forget`), but worth knowing this class of hard refusal exists beyond MCP tools specifically.
