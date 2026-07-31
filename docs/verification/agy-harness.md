# Anti-Gravity CLI harness verification

Audience: Firstmate maintainers.

Status: active verification record for the `agy` harness adapter.

Verified on 2026-07-30 with the installed executable `/home/scott/.local/bin/agy`.
No Agy update, installation, OAuth edit, or non-disposable project mutation was performed.
All interactive probes ran in a disposable nested git repository and dedicated tmux server under the adapter task worktree.

## Version and command surface

```sh
/home/scott/.local/bin/agy --version
```

```text
1.1.8
```

`agy --help` advertised `--prompt-interactive`, `--print`, `--output-format stream-json`, `--dangerously-skip-permissions`, `--model`, `--effort`, `--conversation`, and `--continue`.

```sh
agy --effort xhigh --print 'Reply exactly probe'
agy --effort max --print 'Reply exactly probe'
```

Both commands exited 1.

```text
invalid --effort "xhigh" (valid: low, medium, high)
invalid --effort "max" (valid: low, medium, high)
```

`agy models` returned the following exact identifiers.

```text
gemini-3.6-flash-high
gemini-3.6-flash-medium
gemini-3.6-flash-low
gemini-3.5-flash-high
gemini-3.5-flash-medium
gemini-3.5-flash-low
gemini-3.1-pro-high
gemini-3.1-pro-low
claude-sonnet-4-6
claude-opus-4-6-thinking
gpt-oss-120b-medium
```

An interactive launch with `--model gemini-3.6-flash-low --effort low` rendered `Gemini 3.6 Flash (Low)` in the header.
An unattended shell tool call completed under `--dangerously-skip-permissions`.

## Persistent TUI selection

The initial smoke report established that `--print --output-format stream-json` can return one headless result.
That process exits after the result and therefore cannot accept a later `fm-send` steer in the same live session.
The report's readiness conclusion was not used for the persistent-worker decision.

A bare `agy --dangerously-skip-permissions --model gemini-3.6-flash-low --effort low` launch reached a persistent composer.
The same process accepted multiple later messages and executed tool calls.
This end-to-end steer evidence selects the interactive TUI over headless or repeated-resume designs.

The verified idle composer tail was:

```text
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                                                                       Gemini 3.6 Flash · low
```

Busy turns rendered the stable ASCII footer `esc to cancel`.
Transient status rows included `Generating...`, `Loading...`, and `Running...`.

## Trust and first-prompt ordering

A fresh workspace displayed:

```text
Accessing workspace: <path>
Do you trust the contents of this project?
> Yes, I trust this folder
  No, exit
```

Enter accepted the highlighted choice.

The Agy log for a fresh `--prompt-interactive` launch showed zero hooks at startup and one hook only after trust acceptance.
The initial prompt turn did not invoke Stop, while the next steer did.
This proves that launch-time prompt delivery races hook activation on a fresh path.

A bare launch followed by trust acceptance loaded the hook before any turn.
The first later steer invoked Stop.
`fm-spawn.sh` therefore launches Agy bare, handles only the exact verified trust surface, waits for the structural empty composer, and then sends the absolute brief pointer.

## Stop hook and continuation

The installed lifecycle documentation was inspected at:

```text
/home/scott/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md
```

The documented project customization roots are `.agents`, `.agent`, `_agents`, and `_agent`.
Live probes confirmed `.agents/hooks.json` and `.agent/hooks.json` discovery.
A project plugin under `.agents/plugins/<name>/hooks.json` was not discovered by Agy 1.1.8 and is not used.

A coexistence probe on 2026-07-30 placed a `hooks.json` with a distinct Stop hook in all four roots of one disposable workspace simultaneously.
A single turn fired all four Stop hooks.
Agy 1.1.8 therefore merges hooks from every coexisting customization root instead of loading only the highest-priority occupied root, matching Codex and Claude Code project hook coexistence.

A second probe on 2026-07-30 reproduced the recursive Firstmate-on-Firstmate layout: `.agents/hooks.json` stayed project-owned while the generated token-bound task hook lived in `.agent/hooks.json` beside occupied `_agents` and `_agent` roots.
One steer fired the project hooks and the task hook in the same Stop, and `bin/fm-agy-turnend-hook.sh` touched the registry-bound `*.turn-ended` marker end to end.
This verifies the spawn-time first-unoccupied-root fallback as load-bearing behavior, not an assumption.

A live Stop payload was:

