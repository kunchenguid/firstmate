# reasonix-headless — dispatching reasonix with no multiplexer active

Reached from [`SKILL.md`](../SKILL.md) when task = reasonix-dispatch and engine = none (no Herdr session, or a tmux-only session — see `../SKILL.md` Step 2). No visible pane; this is a plain foreground/background CLI call.

## Overview

reasonix is a separate Go-based coding agent (DeepSeek-native, installed at `~/go/bin/reasonix`), not a Claude subagent. This branch lets Claude act as **orchestrator**, dispatching discrete tasks to reasonix as an independent delegate — same relationship the `Agent` tool has with a subagent, except the worker is a different process and a different model, billed separately.

Dispatch happens through the `reasonix-axi` CLI (`/home/adrian/dev/subagent-factory/tools/reasonix-axi`), which wraps `reasonix run` / `reasonix subagent run` and returns compact, structured results (cost, tokens, session id, output text) instead of raw reasonix JSON.

Facts to keep in mind while orchestrating:

- Every dispatch costs real money (DeepSeek pricing) and returns `cost_usd` in the response. This is not free parallelism — don't fan out dispatches without a reason.
- Verified empirically: one-shot `reasonix run` calls do not hang waiting for interactive tool-approval, even for tasks that need file reads/writes/bash. Safe to call headlessly.
- Each dispatch prompt must be self-contained. reasonix has none of the current conversation's context — name files, symbols, and constraints explicitly, the same discipline used when writing an `Agent` tool prompt.

**For reasonix's built-in tools, subagent profiles, MCP server capabilities, and the failure modes discovered while using them — see [`reasonix-tools-and-mcp.md`](reasonix-tools-and-mcp.md) in this folder.** Read it before any dispatch that needs read-only profiles or MCP tools (web search, docs lookup, browser automation).

## Step 1 — Confirm reasonix-axi is available

IF `which reasonix-axi` returns nothing:
→ STOP. Tell the user reasonix-axi isn't installed or linked. Point them at `cd /home/adrian/dev/subagent-factory/tools/reasonix-axi && npm run build && npm link`. Do not proceed.

ELSE:
→ proceed to Step 2.

## Step 2 — Decide: delegate to reasonix, or do it yourself?

IF the task is something Claude can do directly in the current session with equal or better context (the current conversation already has the relevant files open, or the task is small):
→ STOP delegating. Do it directly — reasonix costs real money per call and adds a process hop for no benefit here.

