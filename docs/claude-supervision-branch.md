# Claude Code supervision branch

Fleet supervision on a Claude Code primary can run on a second, persistent agent inside the same `claude` process as the captain's chat, exactly as the [Pi supervision branch](pi-supervision-branch.md) does inside `pi`.
The Claude Code branch is the `fm-branch-mod` plugin under `.claude/mods/fm-branch-mod`: one function-hooks binding (`hooks/branch.ts`, the thin Claude Code surface that keeps only what needs the host object), the canonical shared modules it delegates to (`lib/fm-branch-eligibility.ts`, `lib/fm-branch-report-sequence.ts`, `lib/fm-branch-provider-latch.ts`, `lib/fm-branch-classifier.ts`, `lib/fm-branch-text.ts`, `lib/fm-branch-scope.ts`, `lib/fm-branch-routing.ts`, `lib/fm-branch-delivery.ts`, `lib/fm-branch-monitor.ts`, and `lib/fm-branch-settlement.ts`), one agent definition (`agents/fm-branch.md`), and the classifier's system prompt (`classifier-system.txt`).
This document owns the operator contract: what the mod does, how a home opts in, the launch settings it requires, its version pin and the pin-bump procedure, its state and config files, the durable classification log and its scorer, and the bounds measured on the pinned Claude Code version.
The module header owns the module's own shape, and [`pi-supervision-branch.md`](pi-supervision-branch.md) owns the design the two branches share: the outcome store, the leases, the verdict distinction, and the lost-wake backstop.

The mod is deliberately inert everywhere it is not asked for:

