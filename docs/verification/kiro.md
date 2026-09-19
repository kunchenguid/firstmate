# Kiro CLI adapter verification

Maintainer-verification record for the `kiro` crewmate/scout adapter (V2 engine).
It records the active empirical facts the adapter depends on and the exact commands that establish them.
The live drift guard `tests/fm-kiro-signals-live-e2e.test.sh` (family `live-harness-optin`, control `FM_KIRO_SIGNALS_LIVE`) is what refreshes the vendor-controlled facts below; run it after every kiro upgrade.
It is opt-in and submits real prompts, so its runtime is unbounded and it is run deliberately rather than from a validation step.
The portable regression `tests/fm-kiro-harness.test.sh` is what CI enforces, and it does not cover the vendor-rendered surface, so a green suite is not evidence that these signals still work.

Scope: V2 engine only (`--agent-engine v2`). The v3/KAS engine is out of scope and was not exercised: it is unsupported on this Amazon Linux 2 host and its hooks are not yet at parity.

## Environment

- Date: 2026-09-13.
- Host: Amazon Linux 2 (Linux 5.10, x86_64).
- Tool: `kiro-cli 2.21.4`, installed via toolbox at `~/.toolbox/bin/kiro-cli` (a bash sandbox shim that runs `aim sandbox --client kiro-cli`, whose descendant is the compiled bun/node binary).
- Auth: a signed-in account. On this Amazon Linux 2 host auth state lives in the XDG data dir `~/.local/share/kiro-cli/data.sqlite3`, not under `KIRO_HOME`. That path does not exist on macOS, so both the location and the untouched-by-relocation premise resting on it are Amazon Linux 2 measurements only - see "What is NOT verified" for the macOS gap and what it costs.
- Three measurements in this record rest on a later build: the idle composer's placeholder colour (`38;2;158;158;158`) and its 256-colour encoding (`38;5;247`) were measured on `kiro-cli 2.21.5` on macOS, and the `--agent` name-collision precedence was measured on `kiro-cli 2.22.2-nightly.2` on macOS. Every other claim here was measured on 2.21.4 on the Amazon Linux 2 host above.

## Agent-config hooks are claude-shaped (V2)

`kiro-cli agent validate --path <file>` is strict: an unknown hook trigger or a wrong value type is rejected.

```
$ kiro-cli agent validate --path config-with-hooks-stop-and-userPromptSubmit.json   # exit 0 (accepted)
$ kiro-cli agent validate --path config-with-bogus-trigger.json
Error: Json ... did not match any variant of untagged enum Repr ...                  # rejected
```

So `hooks.userPromptSubmit` and `hooks.stop`, each an array of `{"command": "..."}`, are accepted V2 triggers.
Both fired per turn in a real run (non-interactive and interactive TUI), with bare `touch` hook commands and no stdout contract:

```
$ KIRO_HOME=<per-task> kiro-cli chat --agent-engine v2 --agent firstmate --trust-all-tools --no-interactive "say hi in one word"
Hi
# both the userPromptSubmit and stop hook marker files were created
```

`stop` does NOT fire on a manual Escape interrupt (the claude behaviour), and no StopFailure/SessionEnd equivalent was found among the accepted triggers.
Those bare commands carry no shell metacharacter, so this run establishes nothing about whether kiro shell-interprets a command string, and nothing needs it to: each hook `command` the spawn emits is a single-token absolute path to a generated script under `state/<id>.kiro-home/hooks/`, which runs the same whether kiro execs it directly or hands it to a shell.

## Out-of-tree config via KIRO_HOME; `--agent` is name-only

`--agent` takes a NAME resolved from the global `KIRO_HOME/agents/` dir plus the workspace `<cwd>/.kiro/agents/`; a path is rejected:

```
$ kiro-cli chat --agent-engine v2 --agent /abs/path/to/config.json --no-interactive "hi"
[warn] failed to set agent '/abs/path/to/config.json': Internal error   # falls back to default
```

`KIRO_HOME` relocates the global config root (agents + settings + sessions) but not auth, measured on the Amazon Linux 2 host above:

