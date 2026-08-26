# Hermes primary harness

Hermes Agent can run the captain-facing Firstmate session through the tracked `firstmate-primary` project plugin.
This integration is primary-only: Hermes never runs crewmates, scouts, or secondmates.

## Requirements

- Hermes Agent with native project-plugin support.
- A separate verified worker harness in `config/crew-harness`.
- The normal Firstmate backend requirements for that worker harness.

The live drift guard targets Hermes Agent 0.20.5.
Run it after every Hermes upgrade before trusting the refreshed installation; [`verification/supervision.md`](verification/supervision.md#hermes-primary-plugin-2026-08-26) owns the current evidence.

## One-time setup

From the root of the trusted Firstmate checkout:

```sh
bin/fm-hermes-primary.sh --setup
bin/fm-hermes-primary.sh --check
```

Setup links the tracked plugin into the active Hermes home and enables its exact plugin key.
It refuses to replace an existing non-matching plugin path.
Normal launches only check that enablement and do not rewrite Hermes configuration.

Configure the workers independently because an absent or `default` worker setting would mirror the Hermes primary and `fm-spawn.sh` deliberately refuses that primary-only runtime.
For Pi workers on Herdr:

```sh
mkdir -p config
printf '%s\n' pi > config/crew-harness
printf '%s\n' pi > config/secondmate-harness
printf '%s\n' herdr > config/backend
```

These operator choices remain local and gitignored by design.
Configure the Hermes model or provider separately with `hermes setup` or `hermes model`; Firstmate does not copy, modify, or own provider credentials.

## Launch

Always launch the primary from the checkout root:

```sh
bin/fm-hermes-primary.sh
```

The launcher forces the persistent classic CLI, keeps resumed sessions in the checkout root, clears inherited markers from other primary harnesses, and accepts only a bounded set of classic-session options.
Profiles, subcommands, one-shot mode, the TUI, safe mode, ignored rules or user configuration, Hermes-managed worktrees, and alternate starting directories are refused because those shapes would disable or escape the Firstmate integration.

The plugin then:

- blocks Hermes's built-in `delegate_task` so work stays in visible Firstmate-managed sessions;
- validates watcher-arm terminal calls through Firstmate's shared command policy;
- requires `terminal(background=true, notify_on_complete=true)` for the one managed watcher process;
- runs the shared turn-end predicate after successful, failed, and interrupted turns and injects one canonically marked, bounded recovery turn when active work lacks healthy supervision;
- publishes a versioned process marker for the CLI lifetime so session start can prove the current lock-owning Hermes process loaded the current plugin build across `/new` and reset boundaries.

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

The live check opens real persistent Hermes processes in PTYs against an isolated local protocol fixture without external provider credentials.
It verifies plugin loading, the exact loaded-plugin digest, structural process identity, agreement between the plugin marker and Firstmate session-lock identity, native `pre_tool_call` delegation blocking, and native `on_session_end` recovery after successful, failed, and interrupted turn outcomes.
Real provider and model behavior remains operator verification because Firstmate does not own Hermes credentials.
The check reports an absent Hermes installation or disabled plugin rather than silently passing.

After `hermes update`, rerun the live check before starting the next Firstmate primary session.
If the check fails, use `hermes plugins show firstmate-primary` and `bin/fm-hermes-primary.sh --check` to distinguish discovery and enablement failures.
`hermes plugins doctor firstmate-primary` can validate import and manifest parsing, but its standalone command is intentionally outside persistent-primary scope and therefore reports no runtime hook registrations.

## Supported limits

- The classic interactive CLI is the only verified primary surface.
- Hermes gateway, desktop, web, TUI, one-shot, ACP, and outer-wrapper modes are outside this integration.
- The plugin intentionally disables built-in Hermes delegation for the lifetime of the loaded primary CLI, including after a cwd change.
- Hermes is excluded from Firstmate's verified worker-harness selection. Firstmate's pre-existing raw-command escape hatch remains explicitly operator-owned and outside adapter guarantees.
- Worker and backend selection use the normal gitignored Firstmate configuration; this integration does not add a second policy layer around those settings.
- Like the rest of Firstmate's local shell tooling, the wrapper is an operational safety boundary for a trusted local operator, not a security boundary against an operator deliberately recreating or modifying its environment.
- Worker busy state, steering, interruption, cleanup, and backend behavior remain properties of the selected worker harness, not Hermes.
