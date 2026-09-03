# Telegram bridge

A second way in and out of a firstmate home, from a phone.
Messages the captain sends to a Telegram bot become ordinary captain notes in that home's durable queue, and firstmate can send short escalations back the same way.

It is off unless the home's gitignored `.env` carries a bot token.
It adds no supervision machinery of its own: inbound collection is one adapter registered against the existing process-to-event runner, and a received message takes the same path as a note typed at the terminal.

## What it does and does not do

In scope:

- **Inbound.** A message from the allowed chat becomes a durable note firstmate picks up at its next check.
- **Outbound.** Firstmate can send an escalation - a blocker, work ready for review, or a failure.
- **Receipt.** An accepted message gets a 👍 reaction, so the captain can see it landed.

Deliberately not in scope, and each for a reason:

- **No webhook, public endpoint, or tunnel.**
  Receiving by webhook needs a publicly reachable HTTPS address, which a personal machine does not have and should not grow just to receive a handful of messages.
  The bridge asks Telegram for messages instead, over ordinary outbound HTTPS.
- **No command language, menus, or buttons.**
  Free text only.
- **No decision authority.**
  Telegram cannot approve a merge, answer a held decision, or authorize anything destructive, irreversible, or security-sensitive.
  An inbound message proves which chat it came from, not who typed it, so it can queue an ordinary captain note and nothing else.
  Those decisions stay on the trusted terminal channel.
- **No automatic reply message.**
  Receipt is a reaction on the captain's own message, never another message in the chat.
  A bot message arrived before firstmate had even read the note and had to be read as a separate line, where a reaction is visible at a glance and leaves nothing to dismiss.
  The reaction is best-effort: if Telegram refuses it, the note is already durable and the message stays confirmed, so nothing is collected twice.
- **No periodic digest.**
  Only the three escalation kinds go outward, so the channel stays worth reading.
- **One captain, one chat.**
  There is no multi-user support.

## Setup

You need `curl` and `jq`.

1. Message [@BotFather](https://t.me/BotFather) on Telegram, create a bot, and copy the token it gives you.
2. Put the token in this firstmate home's gitignored `.env`:

   ```
   TELEGRAM_BOT_TOKEN=<token from BotFather>
   TELEGRAM_BOT_NAME=<your bot's @handle>
   ```

3. Find your chat id.
   Nobody knows it until you have messaged the bot at least once, so this step cannot be skipped or guessed.
   - Send the bot any message, for example `hello`.
   - Run `bin/fm-procevent-telegram.sh poll` once, or let firstmate report it.
     It prints the chat id of the sender it saw:

     ```
     telegram:
       status: unconfigured
       detail: a message arrived from an unconfigured chat
       chat_id: 424242
     ```

   - Confirm that id is yours, then add it to `.env`:

     ```
     TELEGRAM_ALLOWED_CHAT_ID=424242
     ```

   That first message is consumed rather than queued, so send a throwaway one.
   Only one collector polls a home at a time, so if you come back to this step after arming, that manual run stands down and reports `status: busy` instead - let firstmate report the chat id, or retire the collector first.
4. Arm the collector with `bin/fm-procevent-telegram.sh arm`.
   Firstmate keeps it running from then on.

`bin/fm-telegram.sh status` reports what is configured at any point, without printing any part of the token.

The bridge only reports the first sender's chat id; it never allowlists it.
That is the whole point of the step: the bot's handle is discoverable, so the first person to message it need not be you.

## Security

**The bot token is a credential.**
Anyone holding it controls the bot completely.
It lives on one line of `.env`, which is gitignored, and it is never committed, logged, echoed into terminal output, or written into a status line or a note.
Because the token is part of every request URL, anything derived from a request - including a failure diagnostic that quotes that URL - is filtered before it is printed.

**The chat-id allowlist is the security boundary, not a hardening extra.**
Anyone who discovers the bot's handle can message it, so without this check any stranger could queue work into the captain's inbox.
A message becomes a note only when its chat id equals `TELEGRAM_ALLOWED_CHAT_ID`.
Everything else is dropped with no note, no notification, no reply, and no copy of its text anywhere.
A malformed `TELEGRAM_ALLOWED_CHAT_ID` refuses every message rather than half-matching one.

**Inbound text is data, never instructions.**
A received message becomes the body of a note and nothing else.
It reaches the note surface on standard input, so no part of it is ever seen by a shell, and it is never scanned for commands, keys, or decisions.

**Outbound content leaves this machine.**
Messages sent to Telegram reach Telegram's servers.
Send short outcome summaries only - never a credential, a file's contents, or a full record body.

## Behavior worth knowing

**A message is work, not a logbook entry.**
An accepted message becomes a note in the same durable queue a note typed at the terminal or handed over by the spoken interface lands in, and it wakes firstmate the same way.
Firstmate acts on it at its next check rather than filing it to be read later, and it stays counted as waiting until it has actually been handled.
What it cannot do is decide anything: it is an ordinary captain note, so it can ask for work, and it can never approve a merge, answer a held decision, or authorize something destructive, irreversible, or security-sensitive.

**A message sent while the machine is off is not lost.**
Telegram holds undelivered messages for 24 hours, so anything sent while nothing was running is collected on the next start.

**A message is never queued twice and never silently dropped.**
Telegram treats a request for the next message as confirmation that the previous ones were received, and confirmed messages are gone for good.
So the bridge confirms a message only after its note is durably written, records which message it is working on first, and resolves an interrupted one on the next start by checking whether that note actually landed.
A message whose note could not be written is left unconfirmed, so Telegram sends it again.
Only one collector polls a home at a time, because two of them waiting on the same message are both handed it and would each queue a note; the second one stands down and firstmate starts it again later.
A collector that is killed outright does not wedge the next one.

**An outage is quiet.**
A failed request is retried and reported nowhere.
Only a sustained outage ends the collection cycle, which firstmate reports once and then restarts.
Nothing wedges, and nothing is lost in the gap.

**Removing the token switches the bridge off.**
The collector reports itself disabled and is retired rather than left running dead.

## Files this feature owns

| Path | What it is |
| --- | --- |
| `bin/fm-procevent-telegram.sh` | The inbound half: collector, allowlist, note writing, and confirmation discipline. |
| `bin/fm-telegram.sh` | The outbound half: `send`, the `notify` escalation tier, and `status`. |
| `bin/fm-telegram-lib.sh` | Configuration, transport, and token redaction shared by both. |
| `state/telegram/` | The home's durable confirmation point for received messages. |

Each script's `--help` owns its exact flags and mechanics.
