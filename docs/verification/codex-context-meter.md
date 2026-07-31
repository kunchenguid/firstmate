# Codex context meter verification

Date: 2026-07-31.

Versions under test:

- `codex-cli 0.146.0`.
- `herdr 0.7.4`.

## Automated behavior

Command:

```sh
tests/fm-codex-context-meter.test.sh
```

Observed output:

```text
ok - Codex context meter uses active usage and follows compaction immediately
ok - Codex context meter is silent and fail-open for absent, malformed, and reporting failures
ok - context meter installer preserves config, is byte-idempotent, and uninstalls exactly
ok - drifted uninstall removes only Firstmate-owned hooks, footer fields, and $context row
```

The installer fixture also invokes the real Herdr parser against its isolated generated config.

```sh
HERDR_CONFIG_PATH=<isolated-config> herdr config check
```

The command exited zero with no diagnostics.

## Herdr row contract

Command:

```sh
herdr --default-config | sed -n '203,220p'
```

Herdr's default config identifies `$name` values in expanded agent rows as custom pane-metadata tokens and identifies `rows_by_agent` as the canonical-agent override.
The installed Codex override includes `[$context]` as a dedicated row, represented as `["$context"]` in TOML.

## Visual verification limit

Live visual rendering was not proven in an isolated Herdr session during this verification.
A nested named-session launch was refused by Herdr's default nesting guard, and a second isolated named server did not become ready.
A later isolated monolithic probe was terminated before metadata injection and removed at the captain's direction.
Those attempts did not touch the captain's live Herdr config or report metadata to the live pane.
The current evidence proves the documented row contract, generated TOML validity, metadata command shape, and formatter output, but it does not claim a captured live sidebar render.
