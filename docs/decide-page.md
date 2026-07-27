# Decide page

`bin/fm-decide-page.sh` generates a self-contained local HTML page for batch captain decision collection.
The captain opens one URL, reads each decision with its evidence and recommendation, selects an option, and submits all choices at once.
Firstmate is notified through the watcher check mechanism and routes each choice to its waiting task.

## Input JSON schema

The script accepts a single JSON file.
The file must be valid JSON and must satisfy the constraints below; the script refuses invalid input rather than generating a partial page.

```json
{
  "decisions": [
    {
      "key": "deploy-strategy",
      "title": "Deployment strategy for the billing service",
      "context": "Full evidence and context the captain needs to decide.",
      "options": [
        {
          "id": "blue-green",
          "label": "Blue-green deployment",
          "description": "Zero-downtime swap; requires 2x capacity briefly"
        },
        {
          "id": "rolling",
          "label": "Rolling update",
          "description": "Gradual rollout; simpler, brief mixed-version window"
        }
      ],
      "recommendation": "blue-green"
    }
  ]
}
```

Field constraints:

| Field | Type | Rule |
|---|---|---|
| `decisions` | array | Non-empty; all keys must be unique. |
| `decisions[i].key` | string | Non-empty slug matching `[A-Za-z0-9._-]+`. |
| `decisions[i].title` | string | Non-empty. |
| `decisions[i].context` | string | Non-empty. |
| `decisions[i].options` | array | At least 2 items; all `id` values must be unique within the decision. |
| `decisions[i].options[j].id` | string | Non-empty slug matching `[A-Za-z0-9._-]+`. |
| `decisions[i].options[j].label` | string | Non-empty. |
| `decisions[i].options[j].description` | string | Optional. |
| `decisions[i].recommendation` | string | Optional; if present, must be a valid `options[j].id`. |

## Submission format

The captain submits all choices in a single POST.
Each choice is validated against the declared options for that decision key.
Unknown keys and missing keys are rejected with a 400 response.

Per-choice response record written to `state/decide-<run-id>/responses/<key>.json`:

```json
{
  "key": "deploy-strategy",
  "choice": "blue-green",
  "note": "Optional captain note",
  "timestamp": "2026-07-27T10:00:00+00:00",
  "run_id": "decide-1753609200-a1b2c3d4"
}
```

## Watcher integration

`fm-decide-page.sh` writes `state/decide.check.sh` and registers it with `bin/fm-check-register.sh`.
The check script runs on the watcher's `CHECK_INTERVAL` cadence (default 300 seconds) and prints one line when any decide run has a `ready` marker without a `processed` marker:

```
responses-ready: decide-<run-id>
```

The watcher surfaces this as:

```
check: /path/to/state/decide.check.sh: responses-ready: decide-<run-id>
```

Firstmate reads the responses, routes each choice, and writes `state/decide-<run-id>/processed` when done.
The check is then silent for that run.

`state/decide.check.sh` and `state/decide.check-trust` are permanent house-level artifacts.
Re-running `fm-decide-page.sh` re-writes the same bytes and re-registers idempotently.

## Security properties

- Server listens on `127.0.0.1` only; never on all interfaces.
- Port is OS-assigned at runtime; no fixed port is used.
- A per-run one-time secret is required in every submission; submissions without it receive a 403.
- Only decision keys declared in the input JSON are accepted; unknown keys receive a 400.
- The server self-terminates after one valid complete submission or when the timeout elapses (default 1800 seconds, overridden by `FM_DECIDE_TIMEOUT` or `--timeout`).
- The page carries the run secret as an anti-CSRF token in a hidden form field; it is served only to `127.0.0.1` clients and is discarded when the server exits.
- The secret is passed to the server process through the `FM_DECIDE_SECRET` environment variable, never as a command-line argument, so it is not visible in `ps`.
- The page embeds no absolute path and no external resource; all CSS and JavaScript are inline.

## Run state layout

```
state/
  decide.check.sh          house-level watcher check (always same bytes)
  decide.check-trust       registration binding for the check
  decide-<run-id>/
    port                   TCP port the server is listening on (kept until firstmate removes the run directory)
    server.py              embedded Python server for this run
    ready                  written when submission is accepted; ISO-8601 timestamp
    processed              written by firstmate after routing choices
    responses/
      <key>.json           one file per decision key
```

## Verification entry point

See `tests/fm-decide-page.test.sh` for the behavior test suite.
It covers input validation, secret enforcement, unknown-key rejection, valid-submission recording, and the check-script output contract.
