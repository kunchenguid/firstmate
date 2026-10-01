# Local browser inbox

A local dashboard may append one JSON object per line to `state/.inbox`.
The dashboard writes `state/.inbox` with the same local trust as the captain's own session; any process that can append there can already edit the firstmate home.
Firstmate owns only its read cursor (`state/.inbox.seen`) and reply stream (`state/.outbox`); the dashboard owns the incoming append and reads the replies.
This keeps the watcher from draining a queue owned by another process.

The watcher checks for complete newline-terminated records and adds one `check` wake while unread records exist.
It does not advance the cursor.
`bin/fm-web-inbox.sh drain` returns pending records in file order with their ending byte offsets.
Handle the first record, publish a correlated response if it is valid, then acknowledge that record with its exact id and offset.
Retries of the same reply are idempotent; a different second reply is refused.
An unterminated final fragment stays pending only after its newline arrives.

Incoming rows use the shared bridge shape:

```json
{"id":"…","ts":"…","channel":"typed","text":"…"}
```

`channel` may be `typed`, `voice`, or `click`.
A click approval includes `ref.task` and the reviewed `ref.sha`; typed or voice text never grants merge consent.
An approval counts only for a task that is still an open captain call, so a click cannot grant consent that was never asked for.
Firstmate records it with `bin/fm-captain-hold.sh answer <task> --decision-file <file> --release` and then applies it only with `bin/fm-merge-local.sh <task> --expect <sha>`, which refuses a moved branch.
Replies append `{id, ts, kind, text, in_reply_to}` to `.outbox`.
The supported reply kinds are `answer`, `proposal`, `ready`, `decision`, `blocked`, and `fyi`.

The bridge polls the two streams, so no browser-specific process or API server runs in the firstmate home.
See the `local browser inbox` wake rule in `AGENTS.md` for the handling and acknowledgement procedure.
