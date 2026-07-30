# Evals

Standardized checks that a crewmate runs on its own output BEFORE reporting a ship-mode
task done. Fail = loop and fix; never report done on a known-bad deliverable. This is how
the captain stops spending the day doing QA. Ported from the Modern AI Productivity Pack
(`resources/modern-ai-productivity-pack/03-evals/` in the command-center repo) so every
crewmate this firstmate home dispatches can reach the same eval set regardless of target
project — evals live here, not in one project, because firstmate briefs many projects.

## The set

| Eval | Grades | Runs when |
|---|---|---|
| `task-definition-eval` | the TASK, not the output | at dispatch (Next + agent-ready) |
| `principles-eval` | the reasoning/approach | any plan, research, or recommendation |
| `tov-eval` | the writing voice | anything written in Brandon Quijano's voice |
| `completeness-eval` | spec adherence | before any task moves to Done |
| `visual-asset-eval` | generated imagery | before renders reach the pick folder |
| `publish-safety-eval` | public/customer exposure | LAST, before anything leaves the building |

## Run one manually

```bash
./run_eval.sh tov some_draft.md
./run_eval.sh principles research_report.md
```

## The loop

TASK -> [task-definition] -> crewmate works -> [principles + tov/visual + completeness] ->
fails loop back automatically -> [publish-safety] -> the captain sees only cleared work.
