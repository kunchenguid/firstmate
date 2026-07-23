# Active Pi session bridge

Status: P0 conformance foundation only.

The tracked extension at `.pi/extensions/fm-primary-telegram-bridge.ts` adopts normalized external turns into the already-running interactive Firstmate Pi session.
It does not poll or call Telegram, own a token or destination, launch another Pi process, type into a terminal, or create a second conversational authority.
The transport-facing protocol types and exact result codes are owned by `.pi/extensions/fm-primary-telegram-bridge-core.ts`.

## Supported seam

The bridge is pinned to installed Pi `0.80.10`.
It fails closed with `UNSUPPORTED_PI_VERSION` when loaded against another version.
An upgrade must rerun `tests/fm-telegram-pi-bridge.test.sh` before the bridge is considered available.

The extension uses Pi's supported `pi.events` bus as the focused in-process handoff and `pi.sendMessage()` as the active-session injection API.
A future private transport client binds one explicit route and session epoch through the input channel before offering turns.
An ephemeral Pi session is unavailable because it cannot prove durable adoption.
An already-bound live session refuses a competing route or epoch claim.
The bridge emits results through the output channel without knowing the external transport.

Every injected custom message contains only the normalized source label and message text in LLM-visible content.
Its `external_id`, payload hash, route ID, request ID, and session epoch are stored in custom-message details.
Pi persists those details in the session entry and omits them when converting the message for the LLM.

## Persistence boundary

Pi `0.80.10` calls extension `message_end` handlers before `SessionManager.appendCustomMessageEntry()`.
The bridge therefore records the matching event, returns from the handler, and scans the current session manager in the next macrotask.
It emits `ACCEPTED` only when that post-event scan finds exactly one matching persisted marker.
The return from `pi.sendMessage()` and the pre-persistence event are never acceptance evidence.

Exact matches return `DUPLICATE`.
Missing markers return `NOT_FOUND` during reconciliation.
Hash mismatch and multiple markers return `AMBIGUOUS` with a quarantine reason.
Wrong epochs return `STALE_EPOCH`.
A second offer while one adoption awaits persistence returns `BUSY`.
An unbound, replaced, unsupported, or shut-down session returns `UNAVAILABLE`.

Ordinary messages always use `followUp`.
When the active session is busy, the bridge uses `steer` only for an authenticated correction whose `supersedesExternalId` is the exact external turn currently active in Pi.

`session_shutdown` removes the input listener, clears the active route, pending adoption, current external turn, and every session-bound closure before emitting unavailability.
The next `session_start` creates a fresh bridge instance around the new session manager and requires a fresh explicit route and epoch binding.
Reload, replacement, fork, and restart therefore cannot reuse the prior session object.
Any post-event result from a prior generation is ignored, so a stale acknowledgement cannot revive a replaced or shut-down session.

## Conformance evidence

Evidence date: 2026-07-23.

Installed version command:

```text
$ pi --version
0.80.10
```

Installed source fingerprints:

```text
$ shasum -a 256 "$PI_PACKAGE_DIR/package.json" "$PI_PACKAGE_DIR/dist/core/agent-session.js" "$PI_PACKAGE_DIR/dist/core/session-manager.js" "$PI_PACKAGE_DIR/dist/core/messages.js"
49af43fe2618c1deb2558267add98fbbc85ab6828e16ec4ba2b54be6a9b688fe  package.json
ba869d5d61530cbb2b1653044f470c97da161777c4d5ceb538d03e5f6e713fc8  dist/core/agent-session.js
879e80cc6e2371e4b06887e6fb041c323ba4e86f7687bfdac6474c9f61486112  dist/core/session-manager.js
a4e4865e343bf87f8078f75ff179a2a77cd7c2700cf8473476bd4dc5ed36adb6  dist/core/messages.js
```

Focused conformance command:

```text
$ tests/fm-telegram-pi-bridge.test.sh
ok - Pi bridge lifecycle and crash-boundary conformance
ok - installed Pi 0.80.10 active-session adoption conformance
```

The suite uses Pi's installed SDK, extension loader, event bus, faux provider, real `AgentSession`, and file-backed `SessionManager`.
It proves idle injection, busy follow-up, correction steer, single-flight busy refusal, identical rapid text with different external IDs, pre-event and post-persistence crash recovery, restart reconciliation, forced compaction, replacement isolation, stale acknowledgement refusal, and duplicate or mismatch quarantine.

The test observes zero matching entries from the installed Pi `message_end` listener and exactly one matching entry before accepting the bridge result.
It also proves the persisted identifier is absent from the converted LLM message.

## Scope boundary

This P0 proof does not implement the Telegram daemon, polling, durable transport store, live relay, cleanup, activity, lifecycle communication, decisions, buttons, or the required Claude Code adapter.
The captain's full Telegram scope and Pi or Claude parity remain required end-state work in their independently gated slices.
This proof authorizes the active Pi seam for the pinned version only and does not claim end-to-end exactly-once execution.

If a future Pi version cannot preserve this ordering and full-entry reconciliation, the smallest acceptable fallback is a generic atomic Pi API shaped like `acceptExternalTurn({ externalId, payloadHash, content, deliverAs })`.
That fallback must remain transport-neutral and must not be simulated with a headless session, RPC subprocess, or terminal automation.
