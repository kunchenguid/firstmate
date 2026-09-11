# Anti-Gravity CLI harness verification

Audience: Firstmate maintainers.

Status: active verification record for the `agy` harness adapter.

First verified on 2026-07-30 with Anti-Gravity CLI 1.1.8 and re-verified on 2026-09-09 with 1.1.28 from the installed executable `/home/scott/.local/bin/agy`.
No Agy update, installation, OAuth edit, or edit under `~/.gemini` was performed in either pass.
Every interactive probe ran in a disposable git repository on a private tmux socket, inside a throwaway Firstmate home with its own treehouse pool.
Facts below carry the version they were last observed on; a 1.1.8-only fact was not re-driven on 1.1.28 and says so.

## Refresh procedure

The opt-in live guard is the runbook for this record and the command that refreshes it after any Agy upgrade:

```sh
FM_AGY_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-agy-live-e2e.test.sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

The first command needs a signed-in `agy` plus `tmux`, `jq`, `treehouse`, and `git`, spends five short turns on the cheapest listed Flash tier (`FM_AGY_LIVE_MODEL` overrides it), and finished in between one and four minutes across the 2026-09-09 runs.
It drives the real `bin/fm-spawn.sh`, `bin/fm-crew-state.sh`, `bin/fm-send.sh`, `bin/fm-control.sh`, and `bin/fm-teardown.sh` against the installed binary, has the worker run `bin/fm-harness.sh` from inside a real Agy tool call, re-drives the PreToolUse decision renderings recorded below, and prints every capture quoted below as `#` notes beside its `ok` lines.
The guard is the adapter's only live evidence; the refusals of foreign, mismatched, or malformed Stop payloads and the omission of unsupported effort levels have no live surface and are portable-suite facts (`tests/fm-agy-harness.test.sh`), reported as such rather than as live results.
The second command spends no tokens and refreshes the liveness row in [`runtime-backends.md`](runtime-backends.md).
Both fail naming the Agy version rather than skipping when the binary is installed and the guard is requested.
A spawn that aborts with `not proven empty after Enter` means the post-trust repaint window has grown past the settle defaults recorded under "Brief pointer delivery"; widen `FM_AGY_READY_STABLE_POLLS`, `FM_AGY_SUBMIT_SETTLE`, or `FM_AGY_SUBMIT_RETRIES` and record the new floor here.

## Version and command surface

```sh
agy --version
```

```text
1.1.28
```

`agy --help` on 1.1.28 advertised `--model`, `--effort`, `--dangerously-skip-permissions`, `--continue`, `--conversation`, `--prompt-interactive`, `--print`, `--output-format`, `--input-format stream-json`, `--print-timeout`, `--agent`, `--mode`, and `--sandbox`; the guard fails if any flag the adapter relies on disappears.

```sh
agy --effort xhigh --print 'Reply exactly probe'
```

The command exited 1 without a model call:

```text
error: invalid model selection (--model "" --effort "xhigh"): invalid --effort "xhigh" (valid: low, medium, high)
```

1.1.8 printed the same `valid: low, medium, high` clause without the `invalid model selection` wrapper; the accepted set is unchanged, so `bin/fm-spawn.sh` still omits `xhigh` and `max`.

`agy models` on 1.1.28 returned the following exact identifiers:

```text
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
```

Gemini 3.5 Flash, present in the 1.1.8 listing, is gone; Gemini 3.7 and 3.8 Flash are new.
Firstmate passes no default model.
A bare `agy --dangerously-skip-permissions` launch on this install rendered `Gemini 3.8 Flash · high` in its footer, so an omitted `--model` follows the account default rather than anything Firstmate chose.
A launch with `--model gemini-3.8-flash-low --effort low` rendered `Gemini 3.8 Flash · low` in every footer below.

## Persistent TUI selection

