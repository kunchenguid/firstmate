---
name: epic-new
description: Start a new epic. Decide up front whether the work spans several repos or lives in one, then set up the right workspace - a cross-repo umbrella lab (bin/fm-umbrella.sh) when repos must be designed together, or a plain single-repo design when it does not. Use at the very start, before any story is written, when the captain wants to begin a multi-story feature. First skill in the epic pipeline; hands off to /epic-scaffold.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of five epic-pipeline skills (epic-new -> epic-scaffold -> epic-review -> epic-handoff -> epic-ship) that share one voice and one output format. This skill DRIVES bin/fm-umbrella.sh for the cross-repo path; it must not reimplement that script - defer to `fm-umbrella.sh --help` for the exact contract. -->

# epic-new

The entry point of the epic pipeline.
Before any story is written, decide the one thing that shapes everything after it: does this epic span more than one repo, or does it live in a single repo?
That answer picks the workspace, and the workspace is all this skill sets up - the actual design happens next, with the captain.

You are the ENTRY.
You do not design the architecture here and you do not write stories - you choose and stand up the workspace, then hand off.

## When to use

- The captain wants to begin a new multi-story feature and nothing has been scaffolded yet.
- You need to decide cross-repo versus single-repo before design starts.

## The decision

Ask one question: does landing this feature require coordinated changes in two or more repos that must be designed against each other (a shared API shape, schema, proto, or types package one repo produces and another consumes)?

- **Yes - cross-repo.** Stand up an umbrella lab so every involved repo is checked out side by side and the captain can design the cross-repo contract with all of them visible at once.
- **No - single-repo.** Skip the umbrella entirely. Design directly in the one repo's normal workspace; the epic is just several stories in that repo.

Do not stand up an umbrella "just in case" - it is only worth it when repos genuinely constrain each other's design.

## Cross-repo: stand up the umbrella lab (do not reimplement)

The umbrella is created by the engine, not by hand:

    bin/fm-umbrella.sh create <umbrella-id> --repos <repo>,<repo>,...

Run it with `FM_HOME` set to the home that owns the work.
Each named repo must already be cloned in the home's projects; the command refuses a repo it cannot resolve.
`fm-umbrella.sh --help` is the single owner of the exact contract, flags, and teardown - defer to it rather than duplicating them here.

What it gives you: one isolated worktree per repo under the umbrella, a `DESIGN.md` for the cross-repo contract, and a cross-repo `AGENTS.md`.
The captain enters the lab (`cd` into it with their coding agent) and designs the contract there - that captain-direct design is the phase this workspace exists for, and the umbrella launches no autonomous worker.
`DESIGN.md` is the durable output; the worktrees are scratch and are discarded at teardown once `DESIGN.md` exists.

## Single-repo: no umbrella

There is nothing to stand up.
Design the epic directly in the repo's normal checkout.
The captain settles the design, and the epic becomes several stories in that one repo - `/epic-scaffold` records them.

## Output

Report back exactly this shape:

- **Stage:** new
- **Shape:** cross-repo (umbrella) or single-repo
- **Workspace:** the umbrella id and its repos, or the single repo you will design in
- **Design owner:** the captain, working directly - not a spawned worker
- **next:** enter the workspace and design the contract, then /epic-scaffold to record it as a standard epic