```json
{
  "conversationId": "a43bd92d-225e-4601-9d6b-a994f8a63178",
  "error": "",
  "executionNum": 0,
  "fullyIdle": true,
  "modelName": "gemini-3.6-flash-low",
  "terminationReason": "NO_TOOL_CALL",
  "workspacePaths": [
    "/home/scott/.treehouse/firstmate-e218c2/1/firstmate/.agy-smoke-lab"
  ]
}
```

The hook working directory was the customization root containing `hooks.json`.

A Stop hook returned this result on execution zero:

```json
{"decision":"continue","reason":"Reply exactly AGY_NATIVE_CONTINUE_DONE."}
```

The same Agy process produced the requested follow-up.
The next Stop payload carried `executionNum: 1` and the same conversation id.
Returning `{}` allowed that Stop.
This verifies the one-follow-up bound used by `bin/fm-turnend-guard-agy.sh`.

The worker wake path uses a generated task-local hook, exact workspace binding, `.fm-agy-turnend` pointer, random token, and private state registry.
An Agy payload for the bound workspace touched the task marker.
The same token with a different `workspacePaths` value remained inert.

## PreToolUse

A live task-local `run_command` PreToolUse probe received:

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

Agy rendered `Tool call denied by pre-tool hook: FIRSTMATE_AGY_PRETOOL_DENY`.
The disposable sentinel remained absent.
This verifies the stdout deny shape used by the tracked primary arm and cd seatbelts.

## Interrupt, exit, resume, and skills

Single Escape cancelled an active Agy turn and rendered:

```text
Interrupted · What should Antigravity CLI do instead?
```

When the tool had already started `sleep 30`, Escape returned the agent to idle but the child process continued until completion.
Firstmate must not claim that Escape kills an already-running shell child.

`/exit` left the TUI cleanly and printed:

```text
Resume with -c (or command below):
agy --conversation=a43bd92d-225e-4601-9d6b-a994f8a63178
```

`agy --continue --dangerously-skip-permissions --model gemini-3.6-flash-low --effort low` resumed the same conversation.
The printed `--conversation=<uuid>` command is the exact-session alternative.

Typing `/agy-customizations` opened slash autocomplete.
The first Enter selected the command and the next Enter invoked the skill.
Firstmate uses the same `/<skill>` form for `/no-mistakes` and relies on Enter-only submission retries.

## Runtime backend inspection

Tmux uses the shared separated-composer classifier, the Agy-only `esc to cancel` busy fallback, and `agy` foreground process liveness.
The separated-composer classifier is harness-scoped through `FM_COMPOSER_HARNESS`, mirroring the busy-signature rule: `fm-send` sets it from the task meta, `fm-spawn`'s Agy path sets it directly, and the away-mode daemon derives it from its own harness ancestry, so another harness's rule/quote/rule transcript tail is never claimed as an Agy composer.
Herdr prefers native agent state when available and otherwise uses the same harness-scoped busy fallback and separated-composer classifier.
Zellij retains its existing screen-diff submission proof because it exposes no cursor or ANSI composer primitive.
Orca and cmux use the shared separated-composer classifier over their plain screen captures.
Away-mode primary injection currently supports tmux and Herdr, so a separate Agy primary-injection path is not applicable to Zellij, Orca, or cmux.
No Herdr lifecycle command was run because the adapter brief did not enable the guarded Herdr lab.

## Regression commands

### Baseline validation exceptions

#### Scheduler refill timing

The branch's first two `tests/fm-test-run.test.sh` runs failed the existing `jobs=2 must refill the first completed slot` timing assertion.
The initiating trigger was the scheduler starting the replacement fixture after the nominally fast fixture completed.
The masking condition was host CPU contention that consumed the test's 450 millisecond timing margin.
The visible symptom was the replacement fixture observing the slow fixture's `slow-done` marker before its first command ran.

The exact clean `HEAD` source was copied with `git archive HEAD`, initialized as an isolated repository inside the task worktree, and tested without any Agy branch changes.
Its first unloaded run passed:

```text
ok - jobs scheduler runs proven scripts; failure propagates; non-proven refused
FM_TEST_END ... exit=0 duration_ms=15203 gate_skip=false
```

The same unchanged baseline was then run once with six bounded `yes` workers on the three-CPU host.
The workers were children of the foreground diagnostic shell and were killed and waited by its cleanup trap.
That baseline run reproduced the exact branch failure:

```text
FM_TEST_BEGIN ... tests/fm-brief.test.sh ...
FM_TEST_BEGIN ... tests/fm-composer-lib.test.sh ...
ok - fast fixture
FM_TEST_END ... tests/fm-composer-lib.test.sh exit=0 duration_ms=925 gate_skip=false
FM_TEST_BEGIN ... tests/fm-lint.test.sh ...
ok - slow fixture
FM_TEST_END ... tests/fm-brief.test.sh exit=0 duration_ms=1260 gate_skip=false
not ok - scheduler waited for oldest worker
FM_TEST_END ... tests/fm-lint.test.sh exit=1 duration_ms=570 gate_skip=false
not ok - jobs=2 must refill the first completed slot
```