`--print --output-format stream-json` returns one headless result and exits, so that process cannot accept a later `fm-send` steer in the same live session.
A bare interactive launch reaches a persistent composer that accepted three later messages and executed tool calls in the 2026-09-09 run.
This end-to-end steer evidence selects the interactive TUI over headless or repeated-resume designs.

## Trust and first-prompt ordering

A bare launch in a fresh workspace on 1.1.28 rendered:

```text
Accessing workspace:
<path>
Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.
> Yes, I trust this folder
  No, exit
  ↑/↓ Navigate · enter Confirm
                                                             Gemini 3.8 Flash · high
```

The explanatory sentence and the navigation hint are new since 1.1.8.
`bin/fm-spawn.sh` matches only the question, the selected `> Yes, I trust this folder` row, and the `No, exit` row, and accepts with Enter; the live guard observed that dialog on the pool worktree and the spawn accepted it.

The hook-ordering evidence is from 1.1.8: the Agy log for a fresh `--prompt-interactive` launch showed zero hooks at startup and one hook only after trust acceptance, and the initial prompt turn did not invoke Stop while the next steer did.
A bare launch followed by trust acceptance loaded the hook before any turn.
`fm-spawn.sh` therefore launches Agy bare, handles only the exact verified trust surface, waits for the structural empty composer, then sends the absolute brief pointer.
On 1.1.28 that order produced a brief turn whose task Stop hook touched the turn-end marker, so the bare-launch design still delivers the first turn to a loaded hook.

## Detection from inside a session

The brief turn's tool call ran `bin/fm-harness.sh` and captured `ANTIGRAVITY_AGENT` from inside the live 1.1.28 session: the script printed `agy` and the tool child carried `ANTIGRAVITY_AGENT=1`, so the marker precedence in `bin/fm-harness.sh` and the `env -u ANTIGRAVITY_AGENT` clearing at every other adapter's launch boundary rest on a marker the current release still sets.
The parent TUI's exact `agy` process name is the drift guard's evidence in [`runtime-backends.md`](runtime-backends.md).

## Stop hook, coexisting roots, and continuation

The installed lifecycle documentation was re-inspected on 2026-09-09 at:

```text
/home/scott/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md
```

