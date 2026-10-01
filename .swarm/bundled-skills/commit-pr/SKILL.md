---
name: commit-pr
audience: swarm-plugin
description: >
  Apply when committing, pushing, opening or updating a pull request, or closing
  out CI. A portable, project-agnostic commit and PR workflow: verify before you
  push, write conventional commits and a clear PR body, and never commit
  generated or secret files.
effort: medium
---

# Commit & PR Protocol (portable)

## Graph-first evidence contract

Before publication, use `repo_map` `diff_context` and `impact_cone` as a final drift check, then verify the direct source, Git diff, and tests. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or an action fails, publication decisions rely on the direct evidence.

A project-agnostic workflow for landing a change safely. It makes no assumptions
about the language, build tool, or hosting provider — discover each project's
own conventions and follow them. Do every step in order.

> If the repository ships its own commit/PR contract (a `CONTRIBUTING.md`, a
> pull-request template, a contributor-guide file, or a project-specific
> commit-pr skill), that contract wins over this generic guidance. Read it first.

## Step 0 — Working-tree hygiene

1. `git status` and `git diff` — know exactly what you are about to commit.
2. Confirm you are on a feature branch, not the default branch. If you are on
   `main`/`master`, create a branch first.
3. Do not stage generated output, dependency directories, local caches, or
   secrets (build/`dist` output, `node_modules`/`target`/`vendor`, `.env`,
   credentials, keys). If any are tracked or unignored, fix `.gitignore` instead
   of committing them.

## Step 1 — Discover the project's checks

Find the project's own validation commands rather than guessing:

- A package manifest's script section (e.g. `package.json` `scripts`,
  `Makefile` targets, `pyproject.toml`, `Cargo.toml`, `justfile`, `Taskfile`).
- CI workflow files under `.github/workflows/` (or the provider's config) —
  these are the checks that must pass to merge.

Run the project's build, test, lint, type-check, and format checks — whatever
exists. Pin tool versions to what the project declares so local results match
CI. If a check fails, fix the cause; do not weaken, skip, or delete the check.

## Step 2 — Verify before you push

Run the discovered checks and confirm they pass. Report the exact commands and
their results — never claim a check passed without having run it. Passing tests
mean the change is *plausible*, not automatically *correct*: make sure the change
actually does what the task intended.

## Step 3 — Commit

Write a clear, conventional commit message:

- Title: `<type>(<scope>): <summary>` where `<type>` is one of `feat`, `fix`,
  `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `revert`.
- Keep the title short and imperative; put detail in the body.
- One logical change per commit where practical.

## Step 4 — Push

1. Identify the correct remote. If the repo has several remotes, push to the one
   the PR targets (the upstream you are contributing to), not an unrelated fork.
2. `git push -u <remote> <branch>` for a new branch.
3. If a push is rejected because you rebased, use `git push --force-with-lease`
   — never a plain, unconditional force push. `--force-with-lease` refuses to
   overwrite commits the remote gained since your last fetch, so it cannot
   silently clobber a teammate's work.

## Step 5 — Open or update the PR

Search the repo for a PR template
(`.github/PULL_REQUEST_TEMPLATE.md` or `.github/PULL_REQUEST_TEMPLATE/`). If one
exists, fill in its sections. Otherwise write a body with at least:

- **Summary** — what changed and why.
- **Test plan** — the checks you ran and their results.
- A linking keyword (`Closes #<issue>`) when the PR resolves an issue.

Use a PR title in the same conventional-commit form as your commit.

Before generating the PR body, check if `.swarm/issue-reference.json` exists. If it
does and contains a `number` field, auto-populate `Closes #<number>` as the first line
of the PR body. If the file does not exist, fall back to `Closes #<issue-number>`.

## Step 6 — Close out CI

After the PR is open, watch its checks. If CI fails, read the logs, reproduce
locally, fix the real cause, and push again. A PR is not done until its required
checks are green and any review feedback is addressed. Do not merge over failing
required checks or disable a check to go green.

If this session is running an issue trace (`/swarm issue --trace`), call
`record_issue_publication` (issue number, PR number, canonical PR URL, HEAD sha)
right after the PR is opened so the issue-trace workflow can reach its terminal
`published` state — without it the trace stays at `publication_handoff` and is NOT
considered resolved.
