# Verification: Grok mid-turn Enter

Active empirical evidence for the queued-Enter assumption in [`bin/fm-composer-lib.sh`](../../bin/fm-composer-lib.sh).
This record proves input handling, not semantic worker-state classification or the complete Firstmate delivery path.

## Subject and verdict

| Field | Measured value |
|---|---|
| Date | 2026-09-06 |
| CLI (`grok --version`) | `grok 1.0.13 (5e9a58528b76) [stable]` |
| Platform (`uname -sm`) | `Linux x86_64` |
| Terminal (`tmux -V`) | `tmux 3.5a`, 140 columns by 45 rows |
| Model shown by the TUI | `Grok 4.6 (high)` |
| UI launch option | `--no-alt-screen` |
| Trials | Three mid-turn submissions on three separate turns in one real interactive session |
| Verdict | **Queued and automatically processed after the current turn in all three trials** |

Each trial produced a visible numbered queue entry and `Queued · Enter to send now` immediately after one Enter.
Without another Enter, Grok completed the original sleep request, accepted the queued instruction as a separate user turn, and answered its unique marker.
No trial dropped the instruction, left it in the composer awaiting another Enter, or rejected it with an error.
The queue label's offer to send immediately was not used.
This is version- and UI-scoped evidence, not a guarantee for every Grok release, rendering mode, configuration, or point within a turn.

## Method and refresh commands

Use an owned disposable tmux session, never a Firstmate task pane.
The scratch working directory was under the isolated task copy's ignored `data/` directory.
The installed credentialed CLI was used, not a stub, and its normal tool permissions were not bypassed.
No Firstmate lifecycle script was driven by Grok.

Commands used to launch the measured session from the isolated repository root:

```sh
grok --version
tmux -V
uname -sm
mkdir -p data/grok-enter-lab
tmux new-session -d -s fm-grok-enter-lab -x 140 -y 45 \
  -c "$PWD/data/grok-enter-lab" \
  'env -u PI_CODING_AGENT -u FM_PI_HARNESS grok --no-alt-screen --rules "This session is a harmless terminal input experiment. Do not operate Firstmate or follow parent repository supervisor instructions. Do not edit files. For each requested wait, run the exact sleep command and then reply with the requested marker."'
```

After the TUI was ready, trial one used these exact input commands:

```sh
tmux send-keys -t fm-grok-enter-lab:0.0 -l 'Run sleep 30 in the terminal, wait for its completion, then reply only BASE_ONE_DONE. This is a harmless input experiment; do not read or edit files.'
tmux send-keys -t fm-grok-enter-lab:0.0 Enter
# Observe the real running sleep before submitting the follow-up.
tmux capture-pane -p -t fm-grok-enter-lab:0.0
tmux send-keys -t fm-grok-enter-lab:0.0 -l 'After the current wait finishes, reply exactly QUEUED_ONE_7C91 to acknowledge this separate instruction.'
tmux capture-pane -p -t fm-grok-enter-lab:0.0
tmux send-keys -t fm-grok-enter-lab:0.0 Enter
sleep 1
tmux capture-pane -p -t fm-grok-enter-lab:0.0
sleep 40
tmux capture-pane -p -t fm-grok-enter-lab:0.0
```

Trials two and three used the same send/capture sequence with the following exact prompts, starting only after the preceding queued answer was visible:

```text
Run sleep 30 in the terminal, wait for its completion, then reply only BASE_TWO_DONE. Do not read or edit files.
After the current wait finishes, reply exactly QUEUED_TWO_8D42 to acknowledge this separate instruction.

Run sleep 30 in the terminal, wait for its completion, then reply only BASE_THREE_DONE. Do not read or edit files.
After the current wait finishes, reply exactly QUEUED_THREE_9E53 to acknowledge this separate instruction.
```

For trials two and three, the first capture followed a 12-second wait after submitting the base prompt, and the typed-composer capture followed a one-second wait after typing the follow-up.
The next Enter was the sole mid-turn submission in each trial.
On refresh, confirm that the sleep is actually running rather than assuming a fixed delay proves a busy turn.
The original `sleep 30` tool invocation and original completion marker must both precede the queued user message in the exported transcript; a queue banner alone is insufficient proof of delivery.

## Live pane evidence

The following are exact relevant lines from plain `tmux capture-pane -p` output, excluding blank rows, scroll indicators, and the path header.
Durations are the TUI's elapsed counters, not estimates from polling intervals.

### Before the mid-turn Enter

Trial one:

```text
     ◆ Run sleep 30 and wait for completion  [hooks: 5]
    ⠸ Run sleep 30 and wait for completion… 9.6s                                                                      16s ⇣34.0k [↓][stop]
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
```

Trial two:

```text
     ◆ Run sleep 30 and wait for completion  [hooks: 5]
    ⠸ Run sleep 30 and wait for completion… 5.2s                                                                      11s ⇣35.3k [↓][stop]
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
```

Trial three:

