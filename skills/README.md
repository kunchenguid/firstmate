# Public skills

Standalone, installer-facing skills - harness-agnostic and self-contained, invoked as `/<name>` on any coding agent.
These are NOT the firstmate-loaded internal skills (those live under `.agents/skills/` and carry `metadata.internal=true`).

## Epic pipeline

Six skills that take a multi-story feature from an empty workspace to shipped, in order.
Each skill's `SKILL.md` is the single owner of that step's contract; run them the way your coding agent runs skills.

| Skill | One-line |
|---|---|
| `/epic-new` | Entry point: decide cross-repo vs single-repo and stand up the workspace (a `bin/fm-umbrella.sh` lab for cross-repo), then hand off. |
| `/epic-scaffold` | Turn a settled design into a STANDARD epic - `epic.md` plus one story file each carrying the exact required frontmatter, so it promotes with no orphans or doubled epics. |
| `/epic-plan` | Run the fleet's real planning tool once per story to produce a per-story plan directory; the story's plan section becomes a pointer to it, never a hand-written plan. |
| `/epic-review` | Independent design-review GATE (run as a different agent): checks frontmatter, contract, dependencies, and each plan, then writes a PASS/FAIL `REVIEW.md`. FAIL blocks handoff. |
| `/epic-handoff` | Promote a reviewed, captain-signed epic into the home backlog via `bin/fm-umbrella-promote.sh`, seeding ids and tags from the frontmatter so nothing orphans, then guide the next steps. |
| `/epic-ship` | Ship a finished epic per repo through the gated flow via `bin/fm-epic-ship.sh` - opens the epic PRs and records URLs but never merges; the captain or merge authority merges. |

An umbrella lab created by `bin/fm-umbrella.sh` points its design agent at this pipeline through the AGENTS.md it writes into the workspace.

## Other

| Skill | One-line |
|---|---|
| `/stow` | Sweep a session for uncaptured durable knowledge and curate the home's startup memory before a context reset. |
