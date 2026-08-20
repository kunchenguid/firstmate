# Quota utilization check verification

Audience: maintainer verification.

This record supports the weekly utilization check owned by `bin/fm-quota-utilization.sh`.
It exists because a check that reports the wrong tightest window, mixes account homes, or holds ready work would silently invert the confirmed reference-trajectory design.
Task chronology and delivery evidence stay in private reports or PR evidence.

## Behavior oracles

Verified 2026-08-18 on Node v24 and GNU bash 5.3 under Linux.

The suite is hermetic: every case either supplies `--snapshot`/`--observations` or shadows `quota-axi` with a fakebin stub, so the control command never reads a live provider.
Its fixtures mirror quota-axi 0.1.28's published `ProviderQuota`, `QuotaWindow`, and `EffectiveAvailability` shapes, including the degraded cause slugs in `state.error`, confirmed against that release's type declarations rather than by invoking it.

The control command from the repository root:

```sh
bash tests/fm-quota-utilization.test.sh
```

Exact output, exit status 0:

```
ok - tightest-window selection uses the binding weekly window, not the idle session or named-model bound
ok - a short idle window is not spare capacity when the binding weekly window is ahead of pace
ok - a fully consumed short window is not spare capacity even when weekly headroom is behind pace
ok - reset countdown is seconds until the tightest window resetsAt against the fixed clock
ok - a window with no measurable percent or reset reports unknown in text and null in JSON
ok - missing sources name the exact cause in one line and step aside
ok - when every equivalent candidate is tight, the check reports pressure and never holds ready work
ok - intake prefers the healthier binding weekly reserve among equivalent-fit accounts
ok - end-of-window outcomes report exhausted-early time versus expired unused percent
ok - end-of-window outcomes stay reproducible when replayed after the window has reset
ok - --provider scopes the outcomes table to the requested provider
ok - outcomes mode is derived from observations alone and performs no live provider read
ok - a per-profile skip line names which account home failed
ok - --provider restricts the live quota-axi read instead of filtering after the fact
ok - --provider skips Claude profile reads and their skip lines for another provider
ok - CLAUDE_CONFIG_DIR profiles keep per-account windows separate
ok - a failed provider reader names the cause and continues
ok - a noisy provider reader is capped to one short skip line
ok - a short exact reader cause passes through the cap unchanged
ok - CODEX_HOME is forwarded to quota-axi where the existing reader permits it
```

The suite pins widget-compatible tightest-window utilization and reset countdown, that neither an idle short window under an ahead-of-pace weekly nor a fully consumed short window counts as spare capacity, that `CLAUDE_CONFIG_DIR` profiles stay separated, that missing sources such as `sqlite3_unavailable` and `kimi_code_cli_credential_expired` print one skip line and exit 0, that a window with no measurable percent or reset reports `unknown` rather than a literal `null`, that a noisy provider failure is capped to one short skip line while a short exact cause passes through unchanged, that intake prefers the healthier binding weekly reserve without `holdReadyWork`, that end-of-window outcomes distinguish exhausted-early seconds from expired unused percent, and that `--provider` scopes the live read, the Claude profile loop, and the outcomes table alike.

Re-run that suite after changing `bin/fm-quota-utilization.sh`, `bin/fm-quota-utilization.mjs`, or the tests.
Session-start piggybacking is covered by `tests/fm-session-start.test.sh`, which stubs one measurable provider and requires the fleet digest to render that account line, not just the `Quota utilization` header.
