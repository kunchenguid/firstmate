---
name: pre-phase-briefing
audience: swarm-plugin
description: >
  Full execution protocol for MODE: PRE-PHASE BRIEFING -- phase-start context assembly, evidence review, and task readiness checks.
---

# Pre Phase Briefing Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: PRE-PHASE BRIEFING (Required Before Starting Any Phase)

Before creating or resuming any plan, you MUST read the previous phase's retrospective.

**Phase 2+ (continuing a multi-phase project):**
1. Check `.swarm/evidence/retro-{N-1}/evidence.json` for the previous phase's retrospective
2. If it exists: read and internalize `lessons_learned` and `top_rejection_reasons`
3. If it does NOT exist: note this as a process gap, but proceed
4. Print a briefing acknowledgment:
```
→ BRIEFING: Read Phase {N-1} retrospective.
Key lessons: {list 1-3 most relevant lessons}
Applying to Phase {N}: {one sentence on how you'll apply them}
```

**Phase 1 (starting any new project):**
1. Scan `.swarm/evidence/` for any `retro-*` bundles from prior projects
2. If found: review the 1-3 most recent retrospectives for relevant lessons
3. Pay special attention to `user_directives` — these carry across projects
4. Print a briefing acknowledgment:
```
→ BRIEFING: Reviewed {N} historical retrospectives from this workspace.
Relevant lessons: {list applicable lessons}
User directives carried forward: {list any persistent directives}
```
   OR if no historical retros exist:
```
→ BRIEFING: No historical retrospectives found. Starting fresh.
```

This briefing is a HARD REQUIREMENT for ALL phases. Skipping it is a process violation.

### CODEBASE REALITY CHECK (Required Before Speccing or Planning)

Before any spec generation, plan creation, or plan ingestion begins, the Architect must verify the codebase reality of every item the work references. This runs as **asynchronous, fanned-out Explorer lanes by default**, joined behind a hard settlement gate — never as a single blocking explorer call, and never as fire-and-forget.

**1. Enumerate and partition the references (before dispatch).**
List every referenced item — file, module, function, API, config surface, and behavioral assumption — named or implied by the spec, the user request, or the plan. Partition them into **non-overlapping** lane assignments. The partition is the contract: no two lanes may share a reference (this prevents duplicated work), and the **union of all lanes must cover every referenced item** (this prevents gaps). Under-specified lane boundaries are the dominant fan-out failure mode — be explicit about what each lane owns.

**2. Scale the number of lanes to the size of the referenced surface.**
- Trivial surface (a single file/function, one logical area) → **1 lane**.
- Typical phase spanning a few areas → **2–4 lanes**.
- Large surface (many modules/hooks/config surfaces) → **more lanes, up to the dispatch cap of 8 lanes per batch**.

Do not fix the lane count in advance and do not over-spawn: extra lanes on a small surface waste tokens without improving coverage, while too few on a large surface leave gaps. Split by codebase area by default; when the surface is a single dense area, split by check-type instead — one lane for *existence & current state*, one for *assumption correctness & prior-work*.

**Capability gate (before the first dispatch).** Check the session's actual tool
list: if `dispatch_lanes_async`/`collect_lane_results` are not present
(non-controller hosts — Claude Code, Codex, ZCode), run the same lanes as native
parallel subagents, or as strictly sequential passes when no subagent mechanism
exists. The disjoint reference partition, the hard settlement gate, and per-lane
provenance are unchanged on every path; record that dispatch was procedural, and
never fabricate `batch_id` or lane receipts.

**3. Dispatch asynchronously, then keep working.**
Dispatch the lanes with `dispatch_lanes_async`, record the returned `batch_id`, and continue **non-dependent** Architect work while they run — digest the retrospective and `user_directives`, review the spec/plan text for internal consistency, check governance/QA-gate config and the obligation ledger, and prepare the plan skeleton / task decomposition. This is dispatch-and-keep-busy, not fire-and-forget. Poll with `collect_lane_results` (wait omitted or false) to process settled lanes incrementally, or join with `wait: true` once independent work is exhausted.

Each lane must be given: its objective, its named (disjoint) reference subset, the fixed REALITY-CHECK output format below, and clear boundaries. Lanes are read-only — they cannot `declare_scope` or mutate the worktree.

**4. For each referenced item, the lane must determine:**
- Does this file/module/function already exist?
- If it exists, what is its current state? Does it already implement any part of what the plan or spec describes?
- Is the plan's or user's assumption about the current state accurate? Flag any discrepancy between what is expected and what actually exists.
- Has any portion of this work already been applied (partially or fully) in a prior session or commit?

**5. Hard settlement gate (join before any downstream work).**
The Architect synthesizes the lane outputs into a single CODEBASE REALITY REPORT. The report must list every referenced item with one of:
  NOT STARTED | PARTIALLY DONE | ALREADY COMPLETE | ASSUMPTION INCORRECT

Format:
  REALITY CHECK: [N] references verified, [M] discrepancies found.
    ✓ src/hooks/incremental-verify.ts — exists, line 69 confirmed Bun.spawn
    ✗ src/services/status-service.ts — ASSUMPTION INCORRECT: compactionCount is no longer hardcoded (fixed in v6.29.1)
    ✓ src/config/evidence-schema.ts — confirmed phase_number min(1)

No spec finalization, plan generation, plan ingestion, `declare_scope`, or implementation-agent dispatch (coder, reviewer, test-engineer) may begin until ALL lanes in the batch are settled (`collect_lane_results` reports `all_settled`) AND this report is finalized. A lane that is missing, failed, or timed out is an explicit coverage gap, not a pass: mark the affected references BLOCKED or SKIPPED_WITH_REASON and resolve them before proceeding — never silently continue. Async dispatch changes *when* the Architect waits, never *whether* the gate holds.

This check fires automatically in:
- MODE: SPECIFY — before explorer dispatch for context (step 2)
- MODE: PLAN — before plan generation or validation
- EXTERNAL PLAN IMPORT PATH — before parsing the provided plan

GREENFIELD EXEMPTION: If the work is purely greenfield (new project, no existing codebase references), skip this check. A trivial single-area surface stays a single lane rather than being force-fanned.
