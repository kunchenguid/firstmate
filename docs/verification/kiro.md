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
- Three measurements in this record rest on later builds: the idle composer's placeholder colour (`38;2;158;158;158`) and its 256-colour encoding (`38;5;247`) were measured on `kiro-cli 2.21.5` on macOS, and the default-foreground idle row with its `↵` hint was measured on `kiro-cli 2.28.0`. Every other claim here was measured on 2.21.4 on the Amazon Linux 2 host above.

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
- Idle placeholder: `ask a question or describe a task` (followed by a `↵` hint), drawn in truecolor near-gray `38;2;158;158;158` at luminance 158. That clears the shared 128 ghost ceiling, so the kiro-scoped near-achromatic ceiling in `fm_composer_strip_ghost` is what strips it back to the bare glyph on a styled capture. kiro-cli 2.28.0 draws the same row in the default foreground, which no stripper removes; the `↵` hint, which typed input never renders (verified live on 2.28.0), is what `FM_COMPOSER_HINTED_IDLE_RE_DEFAULT` matches, so that row and an unstyled capture read `empty` while the placeholder words typed as input read `pending`. A cursorless read stops the composer at that hinted row, so the `/copy to clipboard` footer below it is never taken for wrapped input.
- Busy footer: `› Kiro is working · Type to steer · Ctrl+S to queue`. The delivery guard matches the harness-named `Kiro is working` literal, not the bare `esc to cancel` token kiro also renders in its tool region and shares with agy. It is never a recorded worker state, and its one reachable consumer is the harness-less union in `FM_DELIVERY_BUSY_REGEX_DEFAULT` that the tmux submit core reads to acknowledge a submit.
`FM_DELIVERY_KIRO_BUSY_REGEX_DEFAULT` is registered per the fleet convention that every verified harness declares its own signature, and has no caller today: away-mode injection reads the primary harness and the pending-reply observation reads a secondmate's harness, neither of which kiro can ever be.

## Control

- Interrupt: a single `Escape` prints `● Cancelled ...` and returns a clean idle composer with no repollution, so no clear key follows.
- Exit: `/quit` prints `Session ended.` then `Resume with: kiro-cli --resume-id <session-id>`.
- Resume: `--resume-id <id>` (id from the exit line) or `--resume` (most recent for the cwd); sessions live under the per-task `KIRO_HOME`. Firstmate automates only `relaunch` from the durable brief.

## Detection and liveness

- The live foreground process name is `kiro-cli` (`tmux #{pane_current_command}` and `ps -o comm=` both report `kiro-cli`; `aim sandbox` and the compiled binary run as descendants).
- No `KIRO_*` identity marker is exported to tool subprocesses, so detection is ancestry alone on the anchored name `kiro-cli`.

## Model and effort

- `kiro-cli chat --agent-engine v2 --list-models -f json` returns `{"models":[{"model_id":"<id>"},...],"default_model":"auto"}`; ids are bare (`auto`, `claude-opus-5`, ...). The spawn refuses a requested id a reachable listing omits, and launches unvalidated with a notice when the listing is unreachable, hung, or yields no `model_id` at all (a renamed field or an empty catalog establishes nothing about whether the model exists).
- `--effort` accepts `low|medium|high|xhigh|max` (per `kiro-cli chat --help`), so the full shared vocabulary passes through.

## Live guard result

`FM_KIRO_SIGNALS_LIVE=1 tests/fm-kiro-signals-live-e2e.test.sh` passed on 2026-09-13 against kiro-cli 2.21.4: the busy footer matched in flight, the launch prompt was answered, both V2 hooks fired per turn, a single Escape cancelled a long turn, and `/quit` stopped the process and printed its resume-id line.
Four parts of the guard changed after that run, so its recorded pass is evidence for the vendor facts above and not for what the guard checks today.
Its footer matcher now folds the captured screen and calls the delivery guard `fm_busy_lines_match kiro` instead of a classifier helper the adapter no longer has.
Its hook commands are now single-token absolute paths to generated scripts, the shape the spawn emits, where the recorded run used bare `touch` commands, so the trigger firing is what the markers now prove.
It now reads the live pane's foreground process group while the turn is in flight and fails unless some comm or argv[0] basename in that group is exactly `kiro-cli`, `fm_backend_agent_state tmux` reads `alive`, and `fm-harness.sh ancestry` returns `comm kiro` for one of that group's pids.
It deliberately does not assert `#{pane_current_command}`, which reports the launcher's name wherever kiro-cli sits behind a wrapper, and captures that field only as the `/quit` exit baseline, where the exit now requires a readable command that differs from the captured one instead of accepting any non-matching value.
Re-running the guard on the Linux desk where the real tool lives is what would prove all four.

