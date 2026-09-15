# fm-calm

Firstmate Calm for Claude Code: a presentation-only transcript toggle driven by `/calm`.

It is the Claude Code counterpart of firstmate's Pi extension `.pi/extensions/fm-calm.ts`.
[`docs/calm.md`](../../docs/calm.md) is the user-facing contract both share, and both read the same `config/calm` file, so the two agree on one preference.

## What it does

While Calm is on:

- tool call rows (`ToolUse`) are drawn at zero height.
- tool result rows (`ToolResult`) are drawn at zero height.
- firstmate's operational user rows are drawn at zero height, recognised by the invisible-separator prefix `FIRSTMATE_OP: ` that `bin/fm-operational-input.sh` writes.
  A genuine prompt you typed is never hidden.
- the `Spinner` row is replaced by a small animated two-row boat.

Everything else is untouched.
The mod reads the transcript and draws rows; it never changes what is sent to the model, what the session stores, or what `/export` writes.
`claude plugin validate .` prints the complete list of engine calls the module makes, which is the check that keeps this true.

Behaviours the Pi extension has and this mod does not: hiding the collapsed-thinking label, and hiding mid-turn assistant narration while keeping the reply that ends a response.
Both are deliberately out of scope here.

## Preference file

The on/off choice persists in `<FM_HOME>/config/calm`, holding `on`, `max`, or `off`.
`max` reads as on, matching the Pi extension.
`FM_CONFIG_OVERRIDE` selects a different config directory, and `FM_ROOT_OVERRIDE` stands in for `FM_HOME` when that is unset.
With none of them set the toggle still works, but only for the session.

The choice is read once at session start and written on every toggle.
A toggle applies immediately through `$.ui.invalidate("ui.render")`; no restart is needed.

## Requirements

Function hooks are early access and off by default, so every command below needs the flag:

```
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
```

Run it against Claude Code 2.1.272 or newer.
The plugin API may change between releases without notice.

## Developing

```
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate .
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test .
npm install --no-save typescript@5 && ./node_modules/.bin/tsc -p tsconfig.json
```

`.claude/types/claude-code.d.ts` is generated, not hand-written.
Regenerate it after a Claude Code upgrade rather than editing it:

```
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude -p "/plugin-types"
```

Its first line names the version that wrote it, so a regenerated diff is how an API change becomes visible.
