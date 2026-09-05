# Antigravity primary verification

## Workspace discovery boundary

Recorded 2026-09-05 with `/Users/cam/.local/bin/agy`, Antigravity CLI 1.1.27.
The reported shortcut launches this command from the Firstmate home:

```sh
agy --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions
```

The initiating trigger is launching without an added Firstmate home.
Antigravity uses `~/.gemini/antigravity-cli` as its workspace rather than adopting the shell's current directory.
The recorded hook log for this launch is:

```text
hooks_manager.go:53 loaded 0 named hooks from 0 hooks.json file(s)
```

Successful model access and unattended tool execution mask the missing Firstmate instruction and hook discovery.
The visible symptom is a conversational session that requires repeated manual wakes to attend fleet events.
The smallest launch counterfactual adds only `--add-dir "$PWD"` from the exact Firstmate home:

```sh
agy --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions --add-dir "$PWD"
```

The recorded discovery result is:

```text
loaded 3 named hooks from 1 hooks.json file(s)
```

The added home exposes `AGENTS.md`, `.agents/skills/`, and the tracked primary hooks.
The startup hook delivers the normal session-start reminder, whose rendered Antigravity protocol directs one foreground `bin/fm-watch.sh` terminal wait.
Pi instead has a tracked extension that owns background wake delivery; its background arm is not an Antigravity wake mechanism.

## Verification limits

The existing evidence establishes workspace and hook discovery, but does not include a retained full transcript proving repeated unattended fleet wake, handling, acknowledgement, and re-arm cycles on 1.1.27.
Discovery alone is not proof that a model follows the foreground protocol reliably.
If an added-home session still stops watching, investigate its terminal-call lifetime and handling of the rendered protocol before extending the fix.
A tracked hook cannot diagnose a launch that never discovers the tracked home; [README](../../README.md#install-and-launch) owns that launch requirement.
The CI repair did not modify the local shortcut or rerun a credentialed model session.

## Executable regression coverage

Run the portable hook transport and rendered-protocol checks:

```sh
tests/fm-antigravity-harness.test.sh
tests/fm-supervision-instructions.test.sh
```

These execute the detection, startup injection, native guard, and prompt-rendering interfaces.
They verify the emitted agent-facing contract, not model interpretation.
The startup check also requires an empty hook response in a no-mistakes gate.

The optional development-only real CLI guard checks added-workspace tools, instruction and skill discovery, and native hook payloads:

```sh
FM_TEST_ANTIGRAVITY_LIVE=1 \
FM_TEST_ANTIGRAVITY_MODEL=<gemini-model-id> \
tests/fm-antigravity-live-e2e.test.sh
```

It requires a signed-in CLI and an isolated Herdr lab, and does not establish long-running primary supervision continuity.
