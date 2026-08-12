# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
It evaluates every PR opening and body edit independently, so a later edit cannot replace an earlier pending compliance check.
GitHub Actions and Dependabot are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. For this captain-owned delivery lane, clone `JTInventory/firstmate` or set your local delivery target to `git@github.com:JTInventory/firstmate.git`.
   A checkout whose `origin` fetches from upstream `kunchenguid/firstmate` is accepted only when `fork/main`, no-mistakes status, the no-mistakes gate, and the resolved `origin` push target all prove delivery to `JTInventory/firstmate`.
2. Create a branch and make your changes.
3. Initialize the gate so its target is `JTInventory/firstmate` (firstmate expects **no-mistakes v1.31.2+** and a GitHub CLI whose `gh pr checks` supports `--json`).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch and opens the PR against `JTInventory/firstmate` for you.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- The authoritative shared/tracked surface is listed in `AGENTS.md`.
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The repository-root `/config/`, `/reports/`, and `/backups/` rules are anchored, so same-named directories nested under shared surfaces such as `docs/examples/` and `tests/` remain trackable.
  Local report or preservation folders such as `/reports/` and `/backups/` are not canonical tracked surfaces; leave them out of PRs unless a specific artifact is intentionally promoted into shared documentation.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations.
  A local `config/backlog-backend=manual` opt-out forces hand-editing and stays gitignored.
  It does not make `data/` tracked.
- Shell entrypoints in `bin/` are Bash; runtime-specific helpers declare their runtime and purpose in a header comment.
  Keep those headers accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass; it is the single owner of the ShellCheck pin and file set used by CI and no-mistakes.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.

## Development

Tracked changes to firstmate itself - the shared surfaces listed in `AGENTS.md` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory and pins the gate's test command to the same bash behavior suite as CI.
In this captain-owned delivery lane, no-mistakes PRs must target `JTInventory/firstmate`.
`bin/fm-no-mistakes-pr-target-guard.sh` checks direct push targets, all no-mistakes fetch and push targets, and `no-mistakes status` before the test suite runs, so stale gate state cannot open or update a PR on `kunchenguid/firstmate`.
It allows `origin` to fetch from upstream `kunchenguid/firstmate` only in a controlled-fork checkout where `fork`, branch tracking, no-mistakes status, the no-mistakes gate, and resolved `origin` push targets all prove delivery to `JTInventory/firstmate`.

### Focused validation

Run the focused isolation and endpoint tests directly.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
bin/fm-lint.sh   # lint the toolbelt and behavior tests; the single owner CI and the no-mistakes gate both run
tests/fm-worker-isolation.test.sh
tests/fm-slot-occupant-proof.test.sh
tests/fm-spawn-route.test.sh
tests/fm-teardown.test.sh
bin/fm-test-isolation-proof.sh --list   # proven parallel candidate set (Phase 2; not production sharding)
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json   # concurrent isolation proof only
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/fm-test-isolation-proof.sh` is the single owner of the Phase 2 concurrent isolation proof for a bounded, audited portable candidate set.
Its `--help` output and focused tests own the candidate set and execution contract.
Local no-mistakes Test stays intent-targeted and must not wire `commands.test` to `--all` or a `tests/*.test.sh` walk.
Tests that need real Herdr or another explicit opt-in (such as the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The [Herdr backend guide](docs/herdr-backend.md) owns the lane's safety and isolation rationale, including why live harness credential tests remain opt-in.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