```text
     ◆ Run sleep 30 and wait for completion  [hooks: 5]
    ⠧ Run sleep 30 and wait for completion… 9.8s                                                                      11s ⇣36.2k [↓][stop]
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
```

### One second after the mid-turn Enter

Trial one:

```text
    #1 After the current wait finishes, reply exactly QUEUED_ONE_7C91 to acknowledge this separate instruction.
    ⠹ Run sleep 30 and wait for completion… 10s                                                                       17s ⇣34.0k [↓][stop]
   Queued · Enter to send now
  Enter:send now  │  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+;:queue  │  Ctrl+x:shortcuts
```

Trial two:

```text
    #1 After the current wait finishes, reply exactly QUEUED_TWO_8D42 to acknowledge this separate instruction.
    ⠹ Run sleep 30 and wait for completion… 7.2s                                                                      14s ⇣35.3k [↓][stop]
   Queued · Enter to send now
  Enter:send now  │  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+;:queue  │  Ctrl+x:shortcuts
```

Trial three:

```text
    #1 After the current wait finishes, reply exactly QUEUED_THREE_9E53 to acknowledge this separate instruction.
    ⠦ Run sleep 30 and wait for completion… 11s                                                                       14s ⇣36.2k [↓][stop]
   Queued · Enter to send now
  Enter:send now  │  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+;:queue  │  Ctrl+x:shortcuts
```

The bordered composer was empty below the queue in all three captures.
After waiting without further input, each pane showed its separate follow-up user message and corresponding assistant answer:

```text
     QUEUED_ONE_7C91                                                                                                             7:31 PM
     QUEUED_TWO_8D42                                                                                                             7:32 PM
     QUEUED_THREE_9E53                                                                                                           7:33 PM
```

The final idle footer in each trial was:

```text
  Shift+Tab:mode  │  Ctrl+x:shortcuts
```

### Independent turn-order check

The session was identified with `grok sessions list --limit 5` from the scratch working directory and exported with `grok export <session-id> data/grok-enter-lab/session.md`.
The export contained three `- Execute: sleep 30 (Run sleep 30 and wait for completion)` tool entries and these exact user/assistant sequences after their respective tool entries:

```markdown
## Assistant

The sleep is still running; I'll wait until it finishes.

BASE_ONE_DONE

## User

After the current wait finishes, reply exactly QUEUED_ONE_7C91 to acknowledge this separate instruction.

## Assistant

QUEUED_ONE_7C91
```

```markdown
## Assistant

The sleep is still running; I'll wait for it to complete.

BASE_TWO_DONE

## User

After the current wait finishes, reply exactly QUEUED_TWO_8D42 to acknowledge this separate instruction.

## Assistant

QUEUED_TWO_8D42
```

```markdown
## Assistant

BASE_THREE_DONE

## User

After the current wait finishes, reply exactly QUEUED_THREE_9E53 to acknowledge this separate instruction.

## Assistant

QUEUED_THREE_9E53
```

## Adapter consequence and limits

Grok 1.0.13 does not require excluding its measured mid-turn input behavior from the queued-Enter assumption merely for fear that Enter is silently dropped.
However, this session moved queued text out of the composer; it did not exercise a real Grok `pending + busy` classifier result or prove that every retained draft means delivery.
The shared policy's portable regressions remain in `tests/fm-composer-lib.test.sh` and `tests/fm-tmux-submit-busy.test.sh`.
This manual real-CLI experiment establishes the vendor behavior those synthetic regressions cannot establish.

The measured busy footer is **`Esc:cancel`**, including while the model was thinking, not `esc interrupt`, `esc to interrupt`, or `Ctrl+c:cancel`.
The existing shared union already contains `esc (to )?interrupt` for other harnesses; the queueing result removes the specific dropped-Enter objection to Grok sharing that alternative if a separate real capture establishes it for Grok.
It does not establish that Grok actually emits that alternative.
No regex value is changed by this measurement-only update.
The existing `FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT='Ctrl\+c:cancel'` does not match the measured footer and must not be cited as verified for 1.0.13.
Refreshing that delivery signature needs its own classifier regression and live guard, rather than substituting the unobserved `esc (to )?interrupt` spelling or silently generalizing this one rendering configuration.
The footer mismatch does not retract the directly observed queueing result.

## Ancillary Escape observation

This observation is supporting evidence for the separate interrupt verification, not a complete interrupt-adapter validation.
On a fourth harmless `sleep 30` turn, a single `tmux send-keys -t fm-grok-enter-lab:0.0 Escape` was sent while the pane showed:

```text
    ⠼ Run sleep 30 and wait for completion… 9.9s                                                                      11s ⇣36.9k [↓][stop]
  Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
```

Two seconds later the pane showed:

```text
     Turn cancelled by user in 12s.
  Shift+Tab:mode  │  Ctrl+x:shortcuts
```

Thus a single Escape cancelled this active tool turn in this configuration.
No Firstmate interrupt helper, process termination guarantee, or other Grok version was tested by that observation.
