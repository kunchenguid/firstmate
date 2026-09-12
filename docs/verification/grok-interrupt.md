# Verification: Grok interrupt key

Audience: maintainer verification.

This record preserves the live evidence gathered before deciding whether to change Firstmate's Grok interrupt key.

## Subject and verdict

| Field | Measured value |
| --- | --- |
| Date | 2026-09-07 |
| PATH winner | `~/.local/bin/grok` -> `~/.grok/downloads/grok-linux-x86_64` |
| PATH winner version | `grok 1.0.13 (5e9a58528b76) [stable]` |
| Other PATH candidate | `~/.nvm/versions/node/v24.19.0/bin/grok` -> `1.0.1` |
| Platform | Linux x86_64 |
| Terminal | tmux 3.5a |
| Model shown by the TUI | `Grok 4.6 (high)` |
| Launch flags | `--always-approve --no-alt-screen` for the first lot, then the production spawn shape `--always-approve` for the re-capture lot |
| Escape trials | Three independent `--no-alt-screen` turns with a real foreground `sleep 30`, interrupted after 23, 27, and 30 seconds; then four independent production-shape turns with a real foreground `sleep 60`, interrupted after 27, 27, 28, and 29 seconds |
| Control trials | One `--no-alt-screen` and one production-shape real foreground turn, interrupted with `C-c` after 27 and 28 seconds |
| Verdict | Escape visibly cancels the turn and preserves an interactive session under both shapes, but so does `C-c`, and neither key reliably stops the already-running tool child; Escape stopped it in two production-shape trials and left it running in another, and no `C-c` control was captured in the pane state where it died, so the two keys are untied on that axis rather than tied and Firstmate retains `C-c` as the established path |

The PATH inventory was captured with `type -a grok`, `readlink -f`, and each candidate's `--version` output before the live trials.
The live session invoked the PATH winner through `exec grok`, which resolved to the 1.0.13 native executable shown above.
The `--no-alt-screen` flag was accepted by the installed CLI and made pane capture deterministic.
Firstmate's own spawn shape in `bin/fm-spawn.sh` omits that flag, so the first lot differed from the fleet launch in exactly one flag, and identical `tmux send-keys` delivery would not have established identical handling: the 0.2.73 premise under revision is precisely that Escape focused the scrollback, and scrollback ownership is what the alternate screen changes hands over.
Both the Escape observations and the footer literals were therefore re-captured under the production launch shape, recorded below; the two shapes agree on the visible cancellation, on the absent `Ctrl+c:cancel` literal, and on the idle bar.
They are uncompared on the tool child rather than disagreeing, because the lots sampled different displayed pane states.
A live tool child existed in every qualifying trial of both lots; what differs is the pane's displayed active item at the moment the key was sent, which was the tool call itself in the production `escape-2`, `escape-3`, and `escape-4` trials and never in the `--no-alt-screen` lot.
Of those three, only `escape-2` and `escape-3` had their tool child read afterwards, and both killed it; `escape-4`'s child was not read.
Every trial sent in a displayed state the other lot also sampled matches across the shapes.

## Method and expected behavior

The earlier maintained premise came from Grok 0.2.73, where Escape focused scrollback and Firstmate sent `Ctrl+C`.
The expected behavior under test was that one key would cancel a genuinely active turn, stop its active work cleanly, leave the Grok process alive, and return an interactive composer that accepts a follow-up.
The initiating trigger was exactly one `tmux send-keys ... Escape` or `C-c` while the foreground `sleep 30` tool was still running.
The masking condition was the TUI's active-turn mode, identified by the `Esc:cancel` footer, rather than an idle composer or an approval dialog.
The visible symptom was `Turn cancelled by user in <seconds>.` followed by the normal composer footer.

The owned tmux launch used this command from the isolated repository root, production-shaped apart from `--no-alt-screen`:

```sh
cd "$PWD" && exec grok --always-approve --no-alt-screen "Use the bash tool to execute exactly the foreground command sleep 30. Do not respond or claim completion until the command has actually exited."
```

Each qualifying trial first verified a direct child command containing `sleep 30` and then waited until the pane's elapsed turn counter was at least 20 seconds before sending exactly one key.
The pane was captured immediately after the key and again after three seconds.

## Raw Escape observations (`--no-alt-screen` lot)

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

## Ctrl+C control (`--no-alt-screen` lot)

The control used the same launch, prompt, foreground `sleep 30`, active-mode check, and capture sequence.
The control pane showed `Thinking... 27s ... [stop]` and the same `Esc:cancel` footer before one `C-c`.
The immediate and settled captures showed:

```text
Turn cancelled by user in 27s.
Shift+Tab:mode  │  Ctrl+x:shortcuts
◎ 1 command still running
```

The control confirms that `C-c` reaches the same visible cancellation path.

## Production-shape re-capture

The re-capture lot used the launch Firstmate actually spawns, with no `--no-alt-screen`:

```sh
grok --always-approve "Use the bash tool to execute exactly the foreground command sleep 60. Do not respond or claim completion until the command has actually exited."
```

Each trial was qualified the same way before the single key was sent: an `Esc:cancel` footer, a live `sleep 60` child, and an elapsed turn counter of at least 20 seconds; the pane was captured immediately and again after three seconds.

