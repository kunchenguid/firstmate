# Contributing

Thanks for wanting to contribute.
Changes should be reviewed against their actual intent before they are proposed, while merge authority remains with the maintainer.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a feature branch, make and commit the change, and run the relevant behavioral tests plus `bin/fm-lint.sh`.
3. Use Codex or TraeX native review against the exact base commit and committed candidate. Give the reviewer the request, acceptance criteria, scope, and exclusions explicitly; repository guidance is context, not a substitute for that intent.
4. Correct actionable findings, rerun relevant checks, commit, and review the complete base-to-final-head diff again.
5. Push only the feature branch to your fork and open a pull request against the parent repository. Required forge checks must pass before merge.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  [`AGENTS.md`](AGENTS.md) owns the supervisor contract, role boundary, and bundled firstmate skill triggers.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, and `projects/`) is gitignored; never commit it.
  Canonical task state lives only in `data/<task>/task.json`; [`bin/fm-tasks-axi.sh`](bin/fm-tasks-axi.sh) is the supported task CRUD entry point.
  The root `.tasks.toml` and compatible external `tasks-axi` remain scoped to the separate public-followup typed-obligation family; they do not select or redirect task storage.
  A local `config/backend` file may select `herdr`, the sole supported terminal; an absent setting selects Herdr and an explicit retired setting refuses.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, pinned shellcheck version, pinned actionlint workflow lint, and the backend-purity check rejecting direct Beads CLI calls in core `bin/` scripts), and CI invokes it with no arguments.
  Its header and `--help` output own the exact local lint modes, file-set selection, and analysis flags.
  A malformed `.github/workflows/*.yml`, including a self-broken `ci.yml`, fails that local lint path before merge because a broken workflow cannot report its own breakage.
  It pins one exact shellcheck version and one exact actionlint version and refuses to run under any other.
  Print the shellcheck pin with `bin/fm-lint.sh --required-version` and the actionlint pin with `bin/fm-lint-workflows.sh --required-version`.
  Use `bin/fm-install-shellcheck.sh` and `bin/fm-install-actionlint.sh` to install those exact builds locally; each installer's header owns its destination usage and supported platforms.
