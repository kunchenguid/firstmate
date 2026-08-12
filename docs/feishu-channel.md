# Feishu channel

The Feishu channel is an opt-in private captain channel for a Firstmate session running in Pi.
It keeps one Feishu P2P conversation and the local TUI on the same live Pi process and the same in-memory `AgentSession`.
It never starts another Pi process, RPC process, SDK AgentSession, model, tool runner, or session-file writer.
The network side uses the official `@larksuiteoapi/node-sdk` long-connection client and does not expose a webhook.

## Supported scope

The MVP allows one exact Feishu user in one exact P2P chat.
Inbound supports plain text only.
Outbound mirrors every finalized non-empty Assistant text persisted after the binding boundary, regardless of whether Feishu, native TUI, watcher, turn-end, or another normal Pi source caused the turn.
The exact fixed response `Captain, shipshape.` stays local and is never pushed.
Mirroring adds no classification, summarization, rewriting, or second model call.
Group chats, cards, attachments, webhooks, multi-home routing, remote slash commands, and attachment downloads are unsupported.
Slash-like Feishu text is ordinary user content and cannot invoke a Pi slash command or prompt template.

Feishu and native TUI input use the same normal Pi tool path.
The channel adds no Feishu-specific tool restriction, local confirmation command, or alternate tool policy.
The ordinary Firstmate and Pi authorization rules continue to apply equally to both input channels.

## SDK and app prerequisites

The tracked dependency is the official `@larksuiteoapi/node-sdk` version recorded in `package.json` and `package-lock.json`.
Install project dependencies only in the operator's intended Firstmate checkout before enabling the optional channel.
The channel remains inert when the dependency, pairing, binding, or app credentials are absent.

Create a self-built Feishu app through the Feishu developer console outside Firstmate.
Enable bot capability and subscribe to `im.message.receive_v1` using the developer console's long-connection mode.
Do not configure a webhook URL, public endpoint, reverse proxy, or tunnel.
Grant only the app-identity scopes required by the developer console for P2P message reception, `im.v1.chat.get`, and bot message creation.

Provide credentials only in the transport process environment:

```sh
export FM_FEISHU_APP_ID='cli_...'
export FM_FEISHU_APP_SECRET='...'
```

Do not put the app secret in tracked files, `config/`, pairing state, command arguments, startup output, or status output.
The official SDK owns app-token acquisition, refresh, long-connection authentication, event decoding, and REST requests.

Compute the safe app-ID fingerprint without storing the app ID in pairing state:

```sh
node -e 'const c=require("node:crypto");const id=process.env.FM_FEISHU_APP_ID||"";process.stdout.write("sha256:"+c.createHash("sha256").update(id).digest("hex")+"\n")'
```

## Local pairing and binding

All control commands are available only in a trusted local Pi TUI that owns the verified Firstmate session lock.
No Feishu message can pair, bind, rebind, disable, or move the channel.

Pair the exact captain open ID, P2P chat ID, and app-ID fingerprint:

```text
/fm-feishu-pair <captain-open-id> <p2p-chat-id> <sha256:app-id-hash>
```

The command stores only the safe app fingerprint and the exact allowlisted user/chat identity.
It performs no authentication or network operation.

Bind the current persisted Pi session:

```text
/fm-feishu-bind
```

The binding records the complete session UUID, exact session file, session cwd, persisted header identity, canonical Firstmate home, generation, and the last persisted session entry at bind time as the outbound history boundary.
Pre-binding Assistant history is never backfilled.
An ephemeral `--no-session` session cannot bind.
The bridge activates only in trusted TUI mode while the current process owns the Firstmate session lock and every stored identity matches.

Use `/fm-feishu-rebind` only when deliberately moving the channel to the current exact persisted session.
Rebinding first waits for the verified transport owner to stop, then increments the generation and reloads the bridge so no old-generation SDK send can race the new binding.
Pending events may retarget only when none already belongs to the prior Pi native queue.
Use `/fm-feishu-disable` to wait for the same verified graceful stop before disabling the pairing.
Use `/fm-feishu-status` for the detailed local identity and queue view.

## Direct SDK long connection

`bin/fm-feishu-transport.sh start` starts one dedicated no-Agent transport after pairing, binding, dependency, and environment credentials are present.
`bin/fm-feishu-transport.sh stop` signals only the exact owner process after home, module, nonce, PID incarnation, and process-title verification.
`bin/fm-feishu-transport.sh restart` performs the same controlled stop followed by start.
`bin/fm-feishu-transport.sh status` prints a body-free and identifier-free health summary.

The transport creates one SDK `WSClient` and one `EventDispatcher` for `im.message.receive_v1`.
It uses one SDK `Client` for P2P chat verification and canonical outbound `message.create` calls to the bound chat.
It verifies the environment app ID against the paired fingerprint and verifies `chat_mode=p2p` before starting the long connection and after reconnect.
A current owner and binding generation must still match before any outbound claim or inbound publication.
A second transport owner for the same Firstmate home is refused.