## Steering a kiro worker: fixed

A real idle kiro composer used to classify as `pending`, and `fm_task_inbox_ring` defers on an exact `pending`, so every steer was skipped and the watcher re-rang forever because the verdict never changed.
`fm_backend_composer_state` returning `pending` on a live idle pane was reproduced directly, and the cause is a colour threshold.

kiro draws its idle placeholder in truecolor `38;2;158;158;158`, luminance 158.0, above the 128 `FM_COMPOSER_GHOST_LUMA_MAX` default, so `fm_composer_strip_ghost` left it in place and it read as real typed content.

The fix applies a higher ceiling only to NEAR-ACHROMATIC truecolor runs, `FM_COMPOSER_GHOST_GRAY_LUMA_MAX` (default 180) within `FM_COMPOSER_GHOST_GRAY_SPREAD_MAX` (default 12) of channel spread, and keeps 128 for anything more saturated.
It applies only on a kiro pane: a caller that knows the target's recorded harness names it through `FM_COMPOSER_HARNESS`, and `fm_composer_kiro_scope` in `bin/fm-composer-lib.sh` turns on this ceiling, the palette-grey test below, and the hinted idle row only for `kiro`.
Every other harness, and a read with no harness named, keeps the shared rules unchanged, because the wider ceiling also strips Claude's typed slash command, which Claude draws in grey `38;2;112;112;112`, so a herdr exit proof judged a typed `/exit` unsent.
Inside the kiro scope, kiro's ghost at spread 0 strips, near-gray real text at luminance 207.0 is kept, and muse's chromatic prompt glyph at spread 165 is unreachable by any luminance ceiling.
`bin/fm-composer-lib.sh`'s ghost-strip comment owns the measured values.

On a kiro pane the same ceiling covers the 256-colour encoding of the same grey, because the encoding follows the pane's terminal rather than the harness.
A kiro crewmate launched into a pane with no `COLORTERM` draws the placeholder as `38;5;247`, xterm grey level 158 - the identical colour - and while only truecolour was luminance-tested that pane's composer read `pending`, so every steer to that worker was skipped and the doorbell never rang.
A palette index is tested only when it falls in the 232-255 greyscale ramp, whose RGB is fixed by definition rather than by a theme.
Every other index is kept untested: a chromatic index carries no fixed grey to measure, indices 0-15 are remapped by every terminal theme, and the 6x6x6 cube's `r == g == b` diagonal is arithmetically grey but has not been measured carrying any harness's ghost text, so testing it would reintroduce the palette-dependence problem the carve-out exists for.

This gap was found because the carve-out was written down rather than left implicit.
Recording that a 38;5 palette index is never luminance-tested is what made it checkable, and driving a real crewmate on a pane without `COLORTERM` is what turned that limit from a footnote into a defect: the fix worked on every truecolor pane and left the original failure fully live everywhere else.
A limit stated plainly can be tested against reality; the same limit left unstated would have shipped as a passing suite over a live defect.
`tests/fm-composer-lib.test.sh` pins the palette greys alongside the truecolor cases, and `tests/fm-kiro-harness.test.sh` classifies kiro's idle row in both encodings, each reading `empty`.

Verified two ways.
`tests/fm-composer-lib.test.sh` pins the kiro-scoped cases and fails on pre-fix code, with near-gray real text and muse's glyph written as explicit non-regression assertions, and proves that without the kiro scope the same grey runs and the hinted idle row are read exactly as before.
Classifying a capture of a live kiro idle pane with tmux's actual descriptor (`styled=1 cursor=1 identity=1 rows=0`) and the cursor on the composer row returns `empty` after the fix, where it returned `pending` before.

Two earlier claims in this record were wrong and are corrected here.
The verdict is portably reproducible from a real capture, so it never needed the live tool.
The descriptor tmux passes is `styled=1 cursor=1 identity=1 rows=0`, not `rows=6`; the earlier `empty` measurement used a descriptor tmux does not send and was therefore not evidence about the real pane.
Restoring the absent kiro entry to the fleet-wide idle-placeholder set still changes no verdict, which remains measured, so that omission stays correct; the hinted idle set above is what reads the 2.28.0 default-foreground row `empty`.