- Harness-adapter ownership spans detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, semantic busy sources and trust gates in `bin/fm-busy-lib.sh`, rendered input-state classification in `bin/fm-composer-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in the skill tree rooted at `.agents/skills/harness-adapters/SKILL.md`; the `firstmate-coding-guidelines` skill owns the validation policy for checks that depend on those harnesses.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) keep current setup and limits in the relevant backend guide and active empirical evidence in [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md).
- [`docs/documentation-audiences.md`](docs/documentation-audiences.md) and its machine-consumed inventory own prose classification; run `bin/fm-doc-audience-check.sh` after documentation changes.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through intent-aware native review on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
For Firstmate-managed work, `bin/fm-native-review.sh` binds the exact base, committed candidate, and task contract to the recorded Codex or TraeX native review command.
For behavioral verification, reach for `bin/fm-test-run.sh` with the subjects you care about rather than chaining `bash tests/a.test.sh && bash tests/b.test.sh`, because a list of script paths gets the same bounded concurrency as `--changed`.

Check and test the toolbelt before pushing:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)   # syntax-check the shell surface fm-lint.sh will cover (changed files locally, full set in CI/on main)
bin/fm-lint.sh   # lint that shell surface plus GitHub workflows via pinned actionlint; the single owner CI runs
bin/fm-test-run.sh tests/<subject>.test.sh   # one script (primary local focus path, timed)
bin/fm-test-run.sh tests/<a>.test.sh tests/<b>.test.sh   # several subjects at once: bounded automatic concurrency
bin/fm-test-run.sh --family pure-contract-unit   # ordinary family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed   # normal changed-file-informed path with automatic bounded concurrency
bin/fm-test-run.sh --changed --jobs 1   # explicit serial override
bin/fm-test-run.sh --changed --max-wall-ms 300000   # same automatic path with a post-run five-minute result check
bin/fm-test-run.sh --proven-isolated --jobs 4   # explicit local parallel of the individually proven set
bin/fm-test-run.sh --lane portable-serial   # portable serial remainder (watcher/stateful)
bin/fm-test-run.sh --list-lanes   # discover exact lane names, including the current CI serial shards
bin/fm-test-run.sh --check-coverage   # prove portable shards + serial + serial shards + Herdr equal the full inventory
bin/fm-test-run.sh --all   # deliberate complete regression (optional local full walk)
bin/fm-test-isolation-proof.sh --list   # proven portable parallel candidate set
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json   # re-run the portable candidate proof
bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4   # re-run an admitted family proof
[ -f AGENTS.md ] && [ ! -L AGENTS.md ]   # canonical project memory is a real file
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/fm-test-run.sh` is the single owner of behavior-suite selection, portable CI lane composition, bounded concurrency admission, per-script timing markers, family totals, the coverage guard, and the optional JSON timing artifact.
Its header and `--help` own the flags, family labels, lanes, and changed-file map; this section only documents the entry points.
`bin/fm-test-isolation-proof.sh` remains the single owner of the portable candidate proof and reusable family proof harness; see `docs/fm-test-isolation-proof.md`.
Portable shard balance evidence lives in `docs/fm-test-portable-shards.md`.
Family selection is the ordinary local path; `--all` is deliberate full regression only.
CI owns broad regression across required portable parallel shards, the portable serial lane's separate-runner shards, the Herdr lane, lint, invariants, the coverage guard, and stock macOS Bash compatibility in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
Pushing a new head to a pull request cancels that pull request's still-running CI so only the current head is validated; pushes to `main` are never cancelled, and the workflow owns that contract and its rationale.
Use `bin/fm-test-run.sh --list-lanes` for exact lane names and `--help` for `--jobs` rules and required gate-skip flags when reproducing a lane locally.
Leave the `sleep 0.1` cadence in the suites' bounded condition waits alone.
Those sleeps look like recoverable overhead - `fm-watch-triage.test.sh` alone issues about 1,900 of them, each paying a flat ~100ms scheduler wake-up penalty on macOS - but they are not overhead added to the clock; they are how a test waits for a subject that only moves on `fm-watch.sh`'s own one-second `FM_POLL` cadence.
Sampling less often does not remove that wait, it only delays detection: raising the interval to 0.5s and charging each sample proportionally measured `fm-watch-triage.test.sh` at 435s and 440s against 390s and 393s for the unchanged script, back to back on 2026-09-03, because each of its ~40 poll-cycle waits and ~73 process-exit waits paid up to half a second more.
Some of those loops are also catching a transient rather than waiting for a settled condition, so a coarser sample can step over the state they assert on.
Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so pass one to `bin/fm-test-run.sh` to focus on a subject with canonical timing output.
Shared test helpers live in `tests/lib.sh` (reporters, temp roots, git fixtures), `tests/fixtures.sh` (fake toolchain and spawn-world builders), `tests/wake-helpers.sh`, and `tests/git-config-helpers.sh` (fixture Git isolation from the host's global and system configuration, already sourced by `tests/lib.sh` and `tests/herdr-test-safety.sh`; a suite that sources neither must source it itself before its first Git operation so a direct invocation stays isolated).
Source those instead of copying a fake toolchain into a new suite.
A fixture may shorten a production timeout to keep a failure path prompt, but never below what the real work inside that window costs on a loaded machine: a fork, an exec, a lock acquisition, a beacon publication, or a first-poll check.
Where a case's assertion is not about the timeout itself, give that window headroom over the measured loaded cost, and bound the test's own waiting with iteration-counted poll loops, which stretch under load where a wall-clock budget does not.
Tests that need a real optional backend or an explicit opt-in (real Herdr smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The [Herdr backend guide](docs/herdr-backend.md#destructive-lab-safety) owns the lane's isolation boundary, while [runtime backend verification](docs/verification/runtime-backends.md#herdr) owns active empirical evidence; live harness credential tests remain opt-in.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
