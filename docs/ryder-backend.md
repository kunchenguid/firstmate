# Ryder runtime backend

Ryder is an experimental backend built on a persistent PTY session host.
It provides task sessions while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

What distinguishes it from every other backend is where the session lives.
tmux, herdr, zellij, and cmux each multiplex sessions inside one long-running process or app, so the endpoint exists only while that process does.
Ryder runs one small detached host per session, reparented to the init process with no controlling terminal, and the sessions directory on disk is the registry.
Quitting or crashing whatever created a session does not touch it, and there is no daemon whose registry can disagree with reality.

## Setup

Pick Ryder when you want task sessions that outlive the tool that started them, and you are willing to run an experimental backend.

Prerequisites:

- The `ryder` binary from the Ryder session host, on `PATH`, speaking protocol v1.
  This is the app-side prerequisite and is not part of Firstmate: build it from the session host's own repository with `cargo build --release` and put `target/release/ryder` on `PATH`.
  The adapter refuses any other protocol version loudly rather than guessing, because a host speaking a different protocol serves a different `$RYDER_HOME/vN` tree and cannot see this one's sessions at all.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

`RYDER_HOME` (default `~/.ryder`) relocates all session state.
Firstmate never sets it; a home that wants sessions elsewhere exports it for the session that runs Firstmate.

## Runtime detection

Ryder is selected explicitly, or by runtime auto-detection when Firstmate itself is running inside a Ryder session.
The marker is `RYDER_SESSION_ID`, which the host sets in every agent's environment.
An auto-detected Ryder spawn prints one stderr notice naming `config/backend` and `--backend tmux` as opt-outs.

Detection stays innermost-first, and `RYDER_SESSION_ID` is checked after `$TMUX` and `HERDR_ENV=1` and before cmux's markers.

`$TMUX` winning is unambiguous and verified from the host's source: Ryder strips an inherited `TMUX`/`TMUX_PANE` from the environment it builds for its agent, because those are outright false inside a Ryder pty and would misdirect any tmux command the agent ran.
So a `$TMUX` seen inside a Ryder session is always a real tmux started in it, and tmux is genuinely the innermost layer.

`HERDR_ENV=1` winning is a deliberate tie-break, not a proof.
Neither host strips the other's marker, so a Ryder session created from a herdr pane and a herdr pane started inside a Ryder session both end up with both markers set, and the environment alone cannot tell them apart.
Keeping herdr's existing verdict is the choice that changes no already-working home's detection.
A home in the other arrangement pins `config/backend` to `ryder`.

## Task shape and metadata

There is no container layer: no session, workspace, or tab to create, and `container_ensure` is a pure client version gate that stands nothing up.
One task is one Ryder session.

The endpoint target is the Ryder session id **alone**, with no colon and no composite parts.
Every other backend's target is a pair that must be split; a Ryder session id is already globally unique, and the host constrains it to `[A-Za-z0-9._@%+-]`, which is exactly Firstmate's own endpoint alphabet, so it is directly usable with no escaping.

The id is **derived, not assigned**: it is the home-scoped task label, `fm-<home-label>-<id>`, where the home label is the readable `FM_HOME` prefix plus a short hash of the resolved `FM_ROOT` path, shared with zellij and cmux.
`$RYDER_HOME` is one machine-global namespace, so that scoping is what stops two Firstmate homes with colliding task ids from addressing each other's sessions.

Because the target is a pure function of the task and the home, a recorded target cannot go stale, and confirming that a recorded endpoint belongs to a task needs no CLI call at all.
That is also why a `ryder` task records **no** backend-specific metadata fields.
herdr, zellij, and cmux each record component ids so cleanup can cross-check that a composite target is internally consistent; a Ryder target has no components, so the exact `endpoint_task_id=` binding plus the id alphabet is the complete identity check, and a second copy of the same id would add no safety.

The pty's agent is a **login shell**, not the harness, exactly as on tmux: Firstmate's shared spawn steps run `treehouse get` in the endpoint and then launch the harness inside the resulting worktree.
The harness name is still declared to the host as session metadata so the session is identifiable, but it is caller-declared and is never used as a liveness signal - that stays with kernel-read foreground process identity.

