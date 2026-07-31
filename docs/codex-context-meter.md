# Codex context meter for Herdr

The Codex context meter is an opt-in display for Codex panes running inside Herdr.
It adds a compact active-context bar to Herdr's agent sidebar and exact context fields to the Codex footer.
It does not install Herdr's official Codex integration, which remains a separate session-restore feature.

## Install

Run the installer from the Firstmate checkout that should own the global hook command.

```sh
bin/fm-codex-context-meter-install.sh install
```

The installer updates the following user-level files:

- `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` when `CODEX_HOME` is unset.
- `$CODEX_HOME/config.toml`, or `~/.codex/config.toml` when `CODEX_HOME` is unset.
- `$HERDR_CONFIG_PATH`, or `${XDG_CONFIG_HOME:-~/.config}/herdr/config.toml` when `HERDR_CONFIG_PATH` is unset.

Existing hook groups, Codex settings, Herdr settings, comments, and unrelated values remain in place.
The installer adds `context-used`, `context-window-size`, and `used-tokens` to the Codex footer only when they are absent.
It adds `"$context"` to `ui.sidebar.agents.rows_by_agent.codex`, preserving existing Codex-specific rows or copying the configured general agent rows before adding the custom row.
A private `.firstmate-codex-context-meter.json` receipt under `CODEX_HOME` records exactly what the installer owns.
Running install again converges to the same bytes.

Restart Codex so its global hooks and footer configuration are reloaded.
Review and trust the new command hooks with `/hooks` when Codex requests it.
Reload a running Herdr server after reviewing the config change.

```sh
herdr server reload-config
```

## Display and update cadence

The handler reads the newest Codex transcript `event_msg` whose payload type is `token_count`.
It uses `payload.info.last_token_usage.total_tokens` for active use and `payload.info.model_context_window` for the window size.
It never uses cumulative `total_token_usage` as the numerator.

The `context` pane metadata token is shaped like this:

```text
████████░░ 216.7k / 258.4k · 84%
```

Global Codex command hooks refresh the token at `SessionStart`, `PostToolUse`, `PostCompact`, and `Stop`.
The `PostCompact` checkpoint lets the sidebar show the lower active count as soon as compaction completes.
There is no polling daemon, launch agent, detached process, or periodic background job.

## Failure behavior and limits

The handler is silent and exits zero on every path.
Missing `jq`, `perl`, Herdr, `HERDR_PANE_ID`, transcript data, valid token records, or a working Herdr socket leaves Codex unaffected.
The transcript read is bounded to its final 4 MiB.
The Herdr report is bounded to one second, and Codex also gives each installed hook a two-second timeout.
The rendered metadata value stays below Herdr's 80-character token limit.

Codex documents `transcript_path` for hooks but does not treat the transcript record format as a stable interface.
A future Codex transcript change can therefore make the meter temporarily inert until this parser is updated.
Current configuration and render verification evidence is recorded in [verification/codex-context-meter.md](verification/codex-context-meter.md).

## Uninstall

Run uninstall from any checkout containing this installer.

```sh
bin/fm-codex-context-meter-install.sh uninstall
```

When the managed files have not changed since installation, uninstall restores their original bytes.
When they have changed, uninstall removes only the Firstmate-owned hook handlers, footer identifiers, and `"$context"` row while retaining later unrelated edits.
It then removes the ownership receipt.
Restart Codex and reload or restart Herdr after uninstalling.
