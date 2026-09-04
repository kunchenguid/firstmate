# Pi permission modes

Permission modes are an opt-in, session-scoped advisory harness control for the Firstmate Pi primary.
They are off by default and change nothing until a mode is explicitly enabled, so Firstmate behavior is preserved exactly when off.
The active mode is session-persisted through Pi's supported extension state, restored on session resume and reload, and never written to a global config file.

This is an advisory harness control, not an OS sandbox.
Pi extensions execute with the user's full privileges, and the bash read-only classifier is a best-effort heuristic because shell is Turing-complete.
Use it to reduce accidental mutations during interactive exploration, not to enforce a security boundary.

## Modes

- `off` - the default; no call is blocked or confirmed, and the existing PreToolUse seatbelts and turn-end guard run unchanged.
- `plan` - block the built-in `edit` and `write` tools and any `bash` command that is not genuinely read-only, while allowing read-only inspection (`read`, `ls`, `grep`, `find`, and read-only `bash`).
- `confirm` - require an interactive approval before the built-in mutating file and shell tools (`edit`, `write`, and non-read-only `bash`); if no UI is available, refuse the call rather than silently permit it.

## Command

```
/fm-permissions off|plan|confirm
```

A bare `/fm-permissions` reports the active mode.
Unknown arguments notify an error and leave the mode unchanged.
The mode name is case-sensitive and leading or trailing whitespace is trimmed.

## State and display

The active mode is stored through Pi `appendEntry` extension state, not a config file.
A fresh session starts `off`; a resumed or reloaded session restores the last persisted mode.
Malformed persisted entries are ignored, so a stale or hand-edited session never restores an invalid mode.
While a mode is active, a short label is shown unobtrusively in the Pi footer; `off` clears it.

## Bash read-only classification

`plan` and `confirm` consult a pure read-only classifier for `bash` commands.
A command is read-only only when it matches a known read-only pattern (such as `ls`, `cat`, `grep`, `rg`, `git status`, `git log`) and no known mutating pattern matches anywhere in the command, so chained, piped, redirected, or substituted mutations are caught even when the leading token looks read-only.
An unrecognized command defaults to non-read-only, so `plan` blocks it and `confirm` prompts for it rather than silently allowing a possible mutation.
The patterns are intentionally conservative; operators who need an unrecognized read-only command in `plan` mode can toggle `off` for that turn.

## Composition with existing seatbelts

Permission modes are an additive gate and never weaken the existing PreToolUse seatbelts or turn-end guard.
Pi runs `tool_call` handlers in load order and short-circuits on the first block, and a no-block decision from this extension lets the existing seatbelts run afterward.
A call this gate allows therefore still passes through the existing `cd`-guard and watcher-arm seatbelts, and a call this gate blocks is blocked regardless.
Approval in `confirm` mode approves only this permission gate; it does not bypass those seatbelts.
See [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`turnend-guard.md`](turnend-guard.md) for the existing seatbelts.

## Scope and limits

Only the built-in `edit`, `write`, and `bash` tools are gated; custom tools and other built-in tools pass through, because permission modes gate the built-in mutating file and shell tools named above.
JARVIS remains the only semantic authority; this extension adds no delegation and no second LLM planner.
The pure classification and decision logic lives in `.pi/extensions/lib/fm-permission-policy.ts` and the wiring in `.pi/extensions/fm-permission-modes.ts`.

## Regression entry points

```sh
tests/fm-permission-modes.test.sh
tests/fm-pi-primary-types.test.sh
```
