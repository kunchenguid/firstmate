---
name: detached-paseo-agent
description: >-
  Agent-only procedure for opening an independent detached Paseo root agent from a lock-refused firstmate session.
  Use only when the captain explicitly asks to open an independent or detached agent or terminal as another tab in the current Paseo workspace, and the session cannot hold the fleet lock.
  Owns the detached-only exception, the runtime-cwd safety gate, the independence prompt, and the strict boundary that this is never a firstmate fleet member.
user-invocable: false
metadata:
  internal: true
---

# detached-paseo-agent

Load this only when both hold:

- The current session is lock-refused (another session owns the home's fleet lock, so this session is read-only under `AGENTS.md` section 3).
- The captain explicitly asks to open an independent or detached agent, terminal, or tab in the current Paseo workspace.

This is a single narrow exception to the read-only rule.
It is NOT a delegation mailbox, a dispatch queue, or a way around the single-writer rule.
It never uses `bin/fm-spawn.sh`, never creates a crewmate or secondmate, and never records anything in the backlog or `state/`.
If the request is anything other than "open one independent agent in this Paseo tab", stop and stay read-only.

## What the lock-refused session still may NOT do

Everything section 3 forbids remains forbidden: no spawn, no crewmate or secondmate, no backlog or `state/` writes, no steering, no merges, no wake-queue drain, no supervision, no repair, no project-worktree mutation, no `--force`, and no lock stealing.
Creating a detached Paseo agent grants none of those.
It also cannot grant the new agent merge authority or any destructive or irreversible authority; those still require the captain through a session that holds the lock.

## The one allowed action

Create exactly one Paseo agent through `mcp__paseo__create_agent` with, and only with:

- `relationship`: `{ "kind": "detached" }` - a new root agent, never `{ "kind": "subagent" }`.
- `workspace`: `{ "kind": "current", "cwd": "<validated cwd>" }` - it stays visible as another tab in the caller's current Paseo workspace.
- `provider`: a real provider/model pair. Call `mcp__paseo__list_providers` and `mcp__paseo__list_models` when unsure; do not guess.
- `title`: a short (<= 60 char) captain-facing label, for example `Independent Codex agent`.
- `initialPrompt`: the independence prompt below.

Do not set `relationship.kind` to anything but `detached`.
Do not use `workspace.kind` `existing` or `create`; the captain asked for another tab in THIS workspace.

## Runtime cwd safety gate (mandatory, before create_agent)

The new agent must start OUTSIDE every firstmate-owned directory so it can never read this home's private operational state.
Do not eyeball this; run the deterministic gate:

```
bin/fm-detached-cwd-check.sh "<captain-supplied-or-default-cwd>"
```

- On exit 0 it prints `SAFE <canonical-path>`; pass that canonical path as `workspace.cwd`.
- On any non-zero exit it prints `UNSAFE: <reason>`; REFUSE the request and tell the captain the concrete reason. Never silently rewrite an unsafe or ambiguous cwd into a safe one - ask the captain for an explicit safe directory instead.

The gate refuses a cwd that equals or sits inside the firstmate code root, this home, `<home>/projects`, any registered project clone, or any active task worktree, and it resolves symlinks, `..` traversal, and alternate or case-insensitive spellings to the same real directory (`bin/fm-detached-cwd-check.sh` header owns the exact rules).
A safe default when the captain gives no directory is `/Users/jacobcole/code` (or another user-named non-firstmate directory); still run it through the gate.

## Independence prompt (initialPrompt)

The first prompt must state, in plain language, that the new agent:

- is an independent root agent the captain opened, not a firstmate crewmate, secondmate, or fleet member;
- must not access, read, or modify firstmate's private operational state (the firstmate home, its `data/`, `state/`, `config/`, `.env`, or `projects/`);
- must do any repository work in its own isolated clone or worktree, never in a firstmate-owned checkout;
- carries no firstmate fleet responsibility, supervision duty, or merge authority.

Template (adapt the specific task the captain names, keep every boundary):

```
You are an independent agent the captain opened directly. You are NOT a Firstmate
crewmate, secondmate, or fleet member, and you carry no Firstmate supervision or
merge responsibility. Do not access, read, or modify any Firstmate operational
state (a Firstmate home and its data/, state/, config/, .env, or projects/). Do
all repository work in your own isolated clone or worktree, never in a
Firstmate-owned checkout. Your task: <captain's task>.
```

## After creation

- Firstmate does not track, supervise, steer, recover, or tear down this agent. It is the captain's own tab.
- Do not write a backlog item, a `state/<id>.meta`, a brief, or any wake for it.
- Report to the captain in plain language that the independent agent is open in this Paseo workspace and that it is separate from the fleet.
- Then return to read-only mode; the session is still lock-refused for everything else.
