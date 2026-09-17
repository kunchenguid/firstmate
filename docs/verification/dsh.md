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

Environment is the only carrier for DSH identity, so `bin/fm-dsh-launch.sh` is the launch boundary: it exports `FM_DSH_HARNESS=dsh`, an explicit `FM_HOME` and `FM_ROOT` as its own checkout, starts the host from that checkout (DSH takes the invoking directory as its workspace root, and `.dsh/profile.patch.yml` resolves the bridge's `configPath` and `projectDir` from `FM_ROOT`, so a launch from any other directory would mount no hooks), pins `LC_ALL`/`LC_CTYPE` (unset, `bin/fm-line-cap-lib.sh`'s character cap becomes a byte cap and slices UTF-8), clears the foreign harness markers so a session started from another harness's pane cannot inherit its identity, applies the tracked `.dsh/profile.patch.yml` with `--patch` (that file is the install step for the bridge mount, the budget and the pinned hook sandbox mode, and without it the documented command boots a profile carrying none of the three), runs the preflight with the profile, the tracked patch and then any operator overlays, and `exec`s `dsh` with the operator's arguments unchanged plus the tracked patch alone, placed immediately after `web` or first otherwise.
An operator `--patch` is an overlay, following the tracked patch and able to override it, only when it comes before every app argument: immediately after `web`, or among the root options.
The launcher collects only those, because DSH applies no other.

Both placements were measured against dsh 0.1.5-rc.1, because the first version of this forwarding broke the launch it was meant to fix while every preflight check passed.
DSH refuses parent options before a subcommand, so `dsh --patch <tracked> web --help` exits 1 with `web takes none of parent --profile, --from-default-profile, --patch, --dump-config, or --dump-default-config`, while `dsh web --patch <tracked> --help` loads the plugin tree and exits 0; `web`'s own options end at the first token it does not know, so a `--patch` after `--port` reaches the web app as `unknown option '--patch'`.
An overlay applied twice is equally invisible to the preflight: `dsh web --patch <tracked> --patch <tracked> --dump-config` composes and exits 0, but loading the tree throws `duplicate loader entry id: hooks-claude-code`, so the launcher adds the tracked patch only when no operator overlay names the same file.
A misplaced operator `--patch` naming it is no overlay, so the tracked patch is still placed after `web` and DSH refuses the misplaced copy.

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
| The effective `agent-instructions` `maxBytes` (65536, the `dsh-base` default) below the rendered chain | FAIL, naming the row's file to raise |
| A budget that covers `AGENTS.md` but not the rendered chain (every instruction file plus the frame) | FAIL |
| The effective `agent-instructions` row absent, disabled, or not provably enabled, whatever its `maxBytes` | FAIL: a disabled row renders nothing |
| Another plugin entry raises its `maxBytes` while `agent-instructions` stays at the default | FAIL: only the `agent-instructions` entry sets the budget |
| A `--patch` overlay given to the launcher raises the budget | forwarded to `dsh --dump-config`, so the checked value is the one the host boots with |
| A `web` composition (host row disabled) whose default agent preset, from the profile or `$DSH_HOME/settings.yaml`, is not `firstmate` | FAIL, naming the preset sessions compose from |
| A `web` composition defaulting to the tracked `firstmate` preset | pass, from that preset's row; FAIL if the preset's row is absent or disabled |
| `dsh --dump-config` fails, or reports no plain-number `agent-instructions` `maxBytes` | FAIL, naming the command to run and the patch file to set |
| New sessions default to a permission preset other than `danger-full-access`, from the profile or from `$DSH_HOME/settings.yaml`, which outranks it | FAIL, naming the preset and where it came from |
| No explicit default permission preset, so DSH would infer one from the sandbox knobs | FAIL |
| The composed `sandbox-policy` mode that hooks run under is not a literal `danger-full-access`: a `!!js` expression, `dsh-base`'s own included, even from a shell exporting `DSH_PERMISSION_MODE=danger-full-access`, or a literal other mode | FAIL, naming the mode, or naming an expression as unpinned |
| Conforming home | pass, all required checks |
| `lsof` absent | warning, not failure: teardown's stale-lock proof and orphan reap refuse rather than proceed |
| `jq` or `node` absent | FAIL, because every guard that needs one fails open and becomes a silent no-op |

