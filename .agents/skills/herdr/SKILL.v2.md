---
name: herdr
description: Use when the user explicitly mentions Herdr and wants to control terminal panes, tabs, or workspaces for coding agents — open/split panes, launch codex/claude/pi/opencode/omp interactively, inspect or read neighboring work, manage git worktrees, or send the workspace to Plannotator for review. Also use whenever the user wants to delegate, dispatch, or run a task "through reasonix" (Google DeepSeek-native coding agent) — as a subagent, for a second/independent opinion, or an adversarial review — regardless of whether Herdr is running; this skill picks visible-pane vs headless dispatch automatically. Also use for browser automation driven through a visible Herdr pane — "open a browser session in Herdr", "drive the browser through Herdr", "run browser-harness in a pane".
allowed-tools: Bash
---

# herdr

## Overview

One contract, one primary engine, three tasks. Modeled on [cyberuni/cyber-mux](https://github.com/cyberuni/cyber-mux)'s "one contract over terminal multiplexers" idea: detect what's running the session, then drive it through a single vocabulary instead of hardcoding one multiplexer's commands into every downstream tool.

This skill implements the **Herdr** engine, plus the headless no-multiplexer fallback for reasonix. It does not implement a tmux driver — cyber-mux itself already covers tmux; this skill borrows its contract shape, not its code.

## Step 1 — Which task is this?

IF the user explicitly mentions Herdr and wants pane/tab/workspace control that is NOT specifically about dispatching reasonix or browser-harness (starting an interactive agent, running an ordinary command in another pane, inspecting/reading a pane, managing a worktree, sending the workspace to Plannotator):
→ task = **pane-control**. Go to Step 2.

ELSE IF the user wants to delegate, dispatch, or run something "through reasonix" — as a subagent, for a second/independent opinion, or an adversarial review — regardless of whether Herdr was mentioned:
→ task = **reasonix-dispatch**. Go to Step 2.

ELSE IF the user wants browser automation (navigate, click, scrape, test a site) driven through a visible, status-tracked Herdr pane, or wants to continue an already-open browser-harness pane from a previous message:
→ task = **browser-harness-dispatch**. Go to Step 2.

ELSE:
→ this skill does not apply. Stop.

## Step 2 — Detect the engine

Run:

```bash
echo "$HERDR_ENV"
echo "$TMUX"
```

IF `HERDR_ENV` is `1`:
→ engine = **herdr**. Go to Step 3.

ELSE IF `TMUX` is set (a tmux session, no Herdr):
→ IF task = pane-control OR task = browser-harness-dispatch: STOP. No verified tmux command path exists in this skill — it borrows cyber-mux's *contract*, not its tmux driver. Tell the user to use cyber-mux directly for tmux pane control, or run the task without pane isolation.
→ ELSE (task = reasonix-dispatch): engine = **none**. Go to Step 3 — reasonix has a headless path independent of any multiplexer.

ELSE (no multiplexer detected):
→ IF task = browser-harness-dispatch: STOP. This branch only works inside a Herdr-managed pane and has no headless fallback. Tell the user, and use `browser-use` or `claude-in-chrome` instead.
→ ELSE: engine = **none**. Go to Step 3.

## Step 3 — Dispatch to the right branch

IF task = pane-control (Step 2 already stopped unless engine = herdr):
→ Read [`references/herdr-panes.md`](references/herdr-panes.md) and follow it.

ELSE IF task = reasonix-dispatch AND engine = herdr:
→ Read [`references/reasonix-herdr.md`](references/reasonix-herdr.md) and follow it — decides `dispatch` (visible, interactive PTY) vs `watch` (visible, status-only) mode.

ELSE IF task = reasonix-dispatch AND engine = none:
→ Read [`references/reasonix-headless.md`](references/reasonix-headless.md) and follow it — no visible pane, plain `reasonix-axi` calls. Also read [`references/reasonix-tools-and-mcp.md`](references/reasonix-tools-and-mcp.md) before any dispatch that needs read-only profiles or MCP tools.

ELSE (task = browser-harness-dispatch, Step 2 already stopped unless engine = herdr):
→ Read [`references/browser-harness-herdr.md`](references/browser-harness-herdr.md) and follow it — session-shaped: `open` once, `run` as many scripts as needed, `close` explicitly when done.

## Step 4 — Learning review

After the task, ask:

| Question | Action |
|---|---|
| A branch fired on the wrong task/engine combination? | Sharpen Step 1 or Step 2's condition |
| tmux pane-control actually got requested? | Consider building a real tmux driver (`references/tmux-panes.md`) instead of the current STOP-and-redirect |
| New failure mode inside a branch? | Add it to that branch's reference file, not here |
| A reference file grew past what one branch needs? | Split further per the branch it doesn't serve |

If anything changed, snapshot + bump:

```bash
cp SKILL.md SKILL.v<N+1>.md
# add a row to VERSIONING.md
```

## Checklist

- [ ] Task identified (pane-control vs reasonix-dispatch vs browser-harness-dispatch)
- [ ] Engine detected (herdr / tmux / none)
- [ ] Correct reference file loaded and followed
- [ ] Result verified before acting on it
- [ ] Learning review done
