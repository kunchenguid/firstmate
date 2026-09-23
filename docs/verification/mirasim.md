# Mirasim adapter verification

This record covers the crewmate and scout adapter only.
Primary and secondmate operation remain unsupported.

## Current evidence

Verified on 2026-09-22 with Mirasim `0.0.303` wrapping Claude Code `2.1.278` on macOS arm64.

`mirasim ui-cli catalog --agent claude` advertised `claude-fable-5-1[1m]`, `claude-fable-5[1m]`, `claude-opus-5[1m]`, `claude-sonnet-5[1m]`, `claude-opus-4-8[1m]`, and `claude-opus-4-6[1m]` in the authenticated environment.
The same listing advertised low, medium, high, xhigh, max, and ultra effort values.
The interactive wrapper remains bounded by the wrapped Claude CLI, whose current `--help` accepts low through max, so Firstmate does not pass ultra through `mirasim claude`.

Run the portable adapter regression with:

```sh
bin/fm-test-run.sh tests/fm-mirasim-harness.test.sh
```

It proves the selectable route records `harness=mirasim`, launches the absolute Mirasim executable resolved during preflight, preserves a bracketed model id as one shell-quoted argument, propagates effort and permission mode, installs Claude lifecycle hooks, trusts `claude-hook`, reuses Claude control mechanics, and refuses secondmate use.

Run the credentialed live guard with:

```sh
FM_MIRASIM_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-mirasim-live-e2e.test.sh
```

The guard uses a temporary empty directory and sends the fixed prompt `Reply with exactly MIRASIM_SMOKE_OK and nothing else.` with tools disabled and session persistence off.
It prefers `claude-fable-5-1[1m]` when the current catalog contains that id, otherwise requests the catalog default, observes the exact response, and checks Claude's `UserPromptSubmit` and `Stop` hook transitions through Firstmate's real busy-state writer.
The run proves that the requested id completed through the authenticated Mirasim route.
It does not prove the upstream served-model identity or quota coverage.