```
$ KIRO_HOME=/tmp/kh kiro-cli agent list
Global:    /tmp/kh/agents          # relocated
# /tmp/kh/{agents,settings} created; auth untouched, chat turns still authenticate
```

So the spawn writes `state/<id>.kiro-home/agents/firstmate.json` (the hook config) plus the two hook scripts it names under `state/<id>.kiro-home/hooks/`, and reaches them with `KIRO_HOME=state/<id>.kiro-home --agent firstmate`, never writing into the worktree's own `.kiro/`.

Because the name resolves from two directories, a target repository can define an agent of the same name, so the precedence between them decides which config a launch actually gets.
On a name collision THE WORKSPACE COPY WINS, measured 2026-09-17 on macOS against `kiro-cli 2.22.2-nightly.2`, which is a later build than the 2.21.4 Amazon Linux 2 host the rest of this record uses, so read this as a 2.22.2-nightly.2 measurement and not as covered by the AL2 run.
The setup was a scratch workspace holding `.kiro/agents/firstmate.json` (the WORKSPACE COPY, standing in for a target repo shipping its own firstmate agent) and a relocated `KIRO_HOME` whose `agents/firstmate.json` is the firstmate-owned config (the HOME COPY).

```
$ cd <scratch>/ws && KIRO_HOME=<scratch>/kirohome kiro-cli agent list
WARNING: Agent conflict for firstmate. Using workspace version.
Workspace: <scratch>/ws/.kiro/agents
Global: <scratch>/kirohome/agents
firstmate    Workspace    WORKSPACE COPY - a target repo shipping its own firstmate agent
```

The control run, same setup with the workspace copy removed, resolves to the relocated home instead:

```
firstmate    Global    HOME COPY - the firstmate-owned per-task config
```

A target repository that ships `.kiro/agents/firstmate.json` therefore shadows the firstmate-owned per-task config, and because that shadowing config carries no hooks, the busy record the spawn seeds is never closed by a turn-end and the supervisor reads that worker as provably working indefinitely.
kiro prints the conflict WARNING on the pane, which nothing in firstmate reads, so a pane-only warning is not a signal the fleet can act on.
The spawn therefore refuses instead, before any launch, when the resolved worktree holds that file, naming it and asking for it to be renamed or removed (`kiro_workspace_agent_validate` in `bin/fm-spawn.sh`, pinned by `tests/fm-kiro-harness.test.sh`).
That is the same rule the whitespace hook path takes: kiro has no second state source, so a pane that could never clear its busy record is never started, and the refusal reaches firstmate's own caller rather than the pane.
The refusal runs once the worktree is known and before the temp root, the retired relaunch wiring or the busy record exist, so it strands nothing.
Renaming the per-task agent to a name a repository cannot plausibly ship would remove the collision rather than refuse it, and is follow-up work: the JSON `name`, the filename, and `--agent` have to move together.

## Trust modal and its suppression setting

`--trust-all-tools` blocks on a modal on first use:

```
Warning: Kiro is running in trust all tools mode
❯ No, exit
  Yes, I accept
  Yes, and don't ask again
```

Selecting "Yes, and don't ask again" persists exactly:

```
$ cat $KIRO_HOME/settings/cli.json
{ "chat.disableTrustAllConfirmation": true }
```

Seeding that setting into the per-task `KIRO_HOME` suppresses the modal, and a positional brief then auto-submits with no extra Enter on a fresh worktree (verified: pane showed `• ready`, both hooks fired).

## Rendered surface (V2 TUI)