```sh
nproc
baseline_dir=$(mktemp -d "$PWD/.baseline-scheduler.XXXXXXXX")
git archive HEAD | tar -x -C "$baseline_dir"
git -C "$baseline_dir" init -q
git -C "$baseline_dir" add .
git -C "$baseline_dir" -c user.name=baseline -c user.email=baseline@example.invalid commit -qm baseline
load_pids=()
cleanup_load() {
  for load_pid in "${load_pids[@]}"; do
    kill "$load_pid" 2>/dev/null || true
  done
  for load_pid in "${load_pids[@]}"; do
    wait "$load_pid" 2>/dev/null || true
  done
}
trap cleanup_load EXIT INT TERM
for _ in 1 2 3 4 5 6; do
  yes >/dev/null &
  load_pids+=("$!")
done
"$baseline_dir/bin/fm-test-run.sh" "$baseline_dir/tests/fm-test-run.test.sh"
```

`git diff -U0 HEAD -- bin/fm-test-run.sh` showed only Agy family registration and changed-path mappings for `.agents/hooks.json` and `tests/fixtures/*`.
No scheduler control-flow line changed.
The baseline counterfactual therefore classifies this as a pre-existing load-sensitive assertion rather than an Agy adapter regression.
The remaining scoped tests are still required and are not waived by this exception.

#### Session-start tool masking

The branch and the clean isolated `HEAD` baseline both failed `tests/fm-session-start.test.sh` at the exact existing assertion `MISSING diagnostic did not appear at all`.
That fixture removes `$fakebin/node` but invokes session start with `$fakebin:$BASE_PATH`.
This host supplies Node through the appended base path, so bootstrap correctly emits no `MISSING: node` line.
The Agy change to this test only unsets `ANTIGRAVITY_AGENT` beside the existing harness markers and does not alter the fake toolchain or base path.

```text
ok - concurrent session-lock acquisition admits exactly one live harness
not ok - MISSING diagnostic did not appear at all
FM_TEST_END ... tests/fm-session-start.test.sh exit=1 duration_ms=120562 gate_skip=false
```

The exact clean-baseline command was:

```sh
"$baseline_dir/bin/fm-test-run.sh" "$baseline_dir/tests/fm-session-start.test.sh"
```

This is a pre-existing host-path-sensitive assertion and is unrelated to the Agy marker isolation change.

```sh
tests/fm-agy-harness.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-bootstrap.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

The final adapter regression completed with:

```text
FM_TEST_END ... tests/fm-agy-harness.test.sh exit=0 duration_ms=9243 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=9382
```

The affected backend, turn-end, and teardown matrix ran through the supported test owner:

```sh
bin/fm-test-run.sh \
  tests/fm-backend-herdr.test.sh \
  tests/fm-backend-orca.test.sh \
  tests/fm-backend-cmux.test.sh \
  tests/fm-backend.test.sh \
  tests/fm-turnend-guard.test.sh \
  tests/fm-teardown.test.sh \
  tests/fm-teardown-endpoint-safety.test.sh
```

```text
FM_TEST_SUMMARY total=7 failed=0 skipped_gate=0 duration_ms=132789
```

The remaining scoped groups used these exact commands:

```sh
bin/fm-test-run.sh tests/fm-arm-pretool-check.test.sh tests/fm-cd-pretool-check.test.sh
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-supervision-instructions.test.sh tests/fm-composer-ghost.test.sh tests/fm-composer-lib.test.sh
bin/fm-test-run.sh tests/fm-kimi-harness.test.sh tests/fm-secondmate-harness.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-session-start.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-tmux-submit-busy.test.sh
bin/fm-test-run.sh tests/fm-agy-harness.test.sh tests/fm-documentation-audiences.test.sh tests/fm-watch-triage.test.sh tests/fm-supervision-events.test.sh
```

The Kimi, secondmate, tmux, watcher, documentation, bootstrap, supervision, composer, arm, and cd regression scripts completed with exit zero.
`tests/fm-session-start.test.sh` is the documented clean-baseline exception.
No real Herdr lifecycle command was run.

The canonical lint owner and final changed-root lint both used the repository's pinned ShellCheck entry point:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

Both exited zero with no diagnostics.
The final documentation check returned:

```text
fm-doc-audience-check: ok surfaces=59 local_links=162
```
