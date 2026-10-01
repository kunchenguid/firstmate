---
name: council
audience: swarm-plugin
description: >
  Full execution protocol for MODE: COUNCIL -- General Council research,
  parallel member dispatch, disagreement handling, and synthesis.
---

# Council Protocol

This protocol is loaded on demand by the architect runtime.
The architect prompt keeps only activation, action, and hard safety constraints;
the full execution details live here.

### MODE: COUNCIL

Activates when: user invokes `/swarm council <question>` (optionally with
`--spec-review`).

Purpose: convene a fixed three-agent multi-model General Council
(generalist / skeptic / domain expert) for an advisory deliberation. The
architect runs a curated web research pass upfront, dispatches the three agents
in parallel with the gathered RESEARCH CONTEXT, routes any disagreements back
for one targeted reconciliation round, and synthesizes the final user-facing
answer directly.

This mode is ADVISORY. It does not block any other workflow and does not modify
code, plans, or specs. The output is for the user (general mode) or for the spec
being drafted (spec_review mode is available via `/swarm council --spec-review`
for manual spec review). General Council advisory input is offered as an early
workflow option in MODE: BRAINSTORM (Phase 1b) and MODE: PLAN before
`save_plan`.

#### Pre-flight (always run first)

1. Read `council.general` from the resolved opencode-swarm config. Resolution
   is global first (`~/.config/opencode/opencode-swarm.json`), then project
   override (`.opencode/opencode-swarm.json`). A global config is valid and must
   be used when no project override is present; do not fail after checking only
   the project file. If `council.general.enabled` is not true OR no search API
   key is configured (neither `council.general.searchApiKey` nor the
   corresponding env var `TAVILY_API_KEY` / `BRAVE_SEARCH_API_KEY`),
   surface to the user: "General Council is not enabled. Set
   council.general.enabled: true and configure a search API key in
   global ~/.config/opencode/opencode-swarm.json or project
   .opencode/opencode-swarm.json." Then STOP.

#### Research Phase (always run before dispatching council agents)

2. Formulate 1-3 targeted `web_search` queries that best capture the
   information needed to answer the question. Prefer specific, keyword-focused
   queries over broad ones.

   Hard grounding rules:
   - Do not append a model training-cutoff year to searches.
   - Use `web_search` with its default `freshness: "auto"` behavior for
     current queries unless the user explicitly asked for a historical window.
   - Preserve each `web_search` result's normalized `query`, `temporalIntent`,
     `freshness`, and `removedStaleYears` metadata in RESEARCH CONTEXT audit
     notes.
   - For current, latest, today, now, state-of-the-art, pricing, release-status,
     legal/regulatory, financial, security, or otherwise time-sensitive
     questions, the Research Phase must produce usable current sources before
     council dispatch.
   - If `web_search` returns no results or an error for a time-sensitive
     question, stop and surface the failed search result to the user instead of
     dispatching ungrounded members.
   - For stable/non-current questions, if `web_search` returns no results or an
     error, note this in the dispatch message and proceed without a context
     block. In that degraded mode, members may use stable background knowledge
     only and must not make current-fact claims.

   Compile all successful results into a RESEARCH CONTEXT block in this format:

```text
RESEARCH CONTEXT
================
[1] <title> - <url>
    <snippet>
    query: <normalized query>; temporalIntent: <current|historical|unspecified>; freshness: <day|week|month|year|none>; removedStaleYears: <comma-separated years or none>

[2] <title> - <url>
    <snippet>
...
```

#### Read-before-cite discipline

When citing source code, API behavior, CLI flags, file paths, or line ranges, the synthesizing agent MUST read the actual file or tool output first. Search snippets, file globs, conversation history, and prior-round memory are not sufficient evidence. Specific anti-patterns to refuse in synthesized output:

- Quoting a line range (e.g. `src/foo.ts:123-145`) without reading those lines in the current revision.
- Restating an API signature, error message, or option flag from prior context after the source has been edited.
- Citing `bunSpawnSync` / `child_process.spawnSync` behavior from documentation that pre-dates the current version.

The synthesized answer's `sources` array should reference URLs and tool outputs the agent actually retrieved during the current session, not sources inherited from prior rounds. Mark `confidence: LOW` for any claim the agent could not verify against current source this round.

#### Round 1 - Parallel Independent Analysis