Sessions are created with a documented set of inherited harness markers removed (`CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `PI_CODING_AGENT`, `FM_PI_HARNESS`, `GROK_AGENT`).
The host deliberately strips only the markers it owns and documents harness-specific markers as the caller's policy.
Firstmate normally spawns a worker from inside an agent session, so without this every worker inherits its parent's child-process markers; the first of those was observed live to make Claude Code silently disable transcript saving in an unrelated agent.

## Agent liveness

The six-state vocabulary in `bin/fm-backend.sh` maps onto the host's own primitives, and only `dead` and `missing` license recovery.

| observation | state |
| --- | --- |
| `no_such_session` or `session_dead` | `missing` |
| any other CLI failure | `unreadable` |
| a reply whose `alive` cannot be read as a boolean | `unreadable` |
| `alive: false` | `dead` |
| a verified harness in the foreground process group | `alive` |
| only shells in the foreground | `dead` |
| anything else in the foreground | `ambiguous` |

`alive` is specifically about the agent, so `alive: false` is an exact answer rather than an inference: the host still answers during its post-exit linger window and reports the agent gone.
Because it is an exact answer, only an explicitly parsed boolean `false` counts as one: a call that succeeds but returns an unparseable body, an empty body, or a body carrying no `alive` at all stays `unreadable`, since `dead` licenses recovery and recovery means a duplicate agent on a live worktree.

**`ambiguous` is retained, correcting the design sketch.**
The sketch expected it to be droppable because the tmux adapter needs it only to reconcile two disagreeing process-name sources, and that disagreement genuinely is gone here - `fg_argv0` is read from the process's vnode and cannot be rewritten, so there is one authority.
What survives is a different case.
Firstmate runs the harness inside a login shell, so the foreground can legitimately be a third process that is neither the harness nor a shell: a build, a pager, a `git` subcommand.
That cannot be attributed either way, and calling it `dead` would license recovery against a live agent - which means spawning a duplicate agent onto a live worktree.
Withholding recovery costs a supervision cycle; a duplicate agent costs the worktree.

`busy_state` reports `busy` only on positive proof, when a process that is neither a harness nor a shell owns the terminal.
It never reports `idle`, because a harness at its prompt and a harness mid-turn are the same process in the same foreground group.
An earlier revision inferred busy from "the foreground group is not the agent's own pid", which a real Claude Code session disproved: since the harness is always a foreground child of the session's login shell, that held for the entire life of every task and reported `busy` forever.

## Capture and composer classification

`snapshot --lines N` is a genuine drop-in for `tmux capture-pane -p -S -N`: the reply is the whole viewport including trailing blank rows, plus up to N lines of scrollback above it.
The herdr and cmux adapters trim their captures to N lines to work around their own CLIs returning less than requested; Ryder has no such bug, and trimming here would silently hand callers less than the tmux path gives them, so the capture is passed through untrimmed.

Ryder is the only backend that offers both halves of the composer problem's ideal input, because the host owns the full terminal grid including cell attributes:

- an **ANSI snapshot** that preserves the harness's own de-emphasis styling, so the shared ghost stripper in `bin/fm-composer-lib.sh` can tell real typed text from a harness's placeholder;
- an **exact cursor position**, so the live input row is identified rather than guessed at from border glyphs.

herdr has the first and not the second, tmux has the second but not a session host's grid, and cmux and zellij have neither.
Both are used, in that order of authority: the cursor row when it carries a composer shape, since that is where typing lands, and otherwise the bottom-most structural match, which is herdr's proven approach.
With no match at all the verdict is `unknown`, and callers that can overwrite input require an exact `empty` before acting.

**The cursor offset is a real trap.**
`cursor_line` is viewport-relative, while the returned text may carry scrollback above the viewport, so the cursor's index in the text is `scrollback + cursor_line` - and `scrollback` must be read from the reply, which reports how much history was actually available rather than how much was asked for.
Getting this wrong silently classifies the wrong row as the composer.

## Verified facts

Run **2026-08-08** on macOS 27 (Darwin 27.0.0, aarch64) against `ryder 0.1.0 (protocol v1)`, built with `cargo build --release` from the session host at commit `96890c1`, with `jq 1.8.1`.
The tables below record what was checked; `tests/fm-backend-ryder.test.sh` is the reusable form of the same coverage and is what a version bump re-runs.

### Contract functions

| checked | result |
| --- | --- |
| `container_ensure` creates nothing | sessions directory still absent afterwards |
| `create_task` target | `fm-firstmate-6dbe2e9d-verify1`, equal to the derived id, endpoint-alphabet valid, no colon |
| duplicate live label | refused: `error: ryder session '...' already exists for 'fm-verify1'` |
| `current_command` | `zsh` (the session's login shell) |
| `current_path` **live-tracks** | `/private/tmp`, then `/usr/local` immediately after a `cd` in the session |
| `capture` | returns the marker; viewport including trailing blank rows, untrimmed |
| `send_literal` | text on screen, and its command output absent - it does not auto-submit |
| `send_key Enter` | submits it; `C-c` and `Escape` both accepted |
| `target_exists` | true for the live session; false for an absent one, a mismatched expected label, and a malformed target |
| `target_exists` is read-only | session count unchanged across every probe |
| `agent_state` | `dead` for a shell-only session, `missing` for an absent one, `unreadable` for a malformed target, `ambiguous` for an unattributable foreground (`sleep`) |
| `agent_state` after the agent exits | `dead` while the host lingers, `missing` once it retires |
| `busy_state` | `busy` while a foreground child runs, `unknown` at an idle prompt, `unknown` for an absent session |
| `list_live` | reports the task by derived id; a second home with a different `FM_ROOT` sees none of it |
| `kill` | refuses an empty, malformed, or label-mismatched target before invoking the CLI; kills the real session; best-effort on an already-gone one |
| id reuse after death | the same task id is re-creatable - the stale directory is archived first |

### Real harnesses

`agent_state` was `alive` and `current_command` named the harness for each, from `fg_argv0` read from the process's vnode.

| harness | composer shape | idle | text typed |
| --- | --- | --- | --- |
| Claude Code 2.1.224 | bare `❯` | `empty` | `pending` |
| codex-cli 0.146.0 | bare `›` plus dim ghost text | `empty` | `pending` |
| grok 0.2.118 | bordered, with a dark-truecolor border | `empty` | `pending` |

The style channel is what makes the idle verdicts correct rather than merely lucky.
An idle codex composer renders as plain text `› Write tests for @filename`, which a plain-text classifier reads as unsubmitted input; the ANSI row is `\x1b[0;1m›\x1b[0m \x1b[0;2mWrite tests for @filename\x1b[0m`, and stripping the dim run leaves `›`, which is empty.
grok's border glyph is a dark truecolor foreground that the same stripper drops, leaving its bare prompt.

End to end against Claude Code, `send_text_submit` returned `empty` - the proof-carrying verdict callers require - and the agent answered.
Against codex, an update-available interstitial was on screen at submit time and classified `pending`, which is the safe verdict; the Enter retry loop then drove through it and returned `empty` with the agent answering.

## Active limits

- **Pull-only.**
  The host sees every pty byte the instant it arrives and could push state transitions natively, which would let the watcher drop its poll loop for Ryder tasks entirely.
  That is a deliberate second pass: `fm_backend_has_push` is false, so the poll loop remains the backstop exactly as designed, and adding push later needs no call-site changes.
- **No muse glyph in the bare-composer vocabulary.**
  The bare shape recognizes Claude's `❯` and codex's `›` only, so a muse crewmate's bare `⟩` composer matches nothing.
  `composer_state` therefore returns `unknown` for it, and `send_text_submit` returns `unknown` rather than the proof-carrying `empty`: the submit is simply not confirmed, and is never silently treated as delivered.
  The glyph is deliberately omitted because muse could not be verified against a real session on this backend, and every entry in a safety-critical classifier here carries live evidence.
  The shared owner [`bin/fm-composer-lib.sh`](../bin/fm-composer-lib.sh) already lists `⟩`, so adding it here would be a vocabulary claim this backend has not earned; upstream's herdr adapter omits it from `FM_BACKEND_HERDR_BARE_PROMPT_RE` for the same practical reason.
  Closing this belongs with verified muse evidence across the adapters, not with this change.
- **No `--secondmate` spawns**, mirroring Orca and cmux.
  Secondmate launch semantics are not designed or verified for this backend, so a `--secondmate` spawn on `backend=ryder` refuses.
- **Socket path length.**
  Sockets live at `$RYDER_HOME/v1/sessions/<id>/sock` and are subject to the platform's ~104-byte `sun_path` limit, so a long `RYDER_HOME` plus a long derived id can exceed it.
  This fails loudly at create time rather than mysteriously at connect time - the host checks up front and refuses with a typed `usage` error naming the byte count.
  Budget roughly `len(RYDER_HOME) + len(id) + 20` bytes; the default `~/.ryder` leaves ample room for ordinary task ids.
- **Blast radius is one.**
  Killing a session's host hangs up that session's agent, because the kernel sends `SIGHUP` when the last descriptor on the pty master closes.
  It is one session, not the fleet, which is the point of the per-session process model, and the session's own log survives.
- **Archived, never deleted.**
  A killed or crashed session leaves its directory behind until the next sweep moves it to `archived/`.
  Teardown does not try to remove it: the log is exactly what a post-mortem needs.
- **macOS verified only.**
  The evidence above is from macOS.
  The host has a Linux path but nothing here has been exercised on it, and its pty layer's Windows support is untested.

## Regression entry points

- `bin/fm-test-run.sh tests/fm-backend-ryder.test.sh` - the adapter's own suite.
  Its structural half always runs; its real-host half runs whenever `ryder` is on `PATH` and skips cleanly otherwise, in a throwaway `RYDER_HOME` that never touches a real fleet.
- `bin/fm-test-run.sh --family ryder` - the same script by family.
- [`verification/runtime-backends.md`](verification/runtime-backends.md#ryder) owns the active empirical record and is what a version bump refreshes.