Three of the guard's other assertions are weaker than the vendor surface its header names, and strengthening them is not attempted here.
Its resume-line check passes whether or not `--resume-id` appears, so a release that drops that line leaves the guard green.
It never asserts the `›` composer glyph, so a glyph change - which would flip every bare-row kiro composer read from `empty` to `unknown` and make steer delivery defer - would not redden it.
Its settled-pane negative runs only against the harness-scoped signature, which has no production caller, so no recorded run proves a settled kiro pane fails the harness-less union that actually decides a steer.

Four traps make that strengthening its own piece of work rather than a small edit, each observed in a rejected attempt at all three at once.
A leading-glyph test written with a shell `?` pattern compares one BYTE, so it rejects kiro's real composer row under any non-UTF-8 locale and reddens a correct tree; `fm_composer_leading_agent_glyph_var` in `../../bin/fm-composer-lib.sh` is locale-safe and already reaches the shared glyph set.
An assertion the live guard makes inline rather than through a shared predicate leaves the portable negatives proving a predicate no live assertion runs.
A portable negative whose command ends in `|| true` swallows both outcomes and asserts nothing.
A resume-line hard fail placed after the process is gone can redden on a healthy tool, because a full-screen TUI exit restores the normal screen and leaves no captured output to match - the sibling rovo guard reads a durable PTY transcript instead.
A settled-pane union negative also has to run after a tool-call turn settles, because `esc to cancel` renders in the tool-call region and cannot be present at a settle point no tool call precedes.

## What is NOT verified

- The v3/KAS engine (out of scope; unsupported on AL2, hooks not yet at parity).
- Where kiro carries auth on macOS, and so whether relocating `KIRO_HOME` leaves it intact there. The XDG path in Environment is an Amazon Linux 2 measurement; `~/.local/share/kiro-cli` does not exist on macOS, so the untouched-by-relocation premise the spawn launches on has no macOS evidence at all. It stays unestablished on purpose rather than by oversight: settling it means probing a credential store, and that store is the operator's alone and is not ours to inspect. The cost is concrete. A kiro worker spawned on macOS may hit an interactive auth prompt, and a prompt nobody is present to answer makes the harness unusable UNATTENDED on that platform - which is the only way this fleet runs it. Do not read the Amazon Linux 2 result as covering macOS.
- Any StopFailure/SessionEnd-equivalent hook trigger (none found). On an abnormal turn end (a stream or API error, a model-side abort) the `stop` hook never fires, so the busy record stays open and the supervisor reads the worker as provably working - deferring instead of surfacing or retiring the endpoint - until the next `userPromptSubmit` re-opens the record. The rendered footer does not rescue it: it is a delivery guard only and the classifier has no kiro pane arm.
- Whether kiro V2 hands a hook `command` string to a shell or splits it into argv. Nothing depends on it: both hook commands are single-token absolute paths to scripts the spawn generates under `state/<id>.kiro-home/hooks/`, so the same script runs either way, and the redirect, the `|| true` tolerance of a refused event and the turn-end `touch` all sit inside the script where the interpreter is fixed by its shebang. The portable regression executes each generated script directly rather than through `sh -c`, so a shape that only a shell could run cannot pass CI.
- Whether a settled kiro pane can carry a stale `esc to cancel` row that the harness-less union matches. This is an inference from the token list and the delivery path, not an observation: kiro renders that token in its tool-call region, agy's `esc[[:space:]]+to[[:space:]]+cancel` alternative is in `FM_DELIVERY_BUSY_REGEX_DEFAULT`, both submit-core reads pass no harness, and a busy read is what lets `fm_composer_queued_enter_verdict` convert a proven `pending` composer to `empty` - so a stale row surviving into the folded tail would let an undelivered steer be recorded as delivered. No run has been observed doing this, and the guard's settled-pane negative runs against the harness-scoped signature rather than the union, so its recorded pass does not bear on it. Narrowing or harness-splitting the union would change agy's delivery semantics and is out of scope for this adapter.
- Primary or secondmate operation: no supervision protocol exists, and `bin/fm-spawn.sh` refuses a secondmate launch.
- Backends other than tmux for the rendered surface (the portable regression drives the signals apart with real processes; the live guard exercises tmux).
