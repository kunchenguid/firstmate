# Discord mention watch adapter plan

Status: APPROVED by Firstcrew on 2026-10-03; implementation in progress.
Task: `discord-mention-watch-adapter-20261002`.

## Goal

Add a Firstmate `bin/` process-event adapter that watches Discord for mentions of Claude bot user `1532391545356161094` and returns captured mention evidence through the existing durable process-event wake path.

## Existing contracts

- `bin/fm-procevent.sh` owns source registration, background polling, durable capture, wake publication, replay, and handled acknowledgement.
- Existing process-event adapters register a bounded blocking source command and provide adapter-owned result classification and lifecycle decisions.
- Self-hosted Discord configuration already reads `FM_DISCORD_BOT_TOKEN` and polls configured channel IDs; `1551134713727426570` is currently the default excluded channel due to a gajae-way collision safeguard.
- The adapter must not execute message content or treat Discord text as authority. It only captures bounded evidence for Firstmate to handle.

## Proposed implementation

1. Add one `bin/fm-procevent-discord-mention.sh` adapter with explicit `arm`, `ensure`, `poll`, `classify`, `terminal`, and `source-id` commands following the existing built-in adapter pattern.
2. Reuse the approved self-hosted Discord bot token source and Discord REST conventions; keep credentials in the existing environment and never print or persist them.
3. Poll only the Firstcrew channel `1551134713727426570` by default, matching mentions against bot user ID `1532391545356161094`, excluding bot-authored messages, and using a durable per-channel cursor so each captured result advances only after safe ingestion.
4. Emit bounded structured result evidence containing message, channel, guild, author, and timestamp identifiers plus sanitized content needed for Firstmate context. Preserve the runner's at-most-capture durability wording; do not claim lossless or exactly-once Discord delivery.
5. Register and reconcile the source through `bin/fm-procevent.sh`; do not add an independent watcher or bypass its durable wake path.
6. Add focused adapter tests for a matching mention, wrong bot ID, wrong channel, bot-authored message, empty poll, pagination/cursor progression, duplicate replay, API/auth/timeout failure, and bounded output.
7. Update the process-event operating documentation and verification record with the adapter's arm/disarm procedure, channel scope, credential source, wake handling, and known Discord polling limits.

## Decisions required before implementation

- **Scope:** channel-only (`1551134713727426570`); guild-wide watching is out of scope.
- **Excluded-channel collision:** Firstcrew approved this channel for this adapter only; all other existing exclusions remain.
- **Mention predicate:** human-authored messages that mention `1532391545356161094`; bot-authored messages, replies without a mention, and DMs are excluded.
- **Polling start point:** first arm records the latest message and ignores earlier history.
- **Plan owner:** Firstcrew approved this plan unchanged.

## Completion evidence

- Focused tests prove matching, filtering, cursor advancement, replay behavior, and failure capture through the public adapter/runner interface.
- `bin/fm-lint.sh` passes for changed shell scripts.
- Process-event verification docs describe the tested adapter contract and its limits.
- A Firstmate review/PR records the implementation; no live Discord poll is armed as part of development verification.
