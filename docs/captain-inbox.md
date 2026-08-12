# Captain's Inbox

Captain's Inbox is an opt-in local record of completed captain-facing responses from a primary Pi or pi-signed session.
It is disabled unless the Firstmate home's private `config/captain-inbox` file contains `on`.
[`configuration.md`](configuration.md#captains-inbox-capture-configcaptain-inbox) owns activation and home resolution.

## Capture boundary

The tracked Pi extension captures a finalized visible assistant text response only after Pi reports that its logical agent run has settled.
A capture candidate must have the `assistant` role, `stop` reason, and nonblank text content, and its trimmed text must not equal the exact routine no-action acknowledgement `Captain, shipshape.`.
The input source is not a capture criterion because Pi does not associate an `input` event with the later logical agent run, so a Firstmate operational envelope may initiate a capture-eligible substantive response without a FIFO input-state queue.
This excludes user prompts, including Firstmate operational envelopes themselves, tool calls and results, thinking blocks, incomplete or tool-using assistant messages, custom extension entries that are not assistant responses, and the exact routine acknowledgement above.
The extension requires both the primary session lock and an unmarked primary home, so a Pi worker or secondmate cannot write this inbox even when it shares project code.
Capture never reads terminal scrollback, session transcripts, screen output, or input text after Pi has accepted it.
Capture is local-only and sends no network request.
Persistence is asynchronous from Pi's `agent_settled` callback, so it does not delay the existing turn-end supervision extension.

## Dashboard interface v1

Use the narrow command interface rather than opening arbitrary paths:

```sh
FM_HOME=<firstmate-home> bin/fm-captain-inbox.sh list
FM_HOME=<firstmate-home> bin/fm-captain-inbox.sh mark <ci_v1_message_id> read
FM_HOME=<firstmate-home> bin/fm-captain-inbox.sh mark <ci_v1_message_id> unread
```

The command accepts no file-path argument.
`list` prints one JSON document with this stable v1 shape:

```json
{
  "version": 1,
  "messages": [
    {
      "id": "ci_v1_<32 lowercase hex characters>",
      "completed_at": "2026-08-01T12:34:56.789Z",
      "body": "Plain assistant response text",
      "source": {"harness": "pi", "session_id": "Pi session identifier"},
      "read": false
    }
  ]
}
```

Messages are ordered newest first.
`mark` prints `{ "version": 1, "id": "...", "read": true|false }` only after the requested state is durably replaced.
The message ID, completion timestamp, body, harness, and session identifier are immutable capture data.
Read state is stored independently and is the only consumer-mutable field.

`body` is plain response text, not HTML or a template.
A dashboard must render it as text, for example through a text node or `textContent`, and must never pass it to an HTML interpreter.

## Storage and safety

The producer keeps versioned private records beneath `state/captain-inbox/v1/` in the effective Firstmate home.
It creates private directories at mode `0700` and JSON records at mode `0600` where the platform supports POSIX modes.
Each replacement is written to a unique temporary file and atomically renamed.
A short private lock serializes capture, list snapshots, retention, and read-state updates, so concurrent dashboard updates cannot lose another update.
Malformed, linked, or unsafe records are rejected without overwriting the existing content.

Duplicate completed-message events resolve to the same stable ID and do not create another record or reset its read state.
The inbox retains the newest 100 messages and removes the corresponding obsolete read-state entries in the same serialized update.
The command returns an error for a disabled inbox, malformed storage, unknown message ID, or a contended update instead of guessing.

## Support matrix

| Surface | Status | Reason |
| --- | --- | --- |
| Pi | Supported | The project-local extension receives finalized `message_end` events and the reliable `agent_settled` completion boundary. |
| pi-signed | Supported | It has the same Pi event API while retaining its distinct harness identity in the captured source. |
| Claude, Codex, OpenCode, Grok, and Kimi | Unsupported | Their current primary integrations do not provide an equivalent reliable completed captain-facing assistant-message event. |
| Muse | Unsupported | Muse is not a supported primary Firstmate surface. |
| tmux, Herdr, Zellij, Orca, and cmux | Supported with Pi or pi-signed | Capture uses Pi's in-process event and the private Firstmate home, not terminal rendering or runtime screen capture. |

Unsupported surfaces intentionally do not fall back to transcript parsing, terminal scraping, or screen capture.

## Verification

Run the deterministic contract and Pi type checks with:

```sh
bin/fm-test-run.sh tests/fm-captain-inbox.test.sh
bin/fm-test-run.sh tests/fm-pi-primary-types.test.sh
```

[`verification/supervision.md`](verification/supervision.md) records the maintained Pi-extension verification entry point.
