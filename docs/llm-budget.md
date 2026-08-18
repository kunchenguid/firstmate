# LLM gateway budget meter

The printed line, cache, Datadog query, and refresh path are owned by [`bin/fm-llm-budget.sh`](../bin/fm-llm-budget.sh).
Read that header and `--help` for flags, cache fields, email resolution, and auth.
Home-local cache and optional email or cap files are listed in [`docs/configuration.md`](configuration.md#llm-gateway-budget-meter-statellm-budget-cachejson).
This page only records where that command is attached.

## Pi

The tracked `.pi/extensions/fm-llm-budget.ts` adapter calls `ctx.ui.setStatus` with the dedicated key `firstmate-llm-budget`.
It does not reuse Calm's `firstmate-calm` key.
The meter is shown only while the active provider is a Rippling gateway family (`rippling-bedrock`, `rippling-openai`, or another `rippling-*` provider).
Any other model clears that status key.

## Claude Code

Do not put `statusLine` in tracked `.claude/settings.json`.
Cursor Agent CLI also loads that project file, and this meter must not appear there.
Claude's user settings file is the Claude-only install path: `$CLAUDE_CONFIG_DIR/settings.json`, defaulting to `~/.claude/settings.json`.
`fm-llm-budget.sh install-claude` patches only the `statusLine` key on that file and leaves every other key unchanged.
The installed command is `fm-llm-budget.sh claude-statusline --kick-refresh`.
On a non-gateway model or URL it prints nothing.

## Codex

Skipped.
Codex CLI 0.147.0 (2026-08-18) has a real status-line surface, but it is a closed picker of built-in items (`/statusline`, persisted as `tui.status_line`), not a command hook.
There is no supported way to render the gateway budget line without inventing a fake footer.

## Cursor

Forbidden for this meter.
Cursor-served models do not consume the Rippling LLM gateway.

## Cache location

Cache and optional Linux OAuth bytes live under the effective `FM_HOME` gitignored `state/` directory.
The command header owns the filenames.
