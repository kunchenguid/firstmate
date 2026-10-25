# Fork exit list

Every change on `umeranjum17/firstmate` main since merge-base `0397cb2b`
(161 commits, 218 changed files, +19,292/−1,942; fork `7a6e4cb0`, 2026-10-18), grouped by feature,
with its exit path and status. The rule behind the list: **the next core gap goes in an
add-on when it can; a fork patch only when it cannot — and it joins this list the same day.**

Exit paths: **add-on** `<dir>` (lives under this repository's `addons/` directory) · **offer to Kun** (upstream fix,
only with the owner's approval) · **stays** (thin hook or fork-only policy, nothing to move).
Statuses: **on fork** · **moved to** add-on + fork shim · **dormant copy** (add-on holds a
verbatim copy; the fork still runs its own) · **done** · **dropped** (add-on removed; the fork
copy still runs until a later fork PR drops it).

## How to add a row

The same-day rule: any new fork commit (or PR merge) lands a row here the same day, with its
exit path decided at entry. Reuse a row when the commit belongs to a listed feature; otherwise
add one. Source of truth: `git -C ~/firstmate fetch origin && git -C ~/firstmate
fetch kun && git -C ~/firstmate log --oneline kun/main..origin/main`. Check each status
against the files, not against this table. PRs at the top until they are resolved.

## Priority: open and recent fork PRs

| Feature | Fork PR | Key files | Exit path | Status |
|---|---|---|---|---|
| Watcher check cadence calls the ask-default add-on's decide for each open ask | [92](https://github.com/umeranjum17/firstmate/pull/92) (merged cfb646f2) | `bin/fm-watch.sh`, `docs/configuration.md`, `docs/scripts.md`, `tests/fm-watch-triage.test.sh` | stays (thin hook; the logic is add-on `ask-default`) | on fork |
| Ready-work nudge reads the fleet-flow add-on's counted lanes | [91](https://github.com/umeranjum17/firstmate/pull/91) (merged 852a3488) | `bin/fm-watch.sh`, `tests/fm-watch-triage.test.sh` | stays (thin hook; the logic is add-on `fleet-flow`) | on fork |
| Live labs write `treehouse.toml` so lab copies stay under the lab root | [86](https://github.com/umeranjum17/firstmate/pull/86) (merged e43cddbc) | `bin/fm-live-lab.sh`, `bin/fm-claude-trust.sh`, `tests/fm-live-lab-up-mate.test.sh` | offer to Kun (lab containment fix, only with the owner's approval) | on fork |
| Skip parked homes in every supervision producer | [85](https://github.com/umeranjum17/firstmate/pull/85) (88e57fe1) | `bin/fm-parked-homes-lib.sh` (new shim), gate lines in `bin/fm-send.sh`, `bin/fm-control.sh`, `bin/fm-remote-secondmate-relaunch.sh`, `bin/fm-secondmate-restart.sh`, `bin/fm-secondmate-reconcile.sh`, `bin/fm-config-push.sh`, `bin/fm-bootstrap.sh`, `bin/fm-pending-reply-lib.sh`, `bin/fm-model-outage-lib.sh`, `bin/fm-watch.sh` | add-on `parked-homes` (the reader + policy live there; fork carries only the shim and one predicate call per producer) | on fork |
| Fork catch-up with Kun's main | [74](https://github.com/umeranjum17/firstmate/pull/74) (merge e9e2ef20) | merge commits only | stays (sync, no feature content) | done — merged; current capacity, tool-exclusion, spend and growth-check libraries match Kun's main |
| Label the Main-owned wait escalation as the check wake | [78](https://github.com/umeranjum17/firstmate/pull/78) (4df0ed20) | `bin/fm-wait-timers-lib.sh` | add-on `wait-timers` | dormant copy |
| Fold open decisions without forking per status line | [79](https://github.com/umeranjum17/firstmate/pull/79) (226ea2b2) | `bin/fm-classify-lib.sh` | offer to Kun | on fork |
| Replace fleet dashboard copy with the firstmate-addons shim | [80](https://github.com/umeranjum17/firstmate/pull/80) (561cc47e) | `bin/fm-dashboard.sh` (now a ~20-line exec shim) | add-on `fleet-dashboard` | done — moved to fleet-dashboard + fork shim PR 80; live dashboard serves from the add-on |
| Withdraw stale ready-work wakes instead of replaying them | [81](https://github.com/umeranjum17/firstmate/pull/81) (c66d9594) | `bin/fm-wake-lib.sh`, `bin/fm-wake-drain.sh`, `bin/fm-watch.sh` | offer to Kun | on fork |
| Move a relaunching worker to another pool account (`--account`) | [83](https://github.com/umeranjum17/firstmate/pull/83) (merged 0766f3c3) | `bin/fm-account-pool-lib.sh`, `bin/fm-control.sh`, `bin/fm-spawn.sh` | add-on `account-pool` if fm-control gains an account hook, else offer to Kun | on fork (see named item fm/fm-acct-f2-relaunch) |
| Retry the watch-triage drain ack under load and log missed attempts | [84](https://github.com/umeranjum17/firstmate/pull/84) (merged 5758e520) | `tests/fm-watch-triage.test.sh` | offer to Kun (test hardening, only with the owner's approval) | on fork — diagnostics only; the flake was not reproduced |
| Home launch-env hook: `config/launch-env-hook <out>` runs in the pane and its export is sourced before the AI-trailer step | [90](https://github.com/umeranjum17/firstmate/pull/90) (merged adcfce9e) | `bin/fm-spawn.sh` (thin hook), `docs/configuration.md` | stays (thin hook; the logic is add-on `git-identity`) | on fork — needed because no existing spawn hook point reaches the pane environment |

## Named items

| Item | Fork PR / commits | Key files | Exit path | Status |
|---|---|---|---|---|
| fm/fm-acct-f2-relaunch | [83](https://github.com/umeranjum17/firstmate/pull/83) (0766f3c3) | fm-control relaunch `--account <id\|next>` | move to an add-on if fm-control gains an account hook, else offer to Kun only with the owner's approval | on fork |
| fork-live-lab-haiku | [82](https://github.com/umeranjum17/firstmate/pull/82) (c19ba5f7) | `bin/fm-live-lab.sh` — Claude lab runtime, supervision host and second-mate defaults all `claude-haiku-5-5` | offer to Kun only with the owner's approval (fleet lab policy); pair with add-on `claude-model-guard` | on fork — verified in files |
| fork-live-lab-treehouse-leak | (no fork-only commit; rule on the shared lab script) | `bin/fm-live-lab.sh:171` — `TREEHOUSE_ROOT` points inside the lab root, so lab copies stay under it | stays (lab containment rule; re-check on every lab change) | holds today — verified in files |
| cicd-ci-tuning Q6/B4 (FM_LINT_JOBS 2–4, shard rebalance) | 7c6b3525 ([18](https://github.com/umeranjum17/firstmate/pull/18)) and later CI commits | `.github/workflows/ci.yml` (still pins `FM_LINT_JOBS: '1'`), `bin/fm-lint.sh` (default 2), `docs/fm-test-portable-shards.md` | stays (fleet CI policy, never an add-on; tune in place) | open — CI still pins 1; raise to 2–4 and rebalance shards |

## Everything else, by feature

### Moved to an add-on

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Fleet dashboard: server, board, charts, kanban, ship view, Insights | 4a43b1ef…c7f2c100 + [80](https://github.com/umeranjum17/firstmate/pull/80) (~20 commits, #10 #13 #20 #26 #28 #30 #31 #34 #42 #43 #49 #50 #53 #62) | `bin/fm-dashboard.sh`, `bin/fm-dashboard/` app | add-on `fleet-dashboard` | done — moved + fork shim (PR 80) |

### Dormant copy in an add-on (fork still runs its own)

| Feature | Commits / PRs | Key files (fork, still live) | Exit path | Status |
|---|---|---|---|---|
| Fleet flow reader (lifecycle/queue/bottleneck JSON) | 3b00213c ([23](https://github.com/umeranjum17/firstmate/pull/23)) | `bin/fm-flow.sh` | add-on `fleet-flow` + fork shim | done — shimmed; the add-on copy is the only reader, reached through the fork shim ([88](https://github.com/umeranjum17/firstmate/pull/88)) |
| Home flow check (lane slots, dry pulse column) | fleet retro (add-on branch `fm/retro-lane-slots`) | `config/fm-flow-check.sh` | add-on `fleet-flow` + operator symlink (fleet-flow README install runbook); never a shim — `bin/fm-flow.sh` reads its stage-clock policy from the file's text | dormant copy — symlink pending |
| Fleet stats (per-model, per-skill, outcome recorder) | 877ded84 ([56](https://github.com/umeranjum17/firstmate/pull/56)), eb0cb110 ([75](https://github.com/umeranjum17/firstmate/pull/75)) | `bin/fm-model-stats.sh`, `bin/fm-skill-stats.sh`, `bin/fm-task-outcome.sh` | add-on `fleet-stats` + fork hook | dormant copy |
| Host memory sampling + admission | 2b3097c7 ([29](https://github.com/umeranjum17/firstmate/pull/29)), 9f63932e ([33](https://github.com/umeranjum17/firstmate/pull/33)), de32a41f ([45](https://github.com/umeranjum17/firstmate/pull/45)) | `bin/fm-host-memory-sampler.sh`, `bin/fm-jev-mem-guard.py` delta, `config/host-memory` flag | add-on `host-memory` + flag hook | dormant copy |
| Wait timers lib + watcher integration | 3d9c09cc ([54](https://github.com/umeranjum17/firstmate/pull/54)), 4df0ed20 ([78](https://github.com/umeranjum17/firstmate/pull/78)) | `bin/fm-wait-timers-lib.sh`, one source line in `bin/fm-watch.sh` | add-on `wait-timers` + source hook | dormant copy |
| Sign-off hold cards, merge gate, answer delivery, receipts | a37c496e ([66](https://github.com/umeranjum17/firstmate/pull/66)), 5dff364f ([71](https://github.com/umeranjum17/firstmate/pull/71)), 06327fc1, 5774d939 | `bin/fm-procevent-signoff.sh`, `bin/fm-run-receipt.sh`, procevent dispatch hunk | add-on `receipts`; add-on `signoff`: 0 copied upstream lines, dormant until the fork dispatch hook (seam in `signoff/README.md`) | dormant copy |
| Sentinel (agent-runtime restart recovery) | 0f03b981 ([12](https://github.com/umeranjum17/firstmate/pull/12)), dce39b61 ([70](https://github.com/umeranjum17/firstmate/pull/70)) | `bin/fm-sentinel.sh` + unit path | add-on `sentinel` (thin wrapper, no copy) + unit hook | dormant thin wrapper; fork runs its own |
| Supervisor-work guard | e4a6c5e0 | `bin/fm-supervisor-work-command-policy.mjs`, `bin/fm-supervisor-work-pretool-check.sh` | add-on `supervisor-guard` (code moved from fork commit e4a6c5e0, fork-only and not in Kun upstream, 0 lines copied from Kun upstream; `install.sh` merges the hook; reads the checkout's scope lib and lexer) + pretool hook | dormant; fork runs its own |
| Model-outage, usage-limit and stuck-wait alerts | 16e04a41 ([48](https://github.com/umeranjum17/firstmate/pull/48)), da71f161 ([52](https://github.com/umeranjum17/firstmate/pull/52)), 01f01944 ([47](https://github.com/umeranjum17/firstmate/pull/47)) | `bin/fm-model-outage-lib.sh`, watch hunks | add-on `alerts` + watch hook | dormant copy |
| Local Qwen tuning docs + bench | 78cc325a | `docs/local-qwen-tuning/` (fork copy still differs from Kun's main) | add-on `local-qwen-tuning` (reference lives there) | dormant copy — drop fork docs on next cleanup |
| Bearings board milestones + evidence thumbnails | 9ad8e1fb, 08472745 | `bin/fm-bearings-board.sh`, `.agents/skills/bearings/` | add-on `bearings-board` (thin wrapper, no copied upstream code); extras in later slices | dormant thin wrapper; fork runs its own |

### Still on the fork, add-on planned

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Lead-wake fleet policy (lane floor, idle lead, stalled ring, ready-work) | afd00e42, bd86f55b, 0ef3188b ([9](https://github.com/umeranjum17/firstmate/pull/9)), 49d4ea80, d4881b01 ([7](https://github.com/umeranjum17/firstmate/pull/7)), a7d3b2cc ([8](https://github.com/umeranjum17/firstmate/pull/8)), c66d9594 ([81](https://github.com/umeranjum17/firstmate/pull/81)) | `bin/fm-watch.sh`, `bin/fm-wake-lib.sh` | add-on (watch-side policy seam); never offer upstream as a "fix" | dormant copy - add-on `lead-wake` holds the whole feature and its tests; the fork step replaces the call sites |
| Worker account pooling at spawn + raw-launch refusal | aa56a40c ([72](https://github.com/umeranjum17/firstmate/pull/72)), 46e2273b ([76](https://github.com/umeranjum17/firstmate/pull/76)) | `bin/fm-account-pool-lib.sh`, `bin/fm-worker-account-lib.sh`, `bin/fm-spawn.sh` | add-on if fm-control gains an account hook, else offer to Kun only with the owner's approval | on fork |
| Shared worker-brief inheritance | e2071b0a | brief builder hunks | add-on (brief seam) | on fork |

### Fork fixes to offer to Kun (owner approval required first)

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Composer classifier furniture (pi, OpenCode, Claude frames, notices, wrappers) | 8f93ec97, 0006081e, dd5473ca, 297c0671, 283bb0ff, 27ab02fa, effd129d, c0101169 ([43](https://github.com/umeranjum17/firstmate/pull/43)), 07e8da20 ([49](https://github.com/umeranjum17/firstmate/pull/49)), 4f9d1833 ([55](https://github.com/umeranjum17/firstmate/pull/55)), 6c218a0b ([59](https://github.com/umeranjum17/firstmate/pull/59)), bcd56b27 ([63](https://github.com/umeranjum17/firstmate/pull/63)), e06887f7 ([65](https://github.com/umeranjum17/firstmate/pull/65)), 226ea2b2 ([79](https://github.com/umeranjum17/firstmate/pull/79)) | `bin/fm-composer-lib.sh`, `bin/fm-classify-lib.sh` | offer to Kun | on fork |
| Herdr backend fixes (liveness, busy reads, registrations, display names, restart husks, lineage) | 9e0f4610, 41791476, 29489df9, 5aba26c9, 89f37b6c, 65e7989a, 738354c1 ([3](https://github.com/umeranjum17/firstmate/pull/3)), 77aa4489, 3b1ef6e1, 158fdf6e | `bin/backends/herdr.sh`, `bin/fm-control.sh` | offer to Kun | on fork |
| Herdr lab isolation (`--isolated-xdg`, disposable homes) | c4a8401e ([25](https://github.com/umeranjum17/firstmate/pull/25)), 64b16da2, 65e7989a | `bin/fm-herdr-lab.sh` | offer to Kun | on fork |
| Treehouse slot lease (spawns stop reusing live slots) | 9d7f14a5 ([39](https://github.com/umeranjum17/firstmate/pull/39)), d146491a | `bin/fm-treehouse-protect.py`, spawn/teardown hunks | offer to Kun | on fork |
| Watch progress false-stale fix | 856dc3c0 | `bin/fm-watch-progress-lib.sh` | offer to Kun | on fork |
| Watcher/supervision fixes (continuity, false-stale, harness pin, stale index.lock, relaunch replaces held worker, busy-record proof, lease lock wait) | 3af203da ([38](https://github.com/umeranjum17/firstmate/pull/38)), 856dc3c0 ([41](https://github.com/umeranjum17/firstmate/pull/41)), c47fb103 ([11](https://github.com/umeranjum17/firstmate/pull/11)), fc2f67e3, 7d273504, 1c46db48 ([58](https://github.com/umeranjum17/firstmate/pull/58)), fed23d2a, 62e1962b, e4696b16, c91ecee4, 910b7cd8 ([77](https://github.com/umeranjum17/firstmate/pull/77)), fc86b441 | `bin/fm-watch.sh`, `bin/fm-lease-lib.sh`, `bin/fm-crew-state.sh` | offer to Kun | on fork |
| Spawn/teardown/control/remote-job worker-lifecycle fixes (no interactive git editors, session store per worker, resume after host restart, merge proof before teardown, executable outcome scripts) | 84e1a4a9 ([19](https://github.com/umeranjum17/firstmate/pull/19)), 482a5072 ([57](https://github.com/umeranjum17/firstmate/pull/57)), 9d8616d9 ([37](https://github.com/umeranjum17/firstmate/pull/37)), 446a05e6 ([67](https://github.com/umeranjum17/firstmate/pull/67)), dce39b61 ([70](https://github.com/umeranjum17/firstmate/pull/70)), ce00911f ([69](https://github.com/umeranjum17/firstmate/pull/69)), eb0cb110 ([75](https://github.com/umeranjum17/firstmate/pull/75)), e216dac7, 96b69521, fdf5a5bd, af26b9a9, 0efa37b2, 9f8be03d | `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-session-start.sh` | offer to Kun (verify each hunk) | on fork |
| Pi 1.2.0 before_agent_start custom events | b1cb0da5 ([68](https://github.com/umeranjum17/firstmate/pull/68)) | `.pi/extensions/fm-branch-supervision.ts` | offer to Kun | on fork |
| Privacy: no public test-evidence publication | 5d304a2c ([35](https://github.com/umeranjum17/firstmate/pull/35)) | test helper + docs | offer to Kun | on fork |
| Docs fixes (stash ban in briefs, composer-restore notes, fm-role rows, sign-off-axi pointers) | db0abe4b ([17](https://github.com/umeranjum17/firstmate/pull/17)), 28482318 ([14](https://github.com/umeranjum17/firstmate/pull/14)), 4887b114, 0624f124 ([73](https://github.com/umeranjum17/firstmate/pull/73)) | `docs/`, `AGENTS.md`, skills | offer to Kun | on fork |

### Fork-only policy (stays, never moves)

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| CI fleet policy (advisory pipeline check, self-hosted light jobs, shard split) | 7c9b2326 ([60](https://github.com/umeranjum17/firstmate/pull/60)), abbac7b6 ([61](https://github.com/umeranjum17/firstmate/pull/61)), 7c6b3525 ([18](https://github.com/umeranjum17/firstmate/pull/18)), 158fdf6e | `.github/workflows/`, `.no-mistakes.yaml` | stays (fleet policy; see cicd-ci-tuning named item) | on fork |
| Upstream ports (capacity, tool exclusions, pipeline spend, growth check) | cd49747b ([44](https://github.com/umeranjum17/firstmate/pull/44)) ported them early | `bin/fm-project-capacity-lib.sh`, `bin/fm-exclude-tools-lib.sh`, `bin/fm-pipeline-spend.sh`, `bin/fm-startup-growth-check.sh` match Kun's main; some other fork files also match | stays — reconcile remaining differences on the next sync | done via PR 74 |

---

Counts and method: fork main `7a6e4cb0a1428dca62dc66d3fcc7472fd85044f8` (2026-10-18) is 161 commits
and 218 files ahead of merge-base `0397cb2bb431948f3865b7f28c522290546dcaaf` (+19,292/−1,942;
three-dot diff). Some fork files are byte-identical to Kun main. Statuses re-checked against fork files
and add-on READMEs. Short SHAs resolve at https://github.com/umeranjum17/firstmate.