- Composer glyph: `›` (U+203A), the same glyph codex draws.
- Idle placeholder: `ask a question or describe a task` (followed by a `↵` hint), drawn in truecolor near-gray `38;2;158;158;158` at luminance 158. That clears the shared 128 ghost ceiling, so the near-achromatic ceiling in `fm_composer_strip_ghost` is what strips it back to the bare glyph on a styled capture; an unstyled one degrades to `unknown` through the bare-row rule.
- Busy footer: the composer row carries the agent glyph, then the harness-named phrase `Kiro is working`, then a separator glyph, then a mode hint of `Type to steer` and a `Ctrl+S to queue` toggle hint.
This record deliberately describes that row rather than spelling it, because any pattern that matches a live kiro pane also matches prose reproducing the same row, and a worker grepping or quoting this file would then put an acknowledgement token on its own pane.
The delivery guard matches the phrase plus whitespace plus the separator and nothing beyond it, not the bare phrase and not the bare `esc to cancel` token kiro also renders in its tool region and shares with agy.
It is never a recorded worker state, and its one consumer is the harness-less union in `FM_DELIVERY_BUSY_REGEX_DEFAULT` that the tmux submit core reads to acknowledge a submit.
The anchor is derived from kiro's own footer template, read out of the `kiro-cli-chat` binary on kiro-cli 2.22.2-nightly.2 on macOS, not from the 2026-09-13 live pass on 2.21.4 on Amazon Linux 2.
That template builds three variants - a spec-task run, STEER interrupt mode, and the default mode - which share only the phrase, whitespace, and the separator, so the mode hint is not required; requiring `Type to steer` would miss the default mode entirely.
The separator is a theme glyph with two values, U+00B7 and an ASCII period, and both are accepted.
A pane narrow enough to truncate the separator does not defer anything, because `fm_tmux_submit_core` types the text and sends Enter before it reads any acknowledgement.
The steer lands, the acknowledgement is then missed, `fm-send` exits nonzero as known-undelivered, and a retry delivers it a second time.
That is the deliberately chosen direction rather than an accident: a duplicate steer beats a silently lost one, which is what a false positive produces when it records an undelivered steer as delivered.
The outcome is not new to kiro either; `bin/fm-send.sh` records the same thing for agy, a steer that landed and ran but was reported exit-1 non-delivery and invited a duplicate resend, which is why agy carries a larger retry budget.
The portable regression cannot catch a real mismatch with vendor output, because its fixtures are built from the same separator byte the source spells, so a wrong separator passes CI green and only the live guard can redden.
kiro declares no per-harness signature of its own, because the union is the only delivery reader it can reach: away-mode injection reads the primary harness and the pending-reply observation reads a secondmate's harness, neither of which kiro can ever be.
A caller that passes `harness=kiro` anyway falls to `fm_busy_lines_match`'s fail-closed arm rather than borrowing another harness's footer, and the portable regression pins that.

## Control

- Interrupt: a single `Escape` prints `● Cancelled ...` and returns a clean idle composer with no repollution, so no clear key follows.
- Exit: `/quit` prints `Session ended.` then `Resume with: kiro-cli --resume-id <session-id>`.
- Resume: `--resume-id <id>` (id from the exit line) or `--resume` (most recent for the cwd); sessions live under the per-task `KIRO_HOME`. Firstmate automates only `relaunch` from the durable brief.

## Detection and liveness

- The live foreground process name is `kiro-cli` (`tmux #{pane_current_command}` and `ps -o comm=` both report `kiro-cli`; `aim sandbox` and the compiled binary run as descendants).
- No `KIRO_*` identity marker is exported to tool subprocesses, so detection is ancestry alone on the anchored name `kiro-cli`.

## Model and effort

- `kiro-cli chat --agent-engine v2 --list-models -f json` returns `{"models":[{"model_id":"<id>"},...],"default_model":"auto"}`; ids are bare (`auto`, `claude-opus-5`, ...). The spawn refuses a requested id a reachable listing omits, and launches unvalidated with a notice when the listing is unreachable, hung, or yields no `model_id` at all (a renamed field or an empty catalog establishes nothing about whether the model exists).
The listing is a remote fetch, so the probe runs with stdin detached under the shared hard bound from `bin/fm-timeout-lib.sh` (15 seconds by default, `FM_KIRO_MODELS_TIMEOUT`; a non-positive or non-numeric value clamps back to that default, because a non-positive bound is not a bound); a stalled fetch or a sign-in prompt is cut off and takes the unvalidated-launch notice instead of blocking the spawn before any pane exists.
- `--effort` accepts `low|medium|high|xhigh|max` (per `kiro-cli chat --help`), so the full shared vocabulary passes through.

