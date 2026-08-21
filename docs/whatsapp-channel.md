# WhatsApp channel

Firstmate can already **send** the captain a WhatsApp message with `mudslide send`.
This document covers the other direction: the captain messages firstmate, firstmate wakes, reads it, and does the work he asked for.

The channel ships inert. A home that never opts in polls nothing, runs nothing, and behaves exactly as it did before.

## Shape

It is the same shape Relay uses for public mentions, for the same reasons:

| piece | Relay | WhatsApp |
| --- | --- | --- |
| poll | `bin/fm-x-poll.sh` | `bin/fm-wa-poll.sh` |
| stash | `state/x-inbox/<request_id>.json` | `state/wa-inbox/<message-id>.json` |
| check shim | `state/x-watch.check.sh` | `state/wa-watch.check.sh` |
| wake | `check:` wake carrying `x-mention ...` | `check:` wake carrying `wa-message ...` |
| skill | `fmx-respond` | `wa-respond` |

Nothing in `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh` or the away-mode daemon changes.
The check runs through the ordinary registered-custom-check path that firstmate already uses for a task's merge poll: `bin/fm-wa-setup.sh arm` writes the shim and binds it with `bin/fm-check-register.sh`, and the watcher hashes it against that binding before running it.

### An armed channel keeps a watcher running

An armed `state/wa-watch.check.sh` counts as a reason to supervise the home, exactly as Relay's `state/x-watch.check.sh` does.
Without that, an idle home with no work in flight arms no watcher at all, so the poll would never run and the captain's messages would pile up in `state/wa-inbox/` with nothing to announce them.
That is the normal case rather than the edge case: the captain messages from his phone precisely when nothing is running, to start something.

The predicate lives in `bin/fm-supervision-lib.sh` and is what the turn-end guards and the watcher-liveness warning already read.
A home that has not armed the channel has no such file and is unaffected.

### Cadence

Arming also writes `config/wa-mode.env`, the generated watcher cadence, the same way `bin/fm-bootstrap.sh` writes `config/x-mode.env` for Relay.
It exports `FM_CHECK_INTERVAL=30`, so a message is picked up within seconds instead of waiting up to the default five minutes for the next sweep.
It is the same value Relay uses, so a home running both cannot end up with two cadences that disagree.

Source it before launching a watcher process.
The emitted session-start supervision block names the file when it exists, and the arm paths that own their own launch (`bin/fm-claude-stop-autoarm.sh`, `bin/fm-turnend-guard-cursor.sh`, `.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`) source it themselves.
`bin/fm-wa-setup.sh disarm` removes it again, and the home reverts to the default cadence on the next supervision cycle.

### Deliberately not reported at session start

Relay lists a pending public commitment in the session-start digest; this channel deliberately does not list a pending inbox there.
Reporting it would mean editing session-start code, and the whole point of the shape above is that the channel stays purely additive so it can never destabilise the supervision backbone.
After a restart an undrained inbox is resurfaced by `FM_WA_REANNOUNCE` instead: the announcement marker goes stale, the next poll cycle announces the pending set again, and the wake arrives through the same path every other message uses.

One thing differs from Relay by necessity. Relay's poll makes the network call itself; WhatsApp cannot work that way, because a WhatsApp connection takes tens of seconds to establish and re-establish. So `bin/fm-wa-listen.sh` runs one long-lived connection that stashes messages as they arrive, and `bin/fm-wa-poll.sh` is a local directory read that also nudges the listener back up if it died. The poll finishes in about 25 milliseconds, far inside `FM_CHECK_TIMEOUT`.

## The connection constraint, and what was chosen

**baileys allows one live connection per credential folder.** A listener holding mudslide's session fights `mudslide send` for it.

That is not theoretical. A listener pointed at mudslide's own folder at `~/.local/share/mudslide` fails with `statusCode 405` on connect and loops reconnecting, and repeated 405 reconnects put the existing pairing at risk.

**This channel takes option (b): a second linked device with its own credential folder.**
WhatsApp permits up to four linked devices. The listener pairs its own, and keeps its credentials in `state/wa-auth/`, which is private to this home and gitignored.

The consequence that matters: **`mudslide send` is never touched.** Arming, disarming, restarting or breaking the listener cannot affect sending, because they do not share a credential folder, a process, or a device registration. Outbound stays exactly where it was.

The cost is one extra pairing, which only the captain can complete, because the code is entered on his phone.