| Trial | Key | Pane state when the key was sent | Immediate effect | Grok process | Tool child after 3s |
| --- | --- | --- | --- | --- | --- |
| escape-1 | `Escape` | `Thinking... 0.7s`, 28s elapsed, `sleep 60` live | `Cancelling...` then the idle bar, `Turn cancelled by user in 28s.` | alive | still running |
| escape-2 | `Escape` | `Run sleep 60 in the foreground... 12s`, 27s elapsed | `Cancelling...` then the idle bar | alive | gone |
| escape-3 | `Escape` | `Foreground sleep for 60 seconds... 13s`, 27s elapsed | the idle bar | alive | gone |
| escape-4 | `Escape` | `Foreground sleep for 60 seconds... 0.6s`, 29s elapsed | `Turn cancelled by user in 29s.` | alive | not read; a follow-up in the same session answered `READY` |
| control | `C-c` | `Thinking... 0.1s`, 28s elapsed, `sleep 60` live | the idle bar and `◎ 1 command still running` | alive | still running |

Two active footers appeared under the production shape, the second only while the running tool was backgroundable:

```text
Shift+Tab:mode  │  Esc:cancel  │  Ctrl+x:shortcuts
Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
```

The idle bar was `Shift+Tab:mode  │  Ctrl+x:shortcuts`, matching the first lot.
So the production shape reproduces the `--no-alt-screen` result rather than contradicting it: one Escape cancels a genuinely in-flight turn and leaves an interactive session that accepts a follow-up.
Neither key reliably stops already-running tool work. `escape-1` and the `C-c` control both left the `sleep 60` child running behind the same `1 command still running` residue, while `escape-2` and `escape-3` were followed three seconds later by a gone child that a 12-13s-old `sleep 60` cannot have exited on its own, so Escape did stop the child in those two trials.
The two keys were not compared in that state: `escape-1` and both `C-c` controls were sent while the pane read `Thinking...`, and no `C-c` control was ever captured with the tool call as the pane's displayed active item, the state `escape-2`, `escape-3`, and `escape-4` were sent in. Tool-child termination is therefore untied between the keys rather than matched, and the remaining axes measured for both keys - visible cancellation, surviving Grok process, restored interactive composer - are the same, with an accepted follow-up recorded only after Escape and never after a `C-c` control, so no discriminator favours switching keys.

## History and disconfirming evidence

The old 0.2.73 adapter record was not treated as evidence about the installed 1.0.13 build.
The earlier 1.0.13 ancillary Escape observation was not treated as complete until these repeated active-turn captures and the `C-c` control were collected.
The separate queued-Enter experiment at `https://github.com/kunchenguid/firstmate/pull/3868` is not required for this result and is not causal evidence.
The captures also disconfirm the maintained Grok busy signature, which is a separate defect this interrupt-scoped verification records rather than fixes.
`FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT` is `Ctrl\+c:cancel` in `bin/fm-composer-lib.sh`, grepped by `fm_busy_grok_tail_busy` in `bin/fm-busy-lib.sh` for the `grok*` classifier arm.
That literal is absent from every 1.0.13 active footer captured above under either launch shape, so on this build the rendered-tail fallback prints `idle grok-regex` for a genuinely busy turn with no error on every backend, and the 1.0.13 idle bar is `Shift+Tab:mode │ Ctrl+x:shortcuts` rather than the `Shift+Tab:mode │ Ctrl+.:shortcuts` form the 0.2.73-era signature description carried.
The same variable is also the delivery guard `fm_busy_lines_match` in `bin/fm-composer-lib.sh`, selected only when a caller passes `grok`, which reaches two further paths.
`pane_is_busy` in `bin/fm-supervise-daemon.sh` takes its harness from `fm_daemon_primary_harness` and, per its own contract, reads only the supervisor pane during away-mode injection, so the hazard there is a grok 1.0.13 PRIMARY pane read as not-busy and injected mid-turn, not a recorded worker task.
`fm_pending_reply_backend_observation` in `bin/fm-pending-reply-lib.sh` is called with the recorded harness, so a busy grok secondmate yields `fallback-idle`, which becomes `idle` after its grace window, stamps the turn completed, and lets `fm_pending_reply_send_recovery` resend into a still-running turn.
The crewmate consequence runs through the classifier instead: `stale_window_is_busy` reads a working grok task as not-working and raises a false `stale persisted ... (possible wedge)` escalation rather than injecting anything.
Herdr hosting does not exempt a grok task: the native short-circuits in `fm_busy_classify` and `pane_is_busy` fire only on a native `busy` verdict, which `fm_backend_herdr_classify_agent_status` returns only for `working`, so a long foreground tool call - the state these captures were taken in - reads native idle and falls through to the same stale grep.
The tmux and herdr submit readers never select the grok literal because their call sites pass no harness, but the `FM_DELIVERY_BUSY_REGEX_DEFAULT` union they fall back to matches none of the captured 1.0.13 rows either, so grok submit acknowledgement is equally stale on this build.
Grok busy detection is therefore known stale on 1.0.13; widening or version-scoping the signature needs its own busy-scoped live verification and regression coverage, and this verification does not change the busy regex.

An Escape-is-safe conclusion would require repeated active-turn captures under the production launch shape where one Escape cancels the turn and the active tool work also stops cleanly, the Grok process remains interactive, and a follow-up is accepted.
It would be falsified by any repeatable capture where Escape only changes scrollback focus, leaves the turn generating, leaves active work running, exits or wedges the Grok process, fails to restore an interactive composer, or prevents a follow-up.
The production-shape lot meets every clause except the active work one: `escape-1` falsifies it and `escape-2` and `escape-3` satisfy it, so Escape's effect on running tool work is state-dependent and not established as clean.
The incumbent key is not shown to be worse either: the one `C-c` control also left the child running, and it was never sent with the tool call as the pane's displayed active item, the state where Escape stopped it, so the comparison on that axis is missing rather than decided.

Firstmate consequently retains one `C-c` for Grok, and the harness guidance records that 1.0.13 also cancels on Escape without giving a reason to switch.
The portable public-control regression remains `tests/fm-control.test.sh`, which verifies the key delivered by `bin/fm-control.sh` rather than asserting implementation source text.
