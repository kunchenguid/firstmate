# Contributing

Use normal Git branches and pull requests for this fork.

Target `rharriso-main` until Ross changes the temporary fork trunk.

## Workflow

1. Create a branch from `rharriso-main`.
2. Make focused changes and run the relevant validation.
3. Commit the changes.
4. Push the branch and open a pull request when Ross explicitly directs those sensitive actions.
5. Do not merge until Ross explicitly directs it.

Validation evidence supports a recommendation, but never authorizes a push, pull request, merge, local apply, or discard.

## Repo conventions

- `AGENTS.md` is the main agent operating contract, and `CLAUDE.md` is its `@AGENTS.md` pointer.
- `.agents/skills/` contains agent-loaded Firstmate skills, while `skills/` contains standalone public skills.
- Captain-private fleet material in `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` is gitignored and must not be committed.
- `config/backend` is ignored by the lean product contract.
  tmux is the only supported runtime backend.
- Read `.agents/skills/firstmate-coding-guidelines/SKILL.md` before changing tracked Firstmate material.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) defines the maintained documentation audience boundary.
- Keep one full sentence per physical line in tracked Markdown and use plain dashes.
- Do not add agent co-authors to commits.

Helper scripts in `bin/` and test scripts in `tests/` are Bash.

Each script header owns its exact flags and mechanics.

`bin/fm-lint.sh` owns the lint definition and must pass for script or workflow changes.

## Development

```sh
bin/fm-lint.sh
bin/fm-test-run.sh tests/<subject>.test.sh
bin/fm-test-run.sh --all
bin/fm-doc-audience-check.sh
```

Use the focused test command while iterating, and use the complete suite only when its broader coverage is warranted.

## Questions

Open an issue in the fork for questions about this local Firstmate surface.
