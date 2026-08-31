# Contributing to Firstmate

Firstmate uses bounded direct pull requests for tracked changes.
Never push to `main` and never merge without the configured merge authority.

## Development loop

1. Create an isolated feature branch and preserve any inherited dirty state.
2. Read `AGENTS.md` and `.agents/skills/firstmate-development-loop/SKILL.md`.
3. Add the smallest behavioral test for each executable contract and run it RED for the expected reason.
4. Implement the contract and run the focused test GREEN.
5. Run relevant targeted or full behavioral validation deliberately.
6. Run `bin/fm-verify.sh`, the canonical deterministic zero-token gate used identically by local work and GitHub Actions.
7. Push the feature branch and open a PR with `gh-axi`.
8. Record the exact PR head SHA and use `bin/fm-pr-ci.sh` or `bin/fm-pr-check.sh` until terminal checks are green for that same SHA.

Pending, ambiguous, missing, failed, skipped, or different-head checks are not green.
Do not put the broad behavioral test corpus into the routine canonical gate.

## Repository rules

- Keep one owner for each contract and place detailed mechanics in the owning script header or skill.
- Keep `AGENTS.md` slim and trigger-oriented.
- Write one sentence per Markdown line and use plain hyphens.
- Keep `bin/` scripts and behavior tests ShellCheck-clean.
- Test through public or executable behavior instead of source-byte regex, parsers, or snapshots.
- Never add an agent name as a commit co-author.
- Keep `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` private and untracked.

Read `docs/documentation-audiences.md` before changing documentation or adding a prose surface.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a real `@AGENTS.md` pointer to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, pinned shellcheck version, and pinned actionlint workflow lint), and `bin/fm-verify.sh` invokes its no-argument full-analysis path locally and in the exact-head PR workflow.
  Its header and `--help` output own the exact local lint modes and flags.
  A malformed `.github/workflows/*.yml`, including a self-broken `ci.yml`, fails that local lint path before merge because a broken workflow cannot report its own breakage.
  It pins one exact shellcheck version and one exact actionlint version and refuses to run under any other.
  Print the shellcheck pin with `bin/fm-lint.sh --required-version` and the actionlint pin with `bin/fm-lint-workflows.sh --required-version`.
  Use `bin/fm-install-shellcheck.sh` and `bin/fm-install-actionlint.sh` to install those exact builds locally; each installer's header owns its destination usage and supported platforms.
- Harness-adapter ownership spans detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, semantic busy sources and trust gates in `bin/fm-busy-lib.sh`, delivery-only rendered guards in `bin/fm-composer-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in the skill tree rooted at `.agents/skills/harness-adapters/SKILL.md`; the `firstmate-coding-guidelines` skill owns the validation policy for checks that depend on those harnesses.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) keep current setup and limits in the relevant backend guide and active empirical evidence in [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md).
- [`docs/documentation-audiences.md`](docs/documentation-audiences.md) and its machine-consumed inventory own prose classification; run `bin/fm-doc-audience-check.sh` after documentation changes.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through bounded direct PR on a feature branch and require the configured merge authority.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation runs focused behavioral proof, deliberate relevant or full validation, and the canonical `bin/fm-verify.sh` gate before push.
The exact-head PR workflow is the routine gate, while `.github/workflows/ci.yml` preserves the broad behavior suite and platform-specific compatibility lanes for `main`.
The tracked `.no-mistakes.yaml` remains inactive migration compatibility and must not be treated as a normal delivery owner.
Never hand-commit `.no-mistakes/` paths onto a feature branch; repository invariants reject personal fleet paths.

Check and test the toolbelt before pushing:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)   # syntax-check the shell surface fm-lint.sh will cover (changed files locally, full set in CI/on main)
bin/fm-verify.sh   # canonical deterministic zero-token PR gate; invokes the lint owner
bin/fm-lint.sh   # lint the shell surface plus GitHub workflows via pinned actionlint
bin/fm-test-run.sh tests/<subject>.test.sh   # one script (primary local focus path, timed)
bin/fm-test-run.sh --family pure-contract-unit   # ordinary family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed   # normal changed-file-informed path with automatic bounded concurrency
bin/fm-test-run.sh --changed --jobs 1   # explicit serial override
bin/fm-test-run.sh --changed --max-wall-ms 300000   # same automatic path with a post-run five-minute result check
bin/fm-test-run.sh --proven-isolated --jobs 4   # explicit local parallel of the individually proven set
bin/fm-test-run.sh --lane portable-serial   # portable serial remainder (watcher/AFK/tmux/stateful)
bin/fm-test-run.sh --list-lanes   # discover exact lane names, including the current CI serial shards
bin/fm-test-run.sh --check-coverage   # prove portable shards + serial + serial shards + Herdr equal the full inventory
bin/fm-test-run.sh --all   # deliberate complete regression, outside the routine PR gate
bin/fm-test-isolation-proof.sh --list   # proven portable parallel candidate set
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json   # re-run the portable candidate proof
bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4   # re-run an admitted family proof
[ ! -L CLAUDE.md ] && cmp -s CLAUDE.md - <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/fm-test-run.sh` is the single owner of behavior-suite selection, portable CI lane composition, bounded concurrency admission, per-script timing markers, family totals, the coverage guard, and the optional JSON timing artifact.
Its header and `--help` own the flags, family labels, lanes, and changed-file map; this section only documents the entry points.
`bin/fm-test-isolation-proof.sh` remains the single owner of the portable candidate proof and reusable family proof harness; see `docs/fm-test-isolation-proof.md`.
Portable shard balance evidence lives in `docs/fm-test-portable-shards.md`.
The canonical verifier stays deterministic and zero-token; do not wire it to `--all` or a `tests/*.test.sh` walk.
Family selection is the ordinary local path; `--all` is deliberate full regression only.
CI owns broad regression across required portable parallel shards, the portable serial lane's separate-runner shards, the Herdr lane, lint, invariants, the coverage guard, and stock macOS Bash compatibility in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
Use `bin/fm-test-run.sh --list-lanes` for exact lane names and `--help` for `--jobs` rules and required gate-skip flags when reproducing a lane locally.
Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so pass one to `bin/fm-test-run.sh` to focus on a subject with canonical timing output.
Shared test helpers live in `tests/lib.sh` (reporters, temp roots, git fixtures), `tests/fixtures.sh` (fake toolchain and spawn-world builders), `tests/wake-helpers.sh`, and `tests/secondmate-helpers.sh`.
Source those instead of copying a fake toolchain into a new suite.
A fixture may shorten a production timeout to keep a failure path prompt, but never below what the real work inside that window costs on a loaded machine: a fork, an exec, a lock acquisition, a beacon publication, or a first-poll check.
Where a case's assertion is not about the timeout itself, give that window headroom over the measured loaded cost, and bound the test's own waiting with iteration-counted poll loops, which stretch under load where a wall-clock budget does not.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The [Herdr backend guide](docs/herdr-backend.md#destructive-lab-safety) owns the lane's isolation boundary, while [runtime backend verification](docs/verification/runtime-backends.md#herdr) owns active empirical evidence; live harness credential tests remain opt-in.

## Inactive migration compatibility

The tracked `.no-mistakes.yaml` and gate-context refusal helper remain only to support already-running legacy migrations and the final migration validation run.
They do not define an active delivery mode, bootstrap dependency, task brief, spawn mode, CI signature requirement, or merge prerequisite.