The rejected alternative, option (a) - one process that both listens and sends, with firstmate handing it outbound work through a queue - would need no second pairing, but it puts the working send path behind a process that can crash, and a raw `mudslide send` typed at a shell would still collide with it. A channel addition should not be able to break something that already works.

## Which chat this is

The mudslide device is linked to the captain's own account, so the channel is his **chat with himself** - "Message yourself" on his phone.
He types there, his linked devices see it, and firstmate's replies land in the same place. No group, no third party, nothing to route.
A second configured phone is a separate account and reaches firstmate as an ordinary inbound message instead; see [More than one captain number](#more-than-one-captain-number) for how far that is proven.

That does mean everything on this chat is `fromMe`, including firstmate's own replies coming back. Two independent guards stop firstmate reading its own words as new instructions:

1. **Sender device.** WhatsApp numbers devices: the captain's phone is device `0`, mudslide is a linked device, and the listener is another. Only device `0` is accepted by default. baileys drops the device from the message key, so the listener reads it from the raw stanza and correlates by message id.
2. **Outbound digest.** `bin/fm-wa-send.sh` records a digest of every message it sends under `state/wa-sent/`, **one marker per recipient**. If matching text arrives back, the listener consumes one marker and drops the message.
   A reply goes to every configured number, each delivery echoes back separately under its own message id, and the listener spends exactly one marker per echo, so a single marker would be spent by the first echo and leave the rest unguarded.
   Each marker is keyed to the send that wrote it as well as to the text, so a second reply of identical words inside the window adds its own markers rather than overwriting the first reply's - byte-identical replies are ordinary traffic here.
   A redelivery of one echo is caught by the durable per-message marker instead of spending a second digest, because WhatsApp delivers the same message more than once.
   The digest is checked before the sender-device filter, so firstmate's own reply consumes its own marker on the way in rather than being rejected as mudslide's device first and leaving the marker behind.
   An echo returns within seconds, so a digest older than ten minutes is swept instead of matched.
   Otherwise the first time the captain himself typed something firstmate once said, his instruction would be swallowed as an echo.
   A send that fails drops its own digest for the same reason: nothing went out, so nothing can come back.
   On a partial delivery only the phone that missed it drops its marker, because the phones that got the message will still echo it back.
   It also reports what mudslide said, so a reply that never reached the captain names its own cause instead of failing silently.

If the captain also wants to command firstmate from WhatsApp Web or Desktop, add those device numbers to `FM_WA_ALLOW_DEVICES`. Do **not** add the device mudslide uses; that is firstmate's own outbound and would loop.

### When the channel is configured correctly and still receives nothing

**Check the device filter first.**
It is the last gate a message passes, after every identity check, and it is the most likely reason a correct configuration still leaves `state/wa-inbox/` empty.

`FM_WA_ALLOW_DEVICES` defaults to `0` on the assumption that the captain's phone is device `0`.
That is not reliable: found live, a real phone was sending as device `22` and later as device `2`.
Both were silently discarded, and from the phone that is indistinguishable from being ignored.

The listener log names the device on every refusal, so read it rather than guessing:

```sh
grep 'is not an accepted captain device' "$FM_HOME/state/wa-listener.log" | tail
```

Each line reads `ignored (device N is not an accepted captain device) <id>`.
Add the `N` the captain's own messages are arriving on to the list and restart the listener:

```sh
FM_WA_ALLOW_DEVICES=0,2,22
```

```sh
bin/fm-wa-listen.sh restart
```

Add only the devices the captain actually types on.
`*` accepts every device including mudslide's, so it leans the whole echo guard on the outbound digest alone; it exists for a host whose baileys exposes no raw stanza hook, not as a shortcut past this.

If the log shows no such lines at all, the message is being refused earlier - `ignored (...)` names which rule - or is not reaching the listener at all, and `bin/fm-wa-listen.sh status` is the next thing to read.

**Check that the configuration reads the way it is written.**
A key whose line cannot be parsed, or whose value is not valid for it, falls back to its documented default - and the default for `FM_WA_ALLOW_DEVICES` is the one that drops the captain's own phone.
That is reported rather than taken silently, so `bin/fm-wa-listen.sh status` names it:

```sh
bin/fm-wa-listen.sh status | grep 'config problem'
```

The same fault reaches firstmate as a `wa-channel-error` naming the key, once rather than on every cycle, and again if it is fixed and later comes back.

**Then check the two refusals that can hide a real message.**
Both are logged under their own reason precisely so they can be grepped apart from routine traffic.

```sh
grep -e 'no phone number' -e 'our own outgoing message' "$FM_HOME/state/wa-listener.log" | tail
```

`ignored (LID chat carries no phone number to check against the configured captains) <jid>` means the server sent a `@lid` chat with no `sender_pn` to resolve it by, so there was nothing to check against `FM_WA_CAPTAIN`.
That is refused rather than assumed, and there is no configuration that widens it.

`ignored (our own outgoing message in a chat that is not the captain's own) <jid>` is usually just firstmate's own reply coming back on one of its deliveries, which is routine.
It is also, however, exactly what a message **from the captain** looks like when the listener does not recognise the chat as his - so if this line names a chat he was typing in, it is a dropped instruction, not an echo.
Compare the `<jid>` against his own number and against `FM_WA_CAPTAIN`: a `@lid` chat that is neither the self-chat nor resolvable to a configured number lands here, and the fix is to configure the number the chat resolves to rather than to widen the identity rules.
`ignored (our own outgoing message, already accounted for)` is the same message arriving a second time and is always routine.

### His two identities

One account, two identifiers, and WhatsApp uses both. The same self-chat arrives addressed to his phone number (`<digits>@s.whatsapp.net`) on some deliveries and to his **LID** (`<digits>@lid`) on others.
That is not a corner case: it was found live, when every real message he sent arrived under his LID, was refused as somebody else's chat, and left `state/wa-inbox/` empty while he believed he was messaging firstmate.

So **both identities are accepted, and only his**.
Two shapes of message get in, and they prove themselves by opposite evidence.

**Our own chat with ourselves** is recognised from the listener's own pairing credentials (`state/wa-auth/creds.json`): the chat's user is our own phone number on a `@s.whatsapp.net` delivery, or our own LID on a `@lid` one.
Each identity is only ever compared inside its own namespace, so a LID can never be mistaken for a phone number.
That chat is necessarily `fromMe`, and the sender-device filter is what keeps discriminating there between the captain's phone and firstmate's own replies coming back.

**Any other chat** is a conversation with a second person, so it must satisfy both halves:

- The counterparty must be one of the numbers in `FM_WA_CAPTAIN`. On a `@s.whatsapp.net` chat that is the chat's own user. On a `@lid` chat the address is opaque and carries no number, so the server supplies one: baileys lifts the stanza's `sender_pn` attribute onto the message key. **The LID is never trusted on its own.**
- The message must be **inbound** - `fromMe` false. This is the load-bearing half. `sender_pn` names the **sender**, so on a message we sent it is always our own number, and checking it without also requiring the message to be inbound matched the configured list in *every* chat the captain has. That turned his private conversations with third parties into firstmate instructions, which firstmate then acted on and replied to inside them. Requiring the message to come *from* him makes that structurally impossible rather than patched around.
- A chat that resolves to no number at all is refused rather than assumed, and reported distinctly from an ordinary stranger, because that is the one refusal that can hide a real message from the captain.

Nothing else changes: groups, broadcasts, status and newsletters carry their own server suffixes and can never match either form.

`creds.me.lid` is **this account's own** LID, not the LID of whoever is in the chat, which is why it identifies the self-chat and nothing else.
A LID-addressed chat that is not the self-chat is admitted only by the number the server resolves it to, on an inbound message.

The stashed message records which identity the chat used in its `chat_identity` field, the number the chat actually resolved to in `sender`, and the direction in `from_me`, so a record from a second phone names that phone rather than whichever number happens to be listed first.

`FM_WA_SELF_LID` overrides the LID the listener treats as **this account's own**, which is how `tests/fm-wa-channel.test.sh` drives the self-chat path with an invented LID rather than committing a real identity.
It is an environment variable rather than a `config/whatsapp.env` key on purpose: it is a test input, not a supported way to configure the channel, and it is deliberately not plumbed through `bin/fm-wa-listen.sh`.
**Never set it to another party's LID, including the second phone's.**
Doing so tells the listener that party's chat is its own, and the rules invert exactly: that phone's real messages arrive inbound and are refused, while firstmate's own replies into the chat are `fromMe` and are read as fresh instructions - a self-reply loop running over the captain's own account.
A second phone needs no LID setting at all; it gets in by its configured number, on the inbound rule above.

## Media, and what is not read yet

A photo, voice note, sticker, video or document sent with no caption is stashed like any other message, with empty `text` and its kind in `attachment`.
It is deliberately not refused: the captain messages from his phone, and no reply at all is indistinguishable from being ignored, which is the one failure he cannot debug from his end.
Firstmate wakes on it and the `wa-respond` skill answers honestly that it cannot read the media and asks him to type it.

**Voice-note transcription is a deliberate next step, not part of this change.**
Transcribing would mean downloading and decrypting media, choosing a transcription provider, and sending the captain's private audio to it - a security and cost decision of its own, separate from getting the channel working at all.
Until it lands, a voice note reaches firstmate and gets an honest answer rather than silence.

## Setup

It needs what outbound already needed, plus nothing else: `node` on `PATH`, and a globally installed `mudslide`, whose own `node_modules` is where the listener finds the baileys package.
Discovery looks under `~/.local/lib/node_modules`, `/usr/local/lib/node_modules` and `/usr/lib/node_modules`, for either `mudslide/node_modules/baileys` or a top-level `baileys`.
A baileys installed anywhere else needs `FM_WA_BAILEYS_DIR` pointing at its package directory; without it the listener refuses to start and says so rather than half-running.

### 1. Opt in

Write the gitignored `config/whatsapp.env`:

```sh
FM_WA_CAPTAIN=447700900123
```

The file is read as data and never sourced, so nothing written in it is ever executed - but it is read the way the shell would read it, so annotating a line does what it looks like it does:

```sh
FM_WA_CAPTAIN=447700900123 # main phone
FM_WA_ALLOW_DEVICES=0,22   # phone and desktop
```

An unquoted `# ...` tail is a note and is dropped; a `#` inside quotes belongs to the value.
A key that is blank once its note is removed is blank, so retiring a number and writing down which one it was does not put it back.
A line that cannot be read that way - an unterminated quote, text after a closing one - is refused and reported rather than quietly falling back to a default, as is a value that is not valid for its key.
The report arrives as an ordinary channel fault naming the key to fix, and `bin/fm-wa-listen.sh status` prints it too.


### More than one captain number

The captain may carry more than one phone, so `FM_WA_CAPTAIN` takes a list. Replies go to all of them, unless `bin/fm-wa-send.sh --to <number>` addresses exactly one, which is how a reply follows an inbound message back to the phone it came from.
A delivery that reaches some phones and not others fails, naming the number that missed it and reporting what mudslide said, rather than passing as sent.

```sh
FM_WA_CAPTAIN=447700900123,447700900124
```

A comma always separates entries, and punctuation inside an entry is dropped, so `+44 7700 900123, 447700900124` is two numbers.
Without a comma, whitespace separates only when every piece is already a plausible number on its own: `447700900123 447700900124` is two numbers, while `+44 7700 900123` stays one.
That rule exists so a single number written the way people actually write one cannot quietly become several that match no phone, which would refuse the captain's messages while the file still looked configured.

The security property is unchanged by the list. Only the configured numbers are accepted, on either identity form, and a number absent from the file is refused even when another number in the file is present.

**The second phone reaches firstmate through this listener, and needs no pairing of its own.**
It is a separate WhatsApp account, so its message is not the self-chat: it arrives inbound, from its own number, and is admitted by the inbound rule in [His two identities](#his-two-identities) above.
Pairing links exactly **one** account - the first number in the list - and the inbound path is what carries the rest, so there is nothing to link on the second handset.

**It is verified by fixture only.**
The path is covered by tests, but no message from a real second handset has ever landed in `state/wa-inbox/`.
Until one does, treat the first configured number as the only proven way in and do not rely on the second.
If a real message from it turns out to need a linked device of its own after all, that is a second pairing and this document will say so plainly rather than implying it already works.

That single non-empty value is the switch. Everything else is optional:

| key | default | meaning |
| --- | --- | --- |
| `FM_WA_CAPTAIN` | *(none)* | captain's number, or a list of them when he carries more than one phone. The channel is on while the file names one; see [More than one captain number](#more-than-one-captain-number) and [A configuration that names no captain is not an opt-out](#a-configuration-that-names-no-captain-is-not-an-opt-out) |
| `FM_WA_ALLOW_DEVICES` | `0` | comma-separated device numbers to accept; `*` accepts any. The default is a guess and is the most likely reason a correct configuration receives nothing; see [When the channel is configured correctly and still receives nothing](#when-the-channel-is-configured-correctly-and-still-receives-nothing) |
| `FM_WA_DRY_RUN` | *(off)* | `1` records replies to `state/wa-outbox/` and sends nothing |
| `FM_WA_HISTORY_HORIZON` | `0` | seconds of backlog to accept on first run |
| `FM_WA_REANNOUNCE` | `1800` | seconds before an undrained inbox is announced again |
| `FM_WA_BAILEYS_DIR` | *(auto)* | baileys package directory, when auto-discovery misses it. A path holding no baileys package is reported as a configuration fault and auto-discovery is used, rather than surfacing later as a listener that will not stay up |

Two further inputs are read from the environment and are deliberately **not** configuration keys:

| variable | meaning |
| --- | --- |
| `FM_WA_DRY_RUN` | also accepted as a key above; in the environment it applies to one command |
| `FM_WA_SELF_LID` | overrides which LID counts as the captain's, for the tests only. It decides an access-control question, so it does not belong in an operator's environment. See [His two identities](#his-two-identities) |

### 2. Pair the listener's device

```sh
bin/fm-wa-listen.sh pair --rounds 20
```

With no number given this pairs the **first** number in `FM_WA_CAPTAIN`, because a pairing links exactly one account.
Pass a number to pair a different one.

It prints `PAIRING_CODE XXXX-XXXX`. On the captain's phone:

> WhatsApp → Settings → Linked Devices → Link a Device → **Link with phone number instead** → enter the code

A code lives about two minutes. `--rounds N` issues a fresh one automatically each time one lapses, up to `N` windows, so the captain does not have to be standing by when pairing starts. Every round prints its own `PAIRING_CODE` line.

Once the code is accepted, WhatsApp asks for a reconnect to finish the link and the pairer prints `PAIRING_ACCEPTED`.
That reconnect keeps the credentials the link just earned and asks for no new code; only a lapsed code starts a genuinely fresh round and clears the folder.

Success prints `PAIRED <jid>`.

### 3. Start the listener and arm the check

```sh
bin/fm-wa-listen.sh start
bin/fm-wa-setup.sh arm
```

`bin/fm-wa-poll.sh` restarts the listener by itself if it dies, at most once every two minutes, so a crash heals without anyone watching.

A restart is not a substitute for reporting, because some faults never heal.
The poll reports one `wa-channel-error` line instead of respawning when the device was logged out, or when three restarts have been spent without the listener settling.
A listener that is alive but whose connection has been down for fifteen minutes is reported and replaced, because only a new process can bring that channel back.
That case is why the listener touches `state/wa-listener.beat` only while it is actually connected: a live process is not a live channel.
A listener that never connects at all writes no beat, so the poll measures that fifteen minutes from when the listener was started, and a channel that has never come up is reported exactly like one that stopped working.

A connected listener is not a working one either.
The accepted-sender-device filter is fed by a raw stanza hook, and a listener that cannot attach that hook rejects every message the captain sends while still reporting a healthy connection and touching its beat.
The listener records that fault alongside its connection state, so the poll reports it as a `wa-channel-error` naming the sender devices it cannot read.
The hook is attached once per connection and a healthy socket never drops on its own, so that fault is repaired the same way a stalled connection is: the listener is stopped and replaced on the same restart budget, and the report clears once the replacement attaches the hook.
A replacement is never judged by the record its predecessor left behind: stopping a listener drops that listener's reported state along with its beat, and a starting one claims the status file as its very first act, before the baileys import that dominates a cold start.
Otherwise the pid file - which appears the instant the replacement forks - would be paired with the dead listener's last word, and a healthy replacement would be stopped for a fault it never had.

Re-pairing clears the previous link's health records, so a freshly linked device is never judged by the old one's logged-out status or restart count.

A restart the poll spawns writes the wrapper's own refusals into `state/wa-listener.log` as well, so a listener that never gets far enough to open that log still explains itself there.
It is also spawned into its own process group, so the watcher tidying up after the check never takes the listener with it.
Restart history is only cleared once no restart has been needed for an hour, so a listener that dies slowly enough to look alive on some cycles still reaches the limit instead of flapping forever.

Spent restarts stop the automatic ones, but never permanently.
The poll tries again an hour after the last attempt, so a channel held down by something transient - no network at boot, a host that was asleep - comes back on its own.
`bin/fm-wa-listen.sh restart` run by hand releases the block immediately, and the reported fault line names that command.
`start` is not the same repair: it reports a listener that is already running and changes nothing, which is why the fault line and the `wa-respond` skill both name `restart`.

Stopping a listener means signalling a pid, and a pid alone is not the listener: the pid file is removed only on a clean exit, so a crash leaves it behind and that number can later belong to any process this user runs.
Every start therefore records the identity of the process it launched in `state/wa-listener.pid-identity`, and the poll refuses to signal a pid whose identity no longer matches.
That identity is the process's own start time and command, taken through the same helper the watcher uses for its own, and it is computed with the timezone, locale and terminal width pinned, so neither a corrected boot clock nor the environment a command happens to run under can re-render it into a mismatch and leave the channel starting a second listener.
It restarts the listener instead, which is the right answer for a pid file the dead listener left behind.

An alive listener whose connection is down is stopped and replaced rather than only reported.
The replacement is spawned on the same restart budget that bounds a crash loop, so a channel that cannot recover still latches and reports instead of respawning forever.
Starting a listener drops the previous process's beat, because a beat belongs to the process that wrote it and a stale one would make the new listener look wedged from its first cycle.

The poll is also the channel's janitor.
`state/wa-listener.log` is capped at 256KB by rewriting it in place, which leaves the running listener's append handle intact.
A `state/wa-seen/` marker is pruned after thirty days, far behind any watermark that could still let an old message back into the inbox.
A `state/wa-sent/` digest is pruned after an hour, well past the ten-minute window in which it could still match an echo.
A `state/wa-outbox/` dry-run record is pruned after seven days, which is long enough to read back a test and short enough that a home left in dry-run does not grow without end.

Exactly one line comes out of a cycle.
A cycle that reports a fault does not also announce the inbox, because the two mean different things to `wa-respond` and the watcher would fold them into a single wake.
The fault is deduped, and each distinct fault is deduped against its own record, so pending messages are announced on the next cycle rather than being buried behind it.
Separate records are what keep a specific report from being replaced by a later, more general one: a listener that cannot read sender devices is replaced every couple of minutes and eventually trips the restart block too, and a shared record would leave the captain holding only the crash-loop wording, whose named repair cannot reattach a hook the listener program can no longer attach.
For the same reason an inbox entry whose name cannot be used as a message id is skipped rather than aborting the announcement: the real messages beside it are still announced, and only an inbox with nothing usable left in it reports the fault instead.
The skipped entry is still reported, on the first cycle that has no announcement to make, so it cannot sit in the inbox outliving every drain unseen.

### 4. Confirm

```sh
bin/fm-wa-listen.sh status
```

Send a WhatsApp message to yourself from the captain's phone and it lands as `state/wa-inbox/<message-id>.json` within a second or two. The next watcher cycle prints one `wa-message ...` line, which becomes a `check:` wake, which loads the `wa-respond` skill.

## Re-pairing

A linked device can be removed from the captain's phone, expire, or be logged out. The listener logs `logged out on WhatsApp` and exits.

```sh
bin/fm-wa-listen.sh unpair     # removes state/wa-auth only; mudslide untouched
bin/fm-wa-listen.sh pair --rounds 20
bin/fm-wa-listen.sh start
```

`unpair` never touches `~/.local/share/mudslide`. Nothing in this channel ever reads or writes that folder.
With the channel still on it also leaves `state/wa-inbox/` alone, so a re-pair never destroys a message the captain has sent and firstmate has not read yet; clearing that is [switching the channel off](#turning-it-off), not re-pairing it.

## Dry-run

`FM_WA_DRY_RUN=1` lets the whole loop - poll, wake, compose, would-send - run end to end without live traffic. The reply is recorded to `state/wa-outbox/<epoch>-<pid>-<n>.json` and nothing is transmitted:

```sh
FM_WA_DRY_RUN=1 bin/fm-wa-send.sh --text-file /tmp/reply.txt
```

Set it in `config/whatsapp.env` to make it the standing mode for the home, or in the environment for one command.

The record is `fm-wa-outbox-v1` JSON, encoded by `bin/fm-wa-lib.sh` rather than by `jq`, so a host without `jq` still gets valid JSON instead of a `.json` file holding raw text.

One record is written per recipient, so a reply that would fan out to both phones records both deliveries and each names the number it would go to in `to`.
The dry run is the only place the fan-out can be inspected before it reaches his phones, so a single record naming the first number would understate what a real send does.

A dry run records the same outbound digest under `state/wa-sent/` that a real send does, one marker per recipient, so the echo guard behaves identically either way.

## Security

Inbound WhatsApp text is untrusted input arriving over a network into a shell environment.

- Message text is **never** interpolated into a command. `bin/fm-wa-send.sh` takes it from a file and hands it to mudslide as one argument-vector element; nothing goes through `eval` or `sh -c`.
  That element is passed after a `--`, which ends mudslide's own option parsing, so a reply that opens with a dash - a bulleted line, say - is sent as text rather than read as an unknown option and never delivered.
- Message ids are validated against `[A-Za-z0-9._-]{1,128}`, with a leading dot excluded, before any path is built from them. The listener and `bin/fm-wa-lib.sh` hold the identical rule, so the listener can never stash an entry the poll would have to skip.
- The listener accepts only a direct chat with the captain, and only under one of the two shapes described in [His two identities](#his-two-identities): our own self-chat, proved from this listener's own pairing credentials and necessarily `fromMe`, from an accepted device; or a chat whose counterparty resolves to a configured number, on an **inbound** message only. Our own outgoing words in anybody else's chat are refused, which is what keeps his private conversations with third parties out of firstmate. Group chats, broadcasts, status, newsletters and forwarded messages are refused and logged.
- `config/whatsapp.env` is read as data, key by key, never sourced, so a stray backtick in it cannot execute.
- Credentials, the inbox, and the logs are `0600` files inside `0700` directories under the home's gitignored `state/`.
- A WhatsApp message carries the captain's ordinary authority for normal reversible work. Destructive, irreversible and security-sensitive actions still need confirmation on the trusted session channel, matching the boundary Relay already draws. The `wa-respond` skill owns that rule.

## Turning it off

```sh
bin/fm-wa-setup.sh disarm       # removes the check shim, its registration, and the cadence, and stops the listener
rm config/whatsapp.env          # every entry point becomes a hard no-op
bin/fm-wa-listen.sh unpair      # removes this device's credentials, and with the channel already off, the stashed messages too
```

That is the ordered path, and it ends with nothing of this channel left in the home.
**Order does not matter, and neither does using the commands at all.** Whichever way the channel is switched off, whatever runs next is what cleans it up: `disarm` stops the listener itself, and so does the poll cycle that finds the config confirmed gone - and that cycle clears the captain's stashed messages with it.
The one case nothing can cover is a home that removes the config and then never runs anything again - no watcher cycle, no command - because the cleanup is something that runs, not something that is written down. There, stopping the listener and clearing the messages are on the operator.

Removing `config/whatsapp.env` on its own is a complete opt-out, not a partial one, and the three things a leftover would cost are all handled by the same cycle.

The first is the check shim. An armed shim is itself a reason to keep a watcher running, so one left behind would keep the home supervised and sweeping every 30 seconds for a poll that can no longer do anything.
The first poll cycle after the config disappears therefore retires the shim, its registration, and the cadence file, the way Relay's bootstrap drops its own generated artifacts when the pairing token goes.
That is all `self_disarm` itself removes - those three generated files, never anything else under `state/` or `config/` - and it is idempotent: with them already gone it does nothing and says nothing.
A home that armed the channel and never received a message is byte-identical afterwards to one that never armed it, which `tests/fm-wa-channel.test.sh` asserts directly.

The second is the listener, and it matters more, because it is a live linked device on the captain's own personal account.
Once the shim is gone nothing polls this home again, so that same retiring cycle stops the listener it started.
`bin/fm-wa-setup.sh disarm` stops it for the same reason: disarming is what removes the cycle that would otherwise have done it, so leaving the listener up would strand it with nothing left to clean up after it.
The two are complementary, not alternatives - between them the listener is stopped whichever way the channel goes down.
Only a listener this home owns is ever signalled by either: the pid is proved against the identity recorded when it was started, and a live process that cannot be claimed is reported - on the retiring cycle, that is the last report there will be - rather than killed on a guess.
A stop is not judged by whether the pid is still visible in the instant after the signal, because a process that is terminating or waiting to be reaped still is; it is judged by waiting, briefly and with a bound, for the pid to actually go.

The third is the captain's own words.
His messages sit in `state/wa-inbox/` as plain JSON, and the records beside them say what he sent and when, so an opt-out that left them there would be claiming more than it did.
Once the listener is stopped, that same retiring cycle clears `state/wa-inbox/`, `state/wa-seen/`, `state/wa-sent/`, `state/wa-outbox/`, `state/wa-watermark`, `state/wa-poll.offered`, `state/wa-poll.error`, `state/wa-listener.log`, and the listener's health and restart records.
It clears them by explicit name, never by sweeping a directory, and never touches anything else under `state/` or `config/`.
If it had to report a listener it could not stop, it leaves those records alone and says so, because a listener still running would write the inbox straight back.

`bin/fm-wa-listen.sh unpair` clears exactly the same set, but only when the channel is already off.
That is the difference between the last step of a teardown and the middle step of a [re-pair](#re-pairing): clearing the inbox during a re-pair would destroy messages the captain has sent and firstmate has not read yet, and drop the watermark that stops WhatsApp's own redelivery from replaying old messages as new instructions.
The linked-device credentials in `state/wa-auth/` are the one thing only `unpair` removes, because getting them back costs a trip to the captain's phone.

Because the listener outlives the config that started it, `stop`, `unpair`, `logs` and `status` all keep working after `config/whatsapp.env` is gone.
`status` still prints the listener line with the channel off, so a listener left over from a partial teardown is visible rather than silent.
Only `start` and `pair` refuse, because they act as the captain and the identity they need is what was removed.

`mudslide send` keeps working through all of it.

### A configuration that names no captain is not an opt-out

Only a configuration that is definitively *gone* switches the channel off.
A permission failure, an unreadable file, the instant an editor has truncated `config/whatsapp.env` to rewrite it, a blanked `FM_WA_CAPTAIN`, and a commented-out one all leave the channel exactly as it is: the listener keeps running, the shim stays armed, and nothing is cleared.
The poll reports that no captain could be read through its ordinary deduped fault line instead, so a transient blip costs one report rather than the channel.
Conflating the two would mean a single unlucky read could stop the listener and delete the poll, after which nothing would ever poll this home again, and the captain would be messaging a home that could not answer and could not say why.

The blanked and commented cases are in that group on purpose, even though they are the likeliest deliberate attempt to switch the channel off.
The two outcomes are not symmetric: a channel that stays armed when he wanted it off is a mistake he can see and correct in one command, while a channel that goes quietly dead is indistinguishable from being ignored, which is the one failure he cannot debug from his phone.
So the deliberate off switches are `rm config/whatsapp.env` and `bin/fm-wa-setup.sh disarm`, and emptying a value is never one.
This is settled; the fault line names both switches rather than leaving him to guess.

The arming artifacts converge back for the same reason.
While `config/whatsapp.env` names a captain, every session start re-arms the check shim and the cadence if either has gone missing, exactly as `bin/fm-bootstrap.sh` re-arms Relay's while a pairing token is present.
That is one-directional: session start only ever arms, never disarms.
The practical consequence is that `disarm` keeps the channel down only until the next session start unless the config goes too - which is why `rm config/whatsapp.env` is the switch, and `disarm` is how you stop it right now.

## Files

| path | what |
| --- | --- |
| `bin/fm-wa-lib.sh` | shared config and private-artifact helpers |
| `bin/fm-wa-listen.mjs` | the baileys listener, pairer, and status reader |
| `bin/fm-wa-listen.sh` | start, stop, status, pair, unpair, logs |
| `bin/fm-wa-poll.sh` | the bounded check: inbox read plus listener nudge |
| `bin/fm-wa-send.sh` | outbound via mudslide, with dry-run and echo marker |
| `bin/fm-wa-setup.sh` | arm the check shim and the watcher cadence, and disarm both plus the listener |
| `config/wa-mode.env` | generated 30s watcher cadence; present only while armed |
| `.agents/skills/wa-respond/SKILL.md` | what to do with a message once it lands |
| `state/wa-inbox/` | pending messages, one JSON file each |
| `state/wa-seen/` | durable per-message markers, outlive the inbox file |
| `state/wa-sent/` | outbound digests for the echo guard |
| `state/wa-outbox/` | dry-run records |
| `state/wa-auth/` | this listener's linked-device credentials |
| `state/wa-listener.log` | listener log, including every refusal and why |
| `state/wa-listener.beat` | touched only while the connection is open; the poll's liveness signal |
| `state/wa-listener.pid` `state/wa-listener.pid-identity` | the running listener and the identity every stop is proved against |
| `state/wa-listener.status` | what the listener says about its own connection and the faults it hit |
| `state/wa-listener.error.*` | per-fault dedupe records, so one report is not repeated every cycle |
| `state/wa-listener.restart` `state/wa-listener.restarts` | the last restart the poll spawned, and how many it has spent |
| `state/wa-watermark` | newest accepted send time, so redelivery cannot replay old messages |
| `state/wa-poll.offered` `state/wa-poll.error` | the announced pending set, and the deduped fault report |
