# Inbox

The captain queues a note for Firstmate while Firstmate is mid-turn, then later sees that note waiting without interrupting the fleet.

## Sub-features

- `note` - write a durable inbox record and append one `check` wake
- `list` - print pending note ids and bodies
- `status` - read-only home, inbox count, and in-flight backlog view with no wake
- `drain-ack` - move a named note to `state/inbox/handled/`

## How to get to it (user POV)

- Run `bin/fm-inbox.sh note <text>` from a shell that can reach the home
- Run `bin/fm-inbox.sh note -` and pass the body on stdin
- Run `bin/fm-inbox.sh status` to see pending notes without waking Firstmate
- Run `bin/fm-inbox.sh list` or `bin/fm-inbox.sh drain --ack <id>` to inspect or acknowledge
- Spoken `say` and side-question `ask` stay off until `config/inbox-region` and the matching model files exist

## Driving it with bin/fm-inbox.sh

Preconditions: scratch home launched and doctor-passed; `FM_HOME` exported to that home; no inbox AWS config required for `note`, `list`, `status`, or `drain`.

- Queue a note: run `bin/fm-inbox.sh note verify-firstmate seeded note` and observe `queued <id>` plus `firstmate will pick this up at its next check.`
- See the record: run `bin/fm-inbox.sh list` and observe that `<id>` and the body `verify-firstmate seeded note`.
- See the side effect: run `bin/fm-inbox.sh status` and observe `inbox    1 note(s) waiting for firstmate` and `home` equal to `$FM_HOME`.
- Confirm the wake stayed in this home: `test -f "$FM_HOME/state/inbox/<id>.note"` and that the live code-root `state/inbox/` was not created.

## Gotchas

`note` appends a wake on this `FM_HOME` only; a wrong `FM_HOME` wakes the live session.

`say` and `ask` send audio or text to Bedrock and refuse until the home's inbox config files exist.

`status` never appends a wake and is safe to re-run.