## Live guard result

`FM_KIRO_SIGNALS_LIVE=1 tests/fm-kiro-signals-live-e2e.test.sh` passed on 2026-09-13 against kiro-cli 2.21.4: the busy footer matched in flight, the launch prompt was answered, both V2 hooks fired per turn, a single Escape cancelled a long turn, and `/quit` stopped the process and printed its resume-id line.
Six parts of the guard changed after that run, so its recorded pass is evidence for the vendor facts above and not for what the guard checks today.
Its footer matcher now folds the captured screen and calls the harness-less delivery union `fm_busy_lines_match` instead of a classifier helper the adapter no longer has, so every one of its footer reads exercises the path that actually decides a steer.
Its hook commands are now single-token absolute paths to generated scripts, the shape the spawn emits, where the recorded run used bare `touch` commands, so the trigger firing is what the markers now prove.
It now reads the live pane's foreground process group while the turn is in flight and fails unless some comm or argv[0] basename in that group is exactly `kiro-cli`, `fm_backend_agent_state tmux` reads `alive`, and `fm-harness.sh ancestry` returns `comm kiro` for one of that group's pids.
It deliberately does not assert `#{pane_current_command}`, which reports the launcher's name wherever kiro-cli sits behind a wrapper, and captures that field only as the `/quit` exit baseline, where the exit now requires a readable command that differs from the captured one instead of accepting any non-matching value.
It now submits a tool-call turn of its own and, once the idle placeholder is the last non-blank row a delivery read would consult, requires `fm_pane_is_busy` with no harness to read the pane as not busy, so the residual-row question below is asked of the delivery read itself.
The union literal its footer reads go through changed after that run too: the recorded pass matched the bare phrase, where the union now also requires whitespace and the separator, so that pass is not evidence the anchored form matches a live pane.
Re-running the guard on the Linux desk where the real tool lives is what would prove all six.

## Steering a kiro worker: fixed

A real idle kiro composer used to classify as `pending`, and `fm_task_inbox_ring` defers on an exact `pending`, so every steer was skipped and the watcher re-rang forever because the verdict never changed.
`fm_backend_composer_state` returning `pending` on a live idle pane was reproduced directly, and the cause is a colour threshold rather than anything kiro-specific.

kiro draws its idle placeholder in truecolor `38;2;158;158;158`, luminance 158.0, above the 128 `FM_COMPOSER_GHOST_LUMA_MAX` default, so `fm_composer_strip_ghost` left it in place and it read as real typed content.
rovo had the same defect from the same cause at luminance 162.9, recorded in `rovo.md`, so this was never a kiro-only problem.

The fix applies a higher ceiling only to NEAR-ACHROMATIC truecolor runs, `FM_COMPOSER_GHOST_GRAY_LUMA_MAX` (default 180) within a fixed channel spread of 12, and keeps 128 for anything more saturated.
The spread bound is a constant, not a knob: the four measured spreads below are 0, 3, 4 and 165, so every threshold from 5 to 164 classifies the whole measured fleet identically.
That separates all four measured cases without threading a harness argument through the shared composer entry points: kiro's ghost at spread 0 and rovo's at spread 3 strip, rovo's real typed text is also near-gray but separated by luminance at 207.0 and is kept, and muse's real prompt glyph at spread 165 is strongly chromatic and unreachable by any luminance ceiling.
`bin/fm-composer-lib.sh`'s ghost-strip comment owns the measured values and both margins.

