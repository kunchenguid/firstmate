# Verification: the DeepSeek Harness (DSH) primary adapter

Active empirical evidence for firstmate's DeepSeek Harness adapter.
[`references/harness/dsh.md`](../../.agents/skills/harness-adapters/references/harness/dsh.md) owns the operating facts, [`docs/supervision-protocols/dsh.md`](../supervision-protocols/dsh.md) owns the wake protocol and the death-window contract.
This record owns how each claim was established, and what is still unproven.
The Stop-hook and watcher-continuity measurements were first written into [`supervision.md`](supervision.md); they are summarized here and remain owned there.

## Subject

| Field | Value |
|---|---|
| Version | DeepSeek Harness 0.1.5-rc.1 (`dsh-base` 0.1.5-rc.2) |
| Verified | 2026-09-16 |
| Binary | `dsh`, launched from an npm `npx` cache (`.bin/dsh`), a global npm install's `<prefix>/bin/dsh` symlink, an installed `@deepseek-ai/dsh/lib/bin.js`, or a source `apps/cli/src/bin.ts` |
| Platform | macOS arm64 (Darwin 27.0.0) |
| Role | PRIMARY only; refused for crewmate, scout and secondmate |

Two properties of DSH shape every finding below.
The host is a **node process** — `ps` reports `comm=node`, so only argv identifies it, and DSH publishes no identity marker for firstmate to read.
And the hook transport is **command-only and synchronous**: DSH implements the Claude Code command-hook dialect, which is why firstmate's existing hook scripts are reused, but it has no module hooks, no `asyncRewake`, and no event after `SessionStart`/`UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`Stop`.

Measurements were taken against throwaway or scratch profiles, except where a live home was required.
The live guard deliberately keeps the real harness home and makes only the profile disposable, because an isolated `DSH_HOME` also isolates the credential store and every session then dies with `MISSING_CREDENTIAL` — a failure that initially read as a context-delivery regression.

## Detection

```
$ ps -o pid=,comm=,args= -p <host>
  comm : node
  args : node /Users/<user>/.npm/_npx/<id>/node_modules/.bin/dsh web
```

`bin/fm-dsh-lib.sh` is the single owner of the launcher path shapes, in both a shell `case` spelling (`fm_dsh_args_evidence`) and a POSIX ERE (`fm_dsh_args_ere`), kept in one file so the two cannot drift.
`bin/fm-harness.sh` gained a source line, a `FM_DSH_HARNESS` marker arm and an interpreter-arm delegate; `bin/fm-session-lock-lib.sh` composes its `FM_HARNESS_RE` from `fm_dsh_args_ere`, and `dsh` is deliberately **absent** from `FM_HARNESS_NAMES` there.
Every pattern is an anchored path shape, never a bare `*dsh*` glob, so `bin/fm-dsh-sessionstart.sh` and an unrelated `dshish.js` cannot claim the identity.
`tests/fm-dsh-harness.test.sh` pins every accepted shape, three false positives in each matcher (a firstmate `fm-dsh-*` path or a node command that merely mentions dsh, a `dshish.js`, and a `dshish.js` under a `bin/` directory the global-install shape must not claim), and the precedence rule that `FM_DSH_HARNESS=dsh` is honored **only** when a genuine dsh process is in the ancestry — the marker is an override, never evidence on its own.

That precedence is load-bearing rather than a fast path: the dsh ancestry verdict is only `args` strength, so a DSH host launched from a Claude pane retains `CLAUDECODE`, which would otherwise rename the session.
A `FM_DSH_HARNESS` that no producer set was the state of the world before this work — every test set it by hand, and the home loaded `unknown.md`.

## Launch: one boundary for values a tool call cannot set

Environment is the only carrier for DSH identity, so `bin/fm-dsh-launch.sh` is the launch boundary: it exports `FM_DSH_HARNESS=dsh`, an explicit `FM_HOME` and `FM_ROOT` as its own checkout, starts the host from that checkout (DSH takes the invoking directory as its workspace root, and `.dsh/profile.patch.yml` resolves the bridge's `configPath` and `projectDir` from `FM_ROOT`, so a launch from any other directory would mount no hooks), pins `LC_ALL`/`LC_CTYPE` (unset, `bin/fm-line-cap-lib.sh`'s character cap becomes a byte cap and slices UTF-8), clears the foreign harness markers so a session started from another harness's pane cannot inherit its identity, runs the preflight with the profile and any `--patch` overlays it was given, and `exec`s `dsh`.

