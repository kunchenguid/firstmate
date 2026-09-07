# Verification: Grok interrupt key

Audience: maintainer verification.

This record preserves the live evidence gathered before deciding whether to change Firstmate's Grok interrupt key.

## Subject and verdict

| Field | Measured value |
| --- | --- |
| Date | 2026-09-07 |
| PATH winner | `/home/awilliam/.local/bin/grok` -> `/home/awilliam/.grok/downloads/grok-linux-x86_64` |
| PATH winner version | `grok 1.0.13 (5e9a58528b76) [stable]` |
| Other PATH candidate | `/home/awilliam/.nvm/versions/node/v24.19.0/bin/grok` -> `1.0.1` |
| Platform | Linux x86_64 |
| Terminal | tmux 3.5a |
| Model shown by the TUI | `Grok 4.6 (high)` |
| Launch flags | `--always-approve --no-alt-screen` |
| Escape trials | Three independent turns with a real foreground `sleep 30`, interrupted after 23, 27, and 30 seconds |
| Control trial | One independent real foreground `sleep 30` turn, interrupted after 27 seconds with `C-c` |
| Verdict | Escape visibly cancelled the TUI turn, but the evidence does not prove a clean production interrupt contract, so Firstmate retains `C-c` |

The PATH inventory was captured with `type -a grok`, `readlink -f`, and each candidate's `--version` output before the live trials.
The live session invoked the PATH winner through `exec grok`, which resolved to the 1.0.13 native executable shown above.
The `--no-alt-screen` flag was accepted by the installed CLI and made pane capture deterministic.

## Method and expected behavior

The earlier maintained premise came from Grok 0.2.73, where Escape focused scrollback and Firstmate sent `Ctrl+C`.
The expected behavior under test was that one key would cancel a genuinely active turn, stop its active work cleanly, leave the Grok process alive, and return an interactive composer that accepts a follow-up.
The initiating trigger was exactly one `tmux send-keys ... Escape` or `C-c` while the foreground `sleep 30` tool was still running.
The masking condition was the TUI's active-turn mode, identified by the `Esc:cancel` footer, rather than an idle composer or an approval dialog.
The visible symptom was `Turn cancelled by user in <seconds>.` followed by the normal composer footer.

The owned tmux launch used this production-shaped command from the isolated repository root:

```sh
cd "$PWD" && exec grok --always-approve --no-alt-screen "Use the bash tool to execute exactly the foreground command sleep 30. Do not respond or claim completion until the command has actually exited."
```

Each qualifying trial first verified a direct child command containing `sleep 30` and then waited until the pane's elapsed turn counter was at least 20 seconds before sending exactly one key.
The pane was captured immediately after the key and again after three seconds.

## Raw Escape observations

All three qualifying trials showed the active footer:

```text
Shift+Tab:mode  │  Esc:cancel  │  Ctrl+x:shortcuts
```

Trial one showed `Waiting for response... 23s ... [stop]` before one Escape and then:

```text
Turn cancelled by user in 23s.
Shift+Tab:mode  │  Ctrl+x:shortcuts
◎ 1 command still running
```

Trial two showed `Waiting for response... 27s ... [stop]` before one Escape and then:

```text
Turn cancelled by user in 27s.
Shift+Tab:mode  │  Ctrl+x:shortcuts
○ 1 command still running
```

Trial three showed `Thinking... 30s ... [stop]` before one Escape and then:

```text
Turn cancelled by user in 30s.
Shift+Tab:mode  │  Ctrl+x:shortcuts
○ 1 command still running
```

The three captures prove a visible TUI cancellation response, but they do not prove that Escape stops the already-running tool command.
The command child remained after the immediate and settled captures and later ended only after its requested sleep completed.
The Grok process itself remained alive, and a later follow-up produced `READY` in the same session.

An earlier Escape sent before the real tool had started restored the composed prompt without a cancellation line, which is additional mode sensitivity rather than qualifying interrupt evidence.

## Ctrl+C control

The control used the same launch, prompt, foreground `sleep 30`, active-mode check, and capture sequence.
The control pane showed `Thinking... 27s ... [stop]` and the same `Esc:cancel` footer before one `C-c`.
The immediate and settled captures showed:

```text
Turn cancelled by user in 27s.
Shift+Tab:mode  │  Ctrl+x:shortcuts
◎ 1 command still running
```

The control confirms that `C-c` reaches the same visible cancellation path, while the older maintained adapter evidence remains the reason Firstmate keeps `C-c` as the production key.
The current experiment does not establish that either key terminates an already-running child tool process, so it cannot safely promote Escape over the established path.

## History and disconfirming evidence

The old 0.2.73 adapter record was not treated as evidence about the installed 1.0.13 build.
The earlier 1.0.13 ancillary Escape observation was not treated as complete until these repeated active-turn captures and the `C-c` control were collected.
The separate queued-Enter experiment at `https://github.com/kunchenguid/firstmate/pull/3868` is not required for this result and is not causal evidence.
The captures also disconfirm the maintained Grok busy signature, which is a separate defect this interrupt-scoped verification records rather than fixes.
`FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT` is `Ctrl\+c:cancel` in `bin/fm-composer-lib.sh`, grepped by `fm_busy_grok_tail_busy` in `bin/fm-busy-lib.sh` for the `grok*` classifier arm.
That literal is absent from every 1.0.13 active footer captured above, so on this build the rendered-tail fallback prints `idle grok-regex` for a genuinely busy turn with no error, and the 1.0.13 idle bar is `Shift+Tab:mode │ Ctrl+x:shortcuts` rather than the recorded `Shift+Tab:mode │ Ctrl+.:shortcuts`.
Grok busy detection is therefore known stale on 1.0.13; widening or version-scoping the signature needs its own busy-scoped live verification and regression coverage, and this verification does not change the busy regex.

An Escape-is-safe conclusion would require repeated active-turn captures where one Escape cancels the turn and the active tool work also stops cleanly, the Grok process remains interactive, and a follow-up is accepted.
It would be falsified by any repeatable capture where Escape only changes scrollback focus, leaves the turn generating, leaves active work running, exits or wedges the Grok process, fails to restore an interactive composer, or prevents a follow-up.
The retained raw captures include the active-command result and therefore do not meet that stronger conclusion.

Firstmate consequently retains one `C-c` for Grok, and the harness guidance continues to carry the older version caveat.
The portable public-control regression remains `tests/fm-control.test.sh`, which verifies the key delivered by `bin/fm-control.sh` rather than asserting implementation source text.