- It loads only through `--plugin-dir`; unlike the Calm mod it is never linked into `.claude/skills`, so no trusted project, worktree, or crewmate session auto-loads it.
- It refuses to load on any Claude Code version other than its pin (see [Version pin](#version-pin)), and a refused module passes every hook through untouched.
- Every `bin/` piece it relies on is switched by the presence of `state/.branch-mod-mode`; a home without that file runs the unchanged wake path, and `bin/fm-lease-lib.sh`, `bin/fm-branch-outcome.sh`, and `bin/fm-wake-grant.sh` are shared with the Pi branch unchanged.
- It never sets `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` or any other Claude Code setting; enabling the function-hooks surface is the captain's own explicit opt-in per session, and `config/claude-function-hooks` is the per-home opt-in that puts the variable on a launched worker's environment (docs/configuration.md "Claude function hooks").
- It depends on nothing outside the tracked `bin/` scripts it calls; in particular it never imports or calls the fork-only tracing series.

## What the mod does

The Claude Code protocol's Stop-hook rewake delivers every actionable watcher close into main's prompt as a `Stop hook feedback` message.
The mod intercepts that message in `prompt.submit` before it opens a main turn, scopes the wake to the queue rows the branch may own (the same eligibility as the Pi branch: task-local `signal` and `stale` rows with no open captain decision, decided by folding the task's status log with the shell fold's v8 rules in `bin/fm-classify-lib.sh`, never a `check` row or a watcher-failure alarm), claims a wake grant, and delivers the wake to the branch agent.
Delivery spawns the agent once per branch generation (`$.agent.spawn`, a background agent named `fm-branch`) and reaches the same agent through `SendMessage` for every later wake, so the branch keeps its context across wakes.
Every task wake hands the branch the deterministic new-status-lines note (the status lines appended since the task's last outcome), so what keeps the branch from re-escalating is the outcome index rather than its memory.
A delivered wake is dropped from main, which stays silent; a wake the branch may not own, or one the mod cannot deliver, passes through to main exactly as it would without the mod.

The branch agent runs on the same system prompt as the Pi branch (`bin/fm-branch-prompt.sh`) plus a hooks-module addendum, generated into `agents/fm-branch.md` by `bin/fm-branch-agent-md.sh`; `bin/fm-branch-agent-md.sh --check` fails when the tracked file is stale.
The module's eligibility scan delegates to the same shared fold the Pi extension consumes, whose canonical copy lives in the mod's own `lib/fm-branch-eligibility.ts` (pure core only - a hooks module may import nothing but its own files, so the scan orchestration in `lib/fm-branch-scope.ts` binds it to the host's file/stat seams instead of `node:fs`, the `FM_CLASSIFY_*` environment read stays in the hook because the strict validator lists the environment a module reads from its literal call sites, and the repo's `lib/fm-branch-eligibility.ts` is a thin wrapper that re-exports the core and adds those bindings).
The loader's rule is realpath containment: a symlink is followed and its target must stay inside the plugin, so the shared modules' canon lives under the mod and the repo's `lib/` entries are tracked symlinks to it, inverting the earlier vendoring (the Calm-mod pattern, [calm.md](calm.md)); no build or resolve hook exists on the plugin surface.
The same canon carries the report/processed decision core (`lib/fm-branch-report-sequence.ts`: report validation, scope verdicts, the settlement argv builders and the module-owned settlement path (call order and failure meanings), and the machine-owned failure and success wordings this host renders byte-identically to Pi), the failure latch machine (`lib/fm-branch-provider-latch.ts`), the pre-branch classifier (`lib/fm-branch-classifier.ts`: evidence mapping, the host-agnostic verdict interpretation, the classification-log record builder, and the passed-to-main cover argv), with this host declaring its latch policy (threshold two, fixed five-minute cooldown, no recovery probe - the doubled-value cap makes the exponential base unobservable here) and keeping its own seams: the duplicate-report guard and the captain-facing latch strings (the scoping refusal's normal-result shape and wording, the failure predicate, and the remaining settlement strings are unified across both hosts by the captain's 2026-09-20 ruling, so they are no longer mod-only).
The mod's own binding modules own the rest of the host-independent decisions the hook used to carry inline: the text builders and parses (`lib/fm-branch-text.ts`: the rewake banner, the reason-line filter, the monitor-event parse, the deterministic new-status-lines note, the processing request, the Bash actor command, and the version-pin probe parsing), the wake-routing decision (`lib/fm-branch-routing.ts`: the pass/grant verdict sequence, the passed-wake dedupe key and window, the classifier gate, and the pass effects), the delivery state machine (`lib/fm-branch-delivery.ts`: spawn-once-then-send, the pinned-ref retry, the unresumable rotation, and the own-agent bookkeeping), the monitor guard (`lib/fm-branch-monitor.ts`: the armed claim, the stale-claim expiry, the re-arm gating, and the Monitor loop command), and the session and settlement rules (`lib/fm-branch-settlement.ts`: the deterministic backstop, the transcript-persistence rule, the counters record, and the usage fold with the rotation bound); each takes its host effects as per-call deps, because the validator's spelling rule for `$` keeps the host object at the call sites.
The classifier's facts objects and log records are byte-stable across both hosts by construction: both hosts consume the same canonical files under the mod's `lib/`, Pi through the repo's tracked symlinks.
It records each handled wake through the mod's `fm_branch_report` tool, which appends to the shared outcome store (`bin/fm-branch-outcome.sh`) before anything reaches main.
A `routine` outcome ends there.
A `captain` outcome opens one sequence-keyed processing request on main, which tells the captain the outcome and acknowledges the sequence through `fm_branch_processed`, exactly as on Pi.
The branch's own Bash calls carry the branch actor identity, so every lease-guarded script sees the branch as the branch.
Its model steps run at low effort, and its model comes from `config/supervision-branch-model` (default `sonnet`).

The branch is bounded inside the mod, not by an `autoCompactWindow` setting: when a wake's per-step request context passes 60,000 tokens, the next wake goes to a fresh agent (`fm-branch-2`, `fm-branch-3`, ...) seeded with the deterministic new-status-lines note, and the old agent simply never receives another message.
The same rotation fires when `SendMessage` reports the agent cannot be resumed (a bridge primary runs with transcript saving off, so the agent's transcript is never written): the wake goes to the fresh agent instead of passing every later wake to main.
A branch turn that ends in a provider error, or without a report, hands the wake back to main; two such turns in a row latch the branch off for five minutes, during which every wake goes to main.
A branch hand-back message, and the completed background agent's own notification, are dropped so they never open a main turn.

Continuity across the branch's own turns uses one `Monitor` task per session, described `fm-branch-mod watcher continuity`, with a 30-minute timeout re-armed on expiry.
Arming never depends on a captain prompt: the monitor is armed at session start when the mode file is present and the session lock is held (the same evidence the restored counters read), every captain prompt and every Stop-hook-sourced wake reaching `prompt.submit` re-arms when no live monitor is claimed (an armed claim older than the monitor timeout plus five minutes with no expiry notice in hand counts as dead; peer messages and non-wake task notifications do not re-check), and a branch turn that settles a wake with the claim still false arms from the branch's own settlement - a module reload followed by silence, a failed arm, or a lost expiry notice each still leave one live cycle behind.
It streams each watcher close that arrives while no main turn is open into `prompt.submit` as a task notification, where the same routing applies.

### Deterministic backstop

After every routine branch outcome, the mod runs `bin/fm-wake-evidence.sh --routine-covered <task>` from the branch's own `turn.complete` hook.
Any captain-facing status line that a routine outcome covered, and main has not been shown, is delivered to main as a supervision backstop prompt.
The same lines surface in main's next `bin/fm-wake-drain.sh` under `STATUS OUTCOME BACKSTOP`, marked `(covered by a ROUTINE branch outcome)`, even when a later routine line is the newest; that drain extension is switched by `state/.branch-mod-mode` and is otherwise silent, and each line is presented once.
A `needs-decision:` or `blocked:` line with a parseable key is never re-presented this way, because the durable OPEN DECISIONS fold alone presents it.

### Classifier

The classifier's decision core is the shared `lib/fm-branch-classifier.ts` (the canonical copy under this mod's `lib/`, which the repo's `lib/` symlinks to and the Pi extension imports directly; its integration is documented in [Pi supervision branch](pi-supervision-branch.md)); the behavior below is one capability on both hosts.

A text-only classifier runs ahead of the branch on every eligible wake.
It is one `$.model.complete` call on the model named by `config/classifier-model` (default `haiku` on this host; [configuration.md](configuration.md) "Claude Code supervision branch" owns the resolution and fallback rule), with no thinking and `maxTokens` bounded at 200, over the wake's reason line and a bash-gathered evidence bundle (`bin/fm-wake-evidence.sh <task>`: the task's current state, the status lines appended since the last classified wake marked NEW, and a few earlier lines marked HISTORY).
Only a confident `routine` verdict lets the wake go to the branch; `captain`, `uncertain`, a malformed answer, and a failed call all pass the wake to main, and main's direct handling is covered in the outcome store so the branch and the backstop never re-escalate it.
The queue rows of a passed wake are recorded in `state/.branch-mod-passed` until main acknowledges them; while one is still queued, every later wake carrying it goes back to main without a classifier call, across a module reload or a session restart, because its lines are already history to the classifier.
Rows that have left the queue are swept from the guard at the next wake whose scan is safe; an unsafe scan (a torn or unresolvable row) passes the wake to main and leaves the guard untouched.
That re-pass treats every eligible row of the wake as passed, covered in the outcome store like a classifier pass, so a newer row queued beside the unacknowledged one is not re-escalated either.
The offset of the last classified bundle lives in `state/.<task>.classifier-offset`, owned by `bin/fm-wake-evidence.sh` and removed by teardown.

Every classifier call appends one record to `state/branch-mod-classifications.jsonl`: the wake text, the tasks and queue sequences, the evidence byte range per task (`{"task","from","to"}`), the verdict, the reason, the model name, the elapsed milliseconds, and the model's answer.
`bin/fm-branch-classifier-score.sh [-v] [<log>]` scores that log retrospectively: each record is re-labelled from the status bytes it judged, using the same captain-relevance test main applies (`status_is_captain_relevant`), and the table mirrors the spike replay scorer, so a record whose label is `captain` and whose verdict was `routine` is a captain miss, and `-v` lists every disagreement with its task and byte range.
Records whose status log was torn down count as unscorable.

## Opting a home in

1. Install Claude Code at the pinned version.
   The pin check reads the version of the binary actually running the session, so launch the pinned binary by absolute path; `claude --version` through PATH is only the fallback and may name a different release.
2. Create `state/.branch-mod-mode`; its presence alone switches the mod and every `bin/` piece it relies on, and its content is ignored.
   Remove the file to switch them all off together.
3. Optionally write `config/classifier-model` and `config/supervision-branch-model`.
4. Add the `claude` entry to `config/watched-tools.json` exactly as [`configuration.md`](configuration.md#watched-tool-updates-configwatched-toolsjson) "Watched tool updates" documents it, so a new Claude Code release is reported rather than discovered when the mod refuses to load.
5. Launch the primary with the settings below.

## Launch settings

Measured on Claude Code 2.1.278 (2026-09-19); `tests/fm-branch-claude-mod-live-e2e.test.sh` launches exactly this way.

- `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` in the environment: the function-hooks surface is early access and default-off, and without it the module never loads.
- `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` in the environment: a Herdr server started inside a Claude session hands the pane its `CLAUDE_CODE_CHILD_SESSION` marker, which switches transcript saving off, and without a disk transcript every resume of the branch agent fails once Claude Code evicts the finished agent from memory 30-60 s after it completes; set in the main home after the branch-reuse root-cause report of 2026-09-19 measured 25 of 25 rotations failing this way.
  The live test does not set it: it scrubs every inherited `CLAUDE_CODE_*` variable instead, so its scratch session never carries the marker; the `session.start` event's `persistenceOn` / `persistenceCause` fields (see the event log below) show which case a home is in.
- `--plugin-dir <code root>/.claude/mods/fm-branch-mod`: the only load path.
- `promptSuggestionEnabled: false` in the launch settings (and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` in the environment): a prompt suggestion is a model call main would make between wakes, so it is switched off.
- The ordinary Claude Stop hook (`bin/fm-claude-stop-autoarm.sh` with `asyncRewake`), as the [Claude supervision protocol](supervision-protocols/claude.md) already requires; the rewake it delivers is what the mod routes.
- `--strict-mcp-config`, so only the mod's own `fm_branch_report` and `fm_branch_processed` tools reach the session beside Claude Code's built-ins.
- No `autoCompactWindow` setting: the branch's context bound lives in the mod.
- No `permissions.deny` entry for `SendMessage`, `Monitor`, or `Agent`.
  On 2.1.274 a `permissions.deny` list removes the named tools from the session for hook frames too: with `["SendMessage","Monitor","Agent","Task"]` denied, `$.agent.spawn` and `$.tool.call` from a hook frame throw `HooksError: <plugin>: $.tool.call: no tool named "Agent" in this session` (likewise `SendMessage` and `Monitor`), so a home running the mod cannot carry the Claude-only deny-list hardening that [`subagent-guard.md`](subagent-guard.md) suggests for primaries.
  The guard against the primary itself delegating is instead `bin/fm-subagent-pretool-check.sh`, which, only while `state/.branch-mod-mode` exists, allows exactly the mod's three calls (an `Agent` or `Task` of type `fm-branch-mod:fm-branch`, a `SendMessage` to `fm-branch`, `fm-branch-<n>`, or either with its `[ref]`, and a `Monitor` described `fm-branch-mod watcher continuity`) and keeps denying every other delegation-shaped call.
  `$.tool.call({tool: 'Task'})` is refused by the host itself (`tool.call: runs the Agent tool: that is $.agent.spawn (host check)`), so the mod never issues it.
- `FM_HOME` and `FM_ROOT_OVERRIDE` in the environment when the home is not the code root; the module resolves its home exactly as `bin/` does (`FM_HOME`, then `FM_ROOT_OVERRIDE`, then the code root three levels above the plugin folder) and honours `FM_STATE_OVERRIDE` and `FM_CONFIG_OVERRIDE`.

## Version pin

The module is measured against one Claude Code release and declares it as `CLAUDE_CODE_PIN` in `hooks/branch.ts` (currently `2.1.278`).
At `session.start` it reads the version of the binary hosting the session (`readlink /proc/$PPID/exe`, Linux only, with `claude --version` through PATH as the fallback where that is unavailable); on any other version it logs `pin.refused`, prints `fm-branch-mod: refusing to load on Claude Code <version> (<source>); built for <pin>`, and passes every hook through untouched for the rest of the session.
Both the `session.start` and the `pin.refused` event record `pinSource` (`running binary` or `PATH claude`) and the probe's raw `--version` output as `probe`, so a split between the running binary and PATH is one log line.
A refusal is a version fact, never a bug to work around: the function-hooks API may change between releases without notice, and the mod's behaviour is only known on the release the live test last passed on.
A home whose Claude Code is not the pin (the main home ran 2.1.271 when the pin was set) runs the unchanged Claude protocol until Claude Code is updated.

### Updating the pin

1. A new Claude Code release becomes known - a report from the home's own watched-tool or update-channel check, or the refusal line above naming a running version that is not the pin.
2. Install the new version in the home that will run the test, then run the live test against it: `FM_BRANCH_MOD_LIVE=1 bin/fm-test-run.sh tests/fm-branch-claude-mod-live-e2e.test.sh` with `CLAUDE_CODE_PIN` temporarily set to the new version.
   Run `claude plugin validate --strict .claude/mods/fm-branch-mod` and `tests/fm-branch-claude-mod-plugin.test.sh` on the same version.
3. When all three pass, land a pin-bump PR that changes `CLAUDE_CODE_PIN`, this page's measured version, and the dated record in [`verification/runtime-backends.md`](verification/runtime-backends.md); when one fails, the mod stays pinned and the failure is the finding.
   The plugin test suite imports its `PIN` from `hooks/branch.ts`, so `CLAUDE_CODE_PIN` is the only version value to change.

## State and configuration

`AGENTS.md` section 2 and [`configuration.md`](configuration.md) route each record to its owner; this is the list.

- `state/.branch-mod-mode`: the opt-in switch; its presence switches the mod, the drain backstop extension, and the pretool escape.
- `state/.branch-mod-passed`: the queue sequences passed to main and not yet acknowledged; module-owned.
- `state/.branch-mod-counters`: the session's counters (wake, spawn, send, generation, branch agent id, monitor task id) keyed by the lock pid, so a module reload re-adopts the live agent; module-owned.
- `state/.<task>.classifier-offset`: the status byte offset of the last classified bundle; owned by `bin/fm-wake-evidence.sh`, removed by teardown.
- `state/branch-mod-events.jsonl`: append-only event log, rotated to `.1` past 4 MB; the evidence source for every count the live test asserts.
  The `session.start` event carries `persistenceOn` and `persistenceCause` (`default`, `inherited CLAUDE_CODE_CHILD_SESSION marker`, or `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE`), and every `agent.send` event names the resume target as `agentId` and `sessionId` (the primary session's transcript id, or `unavailable (<error>)` where the engine does not expose it), so a transcript regression is one log line.
- `state/branch-mod-classifications.jsonl`: the classification log, same rotation; read by `bin/fm-branch-classifier-score.sh`.
- `config/classifier-model`: the model name `$.model.complete` is given; default, fallback, and the recorded model are owned by [configuration.md](configuration.md) "Claude Code supervision branch".
- `config/supervision-branch-model`: the branch agent's model (default `sonnet`), shared with Pi.
- The outcome store, cursors, and leases are the shared files listed under `AGENTS.md` section 2 for the Pi branch.

## Bounds

- Classifier: text-only, one call, no thinking, `maxTokens` 200.
- Branch rotation: 60,000 tokens of per-step request context.
- Provider-error latch: two consecutive failed branch turns, five-minute cooldown.
- Continuity monitor: one per session, 30-minute timeout, re-armed on its own expiry, on any captain prompt or Stop-hook-sourced wake that finds no live monitor, and from the branch's settlement.
- Event and classification logs: 4 MB each before rotation.
- Passed-wake dedupe: 90 seconds per row set; in-flight wake considered stale after 180 seconds.

## Verification

```sh
tests/fm-branch-claude-mod.test.sh
tests/fm-branch-mod-bin.test.sh
tests/fm-branch-eligibility.test.sh
tests/fm-branch-report-sequence.test.sh
tests/fm-branch-classifier.test.sh
tests/fm-branch-text.test.sh
tests/fm-branch-scope.test.sh
tests/fm-branch-routing.test.sh
tests/fm-branch-delivery.test.sh
tests/fm-branch-monitor.test.sh
tests/fm-branch-settlement.test.sh
tests/fm-branch-claude-mod-plugin.test.sh
FM_BRANCH_MOD_LIVE=1 tests/fm-branch-claude-mod-live-e2e.test.sh
```

The first eleven are portable (Node and bash; the eligibility test drives the mod's exported `bind` and `scopeForUnreadWake`, see [`pi-supervision-branch.md`](pi-supervision-branch.md) for the four-fold guarantee it pins, the report-sequence test drives the shared decision core and both latch policies through the mod's exported serving functions against one fixture transcript, the classifier test drives the shared classifier core through its tracked symlink and the mod's `classify` through `bind` on one fixture set, pinning the evidence argv, prompt, verdict rule, record shape, and cover argv byte-identical, and the six per-module suites drive the mod's binding modules directly through their per-call deps), the twelfth runs `claude plugin validate --strict` and the engine-hosted `claude plugin test` suite wherever `claude` is installed, and the live test submits a few Sonnet turns in a temporary scratch home and skips unless `claude --version` is exactly the pin and `tmux` exists; it also proves, across two labs, that a minutes-later wake resumes the persisted agent when transcript saving is on and rotates with `why=unresumable` when an inherited `CLAUDE_CODE_CHILD_SESSION` breaks resume.
The dated results live in [`verification/runtime-backends.md`](verification/runtime-backends.md#claude-code-supervision-branch).