```
bin/fm-dsh-launch.sh web --port 3080
```

The boundary rests on one premise: that a hook or tool subprocess inherits the environment the host was given, so the exported marker actually reaches the guards.
That premise was measured rather than assumed.
A live headless session launched with `FM_DSH_HARNESS=dsh` exported had its `UserPromptSubmit` probe record the value it received, and it recorded `dsh`, so the marker does reach the guards.
Without it, detection inside a hook would fall back to ancestry alone, which under DSH is only `args` strength.
[`tests/fm-dsh-live-e2e.test.sh`](../../tests/fm-dsh-live-e2e.test.sh) asserts it as its fifth contract.

### Preflight: three silent misconfigurations, asserted rather than documented

`bin/fm-dsh-preflight.sh` fails with exit 3 on any required check and `bin/fm-dsh-launch.sh` propagates that as its own exit code; `FM_DSH_SKIP_PREFLIGHT=1` is the escape hatch for a deliberately degraded home.
Measured against synthetic homes:

| Condition | Result |
|---|---|
| Bridge `0.0.1-rc.5` against `dsh-base` `0.1.5-rc.2` | FAIL, naming both versions and the reinstall command |
| Bridge absent from the profile | FAIL, naming the install command at the running version |
| `AGENTS.md` larger than `maxBytes` (65536, the `dsh-base` default) | FAIL, naming the patch file to raise |
| Another plugin entry raises its `maxBytes` while `agent-instructions` stays at the default | FAIL: only the `agent-instructions` entry sets the budget |
| Profile raise, home-level `$DSH_HOME/cordis.patch.yml` default, then a `--patch` raise | FAIL naming the home layer without the overlay, pass from the overlay with it: layers compose profile, then home, then overlays |
| `ps` denied by the sandbox | FAIL, naming the permission preset |
| Conforming home | pass, all required checks |
| `lsof` absent | warning, not failure: teardown's stale-lock proof and orphan reap refuse rather than proceed |
| `jq` or `node` absent | FAIL, because every guard that needs one fails open and becomes a silent no-op |

Each of the three is silent in production, and all three were written into documentation before they were measured.
The instruction budget is the clearest case: `AGENTS.md` is 82128 bytes as of this writing, so the shipped 65536 either truncates it or, if raised, must be monitored; the captain profile sets 262144 and the preflight compares that against the live file size rather than a constant.

## Session-start digest: `UserPromptSubmit`, delivered whole

DSH's `SessionStart` hook runs detached and its `additionalContext` lands **after** the first request as a user-shaped message, which the model read as something the user had just sent; `UserPromptSubmit` fires before the model call and its context is part of that request.
Measured with a probe hook emitting a token that a tool-free prompt asked the model to repeat:

| Event | Result |
|---|---|
| `SessionStart` | No. The token arrived after the first request, as a user-shaped message. |
| `UserPromptSubmit` | Yes. The model saw the token on its first look, with no tools used. |

`bin/fm-dsh-sessionstart.sh` therefore rides `UserPromptSubmit`, and its contract is that the digest is `bin/fm-session-start.sh`'s **stdout, delivered whole**, because that script owns the read-only and `STARTUP TRUNCATED` banners, the read-once contract, fleet state and the single emitted operating block; an adapter that renders only the operating block hands the agent instructions without the diagnosis governing them.
Four defects in the first version of that adapter were found by the full-repository audit and fixed together:

| Defect | Fix |
|---|---|
| The once-per-session marker was written before the digest ran | Written only after a non-empty digest was produced, so a refused or empty startup retries on the next prompt |
| The start path ran as `>/dev/null 2>&1 \|\| true`, swallowing a lock refusal or truncation banner | stderr stays out of the payload; the script's own banners ride stdout, which is what the transport carries |
| The operating block was rendered without `--read-only` | The whole stdout is forwarded |
| `--afk-mode` was never passed, so a quiet posture was reported as away | Same fix |

