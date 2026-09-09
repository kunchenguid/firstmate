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

The first command needs a signed-in `agy` plus `tmux`, `jq`, `treehouse`, and `git`, spends four short turns on the cheapest listed Flash tier (`FM_AGY_LIVE_MODEL` overrides it), and finished in about three minutes on 2026-09-09.
It drives the real `bin/fm-spawn.sh`, `bin/fm-crew-state.sh`, `bin/fm-send.sh`, `bin/fm-control.sh`, and `bin/fm-teardown.sh` against the installed binary and prints every capture quoted below as `#` notes beside its `ok` lines.
The second command spends no tokens and refreshes the liveness row in [`runtime-backends.md`](runtime-backends.md).
Both fail naming the Agy version rather than skipping when the binary is installed and the guard is requested.

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

The `run_command` PreToolUse probe is 1.1.8 evidence from 2026-07-30 and was not re-driven on 1.1.28.
A live task-local hook received:

```json
{
  "toolCall": {
    "name": "run_command",
    "args": {
      "CommandLine": "printf forbidden > '<disposable-sentinel>'"
    }
  }
}
```

The hook returned:

```json
{"decision":"deny","reason":"FIRSTMATE_AGY_PRETOOL_DENY"}
```

Agy rendered `Tool call denied by pre-tool hook: FIRSTMATE_AGY_PRETOOL_DENY` and the sentinel stayed absent.
The 1.1.28 `hooks.md` still documents `deny` as a hard block with the same stdout object, and the 1.1.28 changelog names hook decisions only for the `ask` reason line, so the tracked primary arm and cd seatbelts keep that shape.

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
Zellij retains its existing screen-diff submission proof because it exposes no cursor or ANSI composer primitive.
Orca and cmux use the shared separated-composer classifier over their plain screen captures.
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

The live guard's final lines on 2026-09-09, run twice in a row:

```text
ok - agy 1.1.28: teardown retired only the task hook, pointer, and registry entry and left both project roots standing
ok - live Agy adapter guard: agy 1.1.28 drove spawn, hooks, steer, busy, interrupt, exit, and teardown end to end
```

The drift guard on the same host classified `agy 1.1.28: title='agy' foreground=[agy ]` alive beside Claude, Codex, and Cursor.

The portable adapter regression completed with:

```text
FM_TEST_END 2026-09-09T05:10:59Z tests/fm-agy-harness.test.sh exit=0 duration_ms=30576 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=30636
```
