# Supported-pack notes: addyosmani/agent-skills

Load these when the captain asks what this pack brings, what the adapter leaves out, or for a project's constraints file.

## What the pack brings

At the supported version, 0.6.14, the pack brings 25 skills, 9 commands, and hook scripts it does not register in a `hooks.json`, so the runtime loads its skills and commands and does not run the hooks on its own.
What the runtime loads from the pack, its commands and any hooks it registers, is the runtime's and the captain's choice, not the adapter's.
The adapter replaces nothing, never puts the pack first, and inserts one position, `reproduce`, for bug fixes only.

## Left out on purpose

- The pack's human-wait gates as gates, the `using-agent-skills` router, `context-engineering`, the commands as commands, and everything in `git-workflow-and-versioning` beyond its commit-convention line, its raw worktree and reset steps included; each one either stops a turn for a person or works against isolated parallel work.
- `test-driven-development` as a step before `work`.
- From `code-review-and-quality`: its process for reviewing someone else's change, because no-mistakes owns independent review and the fast paths deliberately have none; its multi-model pattern, because reviewer models are pipeline setup; and its reviewer checklist template, because firstmate writes its own PR and handoff text.
- From `shipping-and-launch`: running a staged rollout, flipping flags in production, running a rollback, and setting up production dashboards or alerts, all outward-facing; its error-budget gate as a merge gate, because merge authority is off limits to every adapter, though a project's own CI may enforce it as project-owned policy; and the production-side checklist items, setting production environment variables, applying migrations, DNS, SSL, and the CDN, each outward-facing.
- From `constraint-driven-development`: block-or-warn gating, which stays with CI and no-mistakes, and the pack's post-edit hook, because worker hooks stay firstmate's.

## A project's constraints file is a task

`constraint-driven-development` writes a project's quality bar to `CONSTRAINTS.md` after a four-question interview, and its own rule says that interview needs a live user, so no worker writes the file on its own and the adapter never interviews.
When the captain wants a project's bar written, take it as a task: ask the skill's four questions in chat, each with its stated default, and write the file only with the captain's explicit approval of its content, through the project's normal delivery.
The same task proposes the skill's tooling as one project change for the captain's approval, shipped the same way: the tool installs of its Step 4 as dev dependencies or CI steps, with machine-wide tools such as gitleaks and osv-scanner in CI only; the check scripts `check:fast`, `check:task`, and `check:full` in the project's own scripts, so the floor's "run the repository's own checks" line and the pipeline's test step pick them up; and the skill's floor-guard reference adapted into the project and reviewed like any other code, never run from the pack.
The line the skill would add to the project's `AGENTS.md` or `CLAUDE.md` stays a deliberate human edit; the adapter reads `CONSTRAINTS.md` directly, so no pointer is needed.
