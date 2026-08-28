# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
The generated `## Pipeline` section must contain `Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)` exactly; prose that merely says the checks passed is not a substitute for that machine-verifiable marker.
Dependency bots are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (firstmate expects **no-mistakes v1.31.2+**; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, `skills/`, and provider-neutral components under `tools/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the ShellCheck file set, config, and pinned ShellCheck version), and both CI and the no-mistakes pre-push gate invoke it with the same full-or-focused Azure-service scope.
  It pins one exact shellcheck version and refuses to run under any other; print it with `bin/fm-lint.sh --required-version` and install that build locally.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, or `docs/codex-app-backend.md` for blocked Codex App transport work.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Changes to the shared tracked material listed under "Repo conventions" ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory and pins the gate's shell and Agent Fleet source checks to their matching CI commands.
That is firstmate-specific; do not commit `.no-mistakes/evidence/` here even when another no-mistakes-managed target project keeps committed PR evidence.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
bin/fm-lint.sh   # lint the complete toolbelt and behavior-test shell inventory
tests/run.sh --skip-herdr   # behavior tests with real-Herdr declarations explicitly skipped
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

Agent Fleet is independently packaged under `tools/agent-fleet` and requires Python 3.11 or newer plus `uv`.
Run the complete locked verification in [`tools/agent-fleet/RELEASING.md`](tools/agent-fleet/RELEASING.md) before pushing; that document also owns versioning, tagging, and clean-install verification.

Discover tests by listing `tests/*.test.sh`: each is a self-contained shell script named `<subject>.test.sh`, and its header comment describes what it covers; partition wrappers source their matching `tests/*-suite.sh` implementation.
Run the complete suite with `tests/run.sh`, or focus on one subject with `tests/run.sh tests/<subject>.test.sh`.
Direct `bash tests/<subject>.test.sh` execution sources the same admission preflight and re-enters the authoritative runner.
Use `tests/run.sh --skip-herdr` only when intentionally selecting the explicit non-Herdr path.
See [`docs/test-isolation.md`](docs/test-isolation.md) for the lifecycle declaration and isolation contract.
CI partitions behavior tests through `bin/fm-behavior-shards.sh`, which admits every selected entrypoint through the same runner and preserves the explicit non-Herdr selection for real-Herdr declarations.
Background process fan-out is report-only unless a behavior test declares and continuously verifies a fixed per-script bound without reducing its assertion or input matrix.
`tests/fm-wake-queue.test.sh` owns its concurrency contract and focused slow-host regression in the script header.
When triaging a red behavior shard, use its begin and end markers to identify each failing script: the shard continues through its complete assignment and records every exit code before the final `Behavior tests` job verifies the executed union.
The runner continues after an individual test failure, so its log records every attempted test.
Reproduce in a checkout whose `origin` is the repository's https URL, as CI's own checkout is: the secondmate network-authority fixtures assert that the product pins the resolved address of the origin host, and a checkout whose `origin` is a local filesystem path has no host to pin, so those cases refuse for a reason that exists only locally.
Run the suites from a checkout sitting on its default branch, not from a task-branch worktree - the worktree-tangle guard fires and several secondmate suites require the default branch, which produces more failures that are pure local artifacts.
Do not bypass `tests/run.sh` for real-Herdr suites: their declarations require the runner to provision a never-default lab, route every Herdr call through the lab helper, and verify the before/after default-fleet tripwire.
Direct execution is safe because the test header immediately re-enters the same runner before its body.
Other tests that need a real optional backend, an explicit opt-in, or an ambient toolchain capability (real zellij/cmux smoke tests, the live Pi regression, the Pi TypeScript-extension checks when node cannot import `.ts` modules directly) skip themselves and print the tool or environment gate needed to enable them.
Units that need a host capability some sealed-suite host genuinely cannot provide go through `tests/host-capability-gate.sh` and are declared in `tests/host-capabilities.tsv` instead: that gate reads the platform and an explicit by-name declaration the environment makes about itself, never a probe of the capability, so a merely broken host still goes red. See [`docs/test-isolation.md`](docs/test-isolation.md).
A test never inherits the operator environment: `tests/run.sh` drops every name in `tests/ambient-seal.tsv` (`FM_HOME`, `FM_WORKER_PROVIDER_COMMAND`, `FM_SPAWN_CLOUD`, `FM_AZURE_*`, `AZURE_*`, `ARM_*`) before admission, binds a refusing fixture worker provider, and puts a refusing `az` on PATH, because an inherited identity once turned a unit that asserts a refusal into a real billable VM. Name your own fixture provider on your own command line; never rely on the default.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
