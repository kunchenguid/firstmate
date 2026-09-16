# Porting firstmate to DeepSeek Harness — plan of record

Status: **Phase 1 built and partially verified; a full-repository audit has invalidated several
"done" claims and added blockers the earlier plan did not contain.** This document supersedes the
phased plan discussed before the audit.

The audit covered all 180 `bin/` scripts, 30 `docs/` pages, 21 skills, all 16 `AGENTS.md` sections
and the 7 per-harness integration directories, producing 3823 capability rows and four consolidated
gap digests. Raw inventories and the four consolidated digests are preserved at
`/Users/stevemcqueen/Sandbox/dsh/firstmate-audit/` (deliberately outside this repository).

-----

## 1. What is actually verified

| Item | Evidence | Status |
|---|---|---|
| Harness detection (`fm-harness.sh`) | marker + ancestry paths both resolve `dsh` live | ✅ done |
| Session-start digest via `UserPromptSubmit` | token visible on the model's first look | ✅ done |
| Bounded `Stop` guard (`--dsh`) | 3 blocks then fail-open, unit + live (count=4) | ✅ done |
| Idle wake by background job | idle at 5.0s, resumed at 19.0s | ✅ done |
| `agent-instructions` budget | composes at 262144 | ✅ done |
| PreToolUse matchers fire | `bash` + `.*` both fired with the shell tool | ✅ done |
| Hooks-bridge version pin | stale `latest` breaks every tool call | ✅ done |
| Regression test + verification record | 10 cases; 113 tests green | ✅ done |

### Corrections to those claims

1. **Detection is necessary but not sufficient.** `bin/fm-session-lock-lib.sh` maintains its own
   `FM_HARNESS_RE` / `FM_HARNESS_NAMES` and has no `dsh` arm, and `bin/fm-lock.sh` never consults
   `fm-harness.sh`. Lock acquisition therefore exits `cannot locate harness process in ancestry` and
   **every DSH session runs permanently read-only** — no spawn, steer, merge, drain or repair. This
   is the single highest-value next fix and it was not in the plan.
2. **`FM_DSH_HARNESS=dsh` has no producer.** It is honoured by detection but nothing sets it —
   not `dsh/profile.patch.yml`, not any launch path. Every test so far set it by hand. Without it an
   inherited `CLAUDECODE` outranks the `args`-strength DSH verdict and the home loads `unknown.md`.
3. **The digest adapter has four defects.** `bin/fm-dsh-sessionstart.sh` writes its once-per-session
   marker *before* running the digest; runs the start path as `>/dev/null 2>&1 || true`, swallowing a
   lock refusal or a truncation banner; renders the operating block without `--read-only`; and never
   passes `--afk-mode`, so a quiet posture is reported as away.
4. **`--dsh` budget semantics are under-specified.** `state/.turnend-dsh-blocks` is keyed on
   `session_id`, never expires, is written with `2>/dev/null || true` (an unwritable state dir
   silently reopens the loop), and resets whenever supervision reads healthy — so it is a turn budget,
   not an episode budget. When the budget lock cannot be acquired the guard falls through to
   `block_stop` without incrementing, which is an unbounded re-block.
5. **The attended fail-open is invisible.** `--dsh` emits `{"systemMessage": …}` and exits 0; the
   installed bridge parses and drops it, so "one loud attended fail-open" is attended by nobody.
6. **PreToolUse deny is unverified.** We proved matchers *fire*; we never proved a deny blocks a
   call, how `permissionDecision: deny` renders, or whether DSH shares Claude's empty-stdout-on-deny
   requirement. Three guards rest on it.

-----

## 2. Hard blockers

Ranked. Each needs either a DSH capability or an explicit scope-out.

1. **Per-home session lock.** As above. Fix: add `dsh` to `bin/fm-session-lock-lib.sh` and marry the
   two identity owners. Without it nothing else on this list matters.
