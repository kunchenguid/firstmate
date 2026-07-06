---
name: deck
description: Generate the "where are we" deck - a per-project or whole-fleet HTML summary rendered on demand from live ground truth (the project registry, the backlog, task meta, and live crew state), never hardcoded and never hand-maintained. Use when the captain invokes /deck (e.g. "/deck", "/deck <project>") or asks "where are we", "where are we on <project>", or wants a glanceable picture of a project's stories and what is waiting on them.
user-invocable: true
metadata:
  internal: true
---

# deck

Answer "where are we" with a generated visual summary instead of a from-memory prose reconstruction.
The deck is a **map, not a cockpit**: it shows each project's story backlog, what is waiting on the captain, and a jump pointer to each live session - and nothing on it is a control.
Review, dialogue, and approvals stay in the harness.

Every deck is generated from ground truth at generation time and thrown away.
Never reuse, hand-edit, or incrementally patch a previously generated deck, and never invent a store, daemon, or refresh loop for it: the next "where are we" simply regenerates from current state.

## Step 1 - Resolve the scope

`/deck <project>` or "where are we on <project>" scopes to one project; resolve the name with the normal intake rules (AGENTS.md section 7) and ask a one-line question on ambiguity.
Bare `/deck` or a general "where are we" means the whole fleet, grouped per project.

## Step 2 - Gather ground truth (all reads, gathered fresh this run)

- **What each project is**: its registry line in `data/projects.md` (name, delivery mode, `+yolo` posture, one-line description), plus a one-line identity from the project's own `README.md` or `AGENTS.md` when the registry line alone is too thin.
- **Stories, two levels (project → story)**: from the backlog - `tasks-axi list --state in_flight`, `tasks-axi list --state queued --fields blocked_by`, and `tasks-axi list --state done` (or read `data/backlog.md` directly per the AGENTS.md section 10 format when the tasks-axi backend is unavailable or opted out), then group the stories by project yourself from each item's `repo:` field.
  Do not scope the deck with `--repo` filtering: the section 10 line forms can carry extra text inside the repo parens (in-flight lines append `, since <date>`) or no repo field at all (done lines), so a `--repo` filter silently drops stories; grouping in your own read keeps every story on the deck, and a per-project deck simply renders only that project's group.
  Attribute an item whose line carries no clean `repo:` field (done lines usually do not) by its PR URL, report path, or task meta `project=`.
- **Live state per in-flight story**: `state/<id>.meta` (`window=`, `kind=`, `mode=`, `pr=` when present), then `bin/fm-crew-state.sh <id>` for the current state line.
- **Needs-you is derived, never stored**: mark a story needs-you when its live state or latest captain-relevant verb says the captain owns the next move - `needs-decision`, `blocked`, `failed`, a parked validation gate, `done: PR <url> checks green` awaiting merge, or `ready in branch` awaiting local review.
  The backlog file never carries a needs-you state; recompute it every generation.
- **Jump-to-session pointer**: from the task meta's `window=` value.
  When meta records no `backend=` (the tmux default), the pointer is the one-liner `tmux select-window -t <window>`.
  For a non-tmux `backend=`, show the backend name and recorded target as a label instead of a tmux command.

If ground truth disagrees with itself - a backlog story with no meta, a meta whose endpoint is dead, a registry project missing from `projects/` - show the drift honestly on the deck rather than papering over it; surfacing that drift is half the deck's value.

## Step 3 - Render

Write the artifact to `.lavish/deck.html` for the whole fleet or `.lavish/deck-<project>.html` for one project (gitignored scratch, never committed).
Run `lavish-axi design` for the CDN snippets and use the Tailwind v4 + DaisyUI v5 stack; keep every nesting level free of horizontal overflow.
If a live-deck prototype happens to exist at `.lavish/firstmate-deck-live.html` (captain-local gitignored scratch, absent on most installs), it may serve as an optional visual reference.
Either way, the numbered structure below is the authoritative template; populate it entirely from step 2's data - no remembered, sample, or placeholder content:

1. **Status strip** - counts across the rendered scope: needs-you, building (in-flight and working), queued, projects tracked.
2. **One section per project with stories** - heading with project name, mode badge, and one-line identity; then story cards ordered needs-you → building → queued → recent done.
   Each card: status badge, story title, a one-line situation note, `blocked-by` when set, and for live stories the crew-state detail plus the jump pointer rendered as copyable code text.
3. **Idle tracked projects** - a compact grid of registry projects with no active stories, so the fleet's full breadth stays visible on a fleet deck.
4. **Honest footer** - generation time and any drift found in step 2.

Buttons and links that pretend to act are forbidden: the only bridge from deck to cockpit is the jump pointer, and annotations are the only input surface.

## Step 4 - Open, no loop

Open it with `lavish-axi .lavish/deck.html` (or the per-project filename).
The deck is read-mostly, so no `lavish-axi poll` loop is required; do not hold the turn waiting on it.
If the captain reacts, they will do it in chat - or with Lavish annotations, which arrive like any other session feedback and are handled in conversation, not by adding interaction to the deck.
End or abandon the session freely; the file is disposable and the next ask regenerates it.