The gate is per session id and re-arms for a new one, and a durable terminal-alarm latch is prepended rather than merged, so a session that died before the agent relayed the alarm still reports it.
`tests/fm-dsh-harness.test.sh` pins all four behaviours against a stub home, including that an empty digest leaves the gate unset.
DSH supplies **no session-open `source` field**, so the digest always runs as a first startup and cannot re-emit after a compaction — a real limitation, not a design choice.

## PreToolUse: deny blocks, but only with a matched bridge

Both matcher rows fire with the shell tool — the catch-all `.*` row and the lowercase `bash` row.
Claude's `Bash` never matches, because DSH's matcher subject is the harness tool name.

| Hook registered | Matcher | Observed |
|---|---|---|
| `PreToolUse` | `.*` | fired |
| `PreToolUse` | `bash` | fired |

Deny was separately unverified until it was measured, and the delegation guard plus both seatbelts rest on it.
Measured through an SDK-driven turn with a `bash`-matcher hook that exits 2 with a reason on stderr:

| Question | Result |
|---|---|
| Does a deny block the call? | Yes. The tool result was `Error: FM-DENY-PROBE: this shell command is refused by policy` with `isError: true`. |
| Did the command still run? | No. The command's sentinel file was **never created**, which is the only proof that matters. |
| Is the reason model-visible? | Yes. The model's next reasoning step quoted the refusal and stated it must not retry. |

The hook wrote nothing to stdout, matching the `--claude` path the guards use, so DSH's empty-stdout-on-deny behaviour is not exercised either way by this result.
`--claude` is passed deliberately: it selects the deny-output dialect, not Claude-specific behavior, and DSH honours that dialect.

**The bridge version must match the runtime.**
The sub-packages' npm `latest` dist-tag is stale (`0.0.1-rc.5` against a `0.1.5-rc.2` runtime), and that old bridge reads `session.events` synchronously, a read DSH deprecated after rc.5.
Under the mismatch the bridge throws inside `lastTurn()` before any hook is matched, so EVERY tool call fails with `Error: agent.session.events is not iterable` while the guards are simultaneously inert and tool-breaking.
The pin is asserted by the preflight rather than documented:

```sh
dsh plugin --profile <name> add @deepseek-ai/dsh-hooks-claude-code@0.1.5-rc.2
```

Three earlier "no hook fired" readings were test-harness faults, not adapter faults: a hook writing outside the session workspace root (silently sandbox-denied, which reads exactly like a hook that never ran), and a reused persisted session id that made `session/prompt` reject the run.

The registration is `.dsh/hooks.json`, mounted by `.dsh/profile.patch.yml`.
Exactly one mounted hook config per profile is required, because DSH has no host-stamp key: a bundle config plus a project `hooks.json` would double-run every event.
The `.*` catch-all group is a single point of failure for all three guards, and each command is a self-verifying wrapper: it re-checks that this file still registers that very script and that the resolved root looks like a firstmate checkout, and exits 0 when either is untrue, so a mis-mounted or double-mounted copy fails safe instead of running a guard against the wrong home.
`tests/fm-dsh-harness.test.sh` proves dispatch **through the tracked file** rather than trusting its shape: the delegation guard denies a delegation tool with exit 2 and allows an ordinary tool, the `Stop` wrapper blocks a blind turn end in a fixture home with exit 2, and every registered wrapper is a silent no-op for a wrong root and for an empty payload.

## The bounded Stop guard

DSH reports `stop_hook_active=false` on **every** Stop, so that field cannot bound a re-block loop the way the default mode relies on; the adapter therefore counts its own continuations.
`bin/fm-turnend-guard-dsh.sh` calls the shared guard with `--dsh`, whose semantics are:

- The budget is **3** continuations (`FM_DSH_TURNEND_BLOCK_BUDGET`) and is an **episode**, not a session lifetime: a ledger older than `FM_DSH_TURNEND_BUDGET_WINDOW` (900s) is discarded, so one exhausted lapse cannot leave a long-lived session permanently blocked.
- The count is incremented and written **before** the stop decision, so a killed hook cannot lose a consumed continuation.
- An unacquirable budget lock raises the alarm rather than falling through to an unbounded block; that exact bug once made the loop unbounded precisely when the guard could prove the least.
- The terminal state is **one alarm turn, then allow**, so the block bound is `budget + 1`.
- Every later stop is allowed once the latch exists, until a healthy supervision read clears the latch and the budget together, so a recovered home can alarm again on a later lapse.
- Unusable input (empty or unparsable stdin) and an unresolvable root both fail open.