It documents the customization roots `.agents`, `.agent`, `_agents`, and `_agent`, the events `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, and `Stop`, no `SessionStart` event, and that multiple named hooks for one event are merged and executed sequentially.

The live guard's lab project commits a project-owned `.agents/hooks.json` and a hookless `.agent/keep.md`.
On 1.1.28 the spawn recorded the task hook root as `.agent` with owner `preexisting`, left `.agents/hooks.json` byte-identical, and the brief turn's single Stop fired both hooks: the project hook captured this payload while the task hook touched `state/<id>.turn-ended`.

```json
{"conversationId":"eda883c1-86bc-40c4-a1ac-abeeba4a25fa","error":"","executionNum":0,"fullyIdle":true,"modelName":"gemini-3.8-flash-low","terminationReason":"NO_TOOL_CALL","workspacePaths":["<task-worktree>"]}
```

`transcriptPath` and `artifactDirectoryPath` are elided; the shape is otherwise unchanged from 1.1.8.
The hook working directory was the customization root containing `hooks.json`.

The project hook answered execution zero with the same decision `bin/fm-turnend-guard-agy.sh` emits:

```json
{"decision":"continue","reason":"Reply exactly AGY_NATIVE_CONTINUE_DONE and stop."}
```

The same Agy process produced the requested follow-up, the next Stop payload carried `executionNum: 1` and the same conversation id, and returning `{}` allowed that Stop.
The guard asserts the exact `[0,1]` execution sequence in one conversation, which is the one-follow-up bound the primary adapter relies on.

The four-root coexistence probe (all four roots holding a Stop hook, one turn firing all four) and the non-discovery of `.agents/plugins/<name>/hooks.json` are 1.1.8 facts from 2026-07-30 that were not re-driven; the two-root merge above is the 1.1.28 evidence that roots still coexist.

The worker wake path uses a generated task-local hook, exact workspace binding, `.fm-agy-turnend` pointer, random token, and private state registry.
On 1.1.28 the payload's sole `workspacePaths` entry equalled the recorded task worktree, which is the binding the task hook enforces before touching the marker; `tests/fm-agy-harness.test.sh` covers the foreign-workspace, foreign-token, and malformed-payload refusals.

## PreToolUse

The decision transport was driven live on 1.1.28 on 2026-09-09, because the tracked primary seatbelts depend on it and the earlier record was 1.1.8 evidence.
Two turns in a trusted disposable workspace attempted the `run_command` calls below, against a `.agents/hooks.json` probe that answered each command line with a different rendering.
"Ran" means the sentinel file the command wrote existed afterwards.

| Hook stdout | Hook exit | Outcome | Rendered to the model |
| --- | --- | --- | --- |
| nothing | 0 | ran | nothing |
| `{}` | 0 | BLOCKED | `Error: tool call denied by pre-tool hook: ` |
| `{"decision":"allow"}` | 0 | ran | nothing |
| `{"decision":"deny","reason":R}` | 0 | BLOCKED | `Error: tool call denied by pre-tool hook: R` |
| `{"decision":"deny","reason":R}` | 2 | BLOCKED | `Error: JSON hook "..." failed: command failed: exit status 2, stderr: ...` |

Two facts follow, and both changed the adapter.

Agy reads the decision from the returned object and treats ANY nonzero exit as a failed hook rather than as a decision, so a deny must exit 0.
The exit-2 row still stopped the command, but as a hook failure whose reason reached the model only as a raw stderr dump, which is not a seatbelt that was seen working.

Agy reads a returned `{}` as a deny with an empty reason, so an ALLOWED command must return nothing at all.
The observed rendering for that row was the deny line above with an empty reason, and the sentinel stayed absent.
A seatbelt that answered every allowed command with `{}` would therefore have blocked every shell call in an Agy primary.

`bin/fm-arm-pretool-check.sh --agy` and `bin/fm-cd-pretool-check.sh --agy` render exactly that contract, and the tracked `.agents/hooks.json` selects it, discards the Claude-shaped stderr object, and exits 0 on every path.
The exact deny reason is unchanged from the 1.1.8 observation:

```json
{"decision":"deny","reason":"FIRSTMATE_AGY_PRETOOL_DENY"}
```

```text
Error: tool call denied by pre-tool hook: FIRSTMATE_AGY_PRETOOL_DENY
```

`tests/fm-agy-live-e2e.test.sh` re-drives every row except the explicit `{"decision":"allow"}` one, which no Firstmate seatbelt emits, and `tests/fm-agy-harness.test.sh` executes the tracked hook commands themselves so an allow that returns an object, a deny that exits nonzero, or a lost `--agy` fails in CI.

## Hook command anchoring

Every command in the tracked `.agents/hooks.json` resolves its checkout from `pwd -P` rather than a relative `../bin/` path, following the `.codex/hooks.json` precedent.
Agy sets the hook working directory to the customization root holding `hooks.json`, confirmed on 1.1.28 by the Stop probe above, so the parent of that directory is the checkout whose registration fired.
Each command therefore requires an executable script under that parent's `bin/`, an `AGENTS.md` beside it, and a `hooks.json` in the loaded root that still names the script it is about to run, and it stands down silently otherwise.
The seatbelt entries stand down by returning nothing, and the Stop entry by returning `{}`, because those are this release's allow renderings for their events.
`tests/fm-agy-harness.test.sh` runs the tracked command strings from a foreign root, an unregistered root, and a directory that is not a Firstmate checkout.

## Brief pointer delivery

Spawning a worker failed outright about one launch in five before the settle fix, and it failed loudly rather than silently:

```text
error: Agy brief pointer submission was not proven empty after Enter (unknown)
```

Two independent live evidence passes on 2026-09-09 hit it: 1 abort in 7 spawns in the first, then 2 hard failures in 11 real spawns in the second, which captured pane frames every 0.4s and identified the cause.
Agy repaints an incomplete composer for one to two seconds after the workspace-trust dialog is accepted.
`agy_wait_for_ready` released on the FIRST frame that classified as an empty composer, so a single good frame inside that repaint satisfied it; the pointer was then typed with no settle, and the post-Enter emptiness proof gave up after about 1.5 seconds.
The window and worktree were left behind for a manual relaunch, so nothing was corrupted.

Three changes in `bin/fm-spawn.sh` close it, all still environment-overridable:

| Knob | Was | Now | Why |
| --- | --- | --- | --- |
| `FM_AGY_READY_STABLE_POLLS` | (no such check) | 2 | the empty composer must hold across consecutive polls, so the repaint window cannot supply a ready verdict |
| `FM_AGY_SUBMIT_SETTLE` | 0 | 0.4 | the typed pointer settles before Enter |
| `FM_AGY_SUBMIT_RETRIES` | 3 | 6 | the post-Enter emptiness proof gets about 3s rather than about 1.5s |

`tests/fm-agy-harness.test.sh` drives the real `bin/fm-spawn.sh` against a frame script whose only isolated good frame sits inside the repaint, and asserts both directions: with the stability requirement the pointer is typed only after the verdict holds, and with it disabled the gate still releases inside the repaint window, so the guard cannot go vacuous.

## What stays portable, and why

Three behaviors are covered by the portable suite rather than the live guard, and the reason differs for each.

The re-ring deferral on a pending composer and the relaunch retirement-and-rearm path were portable-only until 2026-09-09 and are now driven live, because both rest on something the real binary renders or does.
Their portable regressions remain as the CI-side coverage the guideline requires.

Two failure-injection halves stay portable by necessity.
Proving that an interrupted spawn cannot leave armed wiring without a retirement record needs a write to `state/` to fail at a chosen instant inside a real launch, and proving that an away-mode escalation defers into a busy supervisor pane needs that pane to be mid-tool-call.
Neither instant can be hit reliably against a live model turn, so both are pinned deterministically instead.

The away-mode harness forwarding and non-leak behavior stays portable for a different and better reason: its only harness-dependent input is already proven live.
`bin/fm-harness.sh` returning `agy` from inside a real Agy tool call is driven in the guard's brief turn, and the forwarding decision layered on it is deterministic shell over environment variables with no rendered surface for a live drive to observe.
Adding a live stage there would re-prove the same detection through a longer path and report it as new evidence, which is why this record does not claim one.

Read those three as a floor rather than a backlog.
Each is portable for a stated reason rather than for want of effort, so adding further live stages cannot shrink the set to zero.
The three stages driven live on 2026-09-09 were still worth their cost, because each now proves against the real binary something this suite had only assumed.
What closing them did not do is change how validation reports the remainder: the no-mistakes test step rejected this branch on four separate runs for reporting a portable scenario as passing, naming a different scenario each time, so shrinking the portable set was never going to end that.
That gate reads its configuration from the default branch rather than from the branch under validation, so there is no setting on a feature branch that changes it either; [configuration.md](../configuration.md#gate-defaults-no-mistakesyaml) owns that boundary.

## Primary-side seatbelt: untested

The tracked `.agents/hooks.json` seatbelts have NOT been driven inside a live Agy PRIMARY, and this record does not claim they have.
Three attempts on 2026-09-09 stalled in `Generating...` for three to five minutes without ever reaching a tool call, and a hookless control lab on the same account stalled identically, so the stall is the account or the model rather than anything in this change.

What IS proven live is the transport those hooks depend on: the four PreToolUse renderings above were driven against the real binary from a WORKER session inside the e2e guard, which is what establishes that only silence allows and that a returned object blocks at either exit status.
That is the transport, not the primary-side wiring: no claim here rests on the seatbelt scripts having run in a primary.
The wrapper logic that sits between that transport and the seatbelt scripts is covered by the portable suite, which executes the tracked command strings themselves.
Re-drive this scenario when the account reaches tool calls again, and record the result here rather than inferring it.

## Busy footer, composer, and the feedback survey

The idle composer tail captured on 1.1.28 after the brief turn:

```text
────────────────────────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                Gemini 3.8 Flash · low
```

The busy tail captured while a steered `sleep 120` turn ran, with `bin/fm-crew-state.sh` reading `state: working · source: pane · harness busy (agy-regex)` at the same moment:

```text
────────────────────────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────────────────────────
esc to cancel                                                  Gemini 3.8 Flash · low
```

Both shapes are unchanged from 1.1.8 apart from the model label, so the shared separated-composer proof classified the idle pane `empty` and the bottom-row `esc to cancel` fallback classified the running turn busy.
Transient status rows (`Generating...`, `Loading...`, `Running...`) remain 1.1.8 observations.

A third composer shape was driven live on 2026-09-09 and is recorded here in prose because no pane transcript of it was kept.
While the composer holds an unsubmitted draft, Agy drops the `? for shortcuts` hint and leaves only the right-aligned model label on the footer row, with the typed text on the `>` row between the same two separators.
`tests/fm-agy-live-e2e.test.sh` proves it against the real binary: it types a draft, waits for the draft to render in full, and requires the classifier to read `pending`.
That shape is why the separated-composer proof accepts a bare model-label row as a footer at all, because requiring a hint read a real pending composer as `unknown`, and `unknown` is the verdict `fm_task_inbox_ring` types its doorbell into.
Every footer observed on 1.1.28 is the bottom-most nonblank row of its capture, so a bare label row claims the footer only in that position.

Agy 1.1.27 rendered a one-time feedback survey in place of the composer after a turn on 2026-09-08:

```text
 How's the CLI experience so far? Help us improve:
 [1] Good  [2] Fine  [3] Bad  [0] Skip
