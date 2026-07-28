# Merge firstmate's operating discipline into Alfred (global)

## Status: COMPLETE (verified 2026-07-27)

All four items shipped, confirmed by directly reading the live files rather than trusting memory:
- `~/.claude/SOUL.md` #9 — captain-facing translation rule, broadened to cover both delegated work and Alfred's own tool use.
- `~/.claude/SOUL.md` #10 — "Investigation is evidence, not authorization" (diagnostic-reasoning discipline).
- `~/.claude/SOUL.md` #11 — "Never let an open decision go silent" (decision-hold-lifecycle).
- `~/.claude/CLAUDE.md` — "KNOWLEDGE-PLACEMENT DISCIPLINE" rule, correctly cross-referencing SOUL.md rather than duplicating the behavioral commitments.

## Context

Brandon has been running this session with me acting *as* firstmate — a separate persona/repo (`ops/firstmate/`, loaded from its own `AGENTS.md`) that orchestrates a fleet of crewmate agents with heavy operational discipline: supervision loops, receipt-on-done rigor, plain-language escalation, project-write boundaries, decision tracking. He liked how that discipline felt and wants Alfred — his always-on assistant across every project — to run with "all of firstmate's best and most vital systems and logic," permanently, not just inside this repo.

I read Alfred's actual global files (`~/.claude/IDENTITY.md`, `SOUL.md`, `USER.md`) to see what's already there before proposing changes. Finding: **a lot of firstmate's discipline is already ported.** Command-center's project `CLAUDE.md` already has "DEFINITION OF DONE — TWO GATES" (Schema-First + Receipt-on-Done, mirroring firstmate's Ground-Truth-Contract), "NO BLIND TURN-END" (mirrors firstmate's "no turn ends blind while work is under way"), full git safety rules, and a structured memory system (mirrors firstmate's `learnings.md`/`captain.md`/`captain-shared.md`). SOUL.md commitment #9 ("Report delegated work in outcomes and decisions, never in watcher/queue/task-id mechanics") is already a condensed version of firstmate's section 9 translation contract.

So this isn't a wholesale import — it's identifying the **genuine gaps**: firstmate discipline that is *not yet* codified anywhere in Alfred's global behavior, cleanly portable (doesn't depend on firstmate's fleet-specific infrastructure — worktrees, herdr/treehouse backends, tasks-axi, crewmate spawn/supervise loop, which have no equivalent surface for Alfred and shouldn't be cargo-culted in without the underlying tech).

## What NOT to port (and why)

- Crew/task lifecycle mechanics (`fm-spawn.sh`, worktree isolation, herdr/treehouse backends, tasks-axi backlog) — this is fleet-orchestration tooling. Alfred's closest equivalent is the `Agent`/`Workflow` tools, which already have their own dispatch/verification conventions (see the Agent tool's "Trust but verify" guidance already in Alfred's system prompt).
- The full "captain etiquette" jargon-translation table verbatim — firstmate's list translates firstmate-specific terms (worktree, herdr, tasks-axi). Alfred needs the *principle*, not that literal table.
- Watcher/supervision loop (`fm-watch-arm.sh`) — this exists because firstmate runs a fleet with async background completion the primary session must not miss. Alfred's analogous risk is background `Agent`/`Workflow` dispatch, and command-center's CLAUDE.md **already** has "NO BLIND TURN-END" covering exactly this. No new mechanism needed.

## What to actually add (the real gaps)

1. **Diagnostic-reasoning discipline** — firstmate's rule that a scout/investigation/audit finding is evidence, never authorization to implement; a separate go-ahead is required before code changes. Alfred's global files have nothing like this today — worth a short, universal addition since Alfred routinely produces analyses/audits across every project.

2. **Decision-hold-lifecycle** — firstmate never lets an unresolved decision discovered mid-task quietly vanish; it's recorded and tracked to resolution. Alfred has no equivalent principle stated anywhere. Worth adding as a short universal rule: any open question/decision surfaced mid-task gets explicitly named to Brandon before the task is considered done, not buried in a wall of text or silently dropped.

3. **Sharpen the captain-facing translation contract** — SOUL.md commitment #9 already exists but is narrowly scoped to "delegated work." Broaden it into a general rule: never surface tool/infra mechanics (background task IDs, internal hook names, raw file paths unless needed to act) in conversation with Brandon — always translate to outcome + consequence + next decision. This is the one piece of firstmate's section 9 genuinely worth generalizing.

4. **Knowledge-placement discipline for Alfred's own memory system** — firstmate's `firstmate-coding-guidelines` skill has a real, useful meta-system: a decision tree for where a new fact belongs (inline in the always-loaded file vs. a skill vs. docs vs. script help), plus a "one-owner rule" (state a contract once, cross-reference everywhere else, never duplicate). Alfred's own auto-memory system (described in this session's system prompt) doesn't yet state this discipline explicitly. Worth adding as a short principle so Alfred's memory files stay lean as they accumulate, instead of the CLAUDE.md-bloat problem firstmate had to fix.

## Files to change

- **`~/.claude/SOUL.md`** — extend commitment #9 into the broader translation-contract rule (item 3); add diagnostic-reasoning (item 1) and decision-hold (item 2) as new short commitments (10, 11, 12).
- **`~/.claude/CLAUDE.md`** — add a short "Knowledge placement discipline" note near the memory-system instructions (item 4), pointing back to SOUL.md for the behavioral commitments so the rule isn't duplicated in two places (practicing the one-owner rule while adding it).

Each addition will be **short** (2-4 lines, matching the existing terse style of SOUL.md's numbered commitments) — not a copy of firstmate's much longer prose, since Alfred's files are deliberately compact and firstmate's own discipline says don't bloat the always-loaded file.

## Verification

- Read back the edited `SOUL.md` and `CLAUDE.md` in full to confirm the new commitments read naturally alongside existing ones, use Alfred's existing voice/style, and don't duplicate content already covered by "DEFINITION OF DONE — TWO GATES" / "NO BLIND TURN-END" in command-center's project CLAUDE.md.
- No code changes, no repo behavior changes — this is a persona/instruction-file edit only, so "testing" means confirming the files parse as clean markdown and the numbering/cross-references are consistent.