The alarm-turn shape exists because DSH's bridge **logs and drops** a non-blocking `systemMessage` ("not yet surfaced (ignored)"), so the Claude path's loud `terminal_fail_open` produced no operator-visible record at all on DSH — the original "one loud attended fail-open" was attended by nobody.
The only channel DSH surfaces is a blocking `Stop` decision whose reason is model-visible steering, so the alarm rides that, and it is additionally latched durably at `state/.dsh-turnend-fail-open`, which the session-start digest prepends.

Unit fixture: five consecutive blind stops over one in-flight task returned `2, 2, 2, 2, 0` — three budget blocks, one alarm turn, then allow — and left the alarm latched.
Live: an SDK-driven turn under the same conditions ran the guard four times and settled, leaving `state/.turnend-dsh-blocks` at `session=fm-guard-probe\ncount=4`. That run predates the alarm turn: it measured three blocks and a non-blocking fail-open, so it is live evidence that the budget bounds the loop, not of the shipped `budget + 1` shape, which has only the unit fixture.

## Idle wake: the `job` supervision model

A DSH watcher runs as a background job that **exits on every actionable wake**, and the model re-arms it only after handling that wake, so "no live watcher" is this adapter's ordinary mid-turn state.
`bin/fm-wake-lib.sh` gained a fourth model, `job`, resolved for `dsh`; the pre-existing `persistent` model called that state a lapse, which is what made the drain and every guarded command cry `WATCHER DOWN` on every wake.

The proof is the arm's own delivery ledger: `bin/fm-watch-arm.sh` records one line per delivered reason **after** the cycle's final beacon touch, so a ledger mtime at or after the beacon mtime proves the cycle ended by delivering a wake rather than by dying.
`fm_job_midturn_healthy` requires that ordering and bounds the handling turn with `FM_JOB_MIDTURN_GRACE` (900s); a fresh beacon is healthy with or without a live watcher, and a stale one is healthy only inside that window.

| Criterion | Method | Observed |
|---|---|---|
| An actionable event wakes an IDLE captain | arm `sleep 12; echo FM-WAKE-PROBE-FIRED` as a background job, end the turn, hold the notification subscription open | the agent reported idle 5.0s in, stayed idle through 13.0s, and resumed at 19.0s when the job settled |
| The model still alarms a genuine lapse | synthetic state: stale beacon with no delivery evidence; a ledger older than the beacon; a delivery past the handling window | all three read `down` |
| `persistent` is unaffected | same fresh-beacon state under both models | `job` reads healthy, `persistent` still reads down |

The portable suite pins the model resolution, the tolerated gap, all three lapse shapes, and the healthy in-window case.

## Process-event (`when`) sources firing and retiring

A `when` source was armed from a DSH-hosted home, polled its condition tokenlessly three times, fired its action, captured the result durably, published the normalized wake `check: procevent when when-livetest 1` to `state/.wake-queue`, and retired itself once the adapter classified the outcome terminal.
That maps onto DSH directly: `bin/fm-procevent.sh start` is documented as "meant to run as a supervised background process, never in a conversational turn", which is exactly what a DSH background job is.

This is the one contract in this record established by a **single live run** rather than by a repeatable guard.
The mechanism itself is portably covered — `tests/fm-procevent-when.test.sh` pins the arm/poll/fire/classify/retire contract in 17 cases and `tests/fm-procevent.test.sh` adds 106 — so what is measured-once is specifically the DSH-hosted run as a supervised background job, not the process-event machinery.
A DSH release that changed background-job lifetime would move this claim without failing anything; treat it as measured-once until a guard exists.

## Supervisor-only: the refusals

DSH exposes no endpoint, no interrupt key, no verified exit command, no per-task busy-state source and no dialog-dismiss path, so a dispatched worker could not be steered, inspected or stopped.
`refuse_dsh_crewmate` in `bin/fm-spawn.sh` enforces primary-only on **both** harness-resolution arms, and it is called in both so a kind that skipped one cannot stand up an unsteerable worker.

