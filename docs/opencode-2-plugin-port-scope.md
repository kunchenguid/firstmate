# OpenCode 2 primary-plugin port - scoping findings

Point-in-time scoping note recorded 2026-10-01 against the installed OpenCode v2.0.21.
It exists to size the OpenCode 2 primary-integration port so the choice between porting now and holding the OpenCode primary on 1.18.x can be made with evidence.
It is not a standing contract; the adapter reference `.agents/skills/harness-adapters/references/harness/opencode.md` and `docs/turnend-guard.md` remain the owners once the port lands.

All facts below were exercised first-hand on v2.0.21 (`opencode run --standalone --print-logs --auto`, model `openai/gpt-5.5-fast`) unless marked as read from the installed binary or the `@opencode-ai/plugin`/`sdk` packages.

## What changed in the plugin model

OpenCode 2 rejects the v1 plugin module and requires a default export.
The load failure for the v1 shape is `PluginModule.LoadError: Plugin must export a default definition with an id and an effect or setup function.`.
A default export of `{ id, setup }` loads with no failure.

The v1 `server` entrypoint and the hooks it returned are not honored on v2.
A sentinel plugin exporting `{ id, server, setup }` showed only `setup` running: the `server` function was never invoked, and neither its `event` hook nor its `tool.execute.before` hook fired, even though the turn ran a real bash tool call.
So the current `{ id, server, setup(){} }` edits make all five primary plugins and `fm-busy-state.js` load without failure, but leave every hook they rely on inert.
The managed Herdr plugins use the same `{ id, server, setup(){} }` shape and document the same conclusion: their `server` hooks are legacy and their live behavior runs through a separate entrypoint (`herdr-tui-session.js`, the `tui`/`setup` object).

## The v2 server-plugin context

The `setup(ctx)` context on a server plugin exposes these domains (read from the live sentinel):
`app, location, options, agent, aisdk, command, event, experimental, generate, model, provider, integration, mcp, permission, plugin, reference, rpc, skill, storage, tool, vcs, websearch, worktree, session, shell`.

Relevant members:

- `ctx.tool.hook("execute.before" | "execute.after", fn)` registers tool-lifecycle hooks.
- `ctx.event` is `{ subscribe }`; `ctx.event.subscribe({ signal, onActivity })` returns an async-iterable server-sent-event stream consumed with `for await`, the same call the built-in effect plugins use.
- `ctx.session` is `{ hook, create, get, switchAgent, switchModel, prompt, generate, command, synthetic, interrupt, update, move, wait, context }`.
- `ctx.session.hook(name, fn)` accepts only its fixed set (`context`, `compaction`, `generate`, `retry`, `title`, `model.request`, `http.request`, `http.response`); it silently accepts other names but never fires them, so it cannot stand in for the old event bus.

The SDK also exposes the matching server operations `EventSubscribe`, `SessionPrompt`, `SessionPromptAsync`, and the `Tui*` operations (`TuiShowToast`, `TuiSubmitPrompt`, `TuiAppendPrompt`, `TuiExecuteCommand`, `TuiPublish`).

## The three signals firstmate needs

All three are reachable from a v2 server plugin through `ctx.event.subscribe`.
The live 2.0.21 stream expressed turn and activity state as `session.execution.*`, not the v1 `session.idle`/`session.status`.
The event types observed for one tool-using turn, in order, were:
`session.inbox.enqueued`, `session.execution.started`, `session.instructions.updated`, `session.inbox.delivered`, `session.usage.updated`, `session.renamed`, `session.step.started`, `session.tool.input.started`, `session.tool.input.ended`, `session.tool.called`, `shell.created`, `session.tool.progress`, `session.step.streamed`, `shell.exited`, `session.tool.success`, `session.step.ended`, `session.text.started`, `session.text.delta`, `session.text.ended`, `session.execution.succeeded`, `location.shutdown`.

1. Turn-end (turn-end guard follow-up): `session.execution.succeeded`, with `session.execution.interrupted` and `session.execution.failed` as the other terminal transitions.
   This replaces the v1 `session.idle` filter.
