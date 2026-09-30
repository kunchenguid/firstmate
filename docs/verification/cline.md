# Verification: the cline (Cline CLI) crewmate/scout adapter

Active empirical facts for firstmate's cline adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/cline.md`](../../.agents/skills/harness-adapters/references/harness/cline.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `cline 3.0.62` (core `0.0.83`) |
| Verified | 2026-09-16 |
| Binary | `cline` on `PATH` via `/home/azureuser/.npm-global/bin/cline`; the live agent is `/home/azureuser/.npm-global/lib/node_modules/cline/bin/.cline` |
| Platform | Linux x64 (Ubuntu, kernel 6.14.0) |
| Backend | tmux 3.4 (portable evidence below). The Herdr path is exercised by the live guard named at the end of this record. |

Every command below ran in a disposable directory with no firstmate fleet state in view.
Model calls ran on the captain's authenticated ClinePass subscription; the token cost was a handful of one-shot replies.

## Detection: ancestry only, no marker

```
$ cline --version
3.0.62
```

A live TUI carries no cline-identity environment variable, so no marker is promoted.
The long-lived agent process is a native binary named `.cline`:

```
$ ps -eo pid,ppid,comm,args | grep -i '[c]line'
1563856 1563614 node    node /home/azureuser/.npm-global/bin/cline -P cline-pass -m cline-pass/deepseek-v4-flash -i
1563864 1563856 .cline  /home/azureuser/.npm-global/lib/node_modules/cline/bin/.cline -P cline-pass -m cline-pass/deepseek-v4-flash -i
```

`bin/fm-harness.sh` therefore matches the anchored process name `.cline`, with a node-wrapper backup on the anchored script-path fragments `/bin/cline` and `@cline/cli`.
`tests/fm-cline-harness.test.sh` pins the anchored match and the rejection of unrelated names containing the fragment.

## Credential precondition

```
$ jq -r '.lastUsedProvider' ~/.cline/data/settings/providers.json
clinepass
$ jq -r '.providers | keys[]' ~/.cline/data/settings/providers.json
cline
cline-pass
```

ClinePass was signed in through OAuth; `cli-pass` is stored with access and refresh tokens.
Successful runs below prove the credential, so no key export was required.

## Prompt and model shape

```
$ cline --json -P cline-pass -m cline-pass/deepseek-v4-flash "Reply with exactly: READY"
... "text":"READY" ... "model":{"id":"cline-pass/deepseek-v4-flash","provider":"cline-pass", ...}
```

The provider id is `cline-pass` (not `clinepass`), and `--model` takes the full `<provider>/<model>` id.
`-m cline-pass/deepseek-v4-flash` alone (no `-P`) also resolves, because cline derives the provider from the prefix:

```
$ cline --json -m cline-pass/deepseek-v4-flash "Reply exactly: NOFLAG"
... "text":"NOFLAG" ...
```

`--thinking low` was accepted on the same binary.
A bare-model value is refused by cline itself with `invalid model format. Expected format: modelType/model`, which is why `bin/fm-spawn.sh` passes the profile model through unchanged.

## TUI launch and turn lifecycle

Launched in a tmux pane:

```
$ cline -P cline-pass -m cline-pass/deepseek-v4-flash -i "Reply with exactly POSOK"
```

The positional prompt auto-submitted and the reply `* POSOK` rendered, so `-i "<prompt>"` does submit when no first-run splash is showing.

The workspace `.cline/hooks` directory was then populated with executable `TaskStart`, `TaskComplete`, `TaskCancel`, `TaskError`, `SessionShutdown`, and `UserPromptSubmit` files named for cline's config-file hook events, and the TUI was restarted.
On a clean turn the hook log showed:

```
TaskStart
TaskComplete
```

`TaskStart` fired as the turn opened and `TaskComplete` fired as it closed.
`UserPromptSubmit` never fired in the TUI, which is why `TaskStart` is used as the open signal.

While a turn ran the transcript carried the busy row:

```
⠸ Thinking... (esc to cancel)
```

At turn end the same row was rewritten as `▶ Thinking:` with the token gone; the bottom status row stayed `⏵⏵ Auto-approve all enabled (Shift+Tab)` in both states, so it is not a busy signal.

## Interrupt and exit

A single `Escape` while a turn ran stopped it and left the composer at the `Ask anything...` placeholder with no repollution; the hook log gained `SessionShutdown`, and the process stayed alive for further turns.

`/exit` closed the TUI and printed a session summary before returning to the shell:

```
Session Summary
  ID        1789518608362_pi4oo
  Duration  366s
  Model     cline-pass:cline-pass/deepseek-v4-flash
  CWD       /tmp/cline-tui3
  Messages  2
  Continue  cline --id 1789518608362_pi4oo
```

So exit is `/exit`; resume-by-id is advertised by cline itself, but no firstmate pane-resume contract is claimed (deterministic relaunch is used instead).

## Composer gap: placeholder luminance above the ghost ceiling

The idle placeholder renders as a muted truecolor grey, captured live as:

```
[1m[38;2;121;184;255m❯[0m[38;2;255;255;255m [38;2;131;137;140mWhat can I do for you?[38;2;255;255;255m
```

That foreground is `38;2;131;137;140`, perceived luminance `0.299*131 + 0.587*137 + 0.114*140 = 135.5`, just above `bin/fm-composer-lib.sh`'s fleet-wide `FM_COMPOSER_GHOST_LUMA_MAX` default of 128.
`fm_composer_strip_ghost` therefore leaves it unstripped, and on the styled tmux/herdr captures an idle cline composer classifies `pending`, never `empty` - reproduced live on cline 3.0.62 with both the fresh-session and post-turn placeholders.

This is the same class of gap `docs/verification/rovo.md` documents and deliberately did not patch by raising the shared ceiling.
Raising the ceiling for cline is also not a free fix: `tests/fm-composer-lib.test.sh`'s codex starfield fixture draws truecolor braille furniture at greys 132, 136, and 138 straddling the 128 ceiling, and the fixture proves those survivors are then resolved by the braille stripper.
A shared ceiling between cline's 135.5 ghost and codex's 136-138 furniture does not exist, so the adapter does not move the shared default.

Instead, cline's launch-then-send path does not depend on composer-empty:

- readiness leads with cline's own `Auto-approve` status row (`cline_wait_for_ready`), exactly as rovo's readiness leads with the `Welcome to Rovo!` banner;
- the brief pointer is sent once (one literal send plus one Enter) rather than through the shared retrying submit core, and delivery is confirmed from the recorded `busy cline-hook` state the workspace `TaskStart` hook writes (`cline_wait_for_delivery`);
- steering still rides the shared send path, whose queued-Enter policy converts `pending + busy` to delivered, the same bounded retry rovo and agy already accept on a non-`empty` composer read.

The blast radius is therefore bounded to composer-emptiness consumers, and the fix, if desired, is a harness-scoped signal the shared composer classifier does not carry today - a follow-up, not this change.

## Still unproven

- The Herdr backend path end to end for cline; only tmux was driven interactively in this pass. The live guard below is the repeatable refresh command.
- The first-run "Introducing Cline Desktop" splash dismissal on a genuinely fresh profile. The live guard stages a copied `~/.cline` (a fresh profile) and exercises the splash branch, but a genuinely first-run store on a clean host was not observed.
- A `/abort`-driven cancellation distinct from `Escape`; only `Escape` was exercised.
- Interrupt acknowledgement beyond the `SessionShutdown` hook: cline records the abort through its hooks, but no rendered acknowledgement string is claimed.

## Refresh command

`bin/fm-test-run.sh` lists `tests/fm-cline-signals-live-e2e.test.sh` in the `live-harness-optin` family.
Run it after every cline upgrade and before trusting refreshed per-harness evidence; it exercises the installed `cline` for real and fails naming the harness and version when the busy or turn-end signal no longer holds.
