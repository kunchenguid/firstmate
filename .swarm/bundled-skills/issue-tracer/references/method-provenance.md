# Method Provenance (state of the art)

The quality methods in this skill are grounded in current agentic-repair and agent-reliability research, adapted to a plan-first, evidence-first, full-resolution workflow:

- Hierarchical file -> function -> line localization, multi-sample candidate patches, and validate-then-select repair: Agentless (Xia et al. 2024, https://arxiv.org/abs/2407.01489).
- Reasoning-guided, explanation-ranked fault localization (a causal explanation per candidate, not surface similarity): RGFL (https://arxiv.org/pdf/2601.18044); structure/spectrum-aware search: AutoCodeRover (https://arxiv.org/abs/2404.05427).
- "Tests passing is plausible, not correct" / patch overfitting: patch-correctness survey (https://dl.acm.org/doi/10.1145/3702972).
- Self-consistency across independent passes: Wang et al. 2022 (https://arxiv.org/abs/2203.11171).
- A fresh independent context refutes the result (the doer is not the grader) and evidence-grounded reporting (show the command and its output, do not assert success): Anthropic, "Effective harnesses for long-running agents" (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).
- Plan -> implement -> review separation as explicit quality gates: Anthropic, "Building Effective Agents" (https://www.anthropic.com/research/building-effective-agents).
- Escalate when the issue lacks reproducible steps or acceptance criteria (issue clarity predicts resolution success): GitHub coding-agent best practices (https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/best-practices-for-using-copilot-to-work-on-tasks).

Recurrence-class eradication (Phase 4.2) generalizes the "fix the class, not the instance" principle: a single-site repair that leaves the defect class searchable and reintroducible has not closed the issue's real surface. The guardrail ladder (static rule -> type constraint -> runtime/trust-boundary assertion -> CI check -> documented invariant + regression family) prefers machine-enforced prevention over human vigilance.

## Acceptance-check loop (Phase 2.5, "acceptance-test-driven, not ritual TDD")

The figures below are as reported by the cited work and were not re-derived here; the plan relies on the mechanisms, not the exact numbers.

- Current Claude Code guidance frames TDD as "give the agent a check it can run" plus an independent verifier subagent that tries to refute the result, and names the failure mode of an agent weakening a test rather than fixing the implementation. https://code.claude.com/docs/en/best-practices - the load-bearing parts are the red checkpoint and the independent verifier, not the red/green ritual itself. (The older four-step wording sometimes quoted for this guidance is UNVERIFIED against a current primary source.)
- Issue-to-reproduction tests, used as a filter, roughly double patch precision: SWT-Bench (https://arxiv.org/abs/2406.12952).
- Mutation-score-gated test selection raises generated-test quality further: EvoOtter (https://arxiv.org/html/2607.02854v1).
- Human-written acceptance tests as the spec, with patches hard-blocked from touching test folders, found the bottleneck is human-written test quality, not repair capability, and recorded real test-hacking attempts in a large audit: TDFlow (https://arxiv.org/html/2510.23761v1).
- A meaningful share of "test passed" validation events in agentic repair carry no information because the check also passes on the buggy code; replaying checks against the pre-fix state measurably cuts such evidence-inadequate closures - the bug-contrast replay rule in `references/acceptance-checks.md`: BSG-VA (https://arxiv.org/html/2607.28871).
- Agent-generated tests used to rank patches overfit toward the same agent's own patches, motivating a separate test-author context: "Rethinking the Value of Agent-Generated Tests" (https://arxiv.org/pdf/2602.07900).
- Specification-gaming studies show agents overwriting tests, monkey-patching scorers, and deleting assertions at rising rates under RL post-training, which is why independent replay is never optional: SpecBench (https://arxiv.org/html/2605.21384v1, https://arxiv.org/pdf/2605.02269).
- Mutation testing as an adversarial check on agent-written tests, scoped to changed code and fed back as instructions rather than optimized as a metric - the revert/mutation probe recipe: (https://www.awesome-testing.com/2026/08/mutation-testing-for-agent-written-code, https://testdouble.com/insights/keep-your-coding-agent-on-task-with-mutation-testing).
- A controlled experiment on fully autonomous red/green agent loops found no measurable quality gain and tautological, implementation-derived tests; the independent checkpoint between red and green, not the ritual, is the active ingredient: Fowler/Boeckeler (https://martinfowler.com/articles/exploring-gen-ai/tdd-in-the-agent-loop.html).
- Characterization tests first for undocumented/legacy paths, so a fix's blast radius is visible before it is taken: (https://www.tddbuddy.com/blog/characterization-tests-are-the-on-ramp/).
- Untrusted-content and least-privilege handling for intake draws on the general shape of prompt-injection incident reporting in agentic tool use: OWASP agentic top-10 guidance (https://owasp.org/www-project-top-10-for-large-language-model-applications/) - cited for framing only; specific incident statistics are not restated as fact here.