2. Busy/idle state (`fm-busy-state.js`): `session.execution.started` is working; `session.execution.succeeded`/`interrupted`/`failed` settle it.
   This replaces the v1 `session.status` busy/retry/idle filter.
   Child-versus-root session scoping must be rebuilt from the event payload's session id and parent id, as both Herdr plugins do.
3. Watcher-arm trigger: the same terminal turn signal that drives it today, mapped from `session.idle` to `session.execution.succeeded`.

The turn-end and session-start follow-up injection (v1 `client.session.promptAsync`) maps to `ctx.session.prompt` and the `SessionPromptAsync` operation.
The session-start nudge's `session.created` filter remains an event type, reachable through the same subscription.

## Seatbelts (cd-guard and pre-tool)

`ctx.tool.hook("execute.before", fn)` fires on the tool call, and throwing from it blocks the tool: the model reported the bash command denied with the thrown message and did not run it.
So `fm-primary-cd-check.js` and `fm-primary-pretool-check.js`, and the watcher-arm pre-tool seatbelt, keep their throw-to-block behavior by moving the body into `ctx.tool.hook("execute.before")`.

## Rough effort for option A (port now)

This is a server-plugin port inside `setup(ctx)`, not the full TUI-plugin re-architecture flagged as the worst case before this experiment.
The guard scripts (`bin/fm-turnend-guard.sh`, `bin/fm-cd-pretool-check.sh`, `bin/fm-sessionstart-nudge.sh`, `bin/fm-busy-event.sh`) and the latch and coordinator logic are reusable; what changes is the event plumbing and the event-name mapping.

Per plugin:

- `fm-primary-cd-check.js`, `fm-primary-pretool-check.js`: small; relocate the `tool.execute.before` body into `ctx.tool.hook("execute.before")`.
- `fm-primary-sessionstart-nudge.js`: small to medium; drive off `session.created` from the subscription and inject with `ctx.session.prompt`, with a check that the plugin attaches before session creation in the TUI.
- `fm-primary-turnend-guard.js`: medium; drive off `session.execution.succeeded`, keep the guard script and watcher-arm coordination, swap `promptAsync` for `ctx.session.prompt`.
- `fm-busy-state.js` (heredoc in `bin/fm-spawn.sh`): medium; replace the `event` hook with a `ctx.event.subscribe` loop, remap `session.status`/`session.idle` to `session.execution.*`, keep the first-session latch and the turn-end touch.
- `fm-primary-watch-arm.js` (about 560 lines): medium to large; its seatbelt moves to `ctx.tool.hook("execute.before")` and its idle coordination and blind-turn wake move onto `session.execution.*` plus `ctx.session.prompt`.

Shared work: a small per-plugin or shared event-subscribe helper, the event-name remap, and dropping the dead `server` entrypoint from the default export.
Documentation and tests: refresh `opencode.md`, `docs/turnend-guard.md`, `docs/arm-pretool-check.md`, and the supervision verification record, and add the portable regression plus the installed-harness live guard that the harness-dependent-check rule requires for the busy, turn-end, and seatbelt classifiers.

Rough size: on the order of 1.5 to 3 focused days, with the weight in watch-arm, busy-state, and the two live guards and their tests rather than the trivial seatbelts.

## Risks to validate during implementation, not resolved here

- The exact `session.execution.*` payload shape (session id and parent id) for the child-session scoping.
- Whether `session.idle`/`session.status` ever fire on 2.0.21 or are fully replaced by `session.execution.*`; the live run showed only `session.execution.*`, and the port should key off those and treat the old names as legacy.
- The `ctx.session.prompt` signature and whether injecting on `session.execution.succeeded` cleanly starts a new turn without racing the composer.
- Plugin and subscription lifetime across a full TUI session and across session switches; the subscription in the `run` probe ended on `location.shutdown`.
- The `onActivity` heartbeat semantics for keeping the subscription healthy over a long session.