3. Dispatch `the active swarm's council_generalist agent`,
   `the active swarm's council_skeptic agent`, and
   `the active swarm's council_domain_expert agent` with `dispatch_lanes_async`
   when available -- one lane per agent. Before the first dispatch, verify from
   the session's actual tool list whether the controller's lane tools are
   present; when they are absent, use the native parallel subagent path from
   the start rather than discovering the gap on first failure. Record the returned `batch_id`, then
   continue only non-dependent architect work: prepare the synthesis outline,
   normalize the RESEARCH CONTEXT citations, and draft disagreement categories.
   Do not call `convene_general_council` or present conclusions from running
   lanes. Dispatch promptly — do not accumulate extensive planning prose before the
   call, or output truncation may swallow the tool call itself. Keep each lane `prompt`
   compact: send shared context ONCE via the `common_prompt` field, or have lanes read
   it from a file by absolute path, instead of inlining the same large blob into every
   lane prompt. Each dispatch message must
   include:
   - The question
   - Round number: 1
   - The CURRENT DATE in ISO `YYYY-MM-DD` form
   - The full RESEARCH CONTEXT block from step 2
   - Instruction: "Cite from the RESEARCH CONTEXT for external evidence. Your
     memberId and role are hardcoded in your system prompt."

Do NOT share other agents' responses at this stage.

4. While council lanes are running, poll with `collect_lane_results` (without
   `wait` or `wait: false`) to check progress and process any settled member
   responses as they complete — extract the JSON, verify `output_ref`, and
   pre-validate structure — while continuing independent architect work
   (synthesis outline, citation normalization, disagreement categories). Only
   use `wait: true` if lanes are still pending and no more independent work
   remains. All three lanes must be settled before proceeding to synthesis.
   If `dispatch_lanes_async` is unavailable, use blocking `dispatch_lanes`
   as the first fallback and record that async advisory lanes were unavailable.
   This changes only when the architect waits, not whether all council lanes
   must settle. Do not substitute Task-tool dispatch unless lane tools are
   unavailable; when they are unavailable, Task is the final fallback and must be
   verified as equivalent by agent type, prompt, scope, and isolation. The
   `round1Responses` array will contain entries with `memberId` of
   `council_generalist`, `council_skeptic`, and `council_domain_expert` and
   `role` of `generalist`, `skeptic`, and `domain_expert` respectively. If
   any lane result has `output_ref`, call `retrieve_lane_output` and parse
   the full artifact rather than the preview. If a lane is degraded,
   incomplete, truncated without a usable ref, missing, stale, cancelled, or
   failed, treat the council round as blocked or incomplete; do not synthesize
   from partial member JSON. These come from the agents' JSON output; no
   manual construction is needed.

#### Synthesis and Deliberation (when council.general.deliberate is true; default true)

5. Call `convene_general_council` with mode set from the command (`general` or
   `spec_review`), `question`, and the collected `round1Responses` only (omit
   `round2Responses`). Inspect the returned `disagreementsCount`.

6. If `disagreementsCount > 0`:
   a. For each disagreement in the tool's response, identify the disputing
      agents (the agents listed in the disagreement's positions, identified by
      memberId: `council_generalist`, `council_skeptic`, or
      `council_domain_expert`).
   b. Re-delegate ONLY to the disputing agents -- one message per agent --
      passing: their Round 1 response, the disagreement topic, the opposing
      position(s), round number 2, and the same RESEARCH CONTEXT block.
   c. Collect the Round 2 responses.
   d. Call `convene_general_council` AGAIN with both `round1Responses` AND
      `round2Responses` populated.

#### Output

7. Present the final answer to the user from the `synthesis` returned by
   `convene_general_council`. Apply these output rules directly:
   - LEAD WITH CONSENSUS: open with the strongest consensus position.
     Confidence-weighted: higher-confidence claims from multiple agents rank
     first, but evidence quality outranks raw confidence. Never elevate a
     single confident voice over a well-evidenced contrary majority.
   - ACKNOWLEDGE DISAGREEMENT HONESTLY: for each persisting disagreement, write
     "experts disagree on X because..." and present the strongest version of
     each side. Do not pretend disagreements are resolved. Do not silently pick
     a winner.
   - CITE THE STRONGEST SOURCES: link key claims with `[title](url)` format from
     the source list in the synthesis. Pick the most reputable source per claim;
     do not cite duplicates.
   - BE CONCISE: a few short paragraphs plus a bulleted summary. Expand only
     when the question genuinely requires it.
   - HARD CONSTRAINTS: You MUST NOT invent claims not present in the council's
     responses. You MUST NOT add new web research. You MUST NOT favor a position
     based on confidence alone.

Preface the answer with one line listing the participating models (reviewer
model as generalist, critic model as skeptic, SME model as domain expert). Do
NOT present raw per-member JSON.