? for shortcuts                                                Gemini 3.6 Flash · low
```

While it shows, the busy footer is unaffected, the composer proof returns `unknown` because no separator pair is rendered, and a later `fm-send` steer still delivered because the send path's advisory composer check skips only on visibly pending text.
Neither 1.1.28 guard run on 2026-09-09 rendered it; the guard dismisses it with its own `0` (Skip) choice and notes that it appeared.

## Interrupt, exit, resume, and skills

Single Escape through `bin/fm-control.sh <id> interrupt` cancelled the running `sleep 120` turn on 1.1.28 and rendered:

```text
⎿  Interrupted · What should Antigravity CLI do instead?
```

The control plane reported `interrupt-delivered <id> harness=agy backend=tmux verified=agent-alive cancel=unconfirmed`, and the composer returned to `empty`.
When the tool had already started a shell child, Escape returned the agent to idle but the child continued until completion (1.1.8 observation, consistent with the leaked `sleep` teardown reaped on 1.1.28).

That banner is not reliable on 1.1.28 and must not be the only signal.
1.1.28 may run the same steered `sleep 120` through its own background task tracker, which the footer reports as `Gemini 3.8 Flash · low · 1 task(s) · /tasks` beside `esc to cancel`.
Two consecutive runs on 2026-09-09 both took that path and diverged on the rendering: one printed the banner above, the other printed no banner anywhere in the pane while Escape still returned the agent to idle and cleared the busy footer.
The live guard therefore reads the banner and the busy footer clearing as two independent signals and accepts either, after proving the same pane busy immediately before the interrupt.

`bin/fm-control.sh <id> exit` submitted `/exit`, reported `stopped <id> harness=agy backend=tmux`, and the pane printed:

```text
Resume with -c (or command below):
agy --conversation=eda883c1-86bc-40c4-a1ac-abeeba4a25fa
```

`agy --continue` and the printed `agy --conversation=<uuid>` command are the resume forms (`--continue` resumed the same conversation on 1.1.8; both flags remain in the 1.1.28 help).
Slash-skill invocation (`/agy-customizations`, first Enter selects, second Enter invokes) is a 1.1.8 observation not re-driven on 1.1.28.

## Steering and teardown

On 1.1.28 an `fm-send` steer produced the durable inbox record and doorbell, the worker listed the inbox, read the record, moved it into `handled/`, replied, and its Stop fired the task hook again.
`bin/fm-teardown.sh` then removed the task hook from the borrowed `.agent` root, the `.fm-agy-turnend` pointer, the private registry entry, and the state token, and left `.agent/keep.md` and the project-owned `.agents/hooks.json` byte-identical.
`tests/fm-agy-harness.test.sh` and `tests/fm-control-relaunch.test.sh` cover the created-root removal, the empty borrowed root, the project-authored replacement, and the replacement that retains the task token.

## Runtime backend inspection

Tmux uses the shared separated-composer classifier, the Agy-only `esc to cancel` busy fallback, and `agy` foreground process liveness.
The separated-composer classifier is harness-scoped through `FM_COMPOSER_HARNESS`, mirroring the busy-signature rule: `fm-send` and `fm-control` declare the target task's recorded harness resolved to its verified adapter family, `fm-spawn` declares every launch's harness only after the backend container exists so the value never becomes a tmux server's ambient environment, and the away-mode daemon always re-detects its own pane's harness instead of trusting an inherited value, so another harness's rule/quote/rule transcript tail is never claimed as an Agy composer.
Herdr prefers native agent state when available and otherwise uses the same harness-scoped busy fallback and separated-composer classifier.
Zellij did not get an Agy composer branch in this change, and capability is not the reason: its adapter captures with `dump-screen --ansi` and declares `styled=1` with `cursor=0`, so the only primitive it lacks is the cursor, which the separated-composer structure treats as optional.
Orca and cmux use the shared separated-composer classifier over their plain screen captures, and they declare `styled=0` with `cursor=0`, so they lack both primitives and were wired to it anyway.
Away-mode primary injection currently supports tmux and Herdr, so a separate Agy primary-injection path is not applicable to Zellij, Orca, or cmux.
No Herdr lifecycle command was run in either pass.

## Regression commands

```sh
FM_AGY_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-agy-live-e2e.test.sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
bin/fm-test-run.sh tests/fm-agy-harness.test.sh tests/fm-control-relaunch.test.sh tests/fm-control.test.sh
bin/fm-test-run.sh tests/fm-arm-pretool-check.test.sh tests/fm-cd-pretool-check.test.sh
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-supervision-instructions.test.sh tests/fm-composer-lib.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

The live guard's final lines on 2026-09-09:

```text
ok - agy 1.1.28: teardown retired only the task hook, pointer, and registry entry and left both project roots standing
ok - live Agy adapter guard: agy 1.1.28 drove spawn, hooks, steer, seatbelt decisions, busy, interrupt, exit, and teardown end to end
```

```text
FM_TEST_END 2026-09-09T14:07:48Z tests/fm-agy-live-e2e.test.sh exit=0 duration_ms=63939 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=64003
```

That run took the no-banner interrupt path recorded above, so the two-signal interrupt check is exercised rather than assumed.

The guard is not yet reliable on every run against this account.
One run on 2026-09-09 reached the busy stage and then found the recorded endpoint gone (`state: unknown - source: none - no current-state source available`) after a clean sixth Stop payload, with no Agy crash record; the run before it aborted at the interrupt banner.
Re-run rather than reading a single failure as adapter drift, and read the failure text before concluding which surface moved.

The drift guard on the same host classified `agy 1.1.28: title='agy' foreground=[agy ]` alive beside Claude, Codex, and Cursor.

The portable adapter regression completed with:

```text
FM_TEST_END 2026-09-09T11:55:46Z tests/fm-agy-harness.test.sh exit=0 duration_ms=30757 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=30847
```