2. **No session identity for hook/tool subprocesses.** Identity is `ps`-ancestry based, and DSH runs
   as `node` (`comm=node`), so two concurrent DSH sessions are indistinguishable. `fm_pid_identity`
   also prefers `/proc`, which was never measured under the sandbox. Needs a session-id + owner-pid
   surface exposed to hooks and tools.
3. **No observation channel for a running session.** The pane-staleness backbone
   (`bin/fm-watch.sh` layer 1), the rendered-tail busy fallbacks, `fm-crew-state.sh` and the steering
   doorbell all read a tmux/herdr pane. DSH exposes no capture/composer/keystroke surface for another
   session, so crew liveness cannot be proven and unprovable panes either surface as alarms or are
   silently absorbed.
4. **DSH cannot be supervised as a crewmate.** No verified exit command, no interrupt key, no
   per-task busy adapter, no dialog-dismiss path. This is bigger than "teardown parity": the whole
   spawn → steer → observe → control → teardown plane has no DSH target. Either DSH grows an
   endpoint primitive (`submit`/`interrupt`/`stop`/`readState` on a delegation) or DSH stays
   **supervisor-only** and `config/crew-harness=dsh` is refused.
5. **No session-ended or disposed event.** The bridge stops at
   SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop. When the host or session dies, the
   watcher job dies, no `Stop` ever fires, and nothing releases `state/.watch.lock` or clears the
   DSH state files. Every cleanup must become predicate-driven, or DSH needs a disposer event.
6. **Away-mode escalation has no delivery channel.** The AFK daemon batches escalations and types one
   digest into the supervisor pane after proving the composer empty. No pane, no delivery — and a
   leftover `state/.afk` makes `fm_afk_daemon_owns_supervision` prove "supervision healthy",
   silently redefining the guard's healthy predicate.
7. **Per-delegation hook wiring and generation binding.** firstmate installs hook wiring per task and
   embeds a minted `busy_gen` so a superseded incarnation's events fail closed. DSH hooks are a
   per-profile `hooks.json` with no generation convention and no `StopFailure`/`SessionEnd`, so busy
   state cannot be armed, bound or retired for a child.
8. **The `tasks-axi` work database.** Nothing on DSH provides `hold --kind captain`, `unhold`,
   `update --body-file`, multi-ID `mv`, `reopen`, `unblock --by`, or the frozen invariant
   "`state/<id>.meta` exists ⇔ the row is In flight". Without it the backlog and every captain hold
   lose their second half.
9. **No remote-host primitive.** All `fm-remote-*` / `fm-on.sh` capability is "run this in another
   home on another machine with an identity that survives disconnection". Scope remote secondmates
   out of v1 by name, or ship an external transport.
10. **No durable worker/queue host.** `fm-remote-job-worker.sh` needs single-instance locking,
    heartbeat, code-identity freshness, lane-serialised FIFO, preemption and
    quarantine-on-unconfirmed-shutdown. DSH background jobs die with composition teardown and have no
    "the previous owner could not prove it stopped" state.
11. **The shipped protocol contradicts the arm seatbelt.** `docs/supervision-protocols/dsh.md` step 3
    and the `dsh` repair line tell the agent to run `bin/fm-watch.sh`; `bin/fm-arm-command-policy.mjs`
    denies exactly that with `watcher-direct`. One contract must change.

-----

## 3. Gaps the plan was missing

Grouped by theme. These are the reason for the audit.

**Lifecycle, teardown and cleanup**
- Teardown gates are a transaction, not a checkbox: landed-work proof chain (dirty filter, unpushed
  commits, merged-PR head by ancestor *or* patch-id, `merge-tree` content-in-default, gh-error →
  inconclusive → refuse), slot-ownership claim, endpoint-close refusal, captain-hold deferral, and
  two-phase backlog close with `spawn_gen`-bound replay. `--force` has a narrow enumerated meaning
  and never lifts the captain's question or an endpoint-close refusal.
- DSH's own state files (`state/.dsh-sessionstart-delivered`, `state/.turnend-dsh-blocks` + lock)
  appear in no inventory and are swept by nothing; they accumulate per home and survive
  re-provisioning.
