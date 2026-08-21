# Grokbots Discord rooms

This guide stages durable Discord rooms for the eight existing Grokbots seats through the official myfirstmate Relay.
It does not create a ninth seat, a Discord connector, an orchestrator, or a memory authority.
[`configuration.md`](configuration.md#relay-env) remains the owner of Relay activation and reply mechanics.
`bin/fm-discord-rooms.sh --help` owns the address and latency-receipt formats.

## Working path

The live capability audit on 2026-08-21 found one active Composio Discord user OAuth connection.
That connection can identify its user and list the user's guilds, but its Discord toolkit has no action for creating a guild, channel, thread, invite, or message.
The separate Composio Discord Bot toolkit has those actions but has no connected account.
An authenticated read-only proxy request for the existing guild's channels also returned `401 Unauthorized`, confirming that the user OAuth grant is not a hidden bot-management path.
Composio therefore remains discovery evidence only and is not a room connector or wake path.

The working path is the existing Relay plus the seat-message action already used by the live Grokbot runtime:

```text
Jason directly mentions @myfirstmate in a room or job thread
  -> official myfirstmate Discord service
  -> existing authenticated Relay poll
  -> x-mention wake in Firstmate
  -> deterministic room address
  -> existing message-to-seat action
  -> the named existing seat wakes and replies
  -> existing Relay reply returns to the originating Discord thread
```

The repository already proves that a Discord Relay object is retained whole, produces an `x-mention` wake once, keeps Discord reply context, and returns bounded replies through the original opaque request binding.
The active Grokbot operating prompt already defines seat delegation as messaging an existing crewmate, which wakes that seat and returns its result.
This room layer joins those two owners without replacing either one.

The broken Discord Settings plugin is not part of this path.
No direct Discord bot token, webhook, Gateway client, Composio connector, Rakazo process, or new polling loop is added.

## Server and room plan

The live user OAuth audit proved that Jason owns an existing server named `Continuum server`.
Use that server rather than creating another server or memory authority.

| Discord surface | Durable purpose | Wake route |
| --- | --- | --- |
| `#fleet` | Shared roster, short fleet notes, and routing | `fleet:` wakes Eleusis as the roster desk |
| `#projects` | One thread per job, matching the Slack `#projects` convention | `job/<job-id>/<seat>:` wakes one explicitly named seat |
| `#continuum-guest` | Guest door into Continuum conversation | `continuum-guest:` wakes Flux |
| `#mailbox-eleusis` | Questions and notices for Eleusis | `mailbox/eleusis:` |
| `#mailbox-flux` | Questions and notices for Flux | `mailbox/flux:` |
| `#mailbox-spur` | Questions and notices for Spur | `mailbox/spur:` |
| `#mailbox-chronicle` | Questions and notices for Chronicle | `mailbox/chronicle:` |
| `#mailbox-thor` | Questions and notices for Thor | `mailbox/thor:` |
| `#mailbox-qa-engineer` | Questions and notices for QA Engineer | `mailbox/qa-engineer:` |
| `#mailbox-ledger` | Questions and notices for Ledger | `mailbox/ledger:` |
| `#mailbox-argon` | Questions and notices for Argon | `mailbox/argon:` |

Every actionable post directly mentions `@myfirstmate` and begins with the route shown above.
Direct mention is the event trigger.
An ordinary room message without the mention is durable Discord history but does not wake an agent.

`#fleet` does not automatically fan out to eight seats.
Eleusis sees the event first and routes only what needs another seat, avoiding eight simultaneous replies and a new roundtable orchestrator.
`#continuum-guest` does not import Discord into Continuum.
Continuum stays the source of truth, and Flux is the only guest door.

Mailboxes are not job homes.
A mailbox can notify a seat, ask a short question, or point at a job thread.
When work becomes a job, create or use its single thread under `#projects` and continue there.
The task record, project files, Continuum, and each seat's existing memory retain their current authority.

## One owner activation sitting

All account, server, installation, and credential actions below form one owner gate.
Jason performs this sitting himself.
An agent must not sign in, authorize the application, handle the pairing token, or ask Jason to paste a secret into chat.

### Exact click path

1. Open Discord while signed into the owner account for `Continuum server`.
2. Open `Continuum server`, create a category named `GROKBOTS`, and make it private from `@everyone` by disabling `View Channels` on the category.
3. Create the eleven text channels listed in the room plan inside that category.
4. In `#projects`, create one normal message thread for each current job and name each thread with its existing job id.
5. Open `https://myfirstmate.io`, choose Discord sign-in, and confirm that the account shown is the same owner account.
6. Use the authenticated dashboard's Discord install control, choose `Continuum server`, and inspect the authorization screen before approving it.
7. Approve only the scopes and permissions in the least-privilege list below.
8. Return to Discord, open the `GROKBOTS` category permissions, add the installed myfirstmate bot role, and allow the listed room permissions only.
9. Return to the myfirstmate dashboard and copy the pairing token directly into `/home/jason/kun-agent-workspace/.env` with a local editor as `FMX_PAIRING_TOKEN=<token>`.
10. Close the editor without placing the token in chat, shell arguments, terminal output, screenshots, Git, or any task artifact.
11. Start a new Firstmate session so the existing locked bootstrap can activate the Relay poll.
12. Hand control back to Firstmate for the eight-seat canary and latency run.

The owner sitting ends after activation.
The eight canary posts and evidence capture are agent verification, not additional owner authorization gates.

### Least privilege

Accept the `bot` installation scope.
Accept `applications.commands` only if the official install screen shows that the service uses application commands.
The baseline server and channel permissions are exactly:

- `View Channels`.
- `Send Messages`.
- `Read Message History`.
- `Send Messages in Threads`.

Refuse `Administrator`, `Manage Server`, `Manage Roles`, `Manage Channels`, member management, moderation, voice administration, and every unexplained permission.
Do not grant a bot permission merely because Discord offers it.
If the official screen demands a permission outside the list, stop the sitting and record `UNKNOWN_INSTALL_PERMISSION_<name>` rather than approving it.

The bot does not need `Create Public Threads`, `Attach Files`, or permission to create the category or channels because Jason creates the rooms and job threads and this canary uses text only.
That is why the design complies with the prohibition on `Manage Channels`.

## Event wake and measurement

For each seat, post one harmless nonce in the matching mailbox:

```text
@myfirstmate mailbox/<seat-slug>: wake probe <nonce>; reply with the nonce only
```

Capture three timestamps from the live surfaces:

- `discord_event_ms` from the Discord message event.
- `relay_offer_ms` when the preserved Relay request first produces the `x-mention` wake.
- `seat_seen_ms` from the named seat's received-message or run receipt.

Record all eight in one private receipt and run:

```sh
bin/fm-discord-rooms.sh latency <receipt.json>
```

The calculator rejects a missing seat, a duplicate seat, backward timestamps, or a proof label other than `live` or `fixture`.
Any receipt containing fixture evidence remains labeled `fixture`.
Do not report designed cadence, a test-fixture duration, or one seat's observation as another seat's live latency.

## Test post

After the owner sitting, use this first harmless post in `#mailbox-eleusis`:

```text
@myfirstmate mailbox/eleusis: DISCORD-GROKBOTS-CANARY-1; reply with this marker only
```

The proof is the Discord post, the corresponding Relay request, Eleusis's received-message receipt, and the reply in the same Discord thread.
Do not treat the prepared text above as a live post.

## Named unknowns before activation

Keep these names unchanged in the activation report until live evidence replaces them:

- `UNKNOWN_LIVE_ROOM_IDS`.
- `UNKNOWN_OFFICIAL_INSTALL_SCOPES_AND_PERMISSIONS`.
- `UNKNOWN_PAIRING_TOKEN_PRESENT`.
- `UNKNOWN_LIVE_MESSAGE_TO_GROKBOT_SURFACE`.
- `UNKNOWN_ELEUSIS_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_FLUX_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_SPUR_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_CHRONICLE_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_THOR_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_QA_ENGINEER_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_LEDGER_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_ARGON_DISCORD_WAKE_LATENCY_MS`.
- `UNKNOWN_LIVE_TEST_POST_RECEIPT`.

The server name is live evidence from the active user OAuth audit, but no invite URL or requested room id is available.
Do not infer any room or invite from the earlier Rakazo roundtable record.

## Failure boundaries

If Relay does not expose enough live context to return to the originating room or thread, keep the request in Firstmate and report the binding as unavailable.
Do not guess a channel id.
If the current Firstmate runtime cannot invoke the existing message-to-Grokbot action, reply that seat delivery is unavailable and retain the named unknown.
Do not substitute Rakazo, start its ports, create a stand-in seat, or synthesize a seat answer.
If a seat does not respond to its canary, record that seat's failure independently and continue the other seven probes.
