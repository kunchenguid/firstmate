# Lavish

Lavish is firstmate's durable decision inbox.
It stores complete requests and answers under `$FM_HOME/data/decisions/` and uses short-lived terminal commands only.

There is no server, browser, URL, listener, poll, watcher, idle timeout, or resident process.
An unanswered request remains answerable until the files are deliberately removed.

## Human commands

The captain-facing command contract is owned by the [`lavish-decisions` skill](../../.agents/skills/lavish-decisions/SKILL.md).
`lavish-axi create` follows that contract by printing an answer command with the resolved absolute home path.
For direct human use, pass the same explicit home to every command, replacing this example path with the fleet home's resolved absolute path:

```sh
lavish inbox --home '/Users/example/firstmate-home'
lavish show <decision-id> --home '/Users/example/firstmate-home'
lavish answer <decision-id> --home '/Users/example/firstmate-home'
```

`lavish answer` renders the complete request, collects one numbered choice for every ordered question, accepts an optional note, shows the whole batch, and requires one explicit confirmation.
It validates everything before atomically renaming a same-directory temporary file to `answer.toon`.
It then queues a redundant wake pointer and exits without waiting for firstmate.

If wake enqueueing fails, the durable answer remains authoritative.
The command prints `answer saved; wake not queued`, exits nonzero, and the next ordinary intake scan recovers it.

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
    ]
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
  --destination data/deployment-policy/captain-answer.toon
```

`request.md` must contain the complete context, recommendation, alternatives, consequences, and next actions.
`create` computes its digest, validates the ordered question set, and writes the request plus `manifest.toon`.

At firstmate's existing wake and session-start boundaries:

```sh
lavish-axi intake
```

Intake validates every unreceipted answer, writes the declared destination first, then writes `receipt.toon`.
An existing matching destination or receipt is an idempotent success.
A conflicting destination fails closed.

All commands require either `FM_HOME` or an explicit `--home <path>` and never guess a fleet home.
Firstmate's internal commands use `FM_HOME`; captain-facing commands carry the resolved absolute `--home` path.
Tests and recovery tools may also pass `--home <path>` explicitly.
The firstmate bootstrap install command also records the checkout's narrow wake adapter with `lavish-axi configure-wake`; this local pointer is not inherited into other homes.

## Protocol

The protocol has schema version `1`.
TOON's strict decoder validates every encoded array count before Lavish applies the schema rules below.

`manifest.toon` contains:

- `kind: lavish-decision-manifest`
- `schema_version`, stable `decision_id`, `title`, and `created_at`
- an `$FM_HOME`-relative durable `destination`
- `expected_count` and the ordered `questions` array
- each question's nonempty unique key and ordered nonempty options
- `request_sha256`, formatted as `sha256:<hex>`
- optional `legacy_source` provenance for migration-created records

`answer.toon` contains:

- `kind: lavish-decision-answer`
- `schema_version`, `decision_id`, `request_sha256`, and `submitted_at`
- exactly one ordered answer for every expected question key
- each selected option value and label
- an optional note

`receipt.toon` contains:

- `kind: lavish-decision-receipt`
- `schema_version`, `decision_id`, `answer_sha256`, and `consumed_at`
- the declared destination and its content digest

The initial `answer.toon` is write-once.
Later revisions require a future numbered-revision protocol and are not part of schema version `1`.

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
