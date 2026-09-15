# fm-calm

Firstmate Calm for Claude Code: a presentation-only transcript toggle driven by `/calm`.

It is the Claude Code counterpart of firstmate's Pi extension `.pi/extensions/fm-calm.ts`.
[`docs/calm.md`](../../docs/calm.md) is the user-facing contract both share, and both read the same `config/calm` file, so the two agree on one preference.

## What it does

While Calm is on:

- tool call rows (`ToolUse`) are drawn at zero height.
- tool result rows (`ToolResult`) are drawn at zero height.
- the folded tool-run row (`ToolGroup`) is drawn at zero height, which is what takes the `Thinking` / `Thought for Ns` summary off the screen.
- firstmate's operational user rows are drawn at zero height, recognised by every marker `bin/fm-operational-input.sh` writes: the invisible-separator `FIRSTMATE_OP: ` header, the from-firstmate `[fm-from-firstmate]` marker, and the legacy `Supervisor escalate (` prefix.
  A genuine prompt you typed is never hidden.

Everything else is untouched, the working spinner included: Claude Code draws its own, so `thinking`, `still thinking` and `thought for Ns` stay where they are and you can still see the session is alive.

The thinking summary is not addressable on its own.
The `ToolGroup` render input carries `calls`, `isActive` and `isExpanded`; the `Thinking` / `Thought` segment is assembled inside the component from counts the hook never sees, so the row is the smallest thing that can be hidden.
Since the tool counts on that same row are already meant to be hidden here, hiding the whole row is the behaviour, not a compromise.
The mod reads the transcript and draws rows; it never changes what is sent to the model, what the session stores, or what `/export` writes.
`claude plugin validate .` prints the complete list of engine calls the module makes, which is the check that keeps this true.

Behaviours the Pi extension has and this mod does not: hiding mid-turn assistant narration while keeping the reply that ends a response, and replacing the working row with a boat.
The first has no seam - the `AssistantMessage` render input carries no stop reason - and the second was dropped on purpose to keep Claude Code's own spinner text.

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
