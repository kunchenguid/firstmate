# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be validated through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
For this repo, run the review/test/lint pipeline through branch push with `--skip=pr,ci`, then open the GitHub PR manually.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
When you open the PR manually, preserve the no-mistakes marker or copy the generated pipeline section into the PR body.
Dependency bots are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (fork routing requires **no-mistakes v1.30.1+**; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Run the validation pipeline through branch push, but skip automatic PR creation and PR-based CI monitoring:

   ```sh
   no-mistakes --skip=pr,ci
   ```

6. Watch findings, and auto-fix or review as needed.
7. Once the pipeline passes and pushes the branch to your fork, open the PR against the parent repo manually.
   Preserve the no-mistakes marker in the PR body so the required workflow can verify the run.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's entire job description; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and `.agents/skills/`.
  Everything personal to one captain's fleet (`data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  `shellcheck bin/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (launch templates in `bin/fm-spawn.sh`, the adapter tables in `AGENTS.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
