# Lavish

Lavish is firstmate's durable decision inbox.
It stores complete requests and answers under `$FM_HOME/data/decisions/`, and its authoritative store-and-forward operations are bounded local commands.

The core file protocol has no server, URL, listener, long poll, idle timeout, or resident process.
The optional Firstmate board wrapper opens a bounded dedicated Chrome profile and arms one ordinary watcher check; the durable request and answer files remain authoritative.
An unanswered request remains answerable until the files are deliberately removed.

## Human commands

The captain-facing command contract is owned by the [`lavish-decisions` skill](../../.agents/skills/lavish-decisions/SKILL.md).
`lavish-axi create` follows that contract by printing an answer command with the resolved absolute home path.
For direct human use, pass the same explicit home to every command, replacing this example path with the fleet home's resolved absolute path:

```sh
lavish inbox --home '/Users/example/firstmate-home'
lavish show <decision-id> --home '/Users/example/firstmate-home'
lavish answer <decision-id> --home '/Users/example/firstmate-home'
bin/fm-lavish-board.sh <decision-id> --home '/Users/example/firstmate-home'
```

`lavish answer` renders the complete request, collects one numbered choice for every ordered question, accepts an optional note, shows the whole batch, and requires one explicit confirmation.
It validates everything before atomically renaming a same-directory temporary file to `answer.toon`.
It then queues a redundant wake pointer and exits without waiting for firstmate.

If wake enqueueing fails, the durable answer remains authoritative.
The command prints `answer saved; wake not queued`, exits nonzero, and the next ordinary intake scan recovers it.

`bin/fm-lavish-board.sh` owns the dedicated Chrome-profile launch, fail-closed answerability preflight, and bounded pickup integration around the generated file.
`bin/fm-lavish-board.sh` renders the same immutable request into self-contained HTML and opens it with a decision-specific Chrome profile below the effective state root (`FM_STATE_OVERRIDE` or `$FM_HOME/state`).
Submit first writes and reads back a browser-profile record, then shows a confirmation describing that durable record; the optional browser download is not treated as confirmed delivery.
Both records carry the resolved absolute Firstmate home as `home_marker`, so a shared Downloads directory cannot route one home's answer into another home.
The armed check recovers the record from the same profile even after the visible browser closes, validates it through `lavish-axi collect`, and runs intake.
After an answer is committed, the Firstmate wake adapter appends the durable wake pointer and may attempt visible prompt delivery only when the session lock proves a live supervisor route belongs to the same canonical `FM_HOME`.
It never falls back to ambient terminal state, and a visible prompt names the manifest's declared destination rather than assuming a conventional path.
If visible delivery is refused, the durable answer and wake pointer remain authoritative.
Read that script's header or `--help` output for its current mechanics; the [`lavish-decisions` skill](../../.agents/skills/lavish-decisions/SKILL.md) owns when to invoke it and when to use the terminal fallback.

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
To include visual evidence, pass a directory of PNG, JPEG, GIF, or WebP files with `--visuals` and reference copied filenames from a question's optional `visuals` array.
The self-contained board embeds those declared files with the questions that reference them.

To land a schema-version-2 payload produced by a board or recovered download:

```sh
lavish-axi collect <decision-id> --payload /path/to/payload.json --home '/Users/example/firstmate-home'
```

`collect` validates the complete payload against the immutable manifest, commits the write-once `answer.toon`, and then invokes the redundant wake path.

At firstmate's existing wake and session-start boundaries:

```sh
lavish-axi intake
```

Intake validates every unreceipted answer, writes the declared destination first, then writes `receipt.toon`.
An existing matching destination or receipt is an idempotent success.
A conflicting destination fails closed.
New manifests declare `destination_format`; `.json` destinations receive the schema-version-2 browser payload, while other destinations receive the authoritative TOON answer.
Field-less protocol-1 manifests infer that same contract from the destination extension, so a `.json` destination never receives TOON bytes.
Payload recovery scans the effective state root plus configured download locations as one batch.
An unreadable configured location fails the batch before any candidate is committed or any intake result is published.
New payloads route by `home_marker`; legacy unmarked downloads remain recoverable only in a home whose immutable decision id and request digest match.

All commands require either `FM_HOME` or an explicit `--home <path>` and never guess a fleet home.
Firstmate's internal commands use `FM_HOME`; captain-facing commands carry the resolved absolute `--home` path.
Tests and recovery tools may also pass `--home <path>` explicitly.
The firstmate bootstrap install command also records the checkout's narrow wake adapter with `lavish-axi configure-wake`; this local pointer is not inherited into other homes.

## Protocol

Manifest and receipt schema version `1` remain current; answers may be schema version `1` or annotation-capable schema version `2`.
TOON's strict decoder validates every encoded array count before Lavish applies the schema rules below.

`manifest.toon` contains:

- `kind: lavish-decision-manifest`
- `schema_version`, stable `decision_id`, `title`, and `created_at`
- an `$FM_HOME`-relative durable `destination` below `data/`
- optional `destination_format` (`answer-toon` or `payload-json-v2`); absence infers JSON payload output for `.json` destinations and TOON output otherwise
- `expected_count` and the ordered `questions` array
- each question's nonempty unique key, ordered nonempty options, and optional visual filename references
- optional visual metadata binding each copied file's media type, size, and digest
- `request_sha256`, formatted as `sha256:<hex>`
- optional `legacy_source` provenance for migration-created records

`answer.toon` contains:

- `kind: lavish-decision-answer`
- `schema_version`, `decision_id`, `request_sha256`, and `submitted_at`
- exactly one ordered answer for every expected question key
- each selected option value and label
- schema version `2` treats omitted annotations as empty; present question notes and the overall note must be strings, option comments must map declared option values to strings, and explicit `null` is invalid for any annotation field

Schema-version-2 browser and JSON-destination payloads also carry the resolved absolute `home_marker` used for fail-closed cross-home routing.

`receipt.toon` contains:

- `kind: lavish-decision-receipt`
- `schema_version`, `decision_id`, `answer_sha256`, and `consumed_at`
- the declared destination and its content digest

The initial `answer.toon` is write-once.
Later answer revisions require a future numbered-revision protocol and are not part of either accepted answer schema.

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
