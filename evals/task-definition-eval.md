# EVAL: Task Definition — "Is this task actually delegatable?"

**Applies to:** the TASK ITSELF, before an agent picks it up. Run at dispatch time (Next + agent-ready). Being productive today is defining constraints better than everyone else; this eval enforces that.

## Checklist (any miss = FAIL, bounce back to Nick with questions)

1. **Done-state is testable.** A stranger could look at the output and say yes/no it's done. "Improve the landing page" = FAIL. "Rewrite the hero section to lead with the $4M→$6M case study, under 40 words" = PASS.
2. **Constraints stated.** What must NOT change, what tools to use/avoid, budget/length/format limits.
3. **Context linked.** The task names its inputs (files, URLs, prior issues) instead of assuming the agent will guess.
4. **Escalation defined.** What the agent should do when blocked: comment and move to Waiting, never silently stall or improvise around a paywall/permission.
5. **Right-sized.** Completable in one agent session (<2h equivalent). Bigger = should be split.

## Output contract

```
VERDICT: DELEGATABLE | BOUNCE
MISSING: [numbered list of what the task needs before an agent can run it]
SHARPENED REWRITE: [the task description rewritten to pass, best guess flagged with ASSUMPTION tags]
```
