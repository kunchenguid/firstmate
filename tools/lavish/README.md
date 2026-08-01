# Lavish

Lavish is firstmate's durable decision inbox.
It stores complete requests and answers under a Firstmate home and uses bounded commands that exit after each local operation.

The fork runs no server, listener, poller, watcher, idle timeout, or resident process.
It can emit a self-contained browser board, but opening and supervising that file belongs to Firstmate glue outside the fork.
An unanswered request remains answerable until the files are deliberately removed.

## Human commands

```sh
lavish inbox
lavish show <decision-id>
lavish answer <decision-id>
lavish board <decision-id> --out <board.html>
```

`lavish answer` renders the complete request, collects one numbered choice for every ordered question, accepts an optional note, shows the whole batch, and requires one explicit confirmation.
It validates everything before atomically renaming a same-directory temporary file to `answer.toon`.
It then queues a redundant wake pointer and exits without waiting for firstmate.

If wake enqueueing fails, the durable answer remains authoritative.
The command prints `answer saved; wake not queued`, exits nonzero, and the next ordinary intake scan recovers it.

`lavish board` renders the complete Markdown request, ordered questions and options, inline visual evidence, per-option comments, per-question notes, a final review, and a submit step into one HTML file.
The HTML includes its CSS, JavaScript, and images and makes no request to a shared board service.
Its dark default theme inlines the vendored Relvino tokens from `src/relvino-tokens.css`, including Inter, Ruby green, `#007AFF` actions, the semantic aliases, and the 16px card radius.

Submitting the page assigns the complete JSON batch to `window.__lavishPayload` and sets `document.title` to `LAVISH-SUBMIT v2`.
Those browser signals are transport only and do not write an answer until `lavish-axi collect` validates the payload.

Every command accepts `--home <path>`.
A captain command run from a shell that does not export `FM_HOME` must include that option, while `bin/fm-lavish-board.sh` resolves its Firstmate home and supplies the option itself.

## Agent commands

Create a complete Markdown request and a JSON question definition:

```json
[
  {
    "key": "deployment",
    "prompt": "Which deployment policy should we adopt?",
    "options": [
      {"value": "a", "label": "Adopt policy A"},
      {"value": "b", "label": "Adopt policy B"}
    ],
    "visuals": ["deployment-overview.png"]
  }
]
```

Then create the durable decision:

```sh
lavish-axi create \
  --id deployment-policy \
  --title "Deployment policy" \
  --request /path/to/request.md \
  --questions /path/to/questions.json \
  --visuals /path/to/evidence \
  --destination data/deployment-policy/captain-answer.toon
```

`request.md` must contain the complete context, recommendation, alternatives, consequences, and next actions.
`create` computes its digest, validates the ordered question set, copies supported PNG, JPEG, GIF, and WebP files into the decision's `visuals/` directory, records their digests in the manifest, and writes the complete decision atomically.
Question `visuals` entries name files from that copied directory and place the evidence beside that question on the board.
For existing schema-version-1 manifests, `board` also discovers supported regular image files already present in the conventional `visuals/` directory and renders them with the request context.
Copied visual batches are limited to 64 files and 50 MiB total so rendering remains bounded.

Collect a payload captured from a browser board without driving the interactive terminal flow:

```sh
lavish-axi collect deployment-policy \
  --payload /absolute/path/to/payload.json \
  --home /absolute/path/to/firstmate-home
```

The payload shape is:

```json
{
  "schema_version": 2,
  "decision_id": "deployment-policy",
  "request_sha256": "sha256:...",
  "answers": [
    {
      "key": "deployment",
      "value": "a",
      "question_note": "This applies to the whole policy choice.",
      "option_comments": {
        "a": "Keep the rollback guard.",
        "b": "This is too risky today."
      }
    }
  ],
  "note": "Optional note on the complete batch."
}
```

`collect` validates the decision id, exact request hash, answer count, complete question-key set, selected values, and every annotated option value against the immutable manifest.
It derives labels from the manifest, writes the same atomic `answer.toon` that `lavish answer` writes, queues the same wake record, and exits.
Count drift, unknown keys, unknown values, and stale request hashes fail closed with named errors.

At firstmate's existing wake and session-start boundaries:

```sh
lavish-axi intake
```

Intake validates every unreceipted answer, writes the declared destination first, then writes `receipt.toon`.
An existing matching destination or receipt is an idempotent success.
A conflicting destination fails closed.

Commands use `FM_HOME` when it is set and otherwise require `--home <path>`.
Tests, browser glue, recovery tools, and captain-shell commands should pass `--home <path>` explicitly.
The firstmate bootstrap install command also records the checkout's narrow wake adapter with `lavish-axi configure-wake`; this local pointer is not inherited into other homes.

## Protocol

Manifest and receipt records use protocol schema version `1`.
New answer records use schema version `2`, and readers continue to accept existing schema version `1` answers.
TOON's strict decoder validates every encoded array count before Lavish applies the schema rules below.

`manifest.toon` contains:

- `kind: lavish-decision-manifest`
- `schema_version`, stable `decision_id`, `title`, and `created_at`
- an `$FM_HOME`-relative durable `destination`
- `expected_count` and the ordered `questions` array
- each question's nonempty unique key and ordered nonempty options
- optional copied visual metadata and question-level visual filename references
- `request_sha256`, formatted as `sha256:<hex>`
- optional `legacy_source` provenance for migration-created records

`answer.toon` contains:

- `kind: lavish-decision-answer`
- `schema_version`, `decision_id`, `request_sha256`, and `submitted_at`
- exactly one ordered answer for every expected question key
- each selected option value and label
- a question note and option comments keyed by option value for every answer in schema version `2`
- an optional note

`receipt.toon` contains:

- `kind: lavish-decision-receipt`
- `schema_version`, `decision_id`, `answer_sha256`, and `consumed_at`
- the declared destination and its content digest

The initial `answer.toon` is write-once.
Later revisions require a future numbered-revision protocol and are not part of answer schema version `2`.

## Legacy migration

Migration is explicit and source-preserving:

```sh
lavish-axi migrate-legacy \
  --state ~/.lavish-axi/state.json \
  --snapshot-dir /durable/audit/location \
  --pending-map /path/to/reconciled-pending-decisions.json
```

The command first snapshots the complete source state and never edits or deletes it.
It imports every queued legacy prompt into a durable answered decision record.
It creates unanswered replacements only for entries explicitly named by the reconciled pending map.
It never treats an upstream session's `open` status as a work queue.

The pending map is a JSON array whose entries contain `session_key`, `decision_id`, `title`, `destination`, `request_md`, and `questions` in the same shape accepted by `create`.