| Case | Result |
|---|---|
| `--harness dsh` ship | refused, naming "verified PRIMARY adapter only" rather than reporting an unknown harness |
| `config/crew-harness=dsh`, no explicit flag | refused |
| `--scout` and `--secondmate` with `--harness dsh` | refused; the refusal is a property of the harness, not of the kind |
| `--harness dshx` | falls through to `unknown harness`, proving an exact-name match rather than a substring match |
| a raw launch command merely mentioning dsh | not refused; the real failure there is an unusable launch command, not a capability gap |

`bin/fm-busy-lib.sh` and the control-plane tables carry no DSH arm for the same reason, and `docs/configuration.md` states the refusal as operating guidance.

## Crew dispatch and delivery from a DSH-hosted primary

Crewmates are external CLI processes in tmux panes, so nothing about the crew layer depends on DSH, and a DSH captain's ancestry does not leak into a pane: a pane is a child of the tmux server, verified by confirming `FM_DSH_HARNESS` is absent from the tmux session environment.

Phase 2 acceptance was met for the supervisor-only scope: spawn → deliver → captain inventory → teardown ran end to end, and the scout produced `data/<id>/report.md` with the correct answer.
The plan's matrix records crew dispatch for claude, codex, opencode and pi as verified through the scout and ship lifecycles; the detailed narrative evidences the claude path (treehouse worktree, tmux pane, brief delivery, correct deliverable).
Two findings from that run are worth keeping:

1. **The readiness gate cannot detect the already-documented Claude bypass dialog.** With `--dangerously-skip-permissions` the worker parks on Claude's once-per-machine Bypass Permissions warning, whose cursor sits on "No, exit" and which firstmate's key plane cannot answer. This is not a new gap — [`references/harness/claude.md`](../../.agents/skills/harness-adapters/references/harness/claude.md) documents the dialog and the `config/claude-permission-mode=auto` remedy — but the spawn reported `spawned` while the worker sat on it, where the trust-flag path refuses outright. Verified remedy: with `auto` set the worker started its brief immediately.
2. **The primary checkout must be on its default branch.** The spawn warned `WORKTREE TANGLE` while this adapter was being developed on `feat/dsh-primary-adapter`. Advisory in that situation, and the intended check working.

Delivery is per-mode:

| Mode | State | Evidence |
|---|---|---|
| `local-only` | verified end to end | spawn (with the graded deviation notice, since the project's standing posture is `no-mistakes` and the flag carried less rigor) → worker branch `fm/<id>` with one clean commit → `bin/fm-merge-local.sh` fast-forwarded the primary's `main` (`d87fd71 -> 54fefaf`) → teardown returned the worktree and cleared every record |
| `direct-PR`, `no-mistakes` | untested | both push and open a pull request, and this deployment has no GitHub remote for the task repo |
| merge authority, `yolo` | unverified | same missing remote |

The graded deviation notice is itself verification of the posture machinery: it fired because the requested mode was less rigorous than the project's standing posture.

## Teardown and the toolchain it depends on

`fm-captain-hold.sh complete <id> --none` recorded the inventory, `bin/fm-teardown.sh` returned the worktree to the treehouse pool, killed the tmux window and removed the record with no leftover `state/` files.
Every refusal path behaved correctly and preserved state: an unlanded gate, a missing captain inventory, and a missing `treehouse` each aborted **before** any destructive step.

Three dependencies surfaced, all now installed:

| Tool | Version | Floor |
|---|---|---|
| `treehouse` | 2.0.1 | — |
| `no-mistakes` | 1.72.0 | ≥1.46.0 |
| `gh-axi` | 0.1.35 | ≥0.1.29 |
| `quota-axi` | 0.1.44 | ≥0.1.29 |
| `lavish-axi` | 0.1.69 | ≥0.1.46 |
| `chrome-devtools-axi` | 0.1.34 | — |
| `tasks-axi` | 0.2.5 | ≥0.2.4 |

- `tasks-axi` (floor ≥0.2.4) is required by the **scout completion gate**, not merely by the backlog; without it the gate refuses every scout teardown.
- `treehouse` is required by **teardown** as well as spawn; installing it for the spawn alone leaves teardown aborting after it has already force-killed leaked worktree processes. It must resolve on the default PATH — an install beside the checkout is not a deployment.
- The scout independently diagnosed the missing `tasks-axi` and recorded it as a `blocked:` status line. That line is what the classifier reads as an open captain decision, so `complete --none` is refused until a `resolved:` line closes it — the escalation machinery working exactly as designed.
- `no-mistakes` was installed through its documented `curl | sh` script after reading it (2.6 KB, installs under `$HOME` and links into `~/.local/bin` without sudo). It does **not** verify a checksum, unlike firstmate's own pinned installers for `treehouse` and `herdr`.

## Staying mergeable against upstream

The adapter is shaped to stay mergeable rather than merely to work: 12 added files, which an upstream merge cannot conflict on, and 18 modified upstream files, which are the entire conflict surface.
Each modified file is modified additively — a case arm, a new mode, a new function or a call site, never a reorder or a rename — so an upstream change outside those 18 files cannot conflict, and one inside them conflicts at the added line rather than at a rewritten one.

**First sync, 2026-09-16.** Upstream `main` had advanced by one commit (`7111081c`), touching four files, none of them on the conflict surface; the rebase replayed every commit with zero conflicts.

The lesson is the reason this section exists: the rebase was clean and **the adapter was still broken**.
Because `bin/fm-session-lock-lib.sh` gained a source dependency, three upstream test fixtures that copy scripts by explicit list needed the new `bin/fm-dsh-lib.sh`; `fm-turnend-guard.test.sh` failed with `fm-session-lock-lib.sh: line 19: .../bin/fm-dsh-lib.sh: No such file or directory`.
That failure is invisible to the adapter's own suites and appears only when the upstream suites run, so a clean rebase must always be followed by the gates below — never by the adapter's tests alone.

**Second sync, 2026-09-16.** Upstream advanced one more commit (`af1f2ea3`), touching three files on the conflict surface — `AGENTS.md`, `bin/fm-test-run.sh` and `docs/configuration.md` — and the rebase again replayed every commit with zero conflicts.
The adapter was again not actually fine.
`bin/fm-test-run.sh` carries a coverage guard that refuses once more than `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT` of the portable-serial lane has no measured duration hint, and adding two test files moved the share from 25 of 173 to 27 of 175 — over the ceiling, failing `tests/fm-test-run.test.sh` for a reason with nothing to do with DSH.
The fix is the documented refresh: both scripts now carry a measured hint (`fm-dsh-harness.test.sh` 15067 ms, `fm-dsh-live-e2e.test.sh` 143 ms, the latter because the live guard skips without its opt-in).
A new test file is therefore not finished when it passes; it also has to be weighed, and the guard that says so lives in a suite the adapter does not otherwise run.

The upstream changes most likely to break this adapter are the hooks bridge's supported events and payload fields, `bin/fm-harness.sh`'s marker/ancestry arbitration, `fm_watcher_supervision_verdict`'s model set, `bin/fm-spawn.sh`'s harness resolution (a third arm without the refusal would let a DSH crewmate spawn), and DSH renaming its own tools out from under the delegation guard's stems.

## Not established, blocked, or out of scope

Ranked by how likely each is to be mistaken for working.

| Item | State |
|---|---|
| Two concurrent DSH sessions are distinguishable | **unproven.** The lock matches a host by launcher path in argv, but DSH gives hook and tool subprocesses no session identity (`comm=node`), so the acceptance gate that a second concurrent session is refused into read-only has no live test |
| The DSH state files and teardown | **not applicable, by ownership.** `state/.dsh-sessionstart-delivered`, `state/.turnend-dsh-blocks` (+ lock) and `state/.dsh-turnend-fail-open` are home-scoped and session-keyed, and each is self-healing: the gate holds the delivered session id and the next session rewrites it, the budget ledger is discarded once the episode ages past `FM_DSH_TURNEND_BUDGET_WINDOW`, and the alarm latch is cleared by the guard's healthy reset. `bin/fm-teardown.sh`'s volatile sweep is per-task (`$STATE/$ID.*`), and DSH never produces per-task state because it never runs as a crewmate — the same shape as Claude's own `state/.turnend-claude-blocks`, which teardown does not name either. `state/` is gitignored, so no exclude rule is missing |
| The session-death blind window | **unclosable from inside DSH.** No `Stop` fires, so nothing re-arms; recovery happens at the NEXT session start via `state/.watcher-down` → `check: rearm-resurface`, and the only out-of-band closure is an OS-level scheduler. [`docs/supervision-protocols/dsh.md`](../supervision-protocols/dsh.md) states this rather than papering over it |
| Away mode (`/afk`, `/quiet`) | **blocked.** The daemon's only delivery is typing a batched digest into the supervisor's pane after proving the composer empty; DSH has no pane and no inject-into-session primitive, so escalations would buffer forever. Registering it without a delivery channel is worse than not having it: a leftover `state/.afk` makes `fm_afk_daemon_owns_supervision` prove "supervision healthy" and silently redefines the guard's predicate |
| DSH-subagent crewmates | **blocked.** No per-delegation working directory and no child-dispose path, and DSH's own pre-stable tool surface is not a steering endpoint |
| Session identity for the lock | **partially mitigated.** Identity is `ps`-ancestry based and `fm_pid_identity` prefers `/proc`, which was never measured under the sandbox |
| Relay (X/Discord) | **out of scope for this deployment.** No pairing token, and it needs `curl`, `jq` and a wake-into-session path |
| Calm, voice, Lavish board | **out of scope.** Module hooks, a TTY with PortAudio, and a live `lavish-axi` session respectively |
| In-process extension hosts (Pi, omp, OpenCode) | **out of scope.** DSH's bridge is command-only |
| Remote secondmates | **out of scope.** No remote-execution primitive, and no Aqua-birth proof on macOS |
| Secondmates generally, v1 | **refused** by `refuse_dsh_crewmate` |
| `lsof`-dependent teardown proofs | **not isolated.** They ran during a successful teardown, but no measurement confirms the stale-lock proof and orphan reap hold under DSH's sandbox specifically |
| `tests/fm-wake-queue.test.sh` | **flaky independently of this work.** Reverting `bin/fm-wake-lib.sh` entirely still fails most runs; do not read its failures as an adapter regression |

The `systemMessage` drop is not in this table because it was not left unaddressed: the terminal fail-open was re-channelled onto the one surface DSH actually shows a model.

## Refreshing this record

Run the portable suite and the live guard after any DSH upgrade, because the launcher path shapes, the hook payload fields, the tool names and the background-job lifetime are all vendor-controlled surfaces:

```sh
bash tests/fm-dsh-harness.test.sh
FM_DSH_LIVE_E2E=1 bash tests/fm-dsh-live-e2e.test.sh
bin/fm-dsh-preflight.sh --profile <name>
```

As measured on 2026-09-16 against dsh 0.1.5-rc.1 / dsh-base 0.1.5-rc.2: the portable suite passes 37 cases, and the live guard passes all five of its contracts — a matching bridge pin passes the preflight, `UserPromptSubmit` context reaches the FIRST request, a `bash`-matcher deny blocks the command (sentinel absent), a blocking `Stop` forces one bounded continuation (2 firings), and a hook subprocess inherits the host's harness marker.

The live guard resolves the running `dsh-base` version beside the installed `dsh` and fails by name and version rather than degrading quietly; it needs `node`, `jq` and `pnpm`, and it keeps the real harness home on purpose.

Then the upstream suites this branch touches, so an upstream change that invalidates an assumption is caught rather than absorbed:

```sh
for t in fm-turnend-guard fm-wake-drain-outcome-backstop fm-watcher-lock fm-guard-stale-banner \
         fm-session-lock-ancestry fm-harness-precedence fm-arm-pretool-check fm-cd-pretool-check \
         fm-subagent-pretool-check fm-spawn-dispatch-profile fm-supervision-instructions; do
  bash "tests/$t.test.sh" || echo "FAILED: $t"
done
```

As of this writing 10 of those 11 suites pass, 374 `ok` lines between them: `fm-spawn-dispatch-profile` did not complete inside a ten-minute budget in this session and is the one suite this record does not claim a fresh result for.