- Nothing owns watcher-job reap, lock release, or the `busy` record on session death.
- Predecessor retirement before successor start: every arm must retire the previous generation
  serially and wait for its child to close, or a job-based port leaks processes and double-supervises.
- Temp-and-rename residue has no sweeper (`.fm-custom-check.XXXXXX`, inbox `.staging-*`).

**Crash and partial-failure recovery**
- Session-start recovery is a first-class subsystem: backlog-close replay, branch-outcome replay,
  lease sweep, parent-channel redelivery. The current adapter runs the digest *after* writing its
  marker with stderr discarded, so a lock-refused or failed startup is swallowed for that whole
  session and the replay never runs.
- The host/session-death blind window has no owner: no `Stop` fires, so `--dsh` never runs and the
  re-arm becomes model memory. A cron-like schedule must own re-arm.
- Ordering is contract: durable wake → marker/receipt → artifacts. The merge outcome is published
  *before* its dedup marker; reversing that loses merges silently.

**Idempotency, ordering and replay**
- Enqueue-before-suppress ordering appears in at least five places; reversing any one turns a delay
  into permanent loss.
- Incarnation tokens (`spawn_gen`, `busy_gen`, claim generations), not task ids, are the identity. A
  port that treats a task id as stable double-acts after relaunch.
- Wake acknowledgement is generation- *and* sequence-bound; one inbox note has two independent acks.
- Merge outcome is deliberately at-least-once while parent-channel append is at-most-once. The two
  models are opposites on purpose.

**Locking and concurrency**
- Two lock families share a prefix and are **not** the same mechanism: `bin/fm-wake-lib.sh`'s
  symlink-directory mutexes vs `bin/fm-lock-lib.sh`'s read-only `lsof`-based staleness proof.
- At least fifteen distinct scopes, per-path fail directions, and a stated acquisition order. In DSH
  every tool call is its own process and the model decides when work ends, so release must be explicit
  and the check/use window must stay covered.
- Bounded vs unbounded acquisition is deliberate: a stale `.watch.lock` can hang a DSH bash call
  forever. Default every turn-facing acquire to the bounded form.

**Budgets, resets and failure direction**
- Fail direction is per-guard and asymmetric on purpose: hooks fail open; the arm classifier fails
  closed on unclassifiable protected syntax; the cd-guard fails open; the delegation guard fails
  closed on every escape-hatch value but the exact string. Unifying them silently changes the safety
  property.
- Busy's unknown boundary: missing/malformed/stale/untrusted reads `unknown`, never `idle`, and
  unknown is never promoted to busy.
- Positive-recovery resets are contract: a healthy watcher must clear the block budget, the failure
  notice and the attended alarm together.

**Verification and trust gates**
- Acceptance is pinned by firstmate's own suites (`fm-teardown.test.sh`,
  `fm-secondmate-safety.test.sh`, `fm-captain-hold-lifecycle.test.sh`,
  `fm-inactive-reconcile.test.sh`, `fm-backlog-atomicity.test.sh`, `fm-control.test.sh`,
  `fm-crew-state.test.sh` and others), not by new smoke tests. A port that passes a demo still fails
  a `kill -9`.
- A new adapter is *unreachable* until detection, launch, busy state, lifecycle, liveness, primary
  integration and model discovery all land, each with a portable regression **plus** a credentialed
  live guard **plus** a dated verification record.
- PreToolUse deny semantics are unproven (see §1.6).
- One catch-all `.*` PreToolUse group is a single point of failure for all three guards.

**Operator ergonomics and escalation**
- The escalation channel is unnamed: `actionable:` lines, `WAKE_ACK_REQUIRED`, the attended fail-open
  and `fm-guard.sh` banners are the operator contract and DSH has no defined surface for them.
- "Attended" needs a definition — `--attended-override` and `--allow-red` assume a human; DSH is
  unattended by default.
