# Engineering health: agent-context surface audit (2026-07-07)

An audit of firstmate's agent-facing context surface for verbosity and duplication, with compression-only edits and measured before/after token costs.
Every behavioral contract was preserved in meaning; nothing was allowed to change what a rule means, and anything that would have was filed as a proposal in the audit PR instead.

## Method

Tokens were counted with tiktoken's `o200k_base` encoding over each file's full text (a close proxy for production tokenizers; word counts included for tokenizer-independent comparison).
Measurement date 2026-07-07, at commit `a790a20` (before) and this branch (after).
Section numbers, section titles, and the externally referenced subsection headings ("Away-mode stub", "Knowledge routing") were kept stable because `bin/` scripts and skills cross-reference them.

## Results

| File | Before (tok) | After (tok) | Change |
| --- | --- | --- | --- |
| AGENTS.md (always loaded) | 25,867 | 21,570 | -16.6% |
| .agents/skills/afk | 3,157 | 2,771 | -12.2% |
| .agents/skills/fmx-respond | 5,867 | 3,834 | -34.7% |
| .agents/skills/harness-adapters | 5,142 | 4,365 | -15.1% |
| .agents/skills/bootstrap-diagnostics | - | 1,386 | new (moved out of AGENTS.md) |
| other 8 skills (unchanged) | 9,899 | 9,899 | 0% |
| **Always-loaded total** | **25,867** | **21,570** | **-16.6%** |
| **Audited surface total** | **49,932** | **43,825** | **-12.2%** |

Word counts: AGENTS.md 16,098 -> 13,440 (-16.5%); audited surface 31,363 -> 26,853 (-14.4%).
README.md and CONTRIBUTING.md were audited and left unchanged: they are human-facing, and their overlap with agent-facing content is limited to short pointers (CONTRIBUTING's shellcheck command is the command itself, not duplicated prose).
`bin/` script headers were audited and deliberately left as the canonical home for mechanics, per the placement rules in `firstmate-coding-guidelines`; the dedup direction was to slim AGENTS.md's restatements of them, not the headers.

## What changed

All edits are compression, deduplication, and placement moves; no rule changed meaning, no rule priority was reordered, and no safety rule was weakened.

- One-owner dedup inside AGENTS.md: contracts that were stated in full two to four times (config inheritance, the dispatch-consultation backstop, the stale-status-log contract, the "keep Done to 10" rule, secondmate charter wording, backend selection) now have one canonical statement plus cross-references.
- Section 3's bootstrap diagnostic-line handling (about 1,400 tokens that matter only when a diagnostic actually prints) moved to a new on-demand skill, `bootstrap-diagnostics`, with its load trigger declared in sections 3 and 13 - the same inline-stub pattern as the existing away-mode stub.
- Section 5 (recovery) no longer restates section 3's digest contents; it keeps only the reconciliation steps that are unique to recovery.
- The 15-line spawn example block collapsed to 6 representative forms; backend auto-detection internals now point at `docs/configuration.md` "Runtime backend", which already stated them in full.
- Narrative and justification prose compressed to the rule it justified (for example the watcher-arming discipline in section 8, which stated "run as its own tracked background task" four times).
- Skills: fmx-respond stated its three-case mention classification, its destructive-work carve-out, and its follow-up flow three to four times each - now once each; afk stated its composer guard, max-defer escape, and submit model twice each - now once each; harness-adapters no longer restates AGENTS.md section 4's resolution and inheritance contract.

## Expected behavior impact

- Instruction-following: an always-loaded operating manual competes with live task state for attention, and long-context instruction-following degrades as instruction count and repetition grow; removing about 4,300 always-loaded tokens of repetition raises the salience of each remaining rule rather than lowering coverage, because every cut clause survives at its canonical statement.
- Lost-in-the-middle: duplicated statements of one contract in different wordings invite drift and contradictory partial matches when attention is mid-document; the one-owner structure gives retrieval exactly one target per contract.
- Cost: AGENTS.md is loaded by the primary and by every secondmate at every session start and re-read after self-updates, so the saving compounds across the fleet (about 4,300 tokens per session context per instance, plus cache-miss rereads).
- Risk: compression can lose nuance; this was checked by a token-survival sweep (every command, flag, env var, threshold, path, and verb-set token removed from a file was verified to survive somewhere in the instruction surface; the only three losses are deliberately cut redundant examples) plus a scenario walk-through below.

## Qualitative scenario check

Three representative supervision scenarios re-run against the slimmed manual, each still determined unambiguously:

1. A `stale:` wake for a crewmate mid-no-mistakes-validation whose last status line reads `done:` from before the validation started - section 8 still states that a provably-working crew always wins over a stale captain-relevant log line and is absorbed, with the 240s wedge threshold and the `demand-deep-inspection` marker at 3 escalations intact.
2. A `done: PR <url> checks green` signal on a `no-mistakes` project with `yolo=off` - section 7 still requires `fm-pr-check`, relaying the full PR URL with summary and risk level, waiting for the captain's explicit merge word, merging only via `bin/fm-pr-merge.sh`, and teardown only after the merge is confirmed landed.
3. Session start when another session holds the lock - section 3 still requires the read-only banner behavior: tell the captain, mutate nothing, no drain, no watcher arm, no checkout repair.

A fourth flow changed shape deliberately: a bootstrap diagnostic line (for example `MISSING: tasks-axi`) now routes through loading `bootstrap-diagnostics` first; the consent-before-install rule stays inline in section 3 so it holds even if the skill is never loaded.