ELSE IF the user explicitly asked for reasonix, or the task needs a genuinely independent second opinion (cross-checking Claude's own code, an adversarial review):
→ proceed to Step 3.

ELSE IF the task is read-only investigation (survey a codebase, research a library, review/security-review a diff) and running it in parallel with Claude's own work saves wall-clock time:
→ proceed to Step 3.

ELSE:
→ do the task directly instead of delegating.

## Step 3 — Pick the dispatch shape

IF the task is read-only investigation and fits one of the built-in profiles:
→ run `reasonix-axi profiles --dir <path>` first — do not assume a profile is available (see `reasonix-tools-and-mcp.md` for why visibility is workspace-gated).
→ IF the profile is listed: dispatch with `reasonix-axi task <profile> "<self-contained task>" --dir <path>`
→ ELSE: fall through to the general-purpose dispatch below.

IF the task needs writes, shell commands, MCP tools, or doesn't fit a built-in profile:
→ dispatch with `reasonix-axi run "<self-contained prompt>" --dir <path> [--model <name>]`
→ Do NOT pass `--profile delivery` for an investigation/opinion/review-style ask. `delivery` engages reasonix's capability-gate discipline (formal review/test/security sign-off before it will call a task "complete") — built for actual ship-a-change work. Passed on a "review this and tell me what you found" task, it burns tokens producing a sign-off summary ("all tasks signed off...") instead of the findings. Leave `--profile` unset (defaults to `balanced`) unless the task is genuinely deliver-a-change scoped.

IF the expected answer is more than a few short paragraphs (a design scope, an audit, a detailed report):
→ Dispatch with `reasonix-axi run`, not `reasonix-axi task <profile>`, and instruct it to write its full findings to a file (e.g. `tmp/<topic>.md`) instead of relying on its inline chat answer, then Read that file yourself. Read-only profiles (`explore` etc.) have no write tool at all and cannot save to a file no matter how they're asked — see `reasonix-tools-and-mcp.md`. This is the default for any design scope, audit, or multi-section report, not just a fallback after hitting truncation once.

IF you need more out of an existing reasonix session (e.g. "write your last answer to a file"):
→ `--continue` resumes reasonix's newest saved session, which is **not always the one you expect** — verified it can resume an unrelated earlier session and reasonix will report having no memory of the task you meant. Treat `--continue` as best-effort, not reliable session targeting. If it resumes the wrong thing, don't fight it — just redispatch a fresh, fully self-contained prompt instead (this is exactly why prompts must be self-contained in the first place).

## Step 4 — Long dispatches: don't block on the harness's own background runner

Some host environments kill a harness-backgrounded shell call (e.g. Claude Code's `run_in_background`) well before a long `reasonix-axi run` finishes — sometimes within seconds, with no error, no partial output captured, and no relation to the `--timeout` you passed reasonix itself. Confirmed repeatedly in one session: identical dispatches sometimes ran to completion under `run_in_background` and sometimes got killed at ~30s-2min for no visible reason.

→ For any dispatch you expect to take more than ~1-2 minutes, detach it as a real background shell job instead of relying on the harness's backgrounding: `reasonix-axi run "..." --dir <path> > /tmp/some.log 2>&1 &` (note the trailing `&`, and redirect to a file since you lose the tool-call's own stdout capture this way). Then use a `Monitor`/polling tool to watch for the process PID to exit (`while kill -0 <pid> 2>/dev/null; do sleep 10; done`) and read the log file for the result — don't block a single tool call waiting on it.
→ If a dispatch does get killed anyway (via the harness's own backgrounding), check the working tree before redispatching — reasonix often leaves real, usable partial work uncommitted (confirmed: a full multi-file feature was ~90% done, fully coherent, just missing the final commit and one small integration step). Inspect with `git status`/`git diff` first; finishing the last small piece yourself or committing what's there is usually cheaper and more correct than a blind full redispatch, which pays for the same work twice and can diverge from the first attempt.

## Step 5 — Preflight before dispatching, and before a new no-mistakes step

The established cycle in this codebase is: sync `main` → branch → dispatch reasonix → verify → run `no-mistakes` → merge → repeat for the next unit of work. Two checks belong at the start of every cycle, before either dispatching reasonix or starting a fresh `no-mistakes axi run`:

1. **Confirm you're on a feature branch, not `main`/`master`.** `git branch --show-current` — if it returns `main` or `master`, STOP: sync and branch first (`git checkout main && git pull --ff-only && git checkout -b <name>`). Never dispatch reasonix, or start a `no-mistakes` run, directly on the default branch — `no-mistakes` itself will refuse (it validates committed history on a non-default branch), and reasonix has no branch awareness of its own to catch this for you.
2. **Kill leftover monitoring from the previous cycle before arming new monitoring for this one.** A prior phase's background watchers (a `Monitor`-tool poll loop on `no-mistakes axi status`, a detached `tmp/no-mistakes-load-watch.sh` instance, a `Monitor` tailing its log) have no reason to still be running once that phase reached a terminal outcome (merged/failed/cancelled) — leaving them alive wastes background slots and, worse, can deliver a stale phase's notifications interleaved with the new phase's, which reads as confusing or contradictory status. Before starting a new `no-mistakes axi run`: check `pgrep -af "no-mistakes-load-watch"` and kill any instance whose log path doesn't match the phase you're about to start; check your own list of active background tasks (however your harness exposes it — e.g. Claude Code's task list) for any `Monitor` still polling a **different, already-terminal** run id and stop it. A monitor still watching the *current* in-flight run is fine to leave running across a preflight check — only stop ones left over from a run that's already done.

## Step 6 — Interpret the result

IF the response's `status` field is `error`:
→ read the returned text for the reason. Do not retry blindly — either fix the prompt and redispatch once, or fall back to doing the task directly. See `reasonix-tools-and-mcp.md`'s "Why a dispatch can fail mid-flight" section first — reasonix has no automatic retry/backoff on transient provider errors (confirmed not implemented), so a redispatch is often the right call for what looks like a transient failure, not a sign the task itself is broken.

ELSE:
→ treat the returned text as a subagent's final answer — verify anything load-bearing before acting on it, same discipline as any other subagent report. Do not assume it's correct just because it succeeded.

IF a dispatch reports an MCP tool as failed/blocked/still-initializing:
→ see `reasonix-tools-and-mcp.md` for the three known failure modes and their fixes before concluding a tool is genuinely broken.

IF `cost_usd` is non-trivial (roughly > $0.01, or the user is running multiple dispatches in one session):
→ report the cost back to the user — they track spend and appreciate the recap.

## Notes for future updates

| Question | Action |
|---|---|
| New failure mode not covered above? | Add it to Step 6 |
| A profile behaved differently than documented (e.g. gating rules)? | Update Step 3 (or `reasonix-tools-and-mcp.md` if it's about the profile/tool itself) |
| A flag or command shape changed (`reasonix-axi --help` drifted)? | Update the dispatch commands here |
| Delegation was the wrong call in hindsight? | Sharpen the decision criteria in Step 2 |
| A tool, MCP server, or profile behaved unexpectedly? | Update `reasonix-tools-and-mcp.md`, not this file |

If anything changed, snapshot the parent skill (`../SKILL.md` → `../SKILL.v<N+1>.md`) and add a row to `../VERSIONING.md`.
