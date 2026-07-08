# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
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
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations.
  A local `config/backlog-backend=manual` opt-out forces hand-editing and stays gitignored.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, or `docs/codex-app-backend.md` for blocked Codex App transport work.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory and pins the gate's test command to the same bash behavior suite as CI.
That is firstmate-specific; do not commit `.no-mistakes/evidence/` here even when another no-mistakes-managed target project keeps committed PR evidence.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh   # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do bash "$test_script"; done   # behavior tests, matching CI and no-mistakes commands.test
tests/fm-wake-queue.test.sh               # durable wake queue losslessness, catch-up, double-drain, duplicate-collapse, and drain liveness guard tests
tests/fm-watcher-lock.test.sh             # watcher singleton, lock-race, PID identity stability, watch-arm liveness, and guard-warning tests
tests/fm-turnend-guard.test.sh            # shared supervision predicate plus Claude Stop-hook scoping, loop guard, fail-open, and live watcher health tests
tests/fm-watch-triage.test.sh             # always-on watcher triage: benign absorb, actionable surface, stale status-log override, wedge threshold, repeated wedge demand marker, heartbeat backstop, and afk one-shot coherence
tests/fm-daemon.test.sh                   # sub-supervisor classifier, /afk presence-gating, max-defer, composer, and fm-send submit tests
tests/fm-send-settle.test.sh              # fm-send post-submit settle pause, tuning, disable, and --key bypass tests
tests/fm-send-popup-settle.test.sh        # fm-send pre-Enter popup-settle selection for slash commands and codex $skill invocations
tests/fm-send-secondmate-marker.test.sh   # fm-send from-firstmate marker for kind=secondmate targets: marked vs crewmate/explicit/--key, and the exact marker byte sequence
tests/fm-wake-daemon-lifecycle-e2e.test.sh # watcher + daemon lifecycle e2e: restart catch-up, batching, dedupe, stale-pane routing, and digest injection
tests/fm-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/fm-afk-inject-e2e.test.sh           # private-socket end-to-end test of the afk injection path (partial-input deferral, swallowed-Enter retry)
tests/fm-afk-inject-herdr-e2e.test.sh     # real-herdr end-to-end test of the afk daemon's herdr transport, on an isolated throwaway HERDR_SESSION: partial-input deferral, swallowed-Enter retry, a normal digest, and the max-defer wedge alarm on a persistently pending composer
tests/fm-bootstrap.test.sh                # bootstrap dependency, feature-probe, and crew-dispatch reporting tests
tests/fm-session-start.test.sh            # fm-session-start.sh: ABSENT vs empty-vs-present digest files, lock-refusal read-only path skipping every mutating step, diagnostics-first section ordering, status-tail bounding, tmux/herdr endpoint liveness, and composition of the real fm-lock/fm-bootstrap/fm-wake-drain scripts
tests/fm-grok-harness.test.sh             # grok adapter spawn hook, token guard, teardown cleanup, and session-lock detection tests
tests/fm-fleet-sync.test.sh               # project clone refresh: safe detached recovery, STUCK drift reports, benign skips, single-project name resolution, and bootstrap relay
tests/fm-x-mode.test.sh                   # X-mode poll, inbox context round-trip, reply threading, dismiss, completion follow-up counters/caps, dry-run preview, and .env-presence activation tests
tests/fm-tangle-guard.test.sh             # primary-checkout tangle detection, read-only remediation suppression, and spawn/brief isolation tests
tests/fm-brief.test.sh                    # fm-brief.sh bash -n parse regression guard (issue #166) and clean no-mistakes/direct-PR/local-only brief generation tests
tests/fm-dispatch-select.test.sh          # deterministic crew-dispatch profile selection, quota-balanced tie/stale/fallback behavior, and backward-compatible first-profile selection tests
tests/fm-spawn-batch.test.sh              # batch dispatch and FM_HOME project-path scoping tests
tests/fm-spawn-dispatch-profile.test.sh   # concrete dispatch profile flags: active-profile backstop, harness/model/effort meta, launch templates, batch forwarding, and secondmate exemption
tests/fm-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/fm-secondmate-sync.test.sh          # local-HEAD secondmate sync, no-fetch, bootstrap nudge gating, and spawn hook tests
tests/fm-secondmate-liveness.test.sh      # session-start secondmate agent-liveness probe and respawn sweep tests
tests/fm-secondmate-harness.test.sh       # secondmate-vs-crewmate harness resolution, optional secondmate model/effort pins, primary-to-secondmate config inheritance, and config-push tests
tests/fm-secondmate-lifecycle-e2e.test.sh # persistent secondmate routing, seeding, backlog handoff, spawn, recovery, teardown, and FM_HOME flow tests
tests/fm-secondmate-safety.test.sh        # secondmate home safety, idle charter, handoff validation, teardown boundary, and child-cleanup fail-closed tests
tests/fm-teardown.test.sh                 # fm-teardown.sh landed-work safety and reminder checks: fork-remote allow, squash/content landings, dirty and unlanded refusals, PR-head metadata, no-pr= branch discovery, tasks-axi/manual backlog reminder, --force override, stale-vs-live worktree git index.lock recovery
tests/fm-review-diff.test.sh              # fm-review-diff.sh authoritative review diff coverage: recorded pr_head=, fetched refs/pull/<n>/head, no-pr local branch behavior, and warning fallback
tests/fm-pr-merge.test.sh                 # fm-pr-merge.sh records pr= and available pr_head= before merging, parses PR URLs into gh-axi number/--repo calls, defaults to squash, preserves explicit merge methods, rejects malformed URLs and repo overrides, and propagates real merge failures
tests/fm-crew-state.test.sh               # fm-crew-state.sh current-state reconciliation: run-step authority including closed panes and ci log-tail checks-green detection, stale checks-green and needs-decision/blocked superseded by resumed work, genuine-parked, cross-branch runs-list attribution, pane/status-log fallback, scout skip, torn-down/missing-meta graceful
tests/fm-backend.test.sh                  # runtime-backend abstraction: fm-backend.sh selection/meta/dispatch helpers, shell-portable sourced backend matching, blocked codex-app refusal, and old-vs-new fake-tool command-log conformance for fm-send/fm-peek/fm-spawn/fm-teardown
tests/fm-backend-tmux-smoke.test.sh       # real (private-socket) tmux smoke test for the tmux adapter: create/duplicate-refuse, send text + Enter, send literal + key, bounded capture, live-window resolve, kill
tests/fm-backend-herdr.test.sh            # fake herdr CLI unit tests for the experimental herdr adapter, including version/tool gates, target parsing, send/capture, native agent-state submit confirmation, structural composer-state guard/fallback coverage with bordered and unbordered prompt fixtures, slash-submit retry regression coverage, native busy state, per-home workspace-label resolution, default-tab prune safety, restored-layout husk replacement, and verified CLI bug workarounds
tests/fm-backend-herdr-smoke.test.sh      # real herdr adapter smoke test, skipped when herdr or jq is unavailable, using an isolated throwaway HERDR_SESSION and guarded session cleanup, including live-agent duplicate refusal and no-agent husk replacement
tests/fm-backend-autodetect-smoke.test.sh # real herdr auto-detection smoke test, skipped when herdr, jq, or treehouse is unavailable, using the same guarded session cleanup
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh # mandatory isolated E2E for workspace-per-home: primary and secondmate-shaped homes, a crewmate spawned from a secondmate home, teardown, list-live recovery
tests/fm-backend-herdr-prune-safety-e2e.test.sh # isolated real-herdr E2E for the default-tab prune self-kill regression: adopted label-collision workspaces are never pruned, while freshly created workspaces still prune their seeded default tab
tests/fm-backend-herdr-respawn-idem-e2e.test.sh # isolated real-herdr E2E for restored-layout husk respawn idempotency across a real session restart, covering crewmate/scout and secondmate-shaped tabs plus live-agent duplicate refusal
tests/fm-backend-zellij.test.sh           # fake zellij CLI unit tests for the experimental zellij adapter, including version/tool gates, target parsing, home-scoped title creation, legacy-title fallback, send/capture, current-path probing, label-checked target safety, secondmate child cleanup, and tab cleanup
tests/fm-backend-zellij-smoke.test.sh     # real zellij adapter smoke test, skipped when zellij or jq is unavailable, using an isolated throwaway FM_ZELLIJ_SESSION and guarded session cleanup
tests/fm-backend-orca.test.sh             # fake Orca CLI unit tests for primitive adapter routing: capture, send text, Enter/interrupt keys, close, and dispatcher sourcing
tests/cmux-test-safety.sh                 # guarded cleanup helper for real-cmux tests, refusing to close anything except a matching fm-test- workspace
tests/fm-backend-cmux.test.sh             # fake cmux CLI unit tests for the experimental cmux adapter, including socket auth, title scoping, target recovery, fresh-surface liveness, current-path probing, structural composer verification, and secondmate refusal
tests/fm-backend-cmux-smoke.test.sh       # real cmux adapter smoke test, skipped when cmux or jq is unavailable or the socket is not password-mode authenticated, using fm-test- workspaces and guarded cleanup
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