The same ceiling covers the 256-colour encoding of the same grey, because the encoding follows the pane's terminal rather than the harness.
A kiro crewmate launched into a pane with no `COLORTERM` draws the placeholder as `38;5;247`, xterm grey level 158 - the identical colour - and while only truecolour was luminance-tested that pane's composer read `pending`, so every steer to that worker was skipped and the doorbell never rang.
A palette index is tested only when it falls in the 232-255 greyscale ramp, whose RGB is fixed by definition rather than by a theme.
Every other index is kept untested: a chromatic index carries no fixed grey to measure, indices 0-15 are remapped by every terminal theme, and the 6x6x6 cube's `r == g == b` diagonal is arithmetically grey but has not been measured carrying any harness's ghost text, so testing it would reintroduce the palette-dependence problem the carve-out exists for.

This gap was found because the carve-out was written down rather than left implicit.
Recording that a 38;5 palette index is never luminance-tested is what made it checkable, and driving a real crewmate on a pane without `COLORTERM` is what turned that limit from a footnote into a defect: the fix worked on every truecolor pane and left the original failure fully live everywhere else.
A limit stated plainly can be tested against reality; the same limit left unstated would have shipped as a passing suite over a live defect.
`tests/fm-composer-lib.test.sh` pins the palette greys alongside the truecolor cases, and `tests/fm-kiro-harness.test.sh` classifies kiro's idle row in both encodings, each reading `empty`.

Verified two ways.
`tests/fm-composer-lib.test.sh` pins the four cases and fails on pre-fix code, with rovo's real text and muse's glyph written as explicit non-regression assertions.
Classifying a capture of a live kiro idle pane with tmux's actual descriptor (`styled=1 cursor=1 identity=1 rows=0`) and the cursor on the composer row returns `empty` after the fix, where it returned `pending` before.

Two earlier claims in this record were wrong and are corrected here.
The verdict is portably reproducible from a real capture, so it never needed the live tool.
The descriptor tmux passes is `styled=1 cursor=1 identity=1 rows=0`, not `rows=6`; the earlier `empty` measurement used a descriptor tmux does not send and was therefore not evidence about the real pane.
Restoring the absent kiro entry to the fleet-wide idle-placeholder set still changes no verdict, which remains measured, so that omission stays correct.

Two of the guard's other assertions are weaker than the vendor surface its header names, and strengthening them is not attempted here.
Its resume-line check passes whether or not `--resume-id` appears, so a release that drops that line leaves the guard green.
It never asserts the `›` composer glyph, so a glyph change - which would flip every bare-row kiro composer read from `empty` to `unknown` and make steer delivery defer - would not redden it.

Four traps make that strengthening its own piece of work rather than a small edit, each observed in a rejected attempt at all three at once.
A leading-glyph test written with a shell `?` pattern compares one BYTE, so it rejects kiro's real composer row under any non-UTF-8 locale and reddens a correct tree; `fm_composer_leading_agent_glyph_var` in `../../bin/fm-composer-lib.sh` is locale-safe and already reaches the shared glyph set.
An assertion the live guard makes inline rather than through a shared predicate leaves the portable negatives proving a predicate no live assertion runs.
A portable negative whose command ends in `|| true` swallows both outcomes and asserts nothing.
A resume-line hard fail placed after the process is gone can redden on a healthy tool, because a full-screen TUI exit restores the normal screen and leaves no captured output to match - the sibling rovo guard reads a durable PTY transcript instead.

The same traps shape the post-tool-call union negative, which is why it is built the way it is.
It submits its own tool-call turn, because `esc to cancel` renders in the tool-call region and cannot be present at a settle point no tool call precedes.
It decides that the turn has settled by requiring the idle placeholder to be the LAST non-blank row of the folded tail rather than merely present in it, because the placeholder from the previous settle survives in the pane's history and sits inside the fold whenever the turn's own output is shorter than it.
For the same reason the condition does not also require the busy footer to be absent: the footer renders during the turn, strictly later than that stale placeholder, so any premise admitting the placeholder into the fold admits the footer too, and such an arm could hold for the whole polling budget against a healthy tool and fail before the assertion it exists to reach ever runs.
It first requires that row to appear mid-turn, matched through `FM_DELIVERY_AGY_BUSY_REGEX_DEFAULT` rather than a copy of the token, so a turn kiro answered without tools fails the assertion instead of satisfying it vacuously.
It then calls `fm_pane_is_busy` with no harness - the read `fm_tmux_submit_core` makes - rather than folding a capture itself, so it cannot pass against rows the delivery path would not consult.
Its failure names the folded delivery tail it read, alongside the harness and version every failure in the guard carries.

