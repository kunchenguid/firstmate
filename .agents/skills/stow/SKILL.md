---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Required startup-memory pass

Every `/stow` invocation performs this complete pass, even when the session contains no new finding:

1. Run `bin/fm-startup-memory-budget.sh report` before considering a write.
   Record its effective budget and each file's estimated-token total.
   The helper's stable estimate is the documented conservative local approximation, not provider-exact accounting.
   If it rejects the setting or a memory file, do not infer a default or silently continue.
   Report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`.
   Treat an absent local file as absent, not as an invitation to manufacture content.
   In a primary home, all three are curation inputs under their existing ownership rules.
   In a secondmate home, `data/captain-shared.md` is a read-only primary-owned input: count it, never edit it, and curate only the editable local files.
3. Build one whole-file retention plan before editing.
   Retain, in order: current captain preferences, authority and safety boundaries, and recurring working style; stable home-local operating facts that repeatedly affect future work and are expensive to rediscover; then concise pointers to an existing authoritative report, project document, configuration, or backlog item.
   Retain lower-priority material only while budget remains.
4. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Remove, merge, or route completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, superseded claims, duplicates, and report-sized procedures.
   Do not remove a unique current fact unless it is preserved directly elsewhere through a stronger existing owner.
5. Run `bin/fm-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget unless a concrete inability remains.
   A secondmate must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Any other unresolved excess must identify the fact that cannot safely be removed or routed and why.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md section 6 is the source of truth for destinations.
   Do not re-derive or duplicate that mapping here.
3. **Write within the existing boundaries.**
   - Captain preferences and fleet-local operational facts belong in the destination selected by AGENTS.md after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - In a primary home, curate shared captain preferences only under the existing primary-authoritative shared-preference contract.
     In a secondmate home, route a newly discovered shared preference to the main firstmate through marked status or a document pointer instead of editing the inherited file.
   - Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`.
     Route it through a normal ship task so a crewmate records it with `bin/fm-ensure-agents-md.sh` and the project's delivery path.
   - Knowledge general to every Firstmate user belongs in this repo's shared tracked material through the normal branch, no-mistakes, PR, and captain-merge path.
   - For task-scoped notes, inspect the item with `tasks-axi show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then use a considered replacement body through `tasks-axi update <id> --body-file <path>`.
     Use `--archive-body` when recoverability matters.
     Never append.
   - File each undone next step as a queued backlog item with a genuine `blocked-by` dependency when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be deleted, retired, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, or deletion of a stale entry.
   Do not invent another graduation path.

## Fresh-session safety

Treat a compact summary as navigation evidence, never as a durable knowledge destination or a substitute for the ownership routes above.
Call the current session safe to reset only after a major investigation or implementation phase has ended and all of these conditions hold:

- the current goal, accepted requirements, every still-binding authority boundary, every open decision, the exact code or pull request head, active file changes, validation receipts, and ordered next actions are recorded in their authoritative durable owners;
- every unresolved report or visual-review decision has passed the `decision-hold-lifecycle` completion owner;
- no active tool call, queued message, compaction, or retry is in progress;
- no credential or approval exists only in conversation context;
- the next task can resume from named durable files and structured fleet state without broad evidence rereads.

Refuse a reset-safe verdict while any binding authority, open decision, exact head, validation receipt, active change, or next action exists only in conversation context.
Recommend a fresh session after one successful bounded compaction when the next provider-reported input remains above 50,000 tokens on two ordinary turns, the summary exceeds 3,000 output tokens without a documented safety need, or a closed investigation still dominates the next task's context.
Do not recommend a fresh session merely because the JSONL file is large.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`: `unchanged`, `added`, `rewritten`, `pruned`, or `routed`;
- each durable finding filed outside memory and its authoritative owner;
- every unresolved exception, including a primary-owned shared-file constraint in a secondmate home;
- whether the session is safe to reset, only when all durable findings are captured, the fresh-session conditions above hold, and the post-pass result is within budget with no exception;
- when reset is safe, one copy-pasteable final line in this exact shape: `RESUME POINTER: Load <named durable files>; inspect <structured fleet source>; continue with <first next action>.`

Every resume-pointer file and structured source must already exist and contain the current state it names.
Keep the literal uppercase `RESUME POINTER:` prefix and the three semicolon-delimited clauses, and never rename or paraphrase that receipt label.
Withhold the resume pointer and state the missing durable fact when reset is unsafe.
Do not hide an over-budget result or a conversation-only authority fact behind a reset-safe claim.

## Scope exclusion: no skill storage

`/stow` must never store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
Until a human deliberately scopes a skill change as Firstmate repository work, route generalizable knowledge to shared tracked material through its pipeline and fleet-local knowledge to `data/`, never to `.agents/skills/` or public `skills/`.
