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
The harness matrix verifies Claude, Codex, OpenCode, Pi, and Grok inherit the generated Telegram cadence and advance acknowledgement only when their exact harness process owns the home session lock; a lock-refused primary-shaped session cannot rotate the epoch.
The runtime matrix verifies the watcher dispatch remains backend-neutral across tmux, Herdr, zellij, Orca, and cmux.

## Current evidence - 2026-07-31

The implementation was exercised locally with ShellCheck 0.11.0, jq 1.8.1, Perl 5.34.1, GNU Bash 3.2.57, and no-mistakes 1.41.2.

`tests/fm-telegram-bridge.test.sh` exited 0 with all public-interface groups passing, including the five-harness and five-runtime matrix.
`bin/fm-lint.sh` exited 0 with the pinned ShellCheck version.
`tests/fm-documentation-audiences.test.sh`, `tests/fm-instruction-owners.test.sh`, and `bin/fm-test-run.sh --check-coverage` exited 0; coverage reported `total=99 parallel=29 serial=60 herdr=10`.
The affected supervision suites `fm-supervision-instructions`, `fm-turnend-guard`, `fm-claude-stop-autoarm`, `fm-pi-watch-extension`, `fm-arm-pretool-check`, `fm-bootstrap`, and `fm-pr-check-security` all exited 0 in the complete run.

`bin/fm-test-run.sh --all` completed its full ledger in 1,559,426 ms with `total=99 failed=4 skipped_gate=10`.
The bridge family passed in 30,581 ms.
The four failing diagnostics were an Orca metadata-write fixture expectation, the installed Pi 0.82.1 exceeding that test's 0.81.1 compatibility pin, a real-Herdr stale-cleanup state assertion, and the Bash 3.2 session-start concurrency fixture referencing unavailable `BASHPID`.
The pull-request checks remain the authoritative clean-environment acceptance gate.
