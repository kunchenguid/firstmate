# Grokbots Discord rooms verification

Date: 2026-08-21.

## Active claim

The existing myfirstmate Relay can carry explicit Discord room addresses without a second Discord connector, and the local helper resolves only the eight existing Grokbots seats and validates complete eight-seat latency receipts.
The live account audit proves that Jason owns an existing Discord server named `Continuum server`.
The audit resolved the captain-supplied guild id `1539100295932551189` to that server, so the room plan targets it and does not create another guild.
The requested room ids, application installation, live seat-delivery surface, live test post, and live per-seat latency remain owner-gated unknowns until the activation sitting completes.

The operator plan and owner gate are in [`../discord-grokbots-rooms.md`](../discord-grokbots-rooms.md).
The address and receipt mechanics are owned by `bin/fm-discord-rooms.sh --help`.

## Evidence classes

| Claim | Evidence class | Current result |
| --- | --- | --- |
| Relay is inert without a pairing token | Existing hermetic Relay tests | Proven by test |
| A Discord Relay mention is stored whole and emits one `x-mention` wake | Existing hermetic Relay tests | Proven by test |
| Discord replies retain the originating opaque request binding and Discord budget | Existing hermetic Relay tests | Proven by test |
| Room addresses resolve only to Eleusis, Flux, Spur, Chronicle, Thor, QA Engineer, Ledger, or Argon | New hermetic route tests | Proven by test |
| Fleet routes to Eleusis and Continuum guest routes to Flux | New hermetic route tests | Proven by test |
| A latency receipt requires all eight seats exactly once and monotonic timestamps | New hermetic receipt tests | Proven by test |
| Fixture latency cannot be reported as live | New hermetic receipt tests | Proven by test |
| Existing Discord server is available | Live Composio user OAuth audit | `Continuum server` is visible and owner-held |
| Active user OAuth can create or inspect rooms | Live tool-catalog and read-only proxy audit | Refuted: no mutation tools, and channel proxy returned `401 Unauthorized` |
| Requested rooms exist | Owner activation required | `UNKNOWN_LIVE_ROOM_IDS` |
| Official bot is installed with the permitted scope | Owner authorization required | `UNKNOWN_OFFICIAL_INSTALL_SCOPES_AND_PERMISSIONS` |
| Each live Grokbot receives the addressed event | Live seat-delivery surface required | `UNKNOWN_LIVE_MESSAGE_TO_GROKBOT_SURFACE` |
| Per-seat end-to-end latency | Live Discord and seat receipts required | Eight named latency unknowns remain |
| Canary post and reply landed | Live Discord credential required | `UNKNOWN_LIVE_TEST_POST_RECEIPT` |

## Local seat-delivery evidence

The current Grokbot operating prompt says that Firstmate delegates by messaging an existing crewmate, which wakes, performs the work, and messages Firstmate back.
That is the current product-level seat delivery action this room layer targets.
It is not exposed in this Codex worktree, so this change does not claim that a live Discord event reached any seat.

Separate Rakazo evidence proves an analogous `trigger=peer` wake for QA Engineer and a digest-backed response from Ledger.
Rakazo is paused and is not the Grokbot runtime, so those records are supporting fixture evidence only.
They are not reused as live Discord or Grokbot latency proof.

## Commands

Run from the isolated Firstmate worktree:

```sh
bash tests/fm-discord-rooms.test.sh
bash tests/fm-x-mode.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

The new suite uses only temporary JSON fixtures and `jq`.
It makes no network call and reads no credential.
The existing Relay suite uses fake transport and temporary homes.

## Fixture receipt result

The fixture covers all eight seats with distinct monotonic timestamps.
The calculator returns both event legs and total latency while preserving `proof: fixture`.
The rejection cases cover a missing seat, a duplicate seat, backward timestamps, a non-Discord message, an unknown ninth seat, and an empty addressed body.

No fixture number is a live latency measurement.

## Activation report template

After the owner sitting and eight-seat probe, replace the unknowns in the private task report, not in this maintained verification page:

1. Server name or invite URL.
2. Seats actually reached.
3. Per-seat Discord-to-Relay, Relay-to-seat, and total latency.
4. One test post and its reply receipt.
5. Whether the owner authorization gate existed and which one-sitting path completed it.

Separate `PROVED LIVE` entries from `PROVED BY FIXTURE` entries.
Never infer a live value from configuration or a designed cadence.
