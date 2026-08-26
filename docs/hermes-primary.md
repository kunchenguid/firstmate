# Hermes primary harness

Hermes Agent can run the captain-facing Firstmate session through the tracked `firstmate-primary` project plugin.
This integration is primary-only: Hermes never runs crewmates, scouts, or secondmates.

## Requirements

- Hermes Agent with native project-plugin support.
- Pi in both `config/crew-harness` and `config/secondmate-harness`.
- Herdr in `config/backend`, with the normal Herdr backend requirements.

The integration was live-verified with Hermes Agent 0.20.5 on 2026-08-25.
Run the live drift guard after every Hermes upgrade before trusting the refreshed installation.

## One-time setup

From the root of the trusted Firstmate checkout:

```sh
bin/fm-hermes-primary.sh --setup
bin/fm-hermes-primary.sh --check
```

Setup links the tracked plugin into the active Hermes home and enables its exact plugin key.
It refuses to replace an existing non-matching plugin path.
Normal launches only check that enablement and do not rewrite Hermes configuration.
Setup and launch create the checkout state directory when absent and refuse a symlinked or non-directory state path.

Configure the required Pi workers and Herdr backend before launching Hermes:

```sh
mkdir -p config
printf '%s\n' pi > config/crew-harness
printf '%s\n' pi > config/secondmate-harness
printf '%s\n' herdr > config/backend
```

These operator choices remain local and gitignored by design.
The launcher refuses missing or different values and recursively checks local and remote active descendants for Pi plus Herdr before launch.
The checkout-owned loaded-plugin marker activates the same enforcement in `fm-spawn.sh` regardless of per-command home or state overrides, while a durable policy in each launched secondmate home preserves it across remote and nested launches.
Configure the Hermes model or provider separately with `hermes setup` or `hermes model`; Firstmate does not copy, modify, or own provider credentials.

## Launch

Always launch the primary from the checkout root:

```sh
bin/fm-hermes-primary.sh
```

The launcher forces the persistent classic CLI and keeps resumed sessions in the checkout root.
It accepts only bounded classic-session options and refuses profiles, subcommands, one-shot mode, the TUI, safe mode, ignored rules or user configuration, Hermes-managed worktrees, and alternate starting directories because those shapes would disable or escape the Firstmate integration.

The plugin then:

- blocks Hermes's built-in `delegate_task` so work stays in visible Firstmate-managed sessions;
- validates watcher-arm terminal calls through Firstmate's shared command policy;
- requires `terminal(background=true, notify_on_complete=true)` for the one managed watcher process;
- runs the shared turn-end predicate after successful, failed, and interrupted turns and injects one bounded recovery turn when active work lacks healthy supervision;
- publishes an exact-build, checkout-bound process marker with process-incarnation identity for the lifetime of the CLI process so detection and session start can reject stale PID reuse across `/new` and reset boundaries.

## Verification and upgrades

Portable checks:

```sh
bin/fm-test-run.sh tests/fm-hermes-harness.test.sh
bin/fm-test-run.sh tests/fm-hermes-primary.test.sh
```

Live installed-Hermes check:

```sh
FM_HERMES_PRIMARY_LIVE_E2E=1 \
  bin/fm-test-run.sh tests/fm-hermes-primary-live-e2e.test.sh
```

The live check opens a real persistent Hermes process in a PTY without sending a model turn.
It verifies plugin loading, the exact loaded-plugin digest and checkout, marker-bound process identity, and agreement between the plugin marker and Firstmate session-lock identity.
It reports an absent Hermes installation or disabled plugin rather than silently passing.

After `hermes update`, rerun the live check before starting the next Firstmate primary session.
If the check fails, use `hermes plugins show firstmate-primary` and `bin/fm-hermes-primary.sh --check` to distinguish discovery and enablement failures.
`hermes plugins doctor firstmate-primary` can validate import and manifest parsing, but its standalone command is intentionally outside persistent-primary scope and therefore reports no runtime hook registrations.

## Supported limits

- The classic interactive CLI is the only verified primary surface.
- Hermes gateway, desktop, web, TUI, one-shot, ACP, and outer-wrapper modes are outside this integration.
- The plugin intentionally disables built-in Hermes delegation in Firstmate scope.
- Worker busy state, steering, interruption, cleanup, and backend behavior remain properties of Pi and Herdr, not Hermes.
