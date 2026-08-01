# Telegram bridge verification

Audience: maintainer verification.

This record owns current reproducible evidence for the private Telegram bridge.
Operator setup and current product limits remain in [the private Telegram bridge guide](../telegram-bridge.md).

## Deterministic entry points

Run the focused public-interface suite:

```sh
tests/fm-telegram-bridge.test.sh
```

Run the affected supervision and harness contracts:

```sh
tests/fm-supervision-instructions.test.sh
tests/fm-session-start.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-arm-pretool-check.test.sh
```

Run repository lint, documentation inventory, and the complete deterministic suite:

```sh
bin/fm-lint.sh
tests/fm-documentation-audiences.test.sh
bin/fm-test-run.sh --all
```

The focused bridge suite uses a local fake Bot API transport and isolated homes.
It never reads a live token, contacts Telegram, or writes a live Firstmate home.

## Covered guarantees

The focused suite covers protected config modes, regular-file and no-symlink/no-hardlink checks, post-publication failure preservation, exact local pairing, authorized and unauthorized updates, strict update ordering and deduplication, persist-before-offset crash recovery, live-session and harness-turn wake ownership, exact approval correlation and publication recovery, durable request retirement, request-locked expiry versus reply dispatch, sent-receipt precedence and finalization recovery, outbound receipt states and tombstones, definite rejection versus ambiguous delivery, diagnostic redaction, immutable receive-time retention, isolated watcher deadlines, quiet event filtering, and malformed, oversized, edited, and media inputs.
It also covers the one cross-project reply/update presentation boundary: semantic headings, lists, links, quotes, code, mobile table fallback, entity neutralization, no-button payloads, emoji and combining-mark width, oversized-grapheme code-point fallback, readable plain URLs, immutable restart snapshots, final rich/plain UTF-16 postconditions, ordered same-chat part receipts, and one definite rich-validation fallback.

Its threat-oriented negative controls remove the exact allowlist or exact approval correlation and prove the request or approval is rejected.
Its crash controls cover persistence before offset advancement, drained-offer requeue, exact claim publication before inbox publication, request resurrection after retirement, sent-receipt replay before approval and request finalization, and expiry waiting for an in-flight reply before alert arbitration.
The harness matrix verifies Claude, Codex, OpenCode, Pi, and Grok inherit the generated Telegram cadence and advance acknowledgement only when the exact live home session-lock holder appears in the guard process ancestry, including Grok's nested same-session resume; an independent lock-refused primary-shaped session cannot rotate the epoch.
The runtime matrix verifies the watcher dispatch remains backend-neutral across tmux, Herdr, zellij, Orca, and cmux.

## Current evidence - 2026-07-31

With documentation corrections and narrow ShellCheck rationale comments applied to target `28e7d48`, these commands exited 0:

```sh
shellcheck --norc --external-sources bin/fm-telegram-send.sh tests/fm-telegram-bridge.test.sh tests/fm-turnend-guard.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
tests/fm-documentation-audiences.test.sh
tests/fm-instruction-owners.test.sh
git diff --check 3f71cddd764a49ab71bcd53a46b84e5e7336557a
```

Repository lint reported the pinned ShellCheck 0.11.0, and the documentation inventory reported 58 classified surfaces and 153 resolved local links.

No current full-suite or live Telegram evidence is recorded; green pull-request checks remain required.