The SDK event callback performs only bounded validation and private durable publication.
It does not wait for Pi, execute a model, execute a tool, or send an outbound response.
An accepted callback validates the authenticated app identity when present, sender type and open ID, exact chat and P2P mode, text message shape, body size, active binding, and capacity before durable handoff.
Unauthorized, malformed, unsupported, duplicate, overlength, or resource-pressure events never reach Pi.
A durability failure throws from the callback so the SDK can report failure to Feishu rather than acknowledging memory-only receipt.

The SDK owns reconnect and protocol replay behavior.
Firstmate does not poll message history or invent a second replay protocol.
Replayed `event_id` or `message_id` values converge through the durable indexes.
A replay that reaches the adapter after another accepted event receives a later local sequence because local durable commit order remains the audit order.
The channel does not claim source-to-disk exactly-once delivery or recovery of an event the platform never redelivers.

## Pi native queue boundary

Native TUI input is never intercepted, transformed, durably copied, acknowledged, or reinjected by the Feishu extension.
Local images remain entirely Pi-owned.
Watcher and turn-end operational prompts call Pi's supported `sendUserMessage(..., { deliverAs: "followUp" })` path directly.
They do not enter Feishu state.

An accepted Feishu event remains pending until the exact bound live Pi session and current transport identity are available.
The bridge records one owner-fenced submission attempt and calls `sendUserMessage` with Pi's native `steer` mode.
While Pi is busy, each accepted Feishu message is delivered after the current Assistant turn finishes its tool calls and before the next model call.
While Pi is idle, the same call starts a normal turn immediately.
It submits every pending event once to Pi and does not wait for one event to finish before offering the next one to Pi's own queue.
Pi owns turn sequencing, steering order, and pending-message scheduling.
Firstmate does not maintain a cross-channel scheduler.

A privacy-safe leading marker carries only the derived delivery reference and binding generation.
It carries no app ID, open ID, chat ID, credential, or path.
A session restart scans exact persisted Feishu markers to settle prior native-queue submissions.
An owner change resets an unpersisted prior submission to pending instead of redirecting it to another session.
A wrong session, stale generation, lost lock, or closed live owner leaves durable input suspended.

The marker exists only to reconcile accepted inbound submission after restart and to render the authorized Feishu source badge.
It does not control outbound eligibility.
Native TUI and operational user messages remain unmodified and need no synthetic provenance.

## Outbound delivery

After Pi has persisted a finalized Assistant message, the extension scans session entries strictly after the binding's history boundary.
Each eligible entry is identified by its persisted session-entry ID, session order, timestamp, session ID, binding generation, and exact text hash.
That identity makes capture and restart replay converge without depending on source markers, originating Feishu messages, transient ordinals, or text hash alone.
Every finalized non-empty Assistant text is eligible regardless of source, including replies caused by Feishu, native TUI, watcher, and turn-end input.
The exact fixed response `Captain, shipshape.` and empty Assistant text are skipped.
Thinking blocks, partial streams, tool calls and results, user/system/custom messages, and TUI-only alerts are not mirrored.

Each eligible message is sent with SDK `message.create` to the exact bound P2P chat.
General Assistant delivery never requires or replies to an originating Feishu message.
A fixed credential-pattern match refuses the whole message before its text is persisted in channel state and raises one local alert.

Long output is split only at deterministic UTF-8, paragraph, line, or word boundaries.
A complete URL is never split or truncated.
Every chunk carries a stable SDK `uuid` derived from the durable event and chunk index.
The SDK response message ID and chat ID become the durable receipt.
A definite SDK error remains retryable with its bounded delay.
An ambiguous request-without-response retries the same UUID only inside the one-hour idempotency window and then becomes delivery uncertainty.

## Private state and diagnostics

Pairing and binding records live under `data/feishu/`.
Durable accepted events, ledgers, pending indexes, Assistant-registration intents, outbox records, attempts, receipts, quarantine records, alerts, owner identity, and health live under `state/feishu/`.
Directories are mode `0700` and files are mode `0600`.
Raw identity is never used as a filename.
Symlinks, hardlinks, partial files, malformed schemas, cross-record mismatches, and cross-home paths are rejected.

Normal startup and public status show only enabled state, binding status, generation, body-free transport phase, and aggregate counts.
They do not show credentials, app IDs, user/chat IDs, message bodies, session paths, or raw diagnostics.
A paired channel with a missing SDK dependency or missing credential environment remains stopped and reports one body-free local prerequisite.

## Verification boundary

The focused regression uses a local mock of the official SDK constructor, long-connection callbacks, reconnect callbacks, P2P chat API, and message APIs.
It performs no real authentication, network connection, app configuration, event consumption, Pi-session mutation, or Feishu send.
It proves unconfigured inertness, native TUI non-interception, direct operational follow-up delivery, native Feishu steer submission, exact session and generation fencing, all-origin finalized Assistant mirroring, pre-binding-history exclusion, exact routine-response exclusion, restart deduplication, non-Assistant exclusion, canonical bound-chat `message.create`, replay deduplication, app/chat refusal, stable outbound UUIDs, ambiguous retry handling, owner-verified stop, and absence of the former command transport path.

That mock does not prove a real app's scopes, developer-console long-connection selection, tenant policy, or production network reachability.
A future live integration check requires explicit operator authorization and disposable app credentials.
The current dated maintainer evidence is in [Feishu channel verification](verification/feishu-channel.md).
