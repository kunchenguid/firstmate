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

A decision comes in one of two modes, fixed at creation.
A `decision` asks the captain to choose between ordered options.
An `annotation` asks nothing: it presents ordered items and collects free text against each one plus an overall note.
Both use the same durable request, answer, receipt, wake, and intake path, so nothing downstream changes with the mode.

`lavish answer` renders the complete request, collects one numbered choice for every ordered question, or one optional comment for every ordered item, accepts an optional note, shows the whole batch, and requires one explicit confirmation.
It validates everything before atomically renaming a same-directory temporary file to `answer.toon`.
It then queues a redundant wake pointer and exits without waiting for firstmate.

If wake enqueueing fails, the durable answer remains authoritative.
The command prints `answer saved; wake not queued`, exits nonzero, and the next ordinary intake scan recovers it.

`bin/fm-lavish-board.sh` owns the dedicated Chrome-profile launch, fail-closed answerability preflight, and bounded pickup integration around the generated file.
`bin/fm-lavish-board.sh` renders the same immutable request into self-contained HTML and opens it with a decision-specific Chrome profile below the effective state root (`FM_STATE_OVERRIDE` or `$FM_HOME/state`).
The board form refuses to submit nothing, because `answer.toon` is write-once: a decision board requires a choice on every question, and an annotation board requires at least one item comment or the overall note.
That guard is the rendered form's alone; `collect` stays permissive, so a hand-recovered payload is never refused for it.
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

For an annotation board, define ordered items instead and pass `--items`:

```json
[
  {
    "key": "welcome-timing",
    "title": "Welcome message arrives twenty minutes after signup",
    "body": "A new shopper hears from the merchant within one minute today, which reads as automated."
  }
]
```

```sh
lavish-axi create \
  --id welcome-sequence-review \
  --title "Merchant welcome sequence" \
  --request /path/to/request.md \
  --items /path/to/items.json \
  --destination data/welcome-sequence-review/captain-notes.toon
```

Each item needs a unique lowercase-slug `key` and a plain-language `title`; `body` is optional Markdown rendered under the title.
`create` takes `--questions` or `--items`, never both and never neither.
An empty `--questions` array is refused with a pointer to `--items`, because a decision with nothing to ask is an annotation, not a decision with invented options.

`request.md` must assemble one or more complete captain-facing wrappers with no prose outside the item boundaries documented in [`fm-captain-item-check.sh`](../../bin/fm-captain-item-check.sh).
`create` snapshots the request once, requires that exact snapshot to clear request mode, and writes the same bytes plus `manifest.toon`.
Every `--items` body is checked the same way, in note mode, and refusals are numbered in declared order.
The source checkout runs its sibling checker directly; a globally installed CLI resolves the same checker beside the home-configured Firstmate wake adapter.
This permits an unaltered technical finding inside the documented verbatim block while keeping purpose, impact, and the decision in the checked wrapper.
The board renders the stored request with those item-boundary and verbatim marker lines removed, so the checking scaffolding never reaches the captain as literal text; the stored bytes the digest covers are unchanged.
To include visual evidence, pass a directory of PNG, JPEG, GIF, or WebP files with `--visuals` and reference copied filenames from a question's or item's optional `visuals` array.
The self-contained board embeds those declared files with the questions or items that reference them.

To land a schema-version-2 payload produced by a board or recovered download:

```sh
lavish-axi collect <decision-id> --payload /path/to/payload.json --home '/Users/example/firstmate-home'
```

`collect` validates the complete payload against the immutable manifest, commits the write-once `answer.toon`, and then invokes the redundant wake path.

At firstmate's existing wake and session-start boundaries, `bin/fm-lavish-intake.sh` runs:

```sh
LAVISH_SCAN_HOME_DOWNLOADS=0 lavish-axi intake --home "$FM_HOME"
```

The boundary adapter skips only implicit legacy recovery below the invoking user's Downloads directory, because that optional scan must not stall fleet supervision.
Authoritative answer intake and board payload recovery below the effective state root remain enabled.
Run `lavish-axi intake --home <path>` directly when legacy home-Downloads recovery is explicitly needed.

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
- optional `mode` (`decision` or `annotation`); absence means `decision`, so protocol-1 manifests written before annotation boards keep their original meaning
- `expected_count` plus the ordered `questions` array in decision mode, or the ordered `items` array in annotation mode; the unused array is empty and `expected_count` counts whichever is populated
- each question's nonempty unique key, ordered nonempty options, and optional visual filename references
- each item's nonempty unique key, plain-language title, possibly empty Markdown body, and optional visual filename references
- optional visual metadata binding each copied file's media type, size, and digest
- `request_sha256`, formatted as `sha256:<hex>`
- optional `legacy_source` provenance for migration-created records

`answer.toon` contains:

- `kind: lavish-decision-answer`
- `schema_version`, `decision_id`, `request_sha256`, and `submitted_at`
- in decision mode, exactly one ordered answer for every expected question key, carrying each selected option value and label
- in annotation mode, exactly one ordered `annotations` entry for every expected item key, carrying that item's possibly empty note; an item the captain read and had nothing to say about stays present with an empty note rather than being dropped
- an overall `note`
- schema version `2` treats omitted annotations as empty; present question notes, item notes, and the overall note must be strings, option comments must map declared option values to strings, and explicit `null` is invalid for any annotation field
- annotation answers are schema version `2` only, because annotations did not exist in version `1`

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