- Refusal messages are the operator interface: they name the exact record, path, next action and
  whether anything changed. Exit codes carry meaning (`fm-send` 3 = "typed but unconfirmed — verify,
  never retype"; 255 = "unknown remote completion", never "failed").
- Read-only advisory mode (`FM_GUARD_READ_ONLY`) is a separate code path, not a flag flip.

**Contracts invisible in a hook file**
- The delegation guard must classify DSH's real tool names: `subagent`, `subagent_fork`, `workflow`,
  `send_message` match the deny stems (intended), while `ralph`, the goal tools, `job_*` and the
  schedule tools do not — and `ralph` spawns autonomous agents that write no `state/<id>.meta`, the
  exact class the guard exists for.
- Every `FM_*` tunable and `FM_ALLOW_SUBAGENT`/`FM_DSH_HARNESS` are launch-time environment; a tool
  call cannot set them. Prove hook subprocesses inherit firstmate's environment.
- Pin `LC_ALL`/`LC_CTYPE`: a session started from the Web client can leave them unset, turning the
  character cap in `bin/fm-line-cap-lib.sh` into a byte cap that slices UTF-8.
- Hook subprocess toolchain floors: `jq`, `node`, `perl` (with `Fcntl`), `python3`+`tomllib`,
  `lsof`, `timeout`/`gtimeout`, `md5`/`sha256` tools, `stat` in both spellings. Every guard fails
  open without them, so an absent tool is a silent no-op — the failure mode they exist to prevent.

-----

## 4. Declared out of scope for DSH

State these explicitly so nobody builds a partial shim.

| Capability | Owner | Why |
|---|---|---|
| Calm mode | `.claude/mods/firstmate-calm/**` | Needs module hooks, `ui.render` overrides and a blit surface |
| Voice device path | `bin/fm-voice-client.py`, `bin/fm-voice-relay.py` | Push-to-talk needs a TTY and PortAudio; `--in-file`/`--out-file` modes survive |
| Lavish board | `bin/fm-bearings-board.sh` | Needs a live `lavish-axi` session. Note the side effect: `reconcile-requests`' only creator is the board seam, so `reconcile list/note/close` become unreachable |
| In-process extension hosts | `.pi/extensions/**`, `.omp/extensions/**`, `.opencode/plugins/**` | DSH's bridge is command-only: no module hooks, no synchronous extension bus, no per-tool spawn hook |
| Remote secondmates | `bin/fm-on.sh`, `bin/fm-remote-*.sh` | No remote-execution primitive; macOS Aqua/keychain ownership has no DSH analogue |
| Secondmates generally, v1 | `bin/fm-secondmate-*.sh` | Full installs needing an addressable peer and a home-retirement lifecycle |

-----

## 5. DSH prerequisites

Configuration and capabilities the deployment must supply.

**Profile**
- Select the shipped `danger-full-access` **permission preset** (not a bare `sandbox-policy.mode`
  override, which is refused at load). `ps`/`lsof` are load-bearing and their denial is *silent*.
- Add a **startup capability assertion** that `ps`, `lsof`, negative-pid `kill` and (on Linux)
  `/proc` actually work, failing loudly with the effective profile named.
- Raise `dsh-agent-instructions` `maxBytes` on **every** DSH home, and monitor it — the failure is
  silent truncation of `AGENTS.md` §§10–14.
- Pin `@deepseek-ai/dsh-hooks-claude-code` to the running `dsh-base` version **and assert it at
  startup**; a stale bridge makes every tool call fail while the guards go inert.
- Exactly one mounted hook config per profile: DSH has no host-stamp key, so a bundle config plus a
  project `dsh/hooks.json` double-runs every event.

**Launch boundary (launch-time environment, not settable from a tool call)**
- `FM_DSH_HARNESS=dsh`; scrub inherited `CLAUDECODE`/foreign markers.
- `FM_ALLOW_SUBAGENT=1` if the delegation escape hatch is wanted.
- An explicit `FM_HOME` for `bin/fm-send.sh`; pinned `LC_ALL`/`LC_CTYPE`.

**Capabilities DSH must expose**
- A session identity (session id + owner pid) visible to hooks and tools.
- A session-ended/disposed event, or a documented disposer hook.
- A cron-like schedule able to re-arm the watcher independently of any turn.
- A way to enumerate and kill only this home's background job.
- An operator-visible channel for `systemMessage` / `actionable:` lines.
- A session-open `source` field (startup/new/clear/compact/resume/fork) so the digest can re-emit
  after compaction.
- For crewmates only: per-delegation cwd + env, a child-dispose path, and an endpoint control API.

-----

## 6. Revised phased plan

**Phase 1a — make the captain actually functional (blocking).**
1. `dsh` arm in `bin/fm-session-lock-lib.sh` + marry it to `fm-harness.sh`.
2. Producer for `FM_DSH_HARNESS=dsh` at a real launch boundary; scrub `CLAUDECODE`.
3. Fix the four digest-adapter defects; make the marker write *after* success.
4. Fix `--dsh` budget semantics: episode-scoped, expire it, bound the never-acquired-lock path.
5. Route the attended fail-open through a channel DSH surfaces.
6. Resolve the arm-seatbelt / protocol contradiction; bless the exact command text.
7. Startup assertions for the bridge pin, the byte budget and the sandbox capabilities.

**Phase 1b — make supervision honest.**
8. Add the fourth supervision model (`job`/`between-turns`) so `fm-guard.sh` stops crying
   `WATCHER DOWN` on every drain, with a poll-derived grace that tolerates the wake-handling turn.
9. Wire a cron-owned re-arm so a session/host death is not a silent gap.
10. Define the operator surface for escalations and the attended fail-open.
11. Verify PreToolUse **deny** end to end; classify DSH's real tool names in the delegation guard.
12. Add the DSH rows to `docs/configuration.md`, `docs/sessionstart-nudge.md`, the harness-adapters
    routing JSON, and re-author the skills that would otherwise instruct pane workflows.

**Phase 2 — supervisor-only crew (external CLIs).**
13. `fm-spawn.sh` launch templates verified for claude/codex/opencode/pi; per-crewmate model+effort.
14. `treehouse` worktrees; `fm-busy-lib.sh` DSH rows only if a DSH crewmate is ever attempted.
15. Teardown decomposed per §3, including the DSH-only state files in the volatile-state matrix and
    the git-exclude rule for any file the adapter writes into a worktree.

**Phase 3 — delivery and toolchain.**
16. Toolchain: `treehouse`, `no-mistakes`, `gh-axi`, `tasks-axi`, `quota-axi`, `lavish-axi`.
17. Delivery modes end to end; merge gate and merge poll semantics; backlog + captain holds (needs
    the work-database decision from §2.8).

**Phase 4 — optional and advanced.** Away mode (only with a delivery channel), Relay, process-event
sources, DSH-as-crewmate (only if DSH grows the endpoint primitive).

**Phase 5 — verification and upstream.** Portable regressions from firstmate's own suites, a
repeatable opt-in DSH live suite, dated verification records, upstream the adapter.

-----

## 7. Acceptance gates

A DSH home is **unreachable** as a firstmate primary until all of these hold, each with a portable
regression *and* a repeatable opt-in live guard:

1. A DSH session acquires `state/.lock`, records the outermost harness pid, and a second concurrent
   session is refused into read-only rather than failing to find the harness.
2. The digest lands before the first request, and a lock-refused or truncated startup is *visible* to
   the agent rather than swallowed.
3. A blind turn end is blocked, bounded, and leaves an operator-visible record when it fails open.
4. A healthy DSH home between a wake and its re-arm does **not** print `WATCHER DOWN`; a genuinely
   dead watcher does.
5. A PreToolUse deny blocks a call with a human-readable reason and a sentinel proving the command
   never ran.
6. Kill the session mid-fleet and supervision re-arms and alarms within one cadence.
7. A completed task's crewmate is removed, its worktree returned, and its volatile state — including
   every DSH-specific file — cleared; an unlanded task refuses teardown.