## What is NOT verified

- The v3/KAS engine (out of scope; unsupported on AL2, hooks not yet at parity).
- Where kiro carries auth on macOS, and so whether relocating `KIRO_HOME` leaves it intact there. The XDG path in Environment is an Amazon Linux 2 measurement; `~/.local/share/kiro-cli` does not exist on macOS, so the untouched-by-relocation premise the spawn launches on has no macOS evidence at all. It stays unestablished on purpose rather than by oversight: settling it means probing a credential store, and that store is the operator's alone and is not ours to inspect. The cost is concrete. A kiro worker spawned on macOS may hit an interactive auth prompt, and a prompt nobody is present to answer makes the harness unusable UNATTENDED on that platform - which is the only way this fleet runs it. Do not read the Amazon Linux 2 result as covering macOS.
- Any StopFailure/SessionEnd-equivalent hook trigger (none found). On an abnormal turn end (a stream or API error, a model-side abort) the `stop` hook never fires, so the busy record stays open and the supervisor reads the worker as provably working - deferring instead of surfacing or retiring the endpoint - until the next `userPromptSubmit` re-opens the record. The rendered footer does not rescue it: it is a delivery guard only and the classifier has no kiro pane arm.
- Whether kiro V2 hands a hook `command` string to a shell or splits it into argv. Nothing depends on it: both hook commands are single-token absolute paths to scripts the spawn generates under `state/<id>.kiro-home/hooks/`, so the same script runs either way, and the redirect, the `|| true` tolerance of a refused event and the turn-end `touch` all sit inside the script where the interpreter is fixed by its shebang. The portable regression executes each generated script directly rather than through `sh -c`, so a shape that only a shell could run cannot pass CI.
- Whether the union's anchored kiro literal matches a live kiro pane. The anchor is derived from the footer template in the `kiro-cli-chat` binary on kiro-cli 2.22.2-nightly.2 on macOS, so it rests on vendor source rather than on a rendered pane, and no live run has yet read a real footer through the union on the Linux desk. The portable regression cannot settle it either, because its fixtures assemble the same separator bytes the union's alternative accepts, so a separator that does not match vendor output passes CI green. If the literal is wrong the union never matches a live kiro pane and the submit core's post-Enter read stays idle, so every steer to a kiro worker lands and is then reported undelivered, and a retry duplicates it - which is why the anchor requires only what all three template variants share.
- Whether a settled kiro pane can carry a stale `esc to cancel` row that the harness-less union matches. This is still an inference from the token list and the delivery path rather than an observation: kiro renders that token in its tool-call region, agy's `esc[[:space:]]+to[[:space:]]+cancel` alternative is in `FM_DELIVERY_BUSY_REGEX_DEFAULT`, both submit-core reads pass no harness, and a busy read is what lets `fm_composer_queued_enter_verdict` convert a proven `pending` composer to `empty` - so a stale row surviving into the folded tail would let an undelivered steer be recorded as delivered. The assertion that now checks it is the post-tool-call union negative in `tests/fm-kiro-signals-live-e2e.test.sh`, described under "Live guard result" above; it submits a tool-call turn, requires the tool-region row to render, and then requires `fm_pane_is_busy` to read the settled pane as not busy. Running that guard on the Linux desk is what turns the inference into a measurement, and until then this stays here. If it does go red, the fix is not this adapter's: narrowing or harness-splitting `FM_DELIVERY_BUSY_REGEX_DEFAULT` changes agy's delivery semantics, so the remedy is a captain-level decision about the shared union.
- Primary or secondmate operation: no supervision protocol exists, and `bin/fm-spawn.sh` refuses a secondmate launch.
- Backends other than tmux for the rendered surface (the portable regression drives the signals apart with real processes; the live guard exercises tmux).
