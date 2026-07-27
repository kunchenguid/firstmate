---
name: decide
description: >-
  Captain-invocable skill to batch-surface open decisions via a local page.
  Load when the captain invokes /decide to collect and route pending choices.
user-invocable: true
metadata:
  internal: true
---

# decide

Surface all open captain decisions as a single local page so the captain can read each decision's evidence and recommendation, select one option per decision, and submit all choices at once.
Firstmate is notified when choices arrive and routes each one to its waiting task.

## When to load

Load this skill when:

- The captain invokes `/decide` explicitly.
- Multiple ask-user or captain-gated decisions are open and the captain prefers to resolve them in a single review rather than one by one in chat.

## Procedure

### 1. Inventory open decisions

Collect every pending captain decision that is waiting for a choice.
Sources:

- `tasks-axi` captain-kind items whose status is not Done: run `tasks-axi list --kind captain --state held` and read each item's full body with `tasks-axi show <id> --full`.
- Any ask-user findings from an active no-mistakes validation that have surfaced with `needs-decision:` and are logged in the relevant task's status file.

Each decision needs these fields for the input JSON:

- `key` - a stable slug you assign, matching `[A-Za-z0-9._-]+`.
- `title` - a human-readable title (one short sentence).
- `context` - the full evidence, constraint, and background the captain needs to choose.
  Summarize the crewmate's report or the ask-user finding faithfully; do not truncate material evidence.
- `options` - at least two options, each with an `id` slug and a `label`.
  Add `description` when the label alone is not self-explanatory.
- `recommendation` - the option `id` firstmate recommends, or omit if genuinely neutral.

If a pending decision cannot be translated into this structure (for example, it requires a free-form answer or the options space is unbounded), handle it separately in plain chat and exclude it from the batch page.

### 2. Write the input JSON

Write the collected decisions to a temporary file, for example under `data/` or a temp path:

```sh
cat > /tmp/decide-input.json <<'JSON'
{
  "decisions": [
    {
      "key": "deploy-strategy",
      "title": "Deployment strategy for the billing service",
      "context": "The billing service currently deploys with a rolling update...",
      "options": [
        {"id": "blue-green",  "label": "Blue-green",   "description": "Zero-downtime swap; needs 2x capacity briefly"},
        {"id": "rolling",     "label": "Rolling update","description": "Gradual; simpler, small window of mixed versions"}
      ],
      "recommendation": "blue-green"
    }
  ]
}
JSON
```

### 3. Generate the page

Run `bin/fm-decide-page.sh` with the input file.
The script validates the JSON, starts a local HTTP server on `127.0.0.1`, writes a run directory under `state/`, and arms the watcher check.

```sh
bin/fm-decide-page.sh [--timeout SECONDS] /tmp/decide-input.json
```

The script prints the URL and exits; the server continues as a background process and self-terminates after the captain submits or the timeout elapses.

### 4. Give the captain the URL

Tell the captain the URL in plain English.
Example: "Captain, all three pending decisions are ready at http://127.0.0.1:PORT/ - open it in a browser, review each one, and submit your choices."
Do not surface the run ID, the secret, the port number separately, or any internal path.

Resume fleet supervision while waiting; the watcher notifies firstmate when choices arrive.

### 5. Handle the wake

The watcher wakes firstmate with a reason line like:

```
check: /path/to/state/decide.check.sh: responses-ready: decide-<run-id>
```

When this arrives:

1. Drain the wake queue as normal (section 8).
2. Identify the run ID from the reason line.
3. Read each response file from `state/decide-<run-id>/responses/<key>.json`.
   Each file has: `key`, `choice`, `note`, `timestamp`, `run_id`.
4. For each key, match it back to the pending decision it came from and route the choice to its destination.

### 6. Route each choice

Routing depends on the decision's origin:

- **ask-user finding in an active no-mistakes validation**: feed the decision to the gate with `no-mistakes axi respond` exactly as section 7 describes; send the worker the decision key, action, and response command.
- **captain-kind backlog hold**: use `fm-decision-hold.sh resolve` with the choice and the routed task IDs; section 7 owns the exact command.
- **in-progress task requiring a choice**: steer the worker with `fm-send` carrying the decision.

If the captain left a note for a decision, include it verbatim in the routing message so the worker or pipeline receives it.

### 7. Mark the run processed

After routing all choices, write the processed marker so the check does not re-fire:

```sh
touch state/decide-<run-id>/processed
```

### 8. Confirm to the captain

Once all choices are routed, give the captain a brief summary: which choices were made and where they were sent.
Do not expose internal run IDs or file paths in captain-facing chat (section 9 translation rule).

## Security notes

- The page and server are local only; no choice or evidence leaves `127.0.0.1`.
- The one-time secret is generated per run and never logged to the status file or backlog.
- The server self-terminates; no background process remains after all choices are received or the timeout elapses.
- If the server is still running when firstmate wakes, the ready marker is already written; firstmate can safely read responses and mark processed regardless of server state.

## Failure modes

- **Captain closes browser without submitting**: the server times out and terminates without writing `ready`.
  The check will not fire.
  In the next supervision turn, tell the captain the page has expired and ask whether to open a new one.
- **Input JSON is invalid**: `fm-decide-page.sh` exits with an error before starting the server.
  Fix the input and retry.
- **jq/python3 not found**: `fm-decide-page.sh` reports the missing tool; install it and retry.
- **A decision key cannot be matched after routing**: report the unmatched key to the captain with its choice and note, and ask where to send it.