Each of the three is silent in production, and all three were written into documentation before they were measured.
The instruction budget is the clearest case: over budget, DSH omits `AGENTS.md` whole, as the [harness reference](../../.agents/skills/harness-adapters/references/harness/dsh.md#instruction-budget) states.
Reproduced by calling the installed `@deepseek-ai/dsh-agent-instructions` 0.1.5-rc.2's own `discoverBaselineInstructionFiles` and `loadBaselineInstructions` with this checkout as the workspace: discovery returned `AGENTS.md` and `CLAUDE.md`; at `maxBytes` 65536 it omitted `AGENTS.md`, truncated nothing, and rendered a 455-byte `<system-reminder>` holding only the budget marker, the intro and the unexpanded `@AGENTS.md` pointer; at 262144 it omitted nothing.
The captain profile sets 262144, but for the documented launch that raise was on the wrong row.
Under `dsh-web-app` the host `agent-instructions` row is disabled and each new session renders with the default agent preset's row, which for DSH's `standard` preset is 65536 and which no profile layer reaches, so a `web` launch dropped `AGENTS.md` whole while the preflight read 262144 off the disabled host row and reported ok.
Every earlier live measurement of the budget was taken in a mode that masked this: the live guard composes its throwaway profile `--from-default-profile headless`, where the host row is live.
The fix is the tracked `firstmate` agent preset, described in the [harness reference](../../.agents/skills/harness-adapters/references/harness/dsh.md#instruction-budget); it is a copy of `standard` because a preset has no patch layer to express "standard plus one change".
The preflight now checks the composition a new session boots with instead: the default preset's row where an enabled `agent-presets` row exists, the host row otherwise, and never a disabled row.
It does not cover a resumed session or one seated on another preset, which keep the budget of the preset they recorded; the harness reference says to replace them.
Measured on 2026-09-16 against the real dsh 0.1.5-rc.1 in a disposable `DSH_HOME`: the `web` composition with the tracked patch passes on the `firstmate` preset at 262144; without the patch it fails on `standard`; a `$DSH_HOME/settings.yaml` default of `minimal` fails; and `sdk` passes on its host row.
`dsh-agent-presets`' own discovery reports the tracked preset healthy, and DSH's renderer at its budget omits nothing; the live guard's sixth contract repeats those `web` assertions.

The sandbox check was the other assurance that could not fail.
It ran `ps` inside the preflight, but the preflight runs in the launching shell before DSH starts and DSH sandboxes only a live session's tool subprocesses, so it always reported ok; its earlier row in this table was measured with a fake `ps`.
A runtime probe is not possible before exec, so the preflight now asserts what launch can observe: the permission preset a new session is seeded with, read from `$DSH_HOME/settings.yaml`'s `permission.defaultPreset` (written by DSH's settings page, and outranking the profile) or else the composed profile row, failing unless it is `danger-full-access`.
That proves the default, not any one session: a resumed session keeps the preset it recorded, and the per-session `/permission` control can still downgrade a session after launch.

That preset still left every hook without `ps`.
Driven live through the documented `web` launch with every preflight check ok, the digest in a `danger-full-access` session read `READ-ONLY SESSION` and `cannot locate harness process in ancestry`, and a probe hook got `/bin/ps: Operation not permitted`.
The hooks bridge calls `runHook(ctx.shell, …)` with no session, so `dsh-sandbox-policy` resolves the host default, `process.env.DSH_PERMISSION_MODE ?? 'workspace-write'`, whatever preset the session holds.
With the host started under `DSH_PERMISSION_MODE=danger-full-access` the same probe ran `ps` and the digest acquired the lock.
The durable fix is that `.dsh/profile.patch.yml` pins the `sandbox-policy` row to `danger-full-access` literally, alongside `permission.defaultPreset` (the mode alone leaves the composed sandbox and approval defaults matching no preset, which `dsh-permission-presets` refuses at load), so the mode travels with the composed configuration rather than with an environment variable a caller can forget.
The pin is now the single mechanism: `bin/fm-dsh-launch.sh` applies the tracked patch itself and exports no `DSH_PERMISSION_MODE`, so there is no environment fallback. The preflight accepts only that literal: a later layer that hands the row back to `dsh-base`'s expression fails as unpinned, whatever the launching shell carries, because the preflight never resolves an expression from the environment.

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

Two more defects surfaced when the digest was driven through a real DSH host:

| Defect | Fix |
|---|---|
| The adapter exited when `state/` was absent, but `state/` is gitignored and only `fm-session-start.sh`'s lock creates it, so a fresh checkout never got a digest | The existence gate is gone; the gate marker is written after session start has created `state/` |
| Inside the digest the host is the ninth process above `fm-harness.sh` (hooks wrapper, adapter and its command substitution, `fm-session-start.sh` and its timeout wrapper), but the DSH ancestry walk stopped at eight, so `FM_DSH_HARNESS` was refused and the digest named no harness | `fm_dsh_ancestry` walks sixteen parents, the depth the session lock already walks |
DSH supplies **no session-open `source` field**, so the digest always runs as a first startup and cannot re-emit after a compaction — a real limitation, not a design choice.

## The fleet lock refuses a second session

The lock records its owner as a pid and matches it against the caller's harness ancestry, and DSH gives hook and tool subprocesses no session identity of their own — the host reports `comm=node`, so identity rests on the launcher shape in its argv.
Both halves were measured on 2026-09-17 with the tracked hooks mounted, a throwaway `FM_HOME` and `FM_STATE_OVERRIDE`, and the real checkout as `FM_ROOT`, so the real `bin/fm-dsh-sessionstart.sh` and `bin/fm-session-start.sh` ran:

- **Acquisition.** A headless session wrote `state/.lock` with the harness pid and wrote the once-per-session gate afterwards, so the digest owned the fleet lock rather than falling into its read-only path.
- **Refusal.** With `state/.lock` already holding a live node process whose argv carries a dsh launcher shape — which is what `fm_harness_pid_alive` demands of a lock holder — a second headless session delivered `READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED` and left the lock untouched, so it did not take over the home.

`tests/fm-dsh-live-e2e.test.sh` asserts both halves, in one lock home, as its ninth contract.
First a control: with the lock free, a session must leave `state/.lock` holding a numeric pid other than the holder's.
Then the refusal: with the lock holding a live dsh-shaped process and the once-per-session gate cleared, a session must leave the lock unchanged and still deliver a digest.
The control is what makes the refusal mean something, because `bin/fm-lock.sh` exits before touching the lock when a session cannot resolve its own harness ancestry, and the digest still carries the read-only banner, so a session that cannot identify itself would otherwise pass the refusal half too.
What the contract proves is that a real DSH session resolves its own identity from its ancestry and then refuses a live harness-shaped holder; the holder is a synthetic process with a fixed argv, not a second real session.

Forking a session while one is live therefore produces a read-only session, not a second captain.

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

The adapter is shaped to stay mergeable rather than merely to work: 14 added files, which an upstream merge cannot conflict on, and 20 modified upstream files, which are the entire conflict surface.
One added file is not merge-neutral against DSH itself: `.dsh/agent-presets/firstmate/agent.cordis.yml` is a copy of DSH's `standard` preset, so a DSH upgrade means re-copying it and re-applying its budget raise.
Each modified file is modified additively — a case arm, a new mode, a new function or a call site, never a reorder or a rename — so an upstream change outside those 20 files cannot conflict, and one inside them conflicts at the added line rather than at a rewritten one.

**First sync, 2026-09-16.** Upstream `main` had advanced by one commit (`7111081c`), touching four files, none of them on the conflict surface; the rebase replayed every commit with zero conflicts.

The lesson is the reason this section exists: the rebase was clean and **the adapter was still broken**.
Because `bin/fm-session-lock-lib.sh` gained a source dependency, upstream test fixtures that copy scripts by explicit list needed the new `bin/fm-dsh-lib.sh`; `fm-turnend-guard.test.sh` failed with `fm-session-lock-lib.sh: line 19: .../bin/fm-dsh-lib.sh: No such file or directory`.
Two scripts load `bin/fm-dsh-lib.sh` from their own directory, `bin/fm-session-lock-lib.sh` and `bin/fm-harness.sh`, so a fixture needs the lib when it copies or links either of them into its own tree.
For the lock lib that is `fm-turnend-guard`, `fm-claude-stop-autoarm`, `fm-session-lock-ancestry`, `fm-cursor-primary` (missed at first, and caught only by CI's portable serial run) and the opt-in `fm-sessionstart-hook-live-e2e` lab.
`fm-omp-harness`, `fm-secondmate-harness` and `fm-dsh-harness` source the lock lib from the real checkout, and `fm-session-start` only names it in a comment, so none of them needs a copy.
For `bin/fm-harness.sh` it is `install_guard_scripts` in `fm-turnend-guard.test.sh`, which copies the script without `bin/fm-dsh-lib.sh`, and without `bin/fm-cursor-lib.sh` and `bin/fm-gemini-lib.sh` either, as it did before this branch.
No test fails there only because every caller runs harness detection behind a `2>/dev/null || printf unknown` guard, so that fixture's detection already reads `unknown`: a latent fixture gap that predates this branch, not a passing test of detection.
That failure is invisible to the adapter's own suites and appears only when the upstream suites run, so a clean rebase must always be followed by the gates below — never by the adapter's tests alone.

**Second sync, 2026-09-16.** Upstream advanced one more commit (`af1f2ea3`), touching three files on the conflict surface — `AGENTS.md`, `bin/fm-test-run.sh` and `docs/configuration.md` — and the rebase again replayed every commit with zero conflicts.
The adapter was again not actually fine.
`bin/fm-test-run.sh` carries a coverage guard that refuses once more than `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT` of the portable-serial lane has no measured duration hint, and adding two test files moved the share from 25 of 173 to 27 of 175 — over the ceiling, failing `tests/fm-test-run.test.sh` for a reason with nothing to do with DSH.
The fix is the documented refresh: both scripts now carry a measured hint (`fm-dsh-harness.test.sh` 15067 ms, `fm-dsh-live-e2e.test.sh` 143 ms, the latter because the live guard skips without its opt-in).
A new test file is therefore not finished when it passes; it also has to be weighed, and the guard that says so lives in a suite the adapter does not otherwise run.

The upstream changes most likely to break this adapter are the hooks bridge's supported events and payload fields, `bin/fm-harness.sh`'s marker/ancestry arbitration, `fm_watcher_supervision_verdict`'s model set, `bin/fm-spawn.sh`'s harness resolution (a third arm without the refusal would let a DSH crewmate spawn), DSH renaming its own tools out from under the delegation guard's stems, `dsh-base` or `dsh-web-app` changing how the hook sandbox is composed (the tracked patch pins the `sandbox-policy` row and the preflight accepts only a literal mode, so a renamed row or key would read as unpinned), and DSH's shipped `standard` preset, which the `firstmate` preset copies.

## Not established, blocked, or out of scope

Ranked by how likely each is to be mistaken for working.

| Item | State |
|---|---|
| The DSH state files and teardown | **not applicable, by ownership.** `state/.dsh-sessionstart-delivered`, `state/.turnend-dsh-blocks` (+ lock) and `state/.dsh-turnend-fail-open` are home-scoped and session-keyed, and each is self-healing: the gate holds the delivered session id and the next session rewrites it, the budget ledger is discarded once the episode ages past `FM_DSH_TURNEND_BUDGET_WINDOW`, and the alarm latch is cleared by the guard's healthy reset. `bin/fm-teardown.sh`'s volatile sweep is per-task (`$STATE/$ID.*`), and DSH never produces per-task state because it never runs as a crewmate — the same shape as Claude's own `state/.turnend-claude-blocks`, which teardown does not name either. `state/` is gitignored, so no exclude rule is missing |
| The session-death blind window | **unclosable from inside DSH.** No `Stop` fires, so nothing re-arms; recovery happens at the NEXT session start via `state/.watcher-down` → `check: rearm-resurface`, and the only out-of-band closure is an OS-level scheduler. [`docs/supervision-protocols/dsh.md`](../supervision-protocols/dsh.md) states this rather than papering over it |
| Away mode (`/afk`, `/quiet`) | **blocked.** The daemon's only delivery is typing a batched digest into the supervisor's pane after proving the composer empty; DSH has no pane and no inject-into-session primitive, so escalations would buffer forever. Registering it without a delivery channel is worse than not having it: a leftover `state/.afk` makes `fm_afk_daemon_owns_supervision` prove "supervision healthy" and silently redefines the guard's predicate |
| DSH-subagent crewmates | **blocked.** No per-delegation working directory and no child-dispose path, and DSH's own pre-stable tool surface is not a steering endpoint |
| Session identity for the lock | **measured for the live case.** The lock owner is matched by `ps` ancestry against the launcher shape in argv, and the refusal was driven live (see The fleet lock refuses a second session) |
| Relay (X/Discord) | **out of scope for this deployment.** No pairing token, and it needs `curl`, `jq` and a wake-into-session path |
| Calm, voice, Lavish board | **out of scope.** Module hooks, a TTY with PortAudio, and a live `lavish-axi` session respectively |
| In-process extension hosts (Pi, omp, OpenCode) | **out of scope.** DSH's bridge is command-only |
| A misplaced operator `--patch` refused before the preflight | **not done, an operator decision.** In `bin/fm-dsh-launch.sh web --port 3080 --patch op.yml` the `--patch` follows a web app option, so DSH hands it to the web app, which refuses it. The launcher does not collect it, the preflight composes without it and can report ok, and only then does the launch exit 1 with `unknown option '--patch'`. The failure is loud; refusing it in the launcher, before the preflight, would be new launcher behaviour and was left undecided |
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
bin/fm-dsh-preflight.sh --profile <name> --patch .dsh/profile.patch.yml
```

Run the preflight on its own with the tracked patch, as `bin/fm-dsh-launch.sh` passes it.
The launcher applies `.dsh/profile.patch.yml` with `--patch` and never copies it into the profile, so without it the preflight composes a configuration the host never boots with: sessions on DSH's `standard` preset, an inferred permission preset and dsh-base's unpinned hook sandbox mode, each reported as a failure whose remedy the launch does not need.

As measured on 2026-09-17, the portable suite passes 46 cases, and against dsh 0.1.5-rc.1 / dsh-base 0.1.5-rc.2 the live guard passed all nine contracts:

1. a matching bridge pin passes the preflight with the tracked patch;
2. `UserPromptSubmit` context reaches the FIRST request;
3. a `bash`-matcher deny blocks the command, with the sentinel absent;
4. a blocking `Stop` forces one bounded continuation (2 firings);
5. a hook subprocess inherits the host's harness marker;
6. the documented `web` launch renders `AGENTS.md` whole through the `firstmate` preset at budget 262144;
7. the launcher's own `web` exec loads the plugin tree with the tracked patch applied once;
8. the tracked patch keeps every permission preset `dsh-base` offers, `read-only` included;
9. a session takes a free fleet lock as its own pid, and a session finding the lock held by a live dsh-shaped process refuses into read-only.

Contracts 6 through 9 were each added after an earlier run and were exercised on their own first; the run above is the first covering all nine together, and its contract 9 ran the control before the refusal.
The first contract was also run with `DSH_PERMISSION_MODE` unset once the `sandbox-policy` pin landed, and the preflight read `danger-full-access` from the pin alone.
The guard no longer unsets that variable, because the preflight now refuses every `!!js` mode whatever the environment holds, so a pin removed from the tracked patch cannot pass on a value inherited from the caller's shell.

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
